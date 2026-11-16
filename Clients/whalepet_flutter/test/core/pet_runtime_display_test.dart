import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/config/app_paths.dart';
import 'package:whalepet_flutter/core/platform/desktop_window.dart';
import 'package:whalepet_flutter/core/platform/window_placement.dart';
import 'package:whalepet_flutter/core/voice/speech_output.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';
import 'package:whalepet_flutter/ui/desktop_pet/pet_runtime.dart';

/// 能感知显示器变化的假窗口：工作区可以随时换，并记录被设置过的位置。
class FakeDesktopWindow implements DesktopWindowAdapter, DisplayChangeAware {
  FakeDesktopWindow({required this.area});

  WorkArea area;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<WindowRect> positions = <WindowRect>[];
  WindowRect rect = const WindowRect(left: 0, top: 0, width: 380, height: 560);

  @override
  Stream<void> get displayChanges => _changes.stream;

  void changeArea(WorkArea next) {
    area = next;
    _changes.add(null);
  }

  @override
  bool get isReady => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<WorkArea> workArea() async => area;

  @override
  Future<WindowRect> bounds() async => rect;

  @override
  Future<void> setPosition(double left, double top) async {
    rect = rect.copyWith(left: left, top: top);
    positions.add(rect);
  }

  @override
  Future<void> setBounds(WindowRect next) async {
    rect = next;
  }

  @override
  Future<void> setAlwaysOnTop(bool enabled) async {}

  @override
  Future<void> setSkipTaskbar(bool enabled) async {}

  @override
  Future<void> setClickThrough(bool enabled) async {}

  @override
  Future<void> startNativeDrag() async {}

  @override
  ({double x, double y})? cursorPosition() => null;

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}

class FakeSpeechOutput implements SpeechOutputAdapter {
  @override
  Stream<SpeechOutputEvent> get events => const Stream<SpeechOutputEvent>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String utteranceId, String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class FakeVoiceEngine implements VoiceEngineAdapter {
  @override
  Stream<VoiceEngineEvent> get events => const Stream<VoiceEngineEvent>.empty();

  @override
  Future<void> initialize(VoiceEngineConfig config) async {}

  @override
  Future<void> startWakeListening() async {}

  @override
  Future<void> startManualListening() async {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  test('显示器变化后把窗口重新夹回可见工作区', () async {
    final Directory dir = await Directory.systemTemp.createTemp('whalepet-rt-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    // 初始工作区是一块 1000×800 的屏幕，桌宠在右下角。
    final FakeDesktopWindow window = FakeDesktopWindow(
      area: const WorkArea(left: 0, top: 0, width: 1000, height: 800),
    );
    final PetRuntime runtime = PetRuntime(
      paths: AppPaths(rootDirectory: dir),
      window: window,
      speech: FakeSpeechOutput(),
      voiceEngine: FakeVoiceEngine(),
    );
    addTearDown(runtime.dispose);
    await runtime.start();

    // 拔掉这块屏，换成一块更小的：桌宠必须被拉回新屏幕里，不能留在屏外。
    window.changeArea(
      const WorkArea(left: 0, top: 0, width: 640, height: 480),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    // 位置必须动过（原来在 1000×800 的屏幕右下角）。
    expect(window.positions, isNotEmpty);
    final WindowRect moved = window.positions.last;
    expect(moved.left, isNot(310));
    expect(moved.top, isNot(232));

    // 契约：窗口左上角落回新工作区，且与新工作区至少还有 48px 的重叠
    // （`clampToWorkArea` 的 minVisible 兜底），不能整只跑到屏外。
    expect(moved.left, greaterThanOrEqualTo(0));
    expect(moved.top, greaterThanOrEqualTo(0));
    expect(_overlap(moved.left, moved.right, 0, 640), greaterThanOrEqualTo(48));
    expect(_overlap(moved.top, moved.bottom, 0, 480), greaterThanOrEqualTo(48));
  });
}

double _overlap(double a1, double a2, double b1, double b2) {
  final double start = a1 > b1 ? a1 : b1;
  final double end = a2 < b2 ? a2 : b2;
  final double value = end - start;
  return value > 0 ? value : 0;
}
