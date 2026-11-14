import SpriteKit

/// 台词气泡：圆角矩形 + 小尾巴 + SKLabelNode。
/// 纯 SpriteKit 实现，避免 UIKit 覆盖层在 iPadOS 15 上的旋转适配问题。
final class SpeechBubbleNode: SKNode {
    private let bg = SKShapeNode()
    private let tail = SKShapeNode()
    private let label = SKLabelNode(fontNamed: "PingFangSC-Regular")
    private var hideWorkItem: DispatchWorkItem?

    /// 场景据此把气泡约束在屏幕内。
    var contentSize: CGSize { bg.frame.size }

    override init() {
        super.init()
        bg.fillColor = SKColor(white: 1, alpha: 0.94)
        bg.strokeColor = SKColor(red: 0.35, green: 0.55, blue: 0.75, alpha: 1)
        bg.lineWidth = 2
        addChild(bg)

        let p = CGMutablePath()
        p.move(to: CGPoint(x: -8, y: 0))
        p.addLine(to: CGPoint(x: 0, y: -12))
        p.addLine(to: CGPoint(x: 8, y: 0))
        p.closeSubpath()
        tail.path = p
        tail.fillColor = bg.fillColor
        tail.strokeColor = .clear
        addChild(tail)

        label.fontSize = 17
        label.fontColor = SKColor(red: 0.15, green: 0.25, blue: 0.4, alpha: 1)
        label.verticalAlignmentMode = .center
        label.numberOfLines = 2
        label.preferredMaxLayoutWidth = 260
        addChild(label)

        alpha = 0
        isUserInteractionEnabled = false
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    func show(text: String, duration: TimeInterval = 4.0) {
        label.text = text
        // 依据文本实际尺寸重绘气泡
        let w = max(label.frame.width + 28, 60)
        let h = max(label.frame.height + 18, 40)
        bg.path = CGPath(roundedRect: CGRect(x: -w / 2, y: 0, width: w, height: h),
                         cornerWidth: 12, cornerHeight: 12, transform: nil)
        label.position = CGPoint(x: 0, y: h / 2)
        tail.position = CGPoint(x: 0, y: 0)

        removeAction(forKey: "bubble")
        hideWorkItem?.cancel()
        run(.fadeIn(withDuration: 0.18), withKey: "bubble")
        let item = DispatchWorkItem { [weak self] in
            self?.run(.fadeOut(withDuration: 0.4), withKey: "bubble")
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func hide() {
        hideWorkItem?.cancel()
        run(.fadeOut(withDuration: 0.15), withKey: "bubble")
    }
}