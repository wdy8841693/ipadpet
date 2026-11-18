import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/config/app_paths.dart';
import 'package:whalepet_flutter/core/platform/desktop_window.dart';
import 'package:whalepet_flutter/core/platform/window_placement.dart';
import 'package:whalepet_flutter/core/voice/speech_output.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';
import 'package:whalepet_flutter/ui/desktop_pet/pet_layout.dart';
import 'package:whalepet_flutter/ui/desktop_pet/pet_runtime.dart';

/// 可控制光标位置、并记录每次穿透下发的假窗口。
class ClickThroughWindow implements DesktopWindowAdapter {
  ClickThroughWindow();

  WindowRect rect = const WindowRect(left: 0, top: 0, width: 380, height: 560);
  ({double x, double y})? cursor;
  final List<bool> clickThroughCalls = <bool>[];

  @override
  bool get isReady => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<WorkArea> workArea() async =>
      const WorkArea(left: 0, top: 0, width: 1000, height: 800);

  @override
  Future<WindowRect> bounds() async => rect;

  @override
  Future<void> setPosition(double left, double top) async {
    rect = rect.copyWith(left: left, top: top);
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
  Future<void> setClickThrough(bool enabled) async {
    clickThroughCalls.add(enabled);
  }

  @override
  Future<void> startNativeDrag() async {}

  @override
  ({double x, double y})? cursorPosition() => cursor;

  @override
  Future<void> dispose() async {}
}

class _Speech implements SpeechOutputAdapter {
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

class _Voice implements VoiceEngineAdapter {
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

Future<void> _pump() =>
    Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  group('PetLayout.shouldClickThrough 命中判定', () {
    // 窗口内坐标：petRect=(85,344,210,210)，menuRect=(24,56,210,282)，
    // panelRect=(12,8,356,332)。宠物上方那块属于 menuRect/panelRect 范围。
    test('菜单/面板隐藏：宠物本体可点，四周透明区（含宠物上方）穿透', () {
      expect(
        PetLayout.shouldClickThrough(
          const Offset(190, 449), // petRect 中心
          panelVisible: false,
          menuVisible: false,
        ),
        isFalse,
      );
      expect(
        PetLayout.shouldClickThrough(
          const Offset(190, 120), // 宠物上方（menuRect/panelRect 范围内）
          panelVisible: false,
          menuVisible: false,
        ),
        isTrue,
      );
      expect(
        PetLayout.shouldClickThrough(
          const Offset(360, 120), // 窗口右上透明区
          panelVisible: false,
          menuVisible: false,
        ),
        isTrue,
      );
    });

    test('面板或菜单显示时：整窗不穿透，按钮/输入框能拿到点击', () {
      // 即便光标在宠物上方的透明区，只要面板显示就必须接收鼠标。
      expect(
        PetLayout.shouldClickThrough(
          const Offset(190, 120),
          panelVisible: true,
          menuVisible: false,
        ),
        isFalse,
      );
      expect(
        PetLayout.shouldClickThrough(
          const Offset(360, 120),
          panelVisible: false,
          menuVisible: true,
        ),
        isFalse,
      );
    });
  });

  group('PetRuntime 穿透状态转换', () {
    Future<(PetRuntime, ClickThroughWindow)> makeRuntime() async {
      final Directory dir = await Directory.systemTemp.createTemp('whalepet-ct-');
      final ClickThroughWindow window = ClickThroughWindow();
      final PetRuntime runtime = PetRuntime(
        paths: AppPaths(rootDirectory: dir),
        window: window,
        speech: _Speech(),
        voiceEngine: _Voice(),
      );
      addTearDown(() async {
        runtime.dispose();
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await runtime.start();
      // 光标必须在 startServices 前设好：ticker 第一轮就要看到它，否则
      // cursor=null 会跳过穿透判定，初始状态停在"不穿透"。
      window.cursor = (x: 190.0, y: 120.0);
      await runtime.startServices();
      await _pump();
      return (runtime, window);
    }

    test('打开面板立即取消穿透，关闭面板立即恢复（宠物上方透明区）', () async {
      final (PetRuntime runtime, ClickThroughWindow window) =
          await makeRuntime();
      // 光标停在宠物上方的透明区。
      window.cursor = (x: 190.0, y: 120.0);
      await _pump();
      window.clickThroughCalls.clear();

      runtime.openPanel(PetPanel.settings);
      await _pump();
      expect(window.clickThroughCalls, contains(false),
          reason: '面板打开必须关闭穿透，否则输入框拿不到点击');

      window.clickThroughCalls.clear();
      runtime.closePanel();
      await _pump();
      expect(window.clickThroughCalls, contains(true),
          reason: '面板关闭后宠物上方透明区必须恢复穿透，不能吞掉下层点击');
    });

    test('开关菜单同样立即同步穿透状态', () async {
      final (PetRuntime runtime, ClickThroughWindow window) =
          await makeRuntime();
      window.cursor = (x: 190.0, y: 120.0);
      await _pump();
      window.clickThroughCalls.clear();

      runtime.toggleMenu();
      await _pump();
      expect(window.clickThroughCalls, contains(false));

      window.clickThroughCalls.clear();
      runtime.closeMenu();
      await _pump();
      expect(window.clickThroughCalls, contains(true));
    });
  });
}
