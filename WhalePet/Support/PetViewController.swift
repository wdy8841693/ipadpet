import UIKit
import SpriteKit

/// 全屏 SKView 容器。iPad mini 4 性能要点：
/// - preferredFramesPerSecond = 30（A8 省电省热）
/// - ignoresSiblingOrder = true（减少渲染排序开销）
/// - 关闭 showsFPS/showsPhysics 等调试绘制
final class PetViewController: UIViewController {
    private(set) var scene: PetScene?
    private let store = PetStore.shared
    private let settings = ServerSettings()
    private var voice: VoiceController?

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
        s.onMicRequest = { [weak self] in self?.handleMicButton() }
        s.onSettingsRequest = { [weak self] in self?.presentServerSettings() }
        scene = s
        skView.presentScene(s)

        setupVoice()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 旋转 / 尺寸变化时同步场景大小（scaleMode = .resizeFill 也会兜底）
        scene?.size = view.bounds.size
    }

    // MARK: - 语音

    private func setupVoice() {
        let controller = VoiceController(settings: settings)
        controller.onStateChange = { [weak self] state in
            guard let self, let scene = self.scene else { return }
            scene.setVoiceState(state.petState,
                                displayText: state == .disabled ? nil : state.displayText)
        }
        controller.onTranscript = { [weak self] text in
            self?.scene?.showVoiceTranscript(text)
        }
        controller.onResponse = { [weak self] text in
            self?.scene?.showVoiceResponse(text)
        }
        controller.onError = { [weak self] message in
            self?.scene?.showVoiceError(message)
        }
        voice = controller
        // 已配置过则自动恢复语音；首次使用等用户在设置里填好再开。
        if settings.isVoiceEnabled && settings.isConfigured {
            controller.start()
        }
    }

    private func handleMicButton() {
        guard let voice else { return }
        if voice.state == .disabled {
            guard settings.isConfigured else {
                presentServerSettings()
                return
            }
            voice.start()
            settings.isVoiceEnabled = true
        } else {
            voice.startManualCommand()
        }
    }

    /// 退后台停止监听（iOS 不允许后台麦克风常驻，且我们只承诺前台唤醒）。
    func appWillResign() {
        voice?.stop()
        scene?.setVoiceState(nil, displayText: nil)
    }

    func appDidBecomeActive() {
        guard settings.isVoiceEnabled && settings.isConfigured, let voice else { return }
        // 已经连着就不要再 start()：重复 start 会断开重连，白抖一下状态。
        if case .disabled = voice.state {
            voice.start()
        }
    }

    // MARK: - 改名弹窗

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

    // MARK: - 服务器设置

    private func presentServerSettings() {
        let alert = UIAlertController(title: "语音服务器",
                                      message: "填写内网桥接服务器地址与访问令牌",
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.placeholder = "http://192.168.1.10:8787"
            tf.keyboardType = .URL
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
            if let url = self?.settings.serverURL { tf.text = url.absoluteString }
        }
        alert.addTextField { [weak self] tf in
            tf.placeholder = "访问令牌（服务器 WHALEPET_TOKEN）"
            tf.isSecureTextEntry = true
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
            tf.text = self?.settings.token
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并测试", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let fields = alert?.textFields,
                  let urlText = fields[0].text,
                  let tokenText = fields[1].text else { return }
            self.saveServerSettings(urlText: urlText, tokenText: tokenText)
        })
        present(alert, animated: true)
    }

    private func saveServerSettings(urlText: String, tokenText: String) {
        do {
            let url = try ServerSettings.normalizeServerURL(urlText)
            settings.serverURL = url
            settings.token = tokenText.trimmingCharacters(in: .whitespaces)
            testConnection()
        } catch {
            showSettingsResult(nil, error.localizedDescription)
        }
    }

    private func testConnection() {
        guard let base = settings.serverURL else { return }
        let config = DSHClient.Configuration(baseURL: base, token: settings.token,
                                             sessionID: settings.sessionID)
        let client = DSHClient(config: config)
        client.checkHealth { [weak self] problem in
            DispatchQueue.main.async {
                guard let self else { return }
                if let problem {
                    self.showSettingsResult(nil, problem)
                } else {
                    self.showSettingsResult("连接成功！可以说\"小鲸小鲸\"唤醒啦", nil)
                    self.settings.isVoiceEnabled = true
                    self.voice?.start()
                }
            }
        }
    }

    private func showSettingsResult(_ success: String?, _ failure: String?) {
        let message = success ?? failure ?? ""
        let alert = UIAlertController(title: success != nil ? "服务器" : "连接失败",
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
