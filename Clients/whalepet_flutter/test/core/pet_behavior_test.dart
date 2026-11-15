import 'dart:math';

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/pet/pet_behavior.dart';
import 'package:whalepet_flutter/core/pet/pet_state.dart';

void main() {
  group('PetState 分类', () {
    test('自主状态只有 idle / walk / swim / sleep', () {
      expect(kAutonomousStates, <PetState>[
        PetState.idle,
        PetState.walk,
        PetState.swim,
        PetState.sleep,
      ]);
      for (final PetState state in PetState.values) {
        expect(state.isAutonomous, kAutonomousStates.contains(state));
      }
    });

    test('drag / listening / thinking / speaking 属于忙碌状态', () {
      for (final PetState state in <PetState>[
        PetState.drag,
        PetState.listening,
        PetState.thinking,
        PetState.speaking,
      ]) {
        expect(state.isBusy, isTrue, reason: '$state 应当是忙碌状态');
        expect(state.isAutonomous, isFalse);
      }
    });
  });

  group('PetBehavior 随机调度', () {
    test('拖拽时不被打断', () {
      final PetBehavior behavior = PetBehavior(random: Random(1), idleToAutonomousChance: 1.0);
      for (final PetState state in PetState.values) {
        expect(
          behavior.nextAutonomousState(state, isDragging: true, isBusy: false),
          state,
        );
      }
    });

    test('语音状态（listening / thinking / speaking）不被打断', () {
      final PetBehavior behavior = PetBehavior(random: Random(2), idleToAutonomousChance: 1.0);
      for (final PetState state in <PetState>[
        PetState.listening,
        PetState.thinking,
        PetState.speaking,
      ]) {
        expect(
          behavior.nextAutonomousState(state, isDragging: false, isBusy: true),
          state,
        );
      }
    });

    test('非自主的互动状态由场景控制器负责，调度器原样返回', () {
      final PetBehavior behavior = PetBehavior(random: Random(3), idleToAutonomousChance: 1.0);
      for (final PetState state in <PetState>[PetState.happy, PetState.eat, PetState.play]) {
        expect(
          behavior.nextAutonomousState(state, isDragging: false, isBusy: false),
          state,
        );
      }
    });

    test('概率为 0 时永远保持待机', () {
      final PetBehavior behavior = PetBehavior(random: Random(4), idleToAutonomousChance: 0.0);
      for (int i = 0; i < 200; i += 1) {
        expect(
          behavior.nextAutonomousState(PetState.idle, isDragging: false, isBusy: false),
          PetState.idle,
        );
      }
    });

    test('切换结果只落在自主状态里', () {
      final PetBehavior behavior = PetBehavior(random: Random(5), idleToAutonomousChance: 1.0);
      PetState current = PetState.idle;
      for (int i = 0; i < 500; i += 1) {
        current = behavior.nextAutonomousState(current, isDragging: false, isBusy: false);
        expect(kAutonomousStates.contains(current), isTrue, reason: '出现了非自主状态 $current');
      }
    });

    test('同一 seed 的状态序列可重放', () {
      List<PetState> run(int seed) {
        final PetBehavior behavior = PetBehavior(random: Random(seed), idleToAutonomousChance: 0.3);
        final List<PetState> trace = <PetState>[];
        PetState current = PetState.idle;
        for (int i = 0; i < 300; i += 1) {
          current = behavior.nextAutonomousState(current, isDragging: false, isBusy: false);
          trace.add(current);
        }
        return trace;
      }

      expect(run(42), run(42));
      // 不同 seed 不应完全一致（否则说明没真的用随机源）。
      expect(run(42) == run(7), isFalse);
    });

    test('中途进入忙碌状态后，恢复时从当前状态继续', () {
      final PetBehavior behavior = PetBehavior(random: Random(9), idleToAutonomousChance: 1.0);
      const PetState busy = PetState.thinking;
      expect(behavior.nextAutonomousState(busy, isDragging: false, isBusy: true), busy);
      // 忙碌结束后回到待机，再交给调度器。
      final PetState next =
          behavior.nextAutonomousState(PetState.idle, isDragging: false, isBusy: false);
      expect(kAutonomousStates.contains(next), isTrue);
    });
  });
}
