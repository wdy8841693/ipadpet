import XCTest
@testable import WhalePet

/// 纯逻辑单元测试：状态机 / 数值衰减 / 持久化编解码。
/// 不依赖 SpriteKit，可在任意 iPad 模拟器上秒级跑完。
final class PetBrainTests: XCTestCase {
    var rng = SystemRandomNumberGenerator()

    func testVitalsClamp() {
        var v = PetVitals(satiety: 150, mood: -20, energy: 50)
        v.clamp()
        XCTAssertEqual(v.satiety, 100)
        XCTAssertEqual(v.mood, 0)
        XCTAssertEqual(v.energy, 50)
    }

    func testDecayOverFourHours() {
        var v = PetVitals(satiety: 100, mood: 100, energy: 100)
        v.advance(seconds: 4 * 3600, sleeping: false)
        XCTAssertEqual(v.satiety, 0, accuracy: 0.01)
        XCTAssertGreaterThan(v.mood, 0)     // 心情衰减更慢
        XCTAssertLessThan(v.mood, 100)
    }

    func testSleepRestoresEnergy() {
        var v = PetVitals(satiety: 80, mood: 80, energy: 10)
        v.advance(seconds: 60, sleeping: true)
        XCTAssertEqual(v.energy, 82, accuracy: 0.01)   // +1.2/s
    }

    func testOfflineCap() {
        var v = PetVitals(satiety: 100, mood: 100, energy: 100)
        v.advance(seconds: 30 * 24 * 3600, sleeping: false)  // 离开一个月
        // 最多结算 6 小时：饱食 100 - 6h*(100/4h) = -50 → clamp 0
        XCTAssertEqual(v.satiety, 0)
        // energy 6h 扣 120 → clamp 到 0；验证不会 NaN/越界
        XCTAssertEqual(v.energy, 0)
        XCTAssertGreaterThanOrEqual(v.mood, 0)
    }

    func testFeedAndPet() {
        var v = PetVitals(satiety: 50, mood: 50, energy: 50)
        v.feed()
        XCTAssertEqual(v.satiety, 72)
        XCTAssertEqual(v.mood, 56)
        v.pet()
        XCTAssertEqual(v.mood, 66)
    }

    func testWellbeing() {
        XCTAssertEqual(PetVitals(satiety: 10, mood: 80, energy: 80).wellbeing, .hungry)
        XCTAssertEqual(PetVitals(satiety: 80, mood: 80, energy: 5).wellbeing, .tired)
        XCTAssertEqual(PetVitals(satiety: 80, mood: 10, energy: 80).wellbeing, .sad)
        XCTAssertEqual(PetVitals(satiety: 80, mood: 90, energy: 80).wellbeing, .great)
        XCTAssertEqual(PetVitals(satiety: 50, mood: 50, energy: 50).wellbeing, .ok)
    }

    func testDragOverridesAutonomy() {
        var b = PetBrain()
        b.beginDrag()
        XCTAssertEqual(b.state, .drag)
        // drag 永不超时
        for _ in 0..<100 {
            b.tick(dt: 1.0, rng: &rng)
        }
        XCTAssertEqual(b.state, .drag)
        b.endDrag()
        XCTAssertEqual(b.state, .happy)
    }

    func testStateTimeoutTransitions() {
        var b = PetBrain()
        b.petHead()
        XCTAssertEqual(b.state, .happy)
        // happy 2.6s 后应切走
        var changed = false
        for _ in 0..<40 {
            if b.tick(dt: 0.1, rng: &rng) { changed = true; break }
        }
        XCTAssertTrue(changed)
        XCTAssertTrue(b.state.isAutonomous)
    }

    func testSleepToggle() {
        var b = PetBrain()
        b.toggleSleep()
        XCTAssertEqual(b.state, .sleep)
        b.feed()                              // 睡着不吃
        XCTAssertEqual(b.state, .sleep)
        b.toggleSleep()
        XCTAssertEqual(b.state, .idle)
    }

    func testPickNextStateOnlyAutonomous() {
        let b = PetBrain()
        for _ in 0..<200 {
            let s = b.pickNextState(rng: &rng)
            XCTAssertTrue(s.isAutonomous, "\(s) 不应被自主调度选中")
        }
    }

    func testLowEnergyFavorsSleep() {
        var tired = PetBrain(vitals: PetVitals(satiety: 80, mood: 80, energy: 5))
        var sleepCount = 0
        for _ in 0..<400 {
            if tired.pickNextState(rng: &rng) == .sleep { sleepCount += 1 }
        }
        XCTAssertGreaterThan(sleepCount, 150)  // 权重 60/133 ≈ 45%
    }

    func testSaveDataCodableRoundtrip() throws {
        let data = PetStore.SaveData(vitals: PetVitals(satiety: 42, mood: 66, energy: 88),
                                     lastTick: Date(timeIntervalSince1970: 1_700_000_000),
                                     petName: "泡泡", totalFeeds: 3, totalPets: 7,
                                     bornAt: Date(timeIntervalSince1970: 1_699_000_000))
        let raw = try JSONEncoder().encode(data)
        let back = try JSONDecoder().decode(PetStore.SaveData.self, from: raw)
        XCTAssertEqual(back.vitals, data.vitals)
        XCTAssertEqual(back.petName, "泡泡")
        XCTAssertEqual(back.totalFeeds, 3)
    }

    func testStorePersistsToDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = PetStore(directory: dir)
        var brain = PetBrain(vitals: PetVitals(satiety: 33, mood: 44, energy: 55))
        brain.lastTick = Date()
        store.save(brain: brain)
        store.rename("  深蓝  ")
        store.recordFeed()

        let reloaded = PetStore(directory: dir)
        XCTAssertEqual(reloaded.data.vitals.satiety, 33, accuracy: 0.001)
        XCTAssertEqual(reloaded.data.petName, "深蓝")
        XCTAssertEqual(reloaded.data.totalFeeds, 1)
        try? FileManager.default.removeItem(at: dir)
    }
}