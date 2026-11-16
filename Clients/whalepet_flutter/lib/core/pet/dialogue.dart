import 'dart:math';

import 'pet_state.dart';
import 'pet_vitals.dart';

/// 气泡台词库（从 iPad 端 `WhalePet/Pet/Dialogue.swift` 移植，保留同样的语气）。
///
/// 与 iPad 的差异：
///   - 随机源注入，便于测试与复盘（和 `PetBehavior` 保持一致）；
///   - 不做「同一条不连续出现」之外的花样，保持本地静态语料，无 LLM 依赖。
class Dialogue {
  Dialogue({required Random random}) : _random = random;

  final Random _random;
  String _lastLine = '';

  /// 按状态 + 数值挑一句话；没有合适台词时返回 null。
  String? line({
    required PetState state,
    required PetVitals vitals,
    required String petName,
  }) {
    final List<String> pool = _poolFor(state, vitals, petName);
    if (pool.isEmpty) return null;
    String pick = pool[_random.nextInt(pool.length)];
    if (pick == _lastLine && pool.length > 1) {
      final List<String> others =
          pool.where((String item) => item != _lastLine).toList(growable: false);
      pick = others[_random.nextInt(others.length)];
    }
    _lastLine = pick;
    return pick;
  }

  List<String> _poolFor(PetState state, PetVitals vitals, String petName) {
    switch (state) {
      case PetState.eat:
        return <String>['小鱼干！最喜欢了～', '唔姆唔姆……谢谢投喂！', '尾巴开心地摇起来了♪'];
      case PetState.happy:
        return <String>['嘿嘿，再摸摸嘛～', '咕噜咕噜……（发出鲸歌）', '$petName最喜欢你啦！'];
      case PetState.sleep:
        return <String>['zzZ……梦见磷虾自助餐……', '呼……呼……'];
      case PetState.drag:
        return <String>['哇啊啊——放我下来啦！', '晕、晕船了……'];
      case PetState.play:
        return <String>['泡泡球！看我的尾鳍扣杀！', '噗——吹个大泡泡！'];
      case PetState.listening:
        return <String>['我在听～', '嗯嗯，请说～'];
      case PetState.thinking:
        return <String>['让我想想……', '正在翻深海百科……'];
      case PetState.speaking:
        return <String>['听我说～', '是这样哒～'];
      case PetState.walk:
      case PetState.swim:
      case PetState.idle:
        break;
    }
    if (vitals.satiety < PetVitals.kHungryThreshold) {
      return <String>['肚子咕咕叫了……想吃小鱼干', '右键投喂一下嘛👉'];
    }
    if (vitals.energy < 25) {
      return <String>['好困……让我睡一会儿嘛', '精力不足，需要充电zzZ'];
    }
    if (vitals.mood < 30) {
      return <String>['有点寂寞……摸摸头好不好？', '今天还没怎么陪我玩呢……'];
    }
    if (vitals.mood > 85 && vitals.satiety > 70 && vitals.energy > 60) {
      return <String>['今天也是元气满满的鲸鱼娘！', '要不要看我表演跃出水面？', 'DSH——Deep Sea Hug！'];
    }
    return <String>[
      '海里真安静呀～',
      '你知道吗？鲸鱼会唱歌哦',
      '这台 Windows 也要好好保养哦（笑）',
      '我是$petName，你的深海小宠物～',
    ];
  }
}
