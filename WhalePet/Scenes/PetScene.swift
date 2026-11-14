import SpriteKit

/// 主场景：海底背景 + 鲸鱼娘 + 粒子点缀 + 触摸交互。
/// 性能预算（iPad mini 4 / A8 / 2GB RAM）：
/// - 目标 30fps（preferredFramesPerSecond），不追 60；
/// - 无物理引擎、无实时光照，气泡用少量 SKShapeNode 循环复用；
/// - 纹理全部为小尺寸 PNG（部件分层），总显存 < 10MB。
final class PetScene: SKScene {

    private let pet = PetNode()
    private var brain: PetBrain
    private let store: PetStore
    private var dialogue = Dialogue()

    private var lastUpdate: TimeInterval = 0
    private var saveAccumulator: TimeInterval = 0
    private var bubbleTimer: TimeInterval = 6

    // 移动目标
    private var moveTarget: CGPoint?
    private var facingRight = false

    // UI 层（SKNode 实现，避免 UIKit 混排的老设备兼容问题）
    private let speechBubble = SpeechBubbleNode()
    private var hudNode: HUDNode!

    // 拖拽
    private var dragOffset: CGVector = .zero
    private var isDragging = false
    private var touchDownTime: TimeInterval = 0
    private var touchDownPoint: CGPoint = .zero

    // 环境
    private var bubbles: [SKShapeNode] = []
    private let floorRatio: CGFloat = 0.16   // "海底地面"高度占比

    init(size: CGSize, store: PetStore) {
        self.store = store
        var b = PetBrain(vitals: store.data.vitals)
        b.lastTick = store.data.lastTick
        b.settleOffline(until: Date())
        self.brain = b
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = SKColor(red: 0.05, green: 0.16, blue: 0.30, alpha: 1)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    override func didMove(to view: SKView) {
        buildBackground()
        buildBubbles()

        pet.baseScale = petScaleForScreen()
        pet.position = CGPoint(x: size.width / 2, y: floorStandY())
        addChild(pet)

        speechBubble.zPosition = 50
        addChild(speechBubble)

        hudNode = HUDNode(sceneSize: size)
        hudNode.zPosition = 60
        hudNode.onAction = { [weak self] action in self?.handleHUD(action) }
        addChild(hudNode)

        pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
        showSpeech(greeting())
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard hudNode != nil else { return }   // 初始化前跳过
        hudNode.layout(sceneSize: size)
        pet.baseScale = petScaleForScreen()
        clampPetPosition()
        layoutBackground()
    }

    // MARK: - 帧循环

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate == 0 ? 0 : min(currentTime - lastUpdate, 0.1)
        lastUpdate = currentTime
        guard dt > 0 else { return }

        var rng = SystemRandomNumberGenerator()
        if brain.tick(dt: dt, rng: &rng) {
            pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
            onStateChanged()
        }

        updateMovement(dt: dt)
        updateBubbles(dt: dt)

        // 气泡台词：每 12~20 秒冒一句
        bubbleTimer -= dt
        if bubbleTimer <= 0 {
            bubbleTimer = Double.random(in: 12...20)
            if let line = dialogue.line(for: brain.state, wellbeing: brain.vitals.wellbeing,
                                        name: store.data.petName) {
                showSpeech(line)
            }
        }

        // 每 15 秒自动存档
        saveAccumulator += dt
        if saveAccumulator > 15 {
            saveAccumulator = 0
            store.save(brain: brain)
        }

        hudNode.update(vitals: brain.vitals, state: brain.state)
        positionSpeechBubble()
    }

    // MARK: - 状态切换副作用

    private func onStateChanged() {
        switch brain.state {
        case .walk:
            let margin: CGFloat = 90
            moveTarget = CGPoint(x: CGFloat.random(in: margin...(size.width - margin)), y: floorStandY())
        case .swim:
            moveTarget = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)),
                                 y: CGFloat.random(in: (size.height * 0.35)...(size.height * 0.75)))
        case .idle, .sleep, .eat, .happy, .play:
            // 睡觉/吃饭缓缓落回地面
            moveTarget = CGPoint(x: pet.position.x, y: floorStandY())
        case .drag:
            moveTarget = nil
        }
        if let line = dialogue.line(for: brain.state, wellbeing: brain.vitals.wellbeing,
                                    name: store.data.petName), brain.state != .idle {
            showSpeech(line)
        }
    }

    private func updateMovement(dt: TimeInterval) {
        guard !isDragging, let target = moveTarget else { return }
        let speed: CGFloat = brain.state == .swim ? 90 : 55
        let dx = target.x - pet.position.x
        let dy = target.y - pet.position.y
        let dist = hypot(dx, dy)
        if dist < 4 { moveTarget = nil; return }
        let step = min(speed * CGFloat(dt), dist)
        pet.position.x += dx / dist * step
        pet.position.y += dy / dist * step
        // 朝向
        if abs(dx) > 8 {
            let right = dx > 0
            if right != facingRight {
                facingRight = right
                pet.xScale = (right ? -1 : 1) * pet.baseScale
            }
        }
    }

    // MARK: - 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if hudNode.handleTouch(at: p) { return }
        if petHitTest(p) {
            isDragging = true
            touchDownTime = t.timestamp
            touchDownPoint = p
            dragOffset = CGVector(dx: pet.position.x - p.x, dy: pet.position.y - p.y)
            brain.beginDrag()
            pet.applyState(.drag, wellbeing: brain.vitals.wellbeing)
            speechBubble.hide()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDragging, let t = touches.first else { return }
        let p = t.location(in: self)
        pet.position = CGPoint(x: p.x + dragOffset.dx, y: p.y + dragOffset.dy)
        clampPetPosition()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDragging, let t = touches.first else { return }
        isDragging = false
        let moved = hypot(t.location(in: self).x - touchDownPoint.x,
                          t.location(in: self).y - touchDownPoint.y)
        let quick = t.timestamp - touchDownTime < 0.35
        if moved < 12 && quick {
            // 轻点 = 摸头
            brain.petHead()
            store.recordPet()
            pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
            pet.squish()          // 在 applyState 之后，避免被部件复位清掉
            spawnHearts(at: pet.position)
        } else {
            brain.endDrag()
            pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
        }
        onStateChanged()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isDragging {
            isDragging = false
            brain.endDrag()
            pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
        }
    }

    private func petHitTest(_ p: CGPoint) -> Bool {
        let half = CGSize(width: PetNode.nominalSize.width * pet.baseScale * 0.62,
                          height: PetNode.nominalSize.height * pet.baseScale * 0.62)
        return abs(p.x - pet.position.x) < half.width && abs(p.y - pet.position.y) < half.height
    }

    // MARK: - HUD 动作

    private func handleHUD(_ action: HUDNode.Action) {
        switch action {
        case .feed:
            brain.feed()
            store.recordFeed()
            spawnFish()
        case .play:
            brain.playBall()
            spawnBubbleBall()
        case .sleep:
            brain.toggleSleep()
        case .rename:
            onRenameRequest?()
        }
        pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
        onStateChanged()
        store.save(brain: brain)
    }

    /// 由 ViewController 注入：弹 UIKit 输入框改名。
    var onRenameRequest: (() -> Void)?

    func renamePet(to name: String) {
        store.rename(name)
        showSpeech("以后就叫我\(store.data.petName)啦！")
    }

    func appWillResign() { store.save(brain: brain) }

    func appDidBecomeActive() {
        brain.settleOffline(until: Date())
        pet.applyState(brain.state, wellbeing: brain.vitals.wellbeing)
        showSpeech(greeting())
    }

    private func greeting() -> String {
        let w = brain.vitals.wellbeing
        switch w {
        case .hungry: return "\(store.data.petName)饿扁了……快投喂！"
        case .tired:  return "呼啊……\(store.data.petName)好困……"
        case .sad:    return "你终于回来啦……\(store.data.petName)好想你……"
        default:      return "欢迎回来！\(store.data.petName)一直在等你哦～"
        }
    }

    // MARK: - 布局辅助

    private func petScaleForScreen() -> CGFloat {
        // iPad mini 4: 768×1024pt。宠物约占屏宽 1/3。
        return max(0.6, min(1.15, size.width / 768.0))
    }

    private func floorY() -> CGFloat { size.height * floorRatio }
    private func floorStandY() -> CGFloat {
        floorY() + PetNode.nominalSize.height * pet.baseScale * 0.42
    }

    private func clampPetPosition() {
        let m: CGFloat = 60
        pet.position.x = min(max(pet.position.x, m), size.width - m)
        pet.position.y = min(max(pet.position.y, floorStandY() * 0.8), size.height - 120)
    }

    private func positionSpeechBubble() {
        speechBubble.position = CGPoint(x: pet.position.x,
                                        y: pet.position.y + PetNode.nominalSize.height * pet.baseScale * 0.62)
    }

    private func showSpeech(_ text: String) {
        speechBubble.show(text: text)
        positionSpeechBubble()
    }

    // MARK: - 背景与粒子（轻量）

    private var bgGradient: SKSpriteNode!
    private var floorNode: SKShapeNode!

    private func buildBackground() {
        // 静态渐变贴图（Tools/art 生成），比 SKEffectNode 渐变省 GPU
        bgGradient = SKSpriteNode(imageNamed: "bg_gradient")
        bgGradient.zPosition = -10
        addChild(bgGradient)
        floorNode = SKShapeNode()
        floorNode.fillColor = SKColor(red: 0.93, green: 0.85, blue: 0.66, alpha: 1)
        floorNode.strokeColor = .clear
        floorNode.zPosition = -5
        addChild(floorNode)
        layoutBackground()
    }

    private func layoutBackground() {
        bgGradient?.size = size
        bgGradient?.position = CGPoint(x: size.width / 2, y: size.height / 2)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: size.width, height: floorY()), transform: nil)
        floorNode?.path = path
    }

    private func buildBubbles() {
        // 12 个复用气泡，A8 上毫无压力
        for _ in 0..<12 {
            let r = CGFloat.random(in: 3...9)
            let b = SKShapeNode(circleOfRadius: r)
            b.strokeColor = SKColor(white: 1, alpha: 0.35)
            b.fillColor = SKColor(white: 1, alpha: 0.08)
            b.lineWidth = 1
            b.zPosition = -4
            resetBubble(b, randomY: true)
            addChild(b)
            bubbles.append(b)
        }
    }

    private func resetBubble(_ b: SKShapeNode, randomY: Bool) {
        b.position = CGPoint(x: CGFloat.random(in: 0...max(size.width, 1)),
                             y: randomY ? CGFloat.random(in: 0...max(size.height, 1)) : -12)
        b.userData = ["speed": Double(CGFloat.random(in: 18...42))]
    }

    private func updateBubbles(dt: TimeInterval) {
        for b in bubbles {
            let speed = (b.userData?["speed"] as? Double) ?? 25
            b.position.y += CGFloat(speed * dt)
            if b.position.y > size.height + 12 { resetBubble(b, randomY: false) }
        }
    }

    // MARK: - 一次性特效

    private func spawnHearts(at p: CGPoint) {
        for i in 0..<3 {
            let heart = SKSpriteNode(imageNamed: "fx_heart")
            heart.position = CGPoint(x: p.x + CGFloat(i - 1) * 34, y: p.y + 60)
            heart.zPosition = 40
            heart.setScale(0.7)
            addChild(heart)
            heart.run(.sequence([
                .group([.moveBy(x: CGFloat(i - 1) * 16, y: 90, duration: 1.0),
                        .fadeOut(withDuration: 1.0)]),
                .removeFromParent(),
            ]))
        }
    }

    private func spawnFish() {
        let fish = SKSpriteNode(imageNamed: "fx_fish")
        fish.position = CGPoint(x: pet.position.x + (facingRight ? -70 : 70), y: pet.position.y + 30)
        fish.zPosition = 40
        addChild(fish)
        fish.run(.sequence([
            .move(to: CGPoint(x: pet.position.x, y: pet.position.y + 10), duration: 0.5),
            .scale(to: 0.1, duration: 0.3),
            .removeFromParent(),
        ]))
    }

    private func spawnBubbleBall() {
        let ball = SKShapeNode(circleOfRadius: 22)
        ball.strokeColor = SKColor(white: 1, alpha: 0.7)
        ball.fillColor = SKColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.25)
        ball.lineWidth = 2
        ball.zPosition = 39
        ball.position = CGPoint(x: pet.position.x, y: pet.position.y + 120)
        addChild(ball)
        let bounce = SKAction.sequence([
            .moveBy(x: 60, y: -80, duration: 0.5),
            .moveBy(x: -50, y: 90, duration: 0.5),
            .moveBy(x: 40, y: -70, duration: 0.5),
        ])
        ball.run(.sequence([.repeat(bounce, count: 3), .fadeOut(withDuration: 0.4), .removeFromParent()]))
    }
}