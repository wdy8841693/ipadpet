import Foundation

/// 行为调度器：根据数值与随机权重挑选下一个自主行为。
/// 纯逻辑、无 UIKit/SpriteKit 依赖 → 可在 Linux CI 上做单元测试。
struct PetBrain {
    var vitals: PetVitals
    private(set) var state: PetState = .idle
    private(set) var stateRemaining: TimeInterval = PetState.idle.baseDuration ?? 5

    /// 上一次结算的墙钟时间，用于离线衰减。
    var lastTick: Date = Date()

    init(vitals: PetVitals = PetVitals()) {
        self.vitals = vitals
    }

    // MARK: - 事件驱动切换（用户交互优先于自主行为）

    mutating func beginDrag() { transition(to: .drag) }

    mutating func endDrag() {
        vitals.pet(amount: 4)          // 被抱起来也算互动
        transition(to: .happy)
    }

    mutating func petHead() {
        vitals.pet()
        transition(to: .happy)
    }

    /// 返回是否真正执行，渲染层只在成功时播放特效并计数。
    @discardableResult
    mutating func feed() -> Bool {
        guard state != .sleep else { return false }   // 睡着了不进食
        vitals.feed()
        transition(to: .eat)
        return true
    }

    @discardableResult
    mutating func playBall() -> Bool {
        guard state != .sleep else { return false }
        vitals.pet(amount: 8)
        vitals.energy -= 5
        vitals.clamp()
        transition(to: .play)
        return true
    }

    mutating func toggleSleep() {
        transition(to: state == .sleep ? .idle : .sleep)
    }

    mutating func beginVoiceInteraction(_ state: PetState) {
        guard state.isVoiceInteraction else { return }
        transition(to: state)
    }

    mutating func endVoiceInteraction() {
        guard state.isVoiceInteraction else { return }
        transition(to: .idle)
    }

    // MARK: - 时间推进

    /// 每帧调用。返回 true 表示状态发生了变化（渲染层据此换动画）。
    /// 注意：随机源用泛型而非 existential，兼容 Swift 5.7+（Xcode 14）。
    @discardableResult
    mutating func tick<R: RandomNumberGenerator>(dt: TimeInterval, now: Date = Date(), rng: inout R) -> Bool {
        lastTick = now
        vitals.advance(seconds: dt, sleeping: state == .sleep)
        stateRemaining -= dt
        guard stateRemaining <= 0, state != .drag else { return false }
        let next = pickNextState(rng: &rng)
        transition(to: next)
        return true
    }

    /// 离线结算：App 退到后台/被杀后重新打开时调用一次。
    mutating func settleOffline(until now: Date) {
        let dt = now.timeIntervalSince(lastTick)
        guard dt > 1 else { lastTick = now; return }
        vitals.advance(seconds: dt, sleeping: state == .sleep)
        lastTick = now
        // 长时间离开后回来，先待机而不是继续睡觉/游动
        transition(to: .idle)
    }

    // MARK: - 私有

    private mutating func transition(to newState: PetState) {
        state = newState
        stateRemaining = newState.baseDuration ?? .infinity
    }

    /// 加权随机挑选下一个自主状态；数值差时倾向睡觉/待机。
    func pickNextState<R: RandomNumberGenerator>(rng: inout R) -> PetState {
        var weights: [(PetState, Double)] = [
            (.idle, 40),
            (.walk, 25),
            (.swim, 25),
            (.sleep, vitals.energy < 35 ? 60 : 8),
        ]
        if vitals.satiety < 20 || vitals.mood < 20 {
            // 又饿又难过时没精神到处游
            weights = weights.map { ($0.0 == .swim || $0.0 == .walk) ? ($0.0, 6) : $0 }
        }
        let total = weights.reduce(0) { $0 + $1.1 }
        var roll = Double.random(in: 0..<total, using: &rng)
        for (s, w) in weights {
            roll -= w
            if roll < 0 { return s }
        }
        return .idle
    }
}