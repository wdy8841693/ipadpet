import SpriteKit

/// 鲸鱼娘渲染节点：分层拼装（身体/尾巴/鳍/脸），用 SKAction 做程序化动画。
/// 不使用纹理序列帧 → 内存占用极小（A8 + 2GB RAM 友好），任意分辨率不糊。
final class PetNode: SKNode {

    // 分层部件
    private let body = SKSpriteNode(imageNamed: "whale_body")
    private let tail = SKSpriteNode(imageNamed: "whale_tail")
    private let finL = SKSpriteNode(imageNamed: "whale_fin")
    private let finR = SKSpriteNode(imageNamed: "whale_fin")
    private let faceNormal = SKSpriteNode(imageNamed: "whale_face_normal")
    private let faceHappy = SKSpriteNode(imageNamed: "whale_face_happy")
    private let faceSleep = SKSpriteNode(imageNamed: "whale_face_sleep")
    private let faceSad = SKSpriteNode(imageNamed: "whale_face_sad")
    private let blush = SKSpriteNode(imageNamed: "whale_blush")
    private let hair = SKSpriteNode(imageNamed: "whale_hair")       // 鲸鱼娘的"头发"= 喷水鳍冠
    private let spout = SKSpriteNode(imageNamed: "whale_spout")     // 喷水

    /// 逻辑尺寸（点）。场景按屏幕缩放整只宠物。
    static let nominalSize = CGSize(width: 260, height: 300)

    private(set) var animState: PetState = .idle

    override init() {
        super.init()
        buildHierarchy()
        applyState(.idle, wellbeing: .ok)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildHierarchy() {
        addChild(rig)   // 所有部件挂在 rig 下；根节点位置只由场景控制
        // z 序：尾巴 < 后鳍 < 身体 < 前鳍 < 头发 < 脸 < 腮红 < 喷水
        tail.zPosition = 1
        tail.anchorPoint = CGPoint(x: 0.5, y: 0.9)   // 以尾根为轴摆动
        tail.position = CGPoint(x: 0, y: -70)
        rig.addChild(tail)

        finL.zPosition = 2
        finL.position = CGPoint(x: -96, y: -26)
        finL.zRotation = -0.25
        rig.addChild(finL)

        body.zPosition = 3
        rig.addChild(body)

        finR.zPosition = 4
        finR.position = CGPoint(x: 96, y: -26)
        finR.xScale = -1
        finR.zRotation = 0.25
        rig.addChild(finR)

        hair.zPosition = 5
        hair.position = CGPoint(x: 0, y: 108)
        rig.addChild(hair)

        for face in [faceNormal, faceHappy, faceSleep, faceSad] {
            face.zPosition = 6
            face.position = CGPoint(x: 0, y: 18)
            face.isHidden = true
            rig.addChild(face)
        }
        faceNormal.isHidden = false

        blush.zPosition = 7
        blush.position = CGPoint(x: 0, y: 2)
        blush.alpha = 0
        rig.addChild(blush)

        spout.zPosition = 8
        spout.anchorPoint = CGPoint(x: 0.5, y: 0)
        spout.position = CGPoint(x: 0, y: 128)
        spout.alpha = 0
        rig.addChild(spout)

        isUserInteractionEnabled = false   // 事件统一由 Scene 处理
    }

    /// 场景整体缩放宠物时调用。xScale 符号保留朝向（由场景翻转）。
    var baseScale: CGFloat = 1.0 {
        didSet {
            let sign: CGFloat = xScale < 0 ? -1 : 1
            xScale = sign * baseScale
            yScale = baseScale
        }
    }

    // MARK: - 状态动画

    func applyState(_ state: PetState, wellbeing: PetVitals.Wellbeing) {
        animState = state
        removeAllActions()
        rig.removeAllActions()
        for part in [tail, finL, finR, hair, spout, body, blush,
                     faceNormal, faceHappy, faceSleep, faceSad] {
            part.removeAllActions()
        }
        // 复位部件姿态，避免上一状态的旋转/缩放残留
        rig.position = .zero
        rig.zRotation = 0
        finL.zRotation = -0.25
        finR.zRotation = 0.25
        body.setScale(1.0)
        faceNormal.yScale = 1.0
        faceSad.yScale = 1.0
        spout.alpha = 0
        spout.setScale(0.2)
        blush.alpha = 0
        setFace(for: state, wellbeing: wellbeing)

        switch state {
        case .idle:
            runBob(amplitude: 6, period: 2.4)
            runTailSway(period: 2.0)
            runBlinkLoop()
        case .walk:
            runBob(amplitude: 4, period: 0.7)
            runTailSway(period: 0.7)
            runFinFlap(period: 0.7)
        case .swim:
            runBob(amplitude: 10, period: 1.6)
            runTailSway(period: 0.9)
            runFinFlap(period: 0.9)
            runSpout(every: 4.0)
        case .happy:
            runBob(amplitude: 14, period: 0.5)
            runTailSway(period: 0.4)
            blush.run(.sequence([.fadeIn(withDuration: 0.15), .wait(forDuration: 1.8),
                                 .fadeOut(withDuration: 0.8)]))
        case .eat:
            runChew()
            runTailSway(period: 0.5)
        case .sleep:
            runBob(amplitude: 3, period: 3.2)
            runTailSway(period: 3.2)
        case .drag:
            finL.run(.rotate(toAngle: -1.0, duration: 0.2))
            finR.run(.rotate(toAngle: 1.0, duration: 0.2))
            rig.run(.repeatForever(.sequence([
                .rotate(toAngle: 0.08, duration: 0.25),
                .rotate(toAngle: -0.08, duration: 0.25),
            ])))
        case .play:
            runBob(amplitude: 18, period: 0.6)
            runTailSway(period: 0.45)
            runFinFlap(period: 0.45)
            runSpout(every: 2.0)
        }
    }

    private func setFace(for state: PetState, wellbeing: PetVitals.Wellbeing) {
        let target: SKSpriteNode
        switch state {
        case .happy, .eat, .play: target = faceHappy
        case .sleep, .drag:       target = state == .sleep ? faceSleep : faceSad
        default:
            target = (wellbeing == .sad || wellbeing == .hungry) ? faceSad : faceNormal
        }
        for f in [faceNormal, faceHappy, faceSleep, faceSad] { f.isHidden = (f !== target) }
    }

    // MARK: - 基础动作积木

    /// 上下漂浮作用于内部容器而非根节点，避免与场景的移动/拖拽定位互相覆盖。
    private let rig = SKNode()

    private func runBob(amplitude: CGFloat, period: TimeInterval) {
        let up = SKAction.moveBy(x: 0, y: amplitude, duration: period / 2)
        up.timingMode = .easeInEaseOut
        let down = up.reversed()
        rig.run(.repeatForever(.sequence([up, down])), withKey: "bob")
    }

    private func runTailSway(period: TimeInterval) {
        let a: CGFloat = 0.22
        let l = SKAction.rotate(toAngle: a, duration: period / 2)
        l.timingMode = .easeInEaseOut
        let r = SKAction.rotate(toAngle: -a, duration: period / 2)
        r.timingMode = .easeInEaseOut
        tail.run(.repeatForever(.sequence([l, r])), withKey: "sway")
    }

    private func runFinFlap(period: TimeInterval) {
        // 左右鳍镜像摆动（finR.xScale = -1，角度取反）
        let flapL = SKAction.sequence([
            .rotate(byAngle: -0.35, duration: period / 2),
            .rotate(byAngle: 0.35, duration: period / 2),
        ])
        let flapR = SKAction.sequence([
            .rotate(byAngle: 0.35, duration: period / 2),
            .rotate(byAngle: -0.35, duration: period / 2),
        ])
        finL.run(.repeatForever(flapL))
        finR.run(.repeatForever(flapR))
    }

    private func runBlinkLoop() {
        // 用快速压扁脸部模拟眨眼（省一套闭眼贴图）
        let blink = SKAction.sequence([
            .scaleY(0.08, duration: 0.06),
            .scaleY(1.0, duration: 0.08),
        ])
        let wait = SKAction.wait(forDuration: 3.4, withRange: 2.0)
        let loop = SKAction.repeatForever(.sequence([wait, blink]))
        faceNormal.run(loop, withKey: "blink")
        faceSad.run(loop, withKey: "blink")
    }

    private func runChew() {
        let chew = SKAction.sequence([
            .scaleY(0.94, duration: 0.18),
            .scaleY(1.0, duration: 0.18),
        ])
        body.run(.repeatForever(chew), withKey: "chew")
    }

    private func runSpout(every interval: TimeInterval) {
        let burst = SKAction.sequence([
            .group([.fadeIn(withDuration: 0.15), .scaleY(1.0, duration: 0.3)]),
            .wait(forDuration: 0.4),
            .group([.fadeOut(withDuration: 0.3), .scaleY(0.2, duration: 0.3)]),
        ])
        spout.setScale(0.2)
        spout.run(.repeatForever(.sequence([.wait(forDuration: interval), burst])), withKey: "spout")
    }

    /// 摸头时的一次性挤压反馈（Q 弹）。作用于身体部件而非整节点，
    /// 避免覆盖场景设置的整体缩放。
    func squish() {
        body.removeAction(forKey: "squish")
        let s = SKAction.sequence([
            .scale(to: 0.92, duration: 0.08),
            .scale(to: 1.04, duration: 0.10),
            .scale(to: 1.0, duration: 0.10),
        ])
        body.run(s, withKey: "squish")
    }
}