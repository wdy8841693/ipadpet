import SpriteKit

/// 鲸鱼娘渲染节点：整张立绘切换（素材来自开源项目 dsh-whale-musume，MIT）
/// + SKAction 程序化运动（漂浮/摇摆/挤压/翻转）。
///
/// 为什么用整图而不是分层部件：上游素材是完成度很高的 Q 版立绘
/// （蓝发女仆裙 + 鲸尾 + 鳍耳），每个状态一张 512×512 RGBA。
/// 10 张纹理 ≈ 8.6MB 显存，A8 可承受；动画靠运动变换而非序列帧，
/// 30fps 下 GPU 负担极低。
final class PetNode: SKNode {

    /// 状态 → 立绘纹理名（与 Tools/art/import_upstream.py 的 STATE_MAP 对应）
    private static let textureNames: [PetState: String] = [
        .idle:  "pet_idle",
        .walk:  "pet_walk",
        .swim:  "pet_swim",
        .happy: "pet_happy",
        .eat:   "pet_eat",
        .sleep: "pet_sleep",
        .drag:  "pet_drag",
        .play:  "pet_play",
        .listening: "pet_happy",
        .thinking: "pet_swim",
        .speaking: "pet_greet",
    ]

    /// 逻辑尺寸（点）：导入脚本统一为 420×420 画布、底部对齐。
    static let nominalSize = CGSize(width: 420, height: 420)

    private let sprite = SKSpriteNode(imageNamed: "pet_idle")
    /// 运动容器：漂浮/摇摆作用于 rig，根节点位置只由场景控制。
    private let rig = SKNode()

    private(set) var animState: PetState = .idle
    private var currentTexture: String = "pet_idle"

    override init() {
        super.init()
        // 锚点底边中心：站立时 position 即"脚底"
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        rig.addChild(sprite)
        addChild(rig)
        isUserInteractionEnabled = false   // 事件统一由 Scene 处理
        applyState(.idle, wellbeing: .ok)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    /// 场景整体缩放宠物时调用。xScale 符号保留朝向（由场景翻转）。
    var baseScale: CGFloat = 1.0 {
        didSet {
            let sign: CGFloat = xScale < 0 ? -1 : 1
            xScale = sign * baseScale
            yScale = baseScale
        }
    }

    // MARK: - 状态切换

    func applyState(_ state: PetState, wellbeing: PetVitals.Wellbeing) {
        animState = state
        rig.removeAllActions()
        sprite.removeAllActions()
        rig.position = .zero
        rig.zRotation = 0
        sprite.setScale(1.0)
        sprite.alpha = 1

        // 换立绘（低落时用委屈脸覆盖 idle/walk；打招呼用挥手）
        var name = Self.textureNames[state] ?? "pet_idle"
        if (state == .idle || state == .walk),
           wellbeing == .sad || wellbeing == .hungry {
            name = "pet_sad"
        }
        if state == .happy, wellbeing == .great, Bool.random() {
            name = "pet_greet"   // 心情极好时偶尔挥手代替脸红
        }
        if name != currentTexture {
            currentTexture = name
            sprite.texture = SKTexture(imageNamed: name)
        }

        switch state {
        case .idle:
            runBob(amplitude: 5, period: 2.6)
            runBreath()
        case .walk:
            runBob(amplitude: 4, period: 0.55)
            runWaddle(period: 0.55)          // 小碎步左右摇
        case .swim:
            runBob(amplitude: 12, period: 1.8)
            runSway(angle: 0.10, period: 1.8) // 游动摇摆
        case .happy:
            runBounce(height: 16, period: 0.5)
            runSquishLoop()                   // Q 弹庆祝
        case .eat:
            runNibble()                       // 小幅点头咀嚼
        case .sleep:
            runBob(amplitude: 2.5, period: 3.4)
            runBreath(slow: true)
        case .drag:
            runDangle()                       // 被拎起来晃荡
        case .play:
            runBounce(height: 20, period: 0.55)
            runSway(angle: 0.12, period: 0.55)
        case .listening:
            runBob(amplitude: 8, period: 1.2)
            runBreath()
        case .thinking:
            runBob(amplitude: 4, period: 2.0)
            runSway(angle: 0.06, period: 2.0)
        case .speaking:
            runBob(amplitude: 6, period: 0.8)
            runBreath()
        }
    }

    // MARK: - 动作积木

    private func runBob(amplitude: CGFloat, period: TimeInterval) {
        let up = SKAction.moveBy(x: 0, y: amplitude, duration: period / 2)
        up.timingMode = .easeInEaseOut
        rig.run(.repeatForever(.sequence([up, up.reversed()])), withKey: "bob")
    }

    private func runBreath(slow: Bool = false) {
        let t: TimeInterval = slow ? 2.2 : 1.5
        let breath = SKAction.sequence([
            .scaleY(to:1.012, duration: t),
            .scaleY(to:1.0, duration: t),
        ])
        sprite.run(.repeatForever(breath), withKey: "breath")
    }

    private func runWaddle(period: TimeInterval) {
        let a: CGFloat = 0.05
        let l = SKAction.rotate(toAngle: a, duration: period / 2)
        l.timingMode = .easeInEaseOut
        let r = SKAction.rotate(toAngle: -a, duration: period / 2)
        r.timingMode = .easeInEaseOut
        rig.run(.repeatForever(.sequence([l, r])), withKey: "waddle")
    }

    private func runSway(angle: CGFloat, period: TimeInterval) {
        let l = SKAction.rotate(toAngle: angle, duration: period / 2)
        l.timingMode = .easeInEaseOut
        let r = SKAction.rotate(toAngle: -angle, duration: period / 2)
        r.timingMode = .easeInEaseOut
        rig.run(.repeatForever(.sequence([l, r])), withKey: "sway")
    }

    private func runBounce(height: CGFloat, period: TimeInterval) {
        let up = SKAction.moveBy(x: 0, y: height, duration: period / 2)
        up.timingMode = .easeOut
        let down = SKAction.moveBy(x: 0, y: -height, duration: period / 2)
        down.timingMode = .easeIn
        rig.run(.repeatForever(.sequence([up, down])), withKey: "bounce")
    }

    private func runSquishLoop() {
        let s = SKAction.sequence([
            .scaleX(to:1.04, y: 0.96, duration: 0.25),
            .scaleX(to:0.98, y: 1.03, duration: 0.25),
        ])
        sprite.run(.repeatForever(s), withKey: "squishloop")
    }

    private func runNibble() {
        let nod = SKAction.sequence([
            .rotate(toAngle: 0.04, duration: 0.22),
            .rotate(toAngle: 0.0, duration: 0.22),
        ])
        rig.run(.repeatForever(nod), withKey: "nibble")
    }

    private func runDangle() {
        let swing = SKAction.sequence([
            .rotate(toAngle: 0.12, duration: 0.3),
            .rotate(toAngle: -0.12, duration: 0.3),
        ])
        swing.timingMode = .easeInEaseOut
        rig.run(.repeatForever(swing), withKey: "dangle")
    }

    /// 摸头一次性 Q 弹反馈。
    func squish() {
        // 避免与 happy 状态的循环缩放同时写同一节点。
        sprite.removeAction(forKey: "squishloop")
        sprite.removeAction(forKey: "squish")
        let s = SKAction.sequence([
            .scaleX(to:1.08, y: 0.90, duration: 0.08),
            .scaleX(to:0.96, y: 1.05, duration: 0.10),
            .scale(to: 1.0, duration: 0.10),
        ])
        sprite.run(s, withKey: "squish")
    }
}