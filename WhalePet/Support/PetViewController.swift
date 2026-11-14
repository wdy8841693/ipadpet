import UIKit
import SpriteKit

/// 全屏 SKView 容器。iPad mini 4 性能要点：
/// - preferredFramesPerSecond = 30（A8 省电省热）
/// - ignoresSiblingOrder = true（减少渲染排序开销）
/// - 关闭 showsFPS/showsPhysics 等调试绘制
final class PetViewController: UIViewController {
    private(set) var scene: PetScene?
    private let store = PetStore.shared

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func loadView() {
        let skView = SKView(frame: UIScreen.main.bounds)
        skView.preferredFramesPerSecond = 30
        skView.ignoresSiblingOrder = true
        skView.isMultipleTouchEnabled = false
        view = skView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let skView = view as? SKView else { return }
        let s = PetScene(size: skView.bounds.size, store: store)
        s.onRenameRequest = { [weak self] in self?.presentRenameAlert() }
        scene = s
        skView.presentScene(s)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 旋转 / 尺寸变化时同步场景大小（scaleMode = .resizeFill 也会兜底）
        scene?.size = view.bounds.size
    }

    private func presentRenameAlert() {
        let alert = UIAlertController(title: "给鲸鱼娘改名",
                                      message: "最多 12 个字符",
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.text = self?.store.data.petName
            tf.placeholder = "小鲸"
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            if let name = alert?.textFields?.first?.text {
                self?.scene?.renamePet(to: name)
            }
        })
        present(alert, animated: true)
    }
}