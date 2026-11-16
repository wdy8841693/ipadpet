import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/voice/voice_engine.dart';
import '../../core/voice/wake_matcher.dart';

/// Windows 本地语音引擎（KWS + VAD + ASR 全在原生层）。
///
/// 实现：常驻一个 PowerShell 子进程，加载系统自带的 **SAPI 5 离线桌面识别引擎**
/// （`System.Speech.Recognition`）。待机只启用「唤醒词小语法」，唤醒后切成听写语法。
///
/// 为什么这样选：
///   - Windows 自带 zh-CN 桌面识别器，完全离线、零模型下载；
///   - 音频不穿过 Dart / MethodChannel（§7.4），Dart 只收事件、发控制命令；
///   - 与 `VoiceEngineAdapter` 解耦，将来换 sherpa-onnx 只需替换本文件。
///
/// 编码约定：中文配置走 UTF-8 文件（控制台 OEM 代码页 936 会转坏），
/// 子进程 stdout 强制 UTF-8（脚本开头设置 Console.OutputEncoding），
/// 控制命令是纯 ASCII JSON。
///
/// [audioFile] 仅供开发验证：给定时用 `SetInputToWaveFile` 代替麦克风，
/// 可以在没有麦克风的机器上跑通「唤醒 → 识别」全链路。
class SapiVoiceEngine implements VoiceEngineAdapter {
  SapiVoiceEngine({this.powerShellPath = 'powershell.exe', this.audioFile});

  final String powerShellPath;
  final String? audioFile;

  final StreamController<VoiceEngineEvent> _events =
      StreamController<VoiceEngineEvent>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  Directory? _workDir;
  Completer<void>? _initCompleter;
  int _generation = 0;
  int _commandSeq = 0;
  String _mode = 'idle';
  bool _disposed = false;

  /// 唤醒词表（主词 + 别名）：整段听写模式下用它匹配句首唤醒词（§7.7）。
  List<String> _wakePhrases = const <String>[];

  /// 整段听写命中唤醒词所需的最低置信度。
  double _wakeConfidence = 0.45;

  static const String _script = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

$state = @{
  gen = 0
  mode = 'idle'
  wakeConf = 0.45
  dictConf = 0.20
  listenTimeoutMs = 10000
  endSilenceMs = 700
  audioFile = ''
  oneShot = $false
}
$script:engine = $null
$script:wakeGrammar = $null
$script:dictGrammar = $null

function Emit([string]$line) {
  [Console]::Out.WriteLine($line)
  [Console]::Out.Flush()
}

function Stop-Recognition {
  if ($null -ne $script:engine) {
    try { $script:engine.RecognizeAsyncStop() } catch {}
  }
  $state.mode = 'idle'
}

function Set-Mode([string]$next, [int]$gen) {
  Stop-Recognition
  $state.gen = $gen
  if ($next -eq 'idle' -or $null -eq $script:engine) {
    Emit "MODE idle $gen"
    return
  }
  # 待机有两条路（§7.7）：
  #   - oneShot：整段听写语法，Dart 侧用 WakeMatcher 匹配句首唤醒词并取出
  #     「后面那一截」，于是「小鲸小鲸，帮我查天气」一句话说完就执行；
  #   - 否则：唤醒词小语法（低功耗），命中即唤醒，走「我在 → 聆听」两段式。
  if ($next -eq 'wake') {
    $script:wakeGrammar.Enabled = (-not $state.oneShot)
    $script:dictGrammar.Enabled = [bool]$state.oneShot
  } else {
    $script:wakeGrammar.Enabled = $false
    $script:dictGrammar.Enabled = $true
  }
  if ($next -eq 'listen') {
    $script:engine.InitialSilenceTimeout = [TimeSpan]::FromMilliseconds($state.listenTimeoutMs)
    $script:engine.EndSilenceTimeout = [TimeSpan]::FromMilliseconds($state.endSilenceMs)
  } else {
    $script:engine.InitialSilenceTimeout = [TimeSpan]::FromHours(1)
    $script:engine.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(400)
  }
  if ($state.audioFile -ne '') {
    try { $script:engine.SetInputToWaveFile($state.audioFile) } catch {}
  }
  $state.mode = $next
  $script:engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
  Emit "MODE $next $gen"
}

function Initialize-Engine([string]$configPath) {
  $cfg = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $state.wakeConf = [double]$cfg.wake_confidence
  $state.dictConf = [double]$cfg.dictation_confidence
  $state.listenTimeoutMs = [int]$cfg.listen_timeout_ms
  $state.endSilenceMs = [int]$cfg.end_silence_ms
  # 一句话带命令（§7.7）：待机用整段听写还是唤醒词小语法。
  if ($cfg.PSObject.Properties.Name -contains 'one_shot_command') {
    $state.oneShot = [bool]$cfg.one_shot_command
  }
  $state.audioFile = ''
  if ($cfg.PSObject.Properties.Name -contains 'audio_file' -and $cfg.audio_file) {
    $state.audioFile = [string]$cfg.audio_file
  }

  $culture = [string]$cfg.culture
  $info = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() |
          Where-Object { $_.Culture.Name -eq $culture } | Select-Object -First 1
  if ($null -eq $info) { Emit ("FATAL recognizer-not-found " + $culture); return }

  $script:engine = [System.Speech.Recognition.SpeechRecognitionEngine]::new($info)
  if ($state.audioFile -eq '') {
    try {
      $script:engine.SetInputToDefaultAudioDevice()
    } catch {
      Emit 'FATAL no-microphone'
      return
    }
  }

  $choices = [System.Speech.Recognition.Choices]::new()
  foreach ($phrase in $cfg.wake_phrases) {
    $choices.Add([string]$phrase)
  }
  $builder = [System.Speech.Recognition.GrammarBuilder]::new($choices)
  $script:wakeGrammar = [System.Speech.Recognition.Grammar]::new($builder)
  $script:wakeGrammar.Name = 'wake'
  $script:dictGrammar = [System.Speech.Recognition.DictationGrammar]::new()
  $script:dictGrammar.Name = 'dictation'
  $script:engine.LoadGrammar($script:wakeGrammar)
  $script:engine.LoadGrammar($script:dictGrammar)
  $script:wakeGrammar.Enabled = $false
  $script:dictGrammar.Enabled = $false

  $null = Register-ObjectEvent -InputObject $script:engine -EventName SpeechRecognized -MessageData $state -Action {
    $s = $Event.MessageData
    if ($s.mode -eq 'idle' -or $null -eq $EventArgs.Result) { return }
    $r = $EventArgs.Result
    $name = ''
    try { $name = [string]$r.Grammar.Name } catch {}
    $conf = 0.0
    try { $conf = [double]$r.Confidence } catch {}
    $text = [string]$r.Text
    $g = [int]$s.gen
    if ($name -eq 'wake' -and $s.mode -eq 'wake') {
      if ($conf -lt [double]$s.wakeConf) { return }
      [Console]::Out.WriteLine("WAKE $g $conf $text")
      [Console]::Out.Flush()
    } elseif ($s.mode -eq 'wake' -and $name -eq 'dictation') {
      # 整段听写命中：原样上报整句，由 Dart 侧用 WakeMatcher 判断
      # 「是不是句首唤醒词 + 后面那截指令」（§7.7）。
      if ($conf -lt [double]$s.dictConf) { return }
      [Console]::Out.WriteLine("SENT $g $conf $text")
      [Console]::Out.Flush()
    } elseif ($s.mode -eq 'listen') {
      if ($conf -lt [double]$s.dictConf) { return }
      [Console]::Out.WriteLine("FINAL $g $conf $text")
      [Console]::Out.Flush()
    }
  }

  $null = Register-ObjectEvent -InputObject $script:engine -EventName SpeechHypothesized -MessageData $state -Action {
    $s = $Event.MessageData
    if ($s.mode -ne 'listen' -or $null -eq $EventArgs.Result) { return }
    $text = [string]$EventArgs.Result.Text
    if ($text.Trim().Length -eq 0) { return }
    $g = [int]$s.gen
    [Console]::Out.WriteLine("PARTIAL $g $text")
    [Console]::Out.Flush()
  }

  $null = Register-ObjectEvent -InputObject $script:engine -EventName SpeechRecognitionRejected -MessageData $state -Action {
    $s = $Event.MessageData
    if ($s.mode -eq 'idle') { return }
    $g = [int]$s.gen
    [Console]::Out.WriteLine("REJECTED $g")
    [Console]::Out.Flush()
  }

  $null = Register-ObjectEvent -InputObject $script:engine -EventName RecognizeCompleted -MessageData $state -Action {
    $s = $Event.MessageData
    $g = [int]$s.gen
    [Console]::Out.WriteLine("COMPLETED $g $($s.mode)")
    [Console]::Out.Flush()
  }

  Emit ("INIT_OK " + $info.Id)
}

Emit 'READY'
$commandDir = $PSScriptRoot
$seq = 1
$script:quit = $false
# Control commands use numbered files instead of stdin: on Windows the second
# and later lines written to a resident process Console.In are swallowed.
while (-not $script:quit) {
  $path = Join-Path $commandDir ("cmd-{0:D6}.json" -f $seq)
  if (-not (Test-Path -LiteralPath $path)) {
    Start-Sleep -Milliseconds 100
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
    switch ([string]$msg.cmd) {
      'init'   { Initialize-Engine ([string]$msg.config) }
      'wake'   { Set-Mode 'wake' ([int]$msg.gen) }
      'listen' { Set-Mode 'listen' ([int]$msg.gen) }
      'stop'   { Stop-Recognition; Emit ("MODE idle " + [string]$msg.gen) }
      'quit'   { $script:quit = $true; Emit 'BYE' }
      default  { Emit ("ERROR unknown-command " + [string]$msg.cmd) }
    }
  } catch {
    Emit ("ERROR " + [string]$_.Exception.Message)
  }
}
if ($null -ne $script:engine) {
  try { $script:engine.RecognizeAsyncCancel() } catch {}
  try { $script:engine.Dispose() } catch {}
}
# 事件订阅会让宿主进程在脚本结束后继续存活，显式注销以便干净退出。
try { Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue } catch {}
''';

  @override
  Stream<VoiceEngineEvent> get events => _events.stream;

  @override
  Future<void> initialize(VoiceEngineConfig config) async {
    if (_disposed) throw StateError('引擎已释放');
    if (!Platform.isWindows) {
      throw UnsupportedError('SapiVoiceEngine 只能在 Windows 上使用');
    }
    await _stopProcess();
    _commandSeq = 0;
    _workDir = await Directory.systemTemp.createTemp('whalepet-voice-');
    final Directory dir = _workDir!;
    final File scriptFile =
        File('${dir.path}${Platform.pathSeparator}voice.ps1');
    // Windows scripting host parses LF-only scripts unreliably (event Action
    // blocks can be swallowed). Always write CRLF.
    await scriptFile.writeAsString(
      _script.replaceAll('\n', '\r\n'),
      flush: true,
    );

    final Map<String, dynamic> json = config.toJson();
    if (audioFile != null) json['audio_file'] = audioFile;
    _wakePhrases = config.wakePhrases;
    _wakeConfidence = config.wakeConfidence;
    final File configFile =
        File('${dir.path}${Platform.pathSeparator}config.json');
    await configFile.writeAsString(jsonEncode(json), flush: true);

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
    );
    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object _) {});
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((int code) {
      if (Platform.environment['WHALEPET_VOICE_DEBUG'] == '1') {
        stdout.writeln('[exit] $code');
      }
      if (_disposed || process != _process) return;
      _emit(VoiceCaptureErrorEvent(
        code: 'engine-exit',
        message: '语音引擎进程退出（code=$code）',
      ));
    }));

    final Completer<void> init = Completer<void>();
    _initCompleter = init;
    await _send(<String, dynamic>{'cmd': 'init', 'config': configFile.path});
    await init.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw StateError('语音引擎初始化超时'),
    );
  }

  void _onLine(String raw) {
    final String line = raw.trim();
    if (line.isEmpty) return;
    // 开发期排查：WHALEPET_VOICE_DEBUG=1 打印引擎原始 stdout。
    if (Platform.environment['WHALEPET_VOICE_DEBUG'] == '1') {
      stdout.writeln('[voice] $line');
    }
    if (line == 'READY') return;
    if (line.startsWith('INIT_OK ')) {
      final Completer<void>? init = _initCompleter;
      if (init != null && !init.isCompleted) init.complete();
      _emit(VoiceEngineReadyEvent(detail: line.substring(8)));
      return;
    }
    if (line.startsWith('FATAL ')) {
      final String rest = line.substring(6).trim();
      final Completer<void>? init = _initCompleter;
      if (init != null && !init.isCompleted) {
        init.completeError(StateError(rest));
      }
      _emit(VoiceCaptureErrorEvent(code: 'fatal', message: rest));
      return;
    }
    if (line.startsWith('MODE ')) return;
    if (line.startsWith('ERROR ')) {
      _emit(VoiceCaptureErrorEvent(code: 'engine', message: line.substring(6)));
      return;
    }
    final List<String> parts = _splitMarker(line);
    if (parts.length < 2) return;
    final String kind = parts[0];
    final int gen = int.tryParse(parts[1]) ?? 0;
    // 引擎自己过滤过期模式产生的迟到事件。
    if (gen != _generation || _mode == 'idle') return;

    switch (kind) {
      case 'WAKE':
        if (parts.length >= 4) {
          _emit(VoiceWakeDetectedEvent(
            keyword: parts.sublist(3).join(' '),
            confidence: double.tryParse(parts[2]) ?? 0,
          ));
        }
      case 'SENT':
        // 整段听写命中（§7.7）：原句里可能带着唤醒词，剥掉后剩下的就是指令。
        if (parts.length >= 4) {
          final double confidence = double.tryParse(parts[2]) ?? 0;
          if (confidence < _wakeConfidence) break;
          final String text = parts.sublist(3).join(' ');
          final WakeMatch? hit =
              WakeMatcher(_wakePhrases).matchWithRest(text);
          if (hit == null) break;
          _emit(VoiceWakeDetectedEvent(
            keyword: hit.keyword,
            confidence: confidence,
            trailingText: hit.rest,
          ));
        }
      case 'PARTIAL':
        if (parts.length >= 3) {
          _emit(VoicePartialTranscriptEvent(text: parts.sublist(2).join(' ')));
        }
      case 'FINAL':
        if (parts.length >= 4) {
          _emit(VoiceFinalTranscriptEvent(
            confidence: double.tryParse(parts[2]) ?? 0,
            text: parts.sublist(3).join(' '),
          ));
        }
      case 'REJECTED':
        _emit(VoiceRecognitionErrorEvent(
          code: 'rejected',
          message: '识别被拒绝',
          retryable: true,
        ));
      case 'COMPLETED':
        // 听写模式下静音会结束一次异步识别。不在这里自动重启：
        // 协调器的 10 秒聆听超时会决定「允许重说」还是「回待唤醒」，
        // 自动重启还会在 WAV 验证模式里造成无限循环。
        break;
      default:
        break;
    }
  }

  List<String> _splitMarker(String line) {
    final List<String> parts = line.split(' ');
    return parts.where((String part) => part.isNotEmpty).toList();
  }

  /// 写一条控制命令（原子 rename，保证脚本不会读到半截文件）。
  Future<void> _send(Map<String, dynamic> message) async {
    final Directory? dir = _workDir;
    if (dir == null) return;
    final bool debug = Platform.environment['WHALEPET_VOICE_DEBUG'] == '1';
    try {
      _commandSeq++;
      final String name =
          'cmd-${_commandSeq.toString().padLeft(6, '0')}.json';
      final File target = File('${dir.path}${Platform.pathSeparator}$name');
      final File temp = File('${target.path}.tmp');
      if (debug) stdout.writeln('[send] ${jsonEncode(message)}');
      await temp.writeAsString(jsonEncode(message), flush: true);
      await temp.rename(target.path);
    } catch (_) {
      // 进程可能已退出/目录被清理。
    }
  }

  void _emit(VoiceEngineEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> startWakeListening() async {
    _mode = 'wake';
    final int gen = ++_generation;
    await _send(<String, dynamic>{'cmd': 'wake', 'gen': gen});
  }

  @override
  Future<void> startManualListening() async {
    _mode = 'listen';
    final int gen = ++_generation;
    await _send(<String, dynamic>{'cmd': 'listen', 'gen': gen});
  }

  @override
  Future<void> stopListening() async {
    _mode = 'idle';
    final int gen = ++_generation;
    await _send(<String, dynamic>{'cmd': 'stop', 'gen': gen});
  }

  Future<void> _stopProcess() async {
    final Process? process = _process;
    _process = null;
    await _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    if (process != null) {
      await _send(<String, dynamic>{'cmd': 'quit'});
      final int code = await process.exitCode
          .timeout(const Duration(seconds: 3), onTimeout: () => -1);
      if (code < 0) process.kill();
    }
    final Directory? dir = _workDir;
    _workDir = null;
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stopProcess();
    await _events.close();
  }
}
