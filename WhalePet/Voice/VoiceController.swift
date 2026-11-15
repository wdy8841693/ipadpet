import AVFoundation
import Foundation

/// 语音控制器：麦克风采集 → 服务器（VAD/唤醒/ASR/DSH）→ 本地 TTS 播报。
/// 只在 App 前台运行；退后台自动停止。
final class VoiceController: NSObject {

    enum VoiceState: Equatable {
        case disabled       // 未配置或已关闭
        case connecting     // 连接服务器中
        case reconnecting(Int) // 断线自动重连，参数为第几次尝试
        case waiting        // 前台待唤醒
        case listening      // 已唤醒，聆听指令
        case thinking       // DSH 处理中
        case speaking       // 本地播报中
        case error(String)

        var displayText: String {
            switch self {
            case .disabled: return "语音已关闭"
            case .connecting: return "正在连接服务器…"
            case .reconnecting(let attempt): return "正在重连（第 \(attempt) 次）…"
            case .waiting: return "待唤醒（说\"小鲸小鲸\"）"
            case .listening: return "在听，请说指令…"
            case .thinking: return "思考中…"
            case .speaking: return "回答中…"
            case .error(let message): return "语音异常：\(message)"
            }
        }

        /// 映射到宠物的行为状态（PetBrain.beginVoiceInteraction 用）。
        var petState: PetState? {
            switch self {
            case .listening: return .listening
            case .thinking: return .thinking
            case .speaking: return .speaking
            default: return nil
            }
        }
    }

    var onStateChange: ((VoiceState) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onResponse: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// 任务进度气泡（开始 / 需要授权 / 完成 / 失败）。
    var onTaskNotice: ((String) -> Void)?
    /// 首次断线自动重连时给用户一个提示（后续重试不反复打扰）。
    var onReconnectNotice: ((String) -> Void)?

    private(set) var state: VoiceState = .disabled {
        didSet { onStateChange?(state) }
    }

    private let settings: ServerSettings
    private var client: DSHClient?
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    /// start()/stop() 每次递增；旧的权限回调、重连前的晚到事件都靠它失效。
    /// 修复：启动 / 回前台 / 设置保存成功 / 麦克风按钮都会调 start()，
    /// 没有这个代际判断时会同时建出多条 WebSocket（表现是 ready/wake 事件重复、
    /// 甚至两套 AVAudioEngine 同时送音频）。
    private var connectionGeneration = 0

    /// 44.1k/48k → 16k 转换器；iOS 15 上 AVAudioConverter 一步到位。
    private var converter: AVAudioConverter?
    private var targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000, channels: 1,
                                              interleaved: true)

    init(settings: ServerSettings) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
        observeInterruptions()
    }

    // MARK: - 生命周期

    /// 开启语音（配置校验 → 拆旧连接 → 麦克风权限 → 连接）。
    /// 幂等：重复调用只会保留最后一次连接，不会叠加 WebSocket / 音频引擎。
    func start() {
        guard settings.isConfigured else {
            state = .error("请先在设置里填写服务器地址和访问令牌")
            return
        }
        guard let base = settings.serverURL else {
            state = .error("服务器地址无效"); return
        }
        teardownConnection()
        connectionGeneration += 1
        let generation = connectionGeneration
        requestMicrophonePermission { [weak self] granted in
            // 授权回调在任意队列；state 变更会驱动 SpriteKit UI，必须回主线程。
            DispatchQueue.main.async {
                guard let self, generation == self.connectionGeneration else { return }
                guard granted else {
                    self.state = .error("麦克风权限被拒绝，请到系统设置开启")
                    return
                }
                self.startSession(baseURL: base)
            }
        }
    }

    func stop() {
        connectionGeneration += 1
        teardownConnection()
        state = .disabled
    }

    /// 断开旧连接 + 停采集，但不改 state（由调用方决定）。
    private func teardownConnection() {
        if let existing = client {
            // 先摘掉回调，避免旧连接断开时把 error 事件投给新连接的状态机。
            existing.onEvent = nil
            existing.disconnectAudio()
        }
        client = nil
        teardownAudio()
    }

    /// 手动触发一次指令聆听（点按钮，免唤醒词兜底）。
    func startManualCommand() {
        guard client != nil else {
            onError?("语音未开启")
            return
        }
        state = .listening
        client?.sendControl("manual_start")
    }

    func cancelCurrent() {
        client?.sendControl("cancel")
        stopSpeaking()
        state = .waiting
    }

    // MARK: - 连接

    private func startSession(baseURL: URL) {
        state = .connecting
        // 防御：万一有残留连接，先断掉再建，保证同一时刻只有一条语音通道。
        if let existing = client {
            existing.onEvent = nil
            existing.disconnectAudio()
            client = nil
        }
        let config = DSHClient.Configuration(
            baseURL: baseURL,
            token: settings.token,
            sessionID: settings.sessionID,
            wakePhrase: settings.wakePhrase
        )
        let client = DSHClient(config: config)
        client.onEvent = { [weak self] event in self?.handle(event) }
        self.client = client
        // DSHClient 内部会先做 health 检查，失败按指数退避自动重连。
        client.startAutoConnect()
    }

    private func handle(_ event: DSHClient.VoiceEvent) {
        switch event {
        case .ready:
            startCapture()
        case .reconnecting(let attempt, _):
            // 播报中不要用「正在重连」盖掉 speaking 动画。
            if case .speaking = state { break }
            state = .reconnecting(attempt)
            if attempt == 1 {
                onReconnectNotice?("和服务器断开了，我在自动重连…")
            }
        case .wake:
            state = .listening
        case .state(let value):
            switch value {
            case "listening": state = .listening
            case "waiting":
                // 播报结束/超时回等待；不打断 speaking 状态。
                if case .speaking = state { break }
                state = .waiting
            case "thinking", "speaking": state = .thinking
            default: break
            }
        case .transcript(let text):
            onTranscript?(text)
            state = .thinking
        case .thinking:
            state = .thinking
        case .task(let taskState, let text):
            handleTaskNotice(state: taskState, text: text)
        case .response(let text):
            onResponse?(text)
            speak(text)
        case .error(let message):
            onError?(message)
            state = .error(message)
        }
    }

    /// 任务进度提醒：开始 / 需要授权 / 完成 / 失败。
    /// - started: 气泡提示（不打断播报）
    /// - approval: 气泡 + 语音播报，确保用户注意到要去授权
    /// - finished / failed: 只上气泡，结论由后面的 response / error 负责
    private func handleTaskNotice(state taskState: String, text: String?) {
        switch taskState {
        case "started":
            self.state = .thinking
            onTaskNotice?(text ?? "开始处理…")
        case "approval":
            let message = text ?? "有个操作需要你在 DSH 里确认一下"
            onTaskNotice?(message)
            speak(message)
        case "finished":
            onTaskNotice?("做完了")
        case "failed":
            onTaskNotice?("出错了")
        default:
            break
        }
    }

    // MARK: - 麦克风采集

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()
        switch audioSession.recordPermission {
        case .granted:
            completion(true)
        case .undetermined:
            audioSession.requestRecordPermission { completion($0) }
        case .denied:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func startCapture() {
        // 播报中不采集（服务器侧 playback_start 也会暂停）。
        if synthesizer.isSpeaking { state = .speaking; return }
        // 重连/重复 ready 的情况下，旧采集可能还在：先拆干净，避免两套 tap 同时送音频。
        if engine != nil { teardownAudio() }
        do {
            try configureAudioSession()
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let target = targetFormat else { return }

            let converter = AVAudioConverter(from: inputFormat, to: target)
            self.converter = converter

            // 缓存足够多的样本再发（约 100ms 一包，20ms 帧的整数倍 = 5 帧）。
            let bus = 0
            let bufferSize: AVAudioFrameCount = 4800  // 0.1s @48k
            input.installTap(onBus: bus, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
                self?.sendConverted(buffer: buffer)
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            state = .waiting
        } catch {
            state = .error("无法启动麦克风：\(error.localizedDescription)")
        }
    }

    private func pauseCapture() {
        engine?.pause()
    }

    private func resumeCapture() {
        guard let engine, !engine.isRunning else { return }
        try? engine.start()
    }

    private func teardownAudio() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.defaultToSpeaker])
        try audioSession.setActive(true)
    }

    private func sendConverted(buffer: AVAudioPCMBuffer) {
        guard let converter, let target = targetFormat else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let error {
            NSLog("WhalePet: 音频转换失败 %@", error.localizedDescription)
            return
        }
        guard out.frameLength > 0, let channelData = out.int16ChannelData?[0] else { return }
        let byteCount = Int(out.frameLength) * 2
        let pcm = Data(bytes: channelData, count: byteCount)
        client?.sendAudio(pcm)
    }

    // MARK: - TTS

    private func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .waiting
            return
        }
        // 先停采集并通知服务器，避免拾到自己的播报。
        pauseCapture()
        client?.sendControl("playback_start")
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        state = .speaking
        synthesizer.speak(utterance)
    }

    private func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - 中断处理

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            // 来电等中断：停采集与播报，回等待态，避免半开状态。
            pauseCapture()
            stopSpeaking()
            state = .waiting
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            resumeCapture()
        @unknown default:
            break
        }
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        client?.sendControl("playback_end")
        if engine == nil {
            // 播报期间发生重连时采集尚未恢复（startCapture 在 speaking 时直接返回），这里补启动。
            startCapture()
        } else {
            resumeCapture()
            state = .waiting
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        // 主动取消：不重置服务器状态（cancel 控制消息已处理）。
        resumeCapture()
    }
}
