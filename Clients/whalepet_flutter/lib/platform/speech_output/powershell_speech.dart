import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/voice/speech_output.dart';

/// Windows 系统 TTS 适配层。
///
/// 实现选择（§7.5、§10.3「系统 TTS 可使用 Windows 语音合成 API」）：
///   - 起一个**常驻** PowerShell 子进程，加载 `System.Speech`（SAPI 5），
///     逐条朗读 —— 只在 Windows 自带 .NET Framework 上运行，不需要额外安装语音包；
///   - 文本不走 stdin（中文在 OEM 代码页 936 下会被转码搞坏），而是写到 UTF-8 临时文件，
///     stdin 只传纯 ASCII 的 JSON，彻底绕开编码问题；
///   - stdout 只回 `START <id>` / `END <id>` / `ERR <msg>` 三种 ASCII 标记，
///     用来驱动宠物的 speaking 状态与「说完再恢复」。
///
/// 第一版不支持播报中打断（barge-in），停止 = 丢弃后续队列（§7.8）。
class PowerShellSpeechOutput implements SpeechOutputAdapter {
  PowerShellSpeechOutput({this.powerShellPath = 'powershell.exe'});

  /// PowerShell 路径（留出给测试/换 pwsh 的口子）。
  final String powerShellPath;

  final StreamController<SpeechOutputEvent> _events =
      StreamController<SpeechOutputEvent>.broadcast();
  final Map<String, Completer<void>> _pending = <String, Completer<void>>{};

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Timer? _readyTimeout;
  bool _ready = false;
  bool _disposed = false;
  Directory? _workDir;
  int _counter = 0;
  int _commandSeq = 0;
  String? _currentUtteranceId;

  static const String _script = r'''$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$synth = [System.Speech.Synthesis.SpeechSynthesizer]::new()
$synth.Rate = 0
Write-Output 'READY'
[Console]::Out.Flush()
$commandDir = $PSScriptRoot
$seq = 1
$script:quit = $false
# Commands come from numbered files, not stdin: on Windows only the first line
# written to a resident process Console.In is ever observed.
while (-not $script:quit) {
  $path = Join-Path $commandDir ("cmd-{0:D6}.json" -f $seq)
  if (-not (Test-Path -LiteralPath $path)) {
    Start-Sleep -Milliseconds 80
    continue
  }
  $raw = ''
  try {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::Delete($path)
  } catch { $raw = '' }
  $seq++
  if ($raw -eq '') { continue }
  try {
    $msg = $raw | ConvertFrom-Json
    if ($msg.cmd -eq 'quit') {
      $script:quit = $true
      continue
    }
    $id = [string]$msg.id
    $textPath = [string]$msg.path
    $text = [System.IO.File]::ReadAllText($textPath, [System.Text.Encoding]::UTF8)
    if ($text.Trim().Length -eq 0) {
      Write-Output ('END ' + $id)
      [Console]::Out.Flush()
      continue
    }
    Write-Output ('START ' + $id)
    [Console]::Out.Flush()
    $synth.Speak($text)
    Write-Output ('END ' + $id)
    [Console]::Out.Flush()
  } catch {
    Write-Output ('ERR ' + [string]$_.Exception.Message)
    [Console]::Out.Flush()
  }
}
try { $synth.Dispose() } catch {}
''';

  @override
  Stream<SpeechOutputEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    if (_disposed) throw StateError('已经释放');
    if (!Platform.isWindows) {
      throw UnsupportedError('PowerShellSpeechOutput 只能在 Windows 上使用');
    }
    _workDir = await Directory.systemTemp.createTemp('whalepet-tts-');
    final File scriptFile = File('${_workDir!.path}${Platform.pathSeparator}speak.ps1');
    await scriptFile.writeAsString(
      _script.replaceAll('\n', '\r\n'),
      flush: true,
    );

    final Process process = await Process.start(
      powerShellPath,
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptFile.path,
      ],
      runInShell: false,
    );
    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStdout, onError: (Object _) {});
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String _) {});
    unawaited(process.exitCode.then((int code) {
      _ready = false;
      _failAllPending('TTS 进程退出（code=$code）');
    }));

    final Completer<void> ready = Completer<void>();
    _readyCompleter = ready;
    _readyTimeout = Timer(const Duration(seconds: 15), () {
      if (!ready.isCompleted) {
        ready.completeError(StateError('TTS 引擎启动超时（System.Speech 可能不可用）'));
      }
    });
    await ready.future;
    _readyTimeout?.cancel();
  }

  Completer<void>? _readyCompleter;

  void _onStdout(String line) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) return;
    if (trimmed == 'READY') {
      _ready = true;
      final Completer<void>? completer = _readyCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
      return;
    }
    if (trimmed.startsWith('START ')) {
      final String id = trimmed.substring(6).trim();
      _currentUtteranceId = id;
      _emit(SpeechOutputEvent(
        kind: SpeechOutputEventKind.started,
        utteranceId: id,
      ));
      return;
    }
    if (trimmed.startsWith('END ')) {
      final String id = trimmed.substring(4).trim();
      _currentUtteranceId = null;
      _emit(SpeechOutputEvent(
        kind: SpeechOutputEventKind.finished,
        utteranceId: id,
      ));
      _complete(id);
      return;
    }
    if (trimmed.startsWith('ERR ')) {
      final String rest = trimmed.substring(4).trim();
      // `ERR <id> <msg>` 或 `ERR <msg>`（脚本 catch 分支）
      final int space = rest.indexOf(' ');
      final String id = space > 0 ? rest.substring(0, space) : (_currentUtteranceId ?? '');
      final String message = space > 0 ? rest.substring(space + 1) : rest;
      _currentUtteranceId = null;
      _emit(SpeechOutputEvent(
        kind: SpeechOutputEventKind.failed,
        utteranceId: id,
        message: message,
      ));
      if (id.isNotEmpty) _complete(id);
    }
  }

  void _emit(SpeechOutputEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _complete(String id) {
    final Completer<void>? completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _failAllPending(String message) {
    final List<Completer<void>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<void> completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(message));
      }
    }
  }

  @override
  Future<void> speak(String utteranceId, String text) async {
    if (_disposed) return;
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!_ready || _process == null) {
      throw StateError('TTS 引擎还没就绪');
    }
    final Directory dir = _workDir!;
    _counter++;
    final String fileName = 'utt-$_counter.txt';
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(trimmed, flush: true, encoding: utf8);

    final Completer<void> completer = Completer<void>();
    _pending[utteranceId] = completer;
    await _sendCommand(<String, dynamic>{
      'cmd': 'speak',
      'id': utteranceId,
      'path': file.path,
    });

    try {
      await completer.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      _pending.remove(utteranceId);
      throw StateError('播报超时');
    } finally {
      // 单条用完就删，避免临时目录越堆越大。
      unawaited(file.delete().then((_) {}, onError: (Object _) {}));
    }
  }

  /// 写一条播报命令（编号文件 + 原子 rename，保序且不会被 stdin 吞掉）。
  Future<void> _sendCommand(Map<String, dynamic> message) async {
    final Directory? dir = _workDir;
    if (dir == null) return;
    _commandSeq++;
    final String name =
        'cmd-${_commandSeq.toString().padLeft(6, '0')}.json';
    final File target = File('${dir.path}${Platform.pathSeparator}$name');
    final File temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(message), flush: true);
    await temp.rename(target.path);
  }

  @override
  Future<void> stop() async {
    final List<Completer<void>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<void> completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('播报被主动停止'));
      }
    }
    // SAPI 的 Speak 是阻塞的：这里不硬杀进程，等它自然说完；上层已经丢弃结果。
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _readyTimeout?.cancel();
    _ready = false;
    final Process? process = _process;
    _process = null;
    await _sendCommand(<String, dynamic>{'cmd': 'quit'});
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    if (process != null) {
      final bool exited =
          await process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1) >= 0;
      if (!exited) process.kill();
    }
    _failAllPending('适配层已释放');
    await _events.close();
    final Directory? dir = _workDir;
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }
}
