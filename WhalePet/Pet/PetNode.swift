import SpriteKit

/// 鲸鱼娘渲染节点：Q 版人形少女（蓝发 + 水手领连衣裙 + 人手人腿）+ 鲸元素
/// （身后鲸尾 / 头侧鳍发饰 / 头顶喷水孔）。分层拼装，SKAction 程序化动画。
/// 不使用纹理序列帧 → 内存占用极小（A8 + 2GB RAM 友好），任意分辨率不糊。
final class PetNode: SKNode {

    // 分层部件（z 序从后到前）
    private let tail = SKSpriteNode(imageNamed: "whale_tail")          // 身后鲸尾
    private let hairBack = SKSpriteNode(imageNamed: "whale_hair_back") // 蓝色长发
    private let legL = SKSpriteNode(imageNamed: "whale_leg")
    private let legR = SKSpriteNode(imageNamed: "whale_leg")
    private let armL = SKSpriteNode(imageNamed: "whale_arm")
    private let armR = SKSpriteNode(imageNamed: "whale_arm")
    private let body = SKSpriteNode(imageNamed: "whale_body")          // 连衣裙躯干
    private let head = SKSpriteNode(imageNamed: "whale_head")          // 脸底+刘海+呆毛
    private let finL = SKSpriteNode(imageNamed: "whale_fin")           // 鳍发饰（左）
    private let finR = SKSpriteNode(imageNamed: "whale_fin")           // 鳍发饰（右）
    private let faceNormal = SKSpriteNode(imageNamed: "whale_face_normal")
    private let faceHappy = SKSpriteNode(imageNamed: "whale_face_happy")
    private let faceSleep = SKSpriteNode(imageNamed: "whale_face_sleep")
    private let faceSad = SKSpriteNode(imageNamed: "whale_face_sad")
    private let blush = SKSpriteNode(imageNamed: "whale_blush")
    private let spout = SKSpriteNode(imageNamed: "whale_spout")        // 头顶喷水

    /// 逻辑尺寸（点）。场景按屏幕缩放整只宠物。
    static let nominalSize = CGSize(width: 240, height: 340)

    private(set) var animState: PetState = .idle

    /// 漂浮/摇晃作用于内部容器；根节点位置只由场景控制。
    private let rig = SKNode()
    /// 头部子容器：点头/歪头动画不影响身体。
    private let headRig = SKNode()

    override init() {
        super.init()
        buildHierarchy()
        applyState(.idle, wellbeing: .ok)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildHierarchy() {
        addChild(rig)

        // —— 身后层 ——
        tail.zPosition = 1
        tail.anchorPoint = CGPoint(x: 0.5, y: 0.95)   // 尾根为轴
        tail.position = CGPoint(x: 62, y: 40)
        tail.zRotation = -0.5                          // 向右后下方伸出
        rig.addChild(tail)

        hairBack.zPosition = 2
        hairBack.position = CGPoint(x: 0, y: 58)
        rig.addChild(hairBack)

        // —— 腿（裙摆下露出）——
        legL.zPosition = 3
        legL.anchorPoint = CGPoint(x: 0.5, y: 1.0)     // 髋部为轴
        legL.position = CGPoint(x: -18, y: -78)
        rig.addChild(legL)
        legR.zPosition = 3
        legR.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        legR.position = CGPoint(x: 18, y: -78)
        rig.addChild(legR)

        // —— 手臂（肩为轴）——
        armL.zPosition = 4
        armL.anchorPoint = CGPoint(x: 0.6, y: 0.95)
        armL.position = CGPoint(x: -40, y: 28)
        armL.zRotation = 0.18
        rig.addChild(armL)
        armR.zPosition = 6                             // 右臂在裙前
        armR.anchorPoint = CGPoint(x: 0.4, y: 0.95)
        armR.position = CGPoint(x: 40, y: 28)
        armR.xScale = -1
        armR.zRotation = -0.18
        rig.addChild(armR)

        // —— 躯干 ——
        body.zPosition = 5
        body.position = CGPoint(x: 0, y: -22)
        rig.addChild(body)

        // —— 头部容器 ——
        headRig.zPosition = 7
        headRig.position = CGPoint(x: 0, y: 62)
        rig.addChild(headRig)

        head.zPosition = 1
        headRig.addChild(head)

        finL.zPosition = 2
        finL.position = CGPoint(x: -76, y: 12)
        finL.zRotation = 0.45
        headRig.addChild(finL)
        finR.zPosition = 2
        finR.position = CGPoint(x: 76, y: 12)
        finR.xScale = -1
        finR.zRotation = -0.45
        headRig.addChild(finR)

        for face in [faceNormal, faceHappy, faceSleep, faceSad] {
            face.zPosition = 3
            face.position = CGPoint(x: 0, y: -12)     // 对齐脸心
            face.isHidden = true
            headRig.addChild(face)
        }
        faceNormal.isHidden = false

        blush.zPosition = 4
        blush.position = CGPoint(x: 0, y: -12)
        blush.alpha = 0
        headRig.addChild(blush)

        spout.zPosition = 5
        spout.anchorPoint = CGPoint(x: 0.5, y: 0)
        spout.position = CGPoint(x: 28, y: 62)        // 头顶喷水孔上方
        spout.alpha = 0
        headRig.addChild(spout)

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
        headRig.removeAllActions()
        for part in [tail, hairBack, legL, legR, armL, armR, body, head,
                     finL, finR, spout, blush,
                     faceNormal, faceHappy, faceSleep, faceSad] {
            part.removeAllActions()
        }
        // 复位姿态，避免上一状态残留
        rig.position = .zero
        rig.zRotation = 0
        headRig.zRotation = 0
        headRig.position = CGPoint(x: 0, y: 62)
        tail.zRotation = -0.5
        armL.zRotation = 0.18
        armR.zRotation = -0.18
        legL.zRotation = 0
        legR.zRotation = 0
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
            runBreath()
            runBlinkLoop()
        case .walk:
            runBob(amplitude: 4, period: 0.6)
            runTailSway(period: 0.6)
            runLegSwing(period: 0.6)
            runArmSwing(period: 0.6)
        case .swim:
            runBob(amplitude: 10, period: 1.6)
            runTailSway(period: 0.9)
            runArmPaddle(period: 0.9)
            runLegKick(period: 0.9)
            runSpout(every: 4.0)
            rig.run(.rotate(toAngle: 0.12, duration: 0.6))   // 游动时微微前倾
        case .happy:
            runBob(amplitude: 14, period: 0.5)
            runTailSway(period: 0.4)
            runArmCheer()
            blush.run(.sequence([.fadeIn(withDuration: 0.15), .wait(forDuration: 1.8),
                                 .fadeOut(withDuration: 0.8)]))
        case .eat:
            runChew()
            runTailSway(period: 0.5)
            runArmHold()                                     // 双手捧到嘴边
        case .sleep:
            runBob(amplitude: 3, period: 3.2)
            runTailSway(period: 3.2)
            headRig.run(.rotate(toAngle: 0.14, duration: 0.8))  // 低头打盹
            runBreath()
        case .drag:
            // 被拎起来：四肢乱晃
            armL.run(.rotate(toAngle: 1.1, duration: 0.2))
            armR.run(.rotate(toAngle: -1.1, duration: 0.2))
            let dangle = SKAction.sequence([
                .rotate(byAngle: 0.25, duration: 0.22),
                .rotate(byAngle: -0.25, duration: 0.22),
            ])
            legL.run(.repeatForever(dangle))
            legR.run(.repeatForever(dangle.reversed()))
            rig.run(.repeatForever(.sequence([
                .rotate(toAngle: 0.08, duration: 0.25),
                .rotate(toAngle: -0.08, duration: 0.25),
            ])))
        case .play:
            runBob(amplitude: 18, period: 0.6)
            runTailSway(period: 0.45)
            runArmCheer()
            runLegKick(period: 0.6)
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

    private func runBob(amplitude: CGFloat, period: TimeInterval) {
        let up = SKAction.moveBy(x: 0, y: amplitude, duration: period / 2)
        up.timingMode = .easeInEaseOut
        let down = up.reversed()
        rig.run(.repeatForever(.sequence([up, down])), withKey: "bob")
    }

    private func runTailSway(period: TimeInterval) {
        let base: CGFloat = -0.5
        let a: CGFloat = 0.25
        let l = SKAction.rotate(toAngle: base + a, duration: period / 2)
        l.timingMode = .easeInEaseOut
        let r = SKAction.rotate(toAngle: base - a, duration: period / 2)
        r.timingMode = .easeInEaseOut
        tail.run(.repeatForever(.sequence([l, r])), withKey: "sway")
    }

    private func runBreath() {
        // 呼吸：躯干轻微起伏
        let breath = SKAction.sequence([
            .scaleY(1.015, duration: 1.4),
            .scaleY(1.0, duration: 1.4),
        ])
        body.run(.repeatForever(breath), withKey: "breath")
    }

    private func runLegSwing(period: TimeInterval) {
        let swing = SKAction.sequence([
            .rotate(toAngle: 0.3, duration: period / 2),
            .rotate(toAngle: -0.3, duration: period / 2),
        ])
        legL.run(.repeatForever(swing))
        legR.run(.repeatForever(swing.reversed()))
    }

    private func runArmSwing(period: TimeInterval) {
        let swingL = SKAction.sequence([
            .rotate(toAngle: 0.4, duration: period / 2),
            .rotate(toAngle: -0.1, duration: period / 2),
        ])
        let swingR = SKAction.sequence([
            .rotate(toAngle: -0.4, duration: period / 2),
            .rotate(toAngle: 0.1, duration: period / 2),
        ])
        armL.run(.repeatForever(swingL))
        armR.run(.repeatForever(swingR))
    }

    private func runArmPaddle(period: TimeInterval) {
        // 划水：双臂交替大幅摆
        let paddleL = SKAction.sequence([
            .rotate(toAngle: 0.9, duration: period / 2),
            .rotate(toAngle: -0.3, duration: period / 2),
        ])
        let paddleR = SKAction.sequence([
            .rotate(toAngle: -0.9, duration: period / 2),
            .rotate(toAngle: 0.3, duration: period / 2),
        ])
        armL.run(.repeatForever(paddleL))
        armR.run(.repeatForever(paddleR))
    }

    private func runLegKick(period: TimeInterval) {
        let kick = SKAction.sequence([
            .rotate(toAngle: 0.45, duration: period / 2),
            .rotate(toAngle: -0.2, duration: period / 2),
        ])
        legL.run(.repeatForever(kick))
        legR.run(.repeatForever(kick.reversed()))
    }

    private func runArmCheer() {
        // 举手欢呼 \^o^/
        armL.run(.rotate(toAngle: 2.4, duration: 0.25))
        armR.run(.rotate(toAngle: -2.4, duration: 0.25))
        let wave = SKAction.sequence([
            .rotate(byAngle: 0.2, duration: 0.3),
            .rotate(byAngle: -0.2, duration: 0.3),
        ])
        armL.run(.repeatForever(wave), withKey: "wave")
        armR.run(.repeatForever(wave.reversed()), withKey: "wave")
    }

    private func runArmHold() {
        // 双手捧到嘴边等投喂
        armL.run(.rotate(toAngle: 1.5, duration: 0.3))
        armR.run(.rotate(toAngle: -1.5, duration: 0.3))
    }

    private func runBlinkLoop() {
        // 快速压扁表情模拟眨眼（省一套闭眼贴图）
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
        // 咀嚼：头部小幅上下 + 躯干微动
        let chew = SKAction.sequence([
            .moveBy(x: 0, y: -2.5, duration: 0.18),
            .moveBy(x: 0, y: 2.5, duration: 0.18),
        ])
        headRig.run(.repeatForever(chew), withKey: "chew")
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

    /// 摸头时的一次性挤压反馈（Q 弹）。作用于躯干而非整节点，
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