import '../../core/pet/pet_state.dart';

/// 状态 → 立绘文件名（对应 iPad 端 `PetNode.textureNames`）。
///
/// 与 iPad 一致：`listening` 用 happy、`thinking` 用 swim、`speaking` 用 greet，
/// 这样两端观感统一，也避免为每个状态单独准备素材。
String petAssetFor(PetState state) {
  switch (state) {
    case PetState.idle:
      return 'assets/pet/pet_idle.png';
    case PetState.walk:
      return 'assets/pet/pet_walk.png';
    case PetState.swim:
      return 'assets/pet/pet_swim.png';
    case PetState.sleep:
      return 'assets/pet/pet_sleep.png';
    case PetState.happy:
      return 'assets/pet/pet_happy.png';
    case PetState.eat:
      return 'assets/pet/pet_eat.png';
    case PetState.play:
      return 'assets/pet/pet_play.png';
    case PetState.drag:
      return 'assets/pet/pet_drag.png';
    case PetState.listening:
      return 'assets/pet/pet_happy.png';
    case PetState.thinking:
      return 'assets/pet/pet_swim.png';
    case PetState.speaking:
      return 'assets/pet/pet_greet.png';
  }
}

/// 立绘朝向：walk 时按方向水平翻转。
bool petFacesLeft(PetState state, double direction) =>
    state == PetState.walk && direction < 0;

/// 情绪立绘覆盖：数值太差时优先表现「饿 / 难过」。
String petAssetForVitals(PetState state, {required bool hungry, required bool sad}) {
  if (state == PetState.idle || state == PetState.walk || state == PetState.swim) {
    if (hungry) return 'assets/pet/pet_sad.png';
    if (sad) return 'assets/pet/pet_sad.png';
  }
  return petAssetFor(state);
}

/// 特效素材。
const String kFxHeartAsset = 'assets/pet/fx_heart.png';
const String kFxFishAsset = 'assets/pet/fx_fish.png';
