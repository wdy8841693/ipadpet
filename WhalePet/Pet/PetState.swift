import Foundation

/// 鲸鱼娘的行为状态。参考 VPet / Shimeji 的状态驱动动画设计，
/// 但针对 iPadOS 15 + A8 做了大幅精简：纯枚举状态机，无物理引擎。
enum PetState: String, Codable, CaseIterable {
    case idle        // 待机：漂浮 + 眨眼 + 尾巴摆动
    case walk        // 沿"海底地面"散步（左右移动）
    case swim        // 全屏游动（斜向巡游）
    case happy       // 被摸头：冒爱心
    case eat         // 投喂：吃小鱼干
    case sleep       // 睡觉：zzZ
    case drag        // 被拖拽：四肢摊开
    case play        // 玩泡泡球

    /// 该状态的基础时长（秒）。nil 表示由外部事件结束（如 drag）。
    var baseDuration: TimeInterval? {
        switch self {
        case .idle:  return Double.random(in: 4...9)
        case .walk:  return Double.random(in: 5...10)
        case .swim:  return Double.random(in: 6...12)
        case .happy: return 2.6
        case .eat:   return 3.2
        case .sleep: return Double.random(in: 20...40)
        case .drag:  return nil
        case .play:  return 6.0
        }
    }

    /// 是否允许自动行为调度器切换到该状态。
    var isAutonomous: Bool {
        switch self {
        case .idle, .walk, .swim, .sleep: return true
        default: return false
        }
    }
}

/// 宠物数值（0...100）。饱食/心情随时间衰减，睡眠恢复精力。
struct PetVitals: Codable, Equatable {
    var satiety: Double = 80    // 饱食度
    var mood: Double = 80       // 心情
    var energy: Double = 90     // 精力

    static let min: Double = 0
    static let max: Double = 100

    mutating func clamp() {
        satiety = Swift.min(Swift.max(satiety, Self.min), Self.max)
        mood = Swift.min(Swift.max(mood, Self.min), Self.max)
        energy = Swift.min(Swift.max(energy, Self.min), Self.max)
    }

    /// 按经过的秒数衰减值。速率刻意放缓：宠物是陪伴，不是负担。
    /// - satiety: 约 4 小时从 100 → 0
    /// - mood:    约 6 小时从 100 → 0（饱食度低时加倍）
    /// - energy:  清醒约 5 小时耗尽；睡眠时每秒 +1.2
    mutating func advance(seconds dt: TimeInterval, sleeping: Bool) {
        guard dt > 0 else { return }
        let capped = Swift.min(dt, 6 * 3600)   // 离线最多结算 6 小时，避免一觉醒来饿死
        satiety -= capped * (100.0 / (4 * 3600))
        let moodRate = satiety < 25 ? 2.0 : 1.0
        mood -= capped * moodRate * (100.0 / (6 * 3600))
        if sleeping {
            energy += capped * 1.2
        } else {
            energy -= capped * (100.0 / (5 * 3600))
        }
        clamp()
    }

    mutating func feed(amount: Double = 22) {
        satiety += amount
        mood += 6
        clamp()
    }

    mutating func pet(amount: Double = 10) {
        mood += amount
        clamp()
    }

    /// 综合状态等级，用于表情与气泡文案选择。
    var wellbeing: Wellbeing {
        if satiety < 20 { return .hungry }
        if energy < 15 { return .tired }
        if mood < 25 { return .sad }
        if mood > 75 && satiety > 50 { return .great }
        return .ok
    }

    enum Wellbeing: String {
        case hungry, tired, sad, ok, great
    }
}