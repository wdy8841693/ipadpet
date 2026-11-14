import SpriteKit

/// 顶部状态条 + 底部操作按钮。全部 SKNode，触摸由 Scene 分发。
final class HUDNode: SKNode {
    enum Action { case feed, play, sleep, rename }

    var onAction: ((Action) -> Void)?

    private struct Bar {
        let node: SKShapeNode
        let fill: SKShapeNode
        let icon: SKLabelNode
        let maxWidth: CGFloat
    }

    private var bars: [Bar] = []          // satiety / mood / energy
    private var buttons: [(node: SKNode, action: Action, name: String)] = []
    private var sleepButtonLabel: SKLabelNode?
    private let panel = SKShapeNode()
    private var lastBarValues: [Int] = [-1, -1, -1]   // 量化缓存，避免每帧重建路径

    init(sceneSize: CGSize) {
        super.init()
        buildBars()
        buildButtons()
        layout(sceneSize: sceneSize)
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    private func buildBars() {
        let icons = ["🍣", "💙", "⚡️"]
        for i in 0..<3 {
            let bg = SKShapeNode()
            bg.fillColor = SKColor(white: 1, alpha: 0.18)
            bg.strokeColor = .clear
            addChild(bg)
            let fill = SKShapeNode()
            fill.fillColor = [SKColor(red: 1, green: 0.62, blue: 0.35, alpha: 0.95),
                              SKColor(red: 0.45, green: 0.75, blue: 1, alpha: 0.95),
                              SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.95)][i]
            fill.strokeColor = .clear
            addChild(fill)
            let icon = SKLabelNode(text: icons[i])
            icon.fontSize = 16
            icon.verticalAlignmentMode = .center
            addChild(icon)
            bars.append(Bar(node: bg, fill: fill, icon: icon, maxWidth: 96))
        }
    }

    private func buildButtons() {
        panel.fillColor = SKColor(white: 0, alpha: 0.22)
        panel.strokeColor = .clear
        addChild(panel)
        let defs: [(String, String, Action)] = [
            ("🐟", "投喂", .feed),
            ("🫧", "玩耍", .play),
            ("🌙", "睡觉", .sleep),
            ("✏️", "改名", .rename),
        ]
        for (emoji, title, action) in defs {
            let container = SKNode()
            let circle = SKShapeNode(circleOfRadius: 27)
            circle.fillColor = SKColor(white: 1, alpha: 0.92)
            circle.strokeColor = SKColor(red: 0.35, green: 0.55, blue: 0.75, alpha: 1)
            circle.lineWidth = 2
            container.addChild(circle)
            let e = SKLabelNode(text: emoji)
            e.fontSize = 24
            e.verticalAlignmentMode = .center
            e.position = CGPoint(x: 0, y: 4)
            container.addChild(e)
            let t = SKLabelNode(fontNamed: "PingFangSC-Regular")
            t.text = title
            t.fontSize = 12
            t.fontColor = SKColor(white: 1, alpha: 0.9)
            t.verticalAlignmentMode = .top
            t.position = CGPoint(x: 0, y: -32)
            container.addChild(t)
            addChild(container)
            buttons.append((container, action, title))
            if action == .sleep { sleepButtonLabel = e }
        }
    }

    func layout(sceneSize: CGSize) {
        lastBarValues = [-1, -1, -1]   // 强制下次 update 重绘
        // 状态条：左上角竖排三根
        let barH: CGFloat = 10
        for (i, bar) in bars.enumerated() {
            let y = sceneSize.height - 44 - CGFloat(i) * 26
            let x: CGFloat = 46
            bar.node.path = CGPath(roundedRect: CGRect(x: x, y: y - barH / 2, width: bar.maxWidth, height: barH),
                                   cornerWidth: 5, cornerHeight: 5, transform: nil)
            bar.icon.position = CGPoint(x: x - 18, y: y)
        }
        // 按钮：底部居中横排
        let spacing: CGFloat = 86
        let totalW = spacing * CGFloat(buttons.count - 1)
        let startX = sceneSize.width / 2 - totalW / 2
        let y: CGFloat = 64
        for (i, b) in buttons.enumerated() {
            b.node.position = CGPoint(x: startX + CGFloat(i) * spacing, y: y)
        }
        panel.path = CGPath(roundedRect: CGRect(x: startX - 44, y: y - 48,
                                                width: totalW + 88, height: 96),
                            cornerWidth: 20, cornerHeight: 20, transform: nil)
    }

    func update(vitals: PetVitals, state: PetState) {
        let values = [vitals.satiety, vitals.mood, vitals.energy]
        let quantized = values.map { Int($0.rounded()) }
        if quantized != lastBarValues {
            lastBarValues = quantized
            let barH: CGFloat = 10
            for (i, bar) in bars.enumerated() {
                let w = max(4, bar.maxWidth * CGFloat(values[i] / 100))
                let originX: CGFloat = 46
                let y = bar.icon.position.y
                bar.fill.path = CGPath(roundedRect: CGRect(x: originX, y: y - barH / 2, width: w, height: barH),
                                       cornerWidth: 5, cornerHeight: 5, transform: nil)
            }
        }
        let moon = state == .sleep ? "☀️" : "🌙"
        if sleepButtonLabel?.text != moon { sleepButtonLabel?.text = moon }
    }

    /// 命中返回 true（Scene 不再把事件传给宠物）。
    func handleTouch(at p: CGPoint) -> Bool {
        for b in buttons {
            if hypot(p.x - b.node.position.x, p.y - b.node.position.y) < 34 {
                // 按压反馈
                b.node.run(.sequence([.scale(to: 0.88, duration: 0.06),
                                      .scale(to: 1.0, duration: 0.1)]))
                onAction?(b.action)
                return true
            }
        }
        return false
    }
}