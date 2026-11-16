import AVFoundation
import Speech

/// macOS 本地语音引擎（docs/CROSS_PLATFORM.md §7.4、§7.5、§10.2）。
///
/// 采集与识别都在这一层，PCM 不进 Dart：
///
/// ```text
/// 麦克风 → AVAudioEngine → SFSpeechAudioBufferRecognitionRequest
///        → 系统 SFSpeechRecognizer（本机识别）→ 文字事件 → Dart
/// ```
///
/// Provider 选择：文档 §10.2 首选 sherpa-onnx（随包带模型、离线可控）。这一版
/// 先用系统识别器，理由是零模型下载、零第三方依赖，先把「唤醒 → 识别 → 文本 →
/// DSH → 播报」这条垂直闭环在 macOS 上打通。系统识别没有「关键字语法」这类能力，
/// 唤醒只能靠「常驻识别 + 唤醒词文本匹配」（与 Android 版同一种廉价替代）。
/// 将来换 sherpa-onnx（§7.9）时，只要保持同样的 start/stop + 事件回调，
/// Dart 侧（`MacOSVoiceEngine` + `VoiceEventRouter`）一行都不用改。
///
/// 事件协议（→ Dart，`whalepet/voice` 通道的 `event` 方法）：
///
/// ```text
/// { "type": "partial" | "final" | "error",
///   "mode": "wake" | "listen",
///   "text": String, "confidence": Double,
///   "code": String, "message": String, "retryable": Bool }
/// ```
///
/// `code` 用 core/voice/voice_event_router.dart 里的 `kFatalVoiceErrorCodes`
/// 约定：`permission_denied` / `not_available` / `mic_unavailable` /
/// `engine_stalled` 是致命错误，其余（`no_speech` / `recognition_failed`）
/// 是可恢复错误。
final class WhalePetVoiceEngine {

  /// 采集/识别模式：与 Dart 侧 `VoiceEngineMode` 一一对应。
  enum Mode: String {
    /// 不采集、不识别。
    case idle
    /// 常驻待机：只关心有没有命中唤醒词。
    case wake
    /// 正在聆听指令。
    case listen
  }

  /// 初始化成功后回给 Dart 的能力信息。
  struct InitInfo {
    let provider: String
    /// 系统是否提供本机识别；false 时可能悄悄走 Apple 服务器。
    let onDevice: Bool
    /// 唤醒是怎么判定的：
    ///   - `kws`：本地关键词模型（sherpa-onnx）直接判唤醒，不跑整段识别；
    ///   - `text-match`：退回「系统识别 + 唤醒词文本匹配」。
    let wakeProvider: String

    var asDictionary: [String: Any] {
      return [
        "provider": provider,
        "onDevice": onDevice,
        "wakeProvider": wakeProvider,
      ]
    }
  }

  enum EngineError: LocalizedError {
    case speechDenied
    case micDenied
    case recognizerUnavailable(String)
    case noInputDevice
    case audioEngineFailed(String)

    var errorDescription: String? {
      switch self {
      case .speechDenied:
        return "系统语音识别权限被拒绝（系统设置 → 隐私与安全性 → 语音识别）"
      case .micDenied:
        return "麦克风权限被拒绝（系统设置 → 隐私与安全性 → 麦克风）"
      case .recognizerUnavailable(let locale):
        return "系统没有 \(locale) 的语音识别器"
      case .noInputDevice:
        return "没有可用的音频输入设备"
      case .audioEngineFailed(let message):
        return "音频采集起不来：\(message)"
      }
    }
  }

  /// 事件回调：payload 直接丢给 Dart 的 `whalepet/voice` 通道。
  typealias EventSink = ([String: Any]) -> Void

  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var eventSink: EventSink?
  private var localeIdentifier = "zh-CN"
  private var mode: Mode = .idle
  private var supportsOnDevice = false

  /// 这一轮要监听的唤醒词（主词 + 别名）。
  private var wakePhrases: [String] = []

  /// 本地唤醒词进程（sherpa-onnx KWS）。
  ///
  /// 为 nil 表示这台机器没有 KWS 载荷（没跑过 `tool/fetch_sherpa_onnx.sh`、
  /// 或出包时没带上），或者配置的唤醒词不在拼音表里 → 这两种情况都退回
  /// 「系统识别 + 文本匹配唤醒」。
  private var kws: WhalePetKWS?

  /// 是否走真 KWS 路径（待机期只跑关键词模型，不跑整段识别）。
  private var kwsEnabled = false

  /// tap 是否真的装上了：没装过就不能 removeTap（会抛异常）。
  private var tapInstalled = false

  /// 采集轮次编号：每次 start/stop 都 +1，旧任务的回调据此判定自己已过期。
  /// 不做这个隔离的话，「切模式时取消旧任务」的回调可能落在新模式上，
  /// 把上一轮的结果当成这一轮的（§7.2 的 generation 守卫在原生侧的对应物）。
  private var sessionId = 0

  /// 本轮是否已经产出过 final（区分「说完了」和「引擎自己结束了」）。
  private var producedFinal = false

  /// 自动续接的防抖：连续快速重启说明引擎在反复崩，不能无限重试。
  private var restartCount = 0
  private var lastRestartAt = Date.distantPast
  private var restartScheduled = false

  private var debugEnabled: Bool {
    return ProcessInfo.processInfo.environment["WHALEPET_VOICE_DEBUG"] == "1"
  }

  // MARK: - 初始化与权限

  /// 申请权限并准备识别器。
  ///
  /// 权限是异步的：语音识别走 `SFSpeechRecognizer.requestAuthorization`，
  /// 麦克风走 `AVCaptureDevice.requestAccess(for: .audio)`。两者都通过
  /// `completion` 回结果（失败时带可读的本地化原因）。
  ///
  /// [wakePhrases] 是这一轮要监听的唤醒词（主词 + 别名）：如果它们能转成
  /// sherpa 关键词（见 `WhalePetWakeKeywords`），就额外拉起本地 KWS 进程，
  /// 待机期用真正的关键词检测代替「常驻识别 + 文本匹配」。
  func initialize(locale: String,
                  wakePhrases: [String],
                  eventSink: @escaping EventSink,
                  completion: @escaping (Result<InitInfo, Error>) -> Void) {
    localeIdentifier = locale
    self.eventSink = eventSink
    self.wakePhrases = wakePhrases
    // 重建引擎时（唤醒词变了）可能还留着上一轮的采集，先收干净。
    stopRecognition()

    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self = self else { return }
      switch status {
      case .authorized:
        self.requestMicrophone { result in
          switch result {
          case .success:
            self.prepareRecognizer(completion: completion)
          case .failure(let error):
            completion(.failure(error))
          }
        }
      case .denied, .restricted, .notDetermined:
        completion(.failure(EngineError.speechDenied))
      @unknown default:
        completion(.failure(EngineError.speechDenied))
      }
    }
  }

  private func requestMicrophone(completion: @escaping (Result<Void, Error>) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(.success(()))
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
          completion(.success(()))
        } else {
          completion(.failure(EngineError.micDenied))
        }
      }
    case .denied, .restricted:
      completion(.failure(EngineError.micDenied))
    @unknown default:
      completion(.failure(EngineError.micDenied))
    }
  }

  private func prepareRecognizer(completion: @escaping (Result<InitInfo, Error>) -> Void) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      completion(.failure(EngineError.recognizerUnavailable(localeIdentifier)))
      return
    }
    guard recognizer.isAvailable else {
      completion(.failure(EngineError.recognizerUnavailable(localeIdentifier)))
      return
    }
    self.recognizer = recognizer
    // supportsOnDeviceRecognition：macOS 10.15+ 才有；本工程部署目标是 12.0。
    supportsOnDevice = recognizer.supportsOnDeviceRecognition
    prepareKWS()
    let info = InitInfo(
      provider: "apple-speech/\(localeIdentifier)",
      onDevice: supportsOnDevice,
      wakeProvider: kwsEnabled ? "kws" : "text-match"
    )
    if debugEnabled {
      print("[voice] initialized provider=\(info.provider) onDevice=\(info.onDevice) wake=\(info.wakeProvider)")
    }
    completion(.success(info))
  }

  // MARK: - 本地唤醒词（sherpa-onnx KWS）

  /// 拉起本地关键词检测进程。
  ///
  /// 拉不起来不是错误：唤醒方式会自动退回「系统识别 + 文本匹配」，功能还在，
  /// 只是待机期更费电一点。所以这里不报错，只在引擎信息里标明用的是哪种。
  private func prepareKWS() {
    kws?.stop()
    kws = nil
    kwsEnabled = false

    guard let keywordString = WhalePetWakeKeywords.keywordString(for: wakePhrases),
      let configuration = WhalePetKWS.makeConfiguration(keywords: keywordString)
    else {
      if debugEnabled {
        print("[voice] KWS 不可用（无载荷或唤醒词不在拼音表里），退回文本匹配")
      }
      return
    }

    let process = WhalePetKWS { [weak self] event in
      guard let self else { return }
      switch event {
      case .ready:
        if self.debugEnabled { print("[voice] KWS 进程就绪") }
      case .wake(let keyword):
        // 真 KWS 的命中是权威的：直接报唤醒事件，Dart 侧不再做文本匹配。
        self.emit([
          "type": "wake",
          "mode": "wake",
          "keyword": keyword,
          "confidence": 0.9,
        ])
      case .failure(let message):
        self.kwsEnabled = false
        // KWS 进程没了：退回「系统识别 + 文本匹配」，别让唤醒彻底不可用。
        // 用的是非致命错误码——Dart 侧在待机阶段会忽略它（§7.2）。
        self.emit([
          "type": "error",
          "mode": "wake",
          "code": "kws_unavailable",
          "message": message,
          "retryable": true,
        ])
        if self.mode == .wake {
          try? self.start(mode: .wake)
        }
      }
    }

    if process.start(configuration: configuration) {
      kws = process
      kwsEnabled = true
    } else {
      kws = nil
      kwsEnabled = false
    }
  }

  // MARK: - 采集与识别

  /// 开始常驻待机（只关心唤醒词）。
  func startWakeListening() throws {
    try start(mode: .wake)
  }

  /// 开始聆听指令。
  func startManualListening() throws {
    try start(mode: .listen)
  }

  /// 停止采集与识别（播报前闭麦用，§7.8）。
  func stopListening() {
    stopRecognition()
  }

  /// 彻底释放。
  func dispose() {
    stopRecognition()
    kws?.stop()
    kws = nil
    kwsEnabled = false
    eventSink = nil
    recognizer = nil
  }

  private func start(mode next: Mode) throws {
    stopRecognition()
    guard let recognizer = recognizer else {
      throw EngineError.recognizerUnavailable(localeIdentifier)
    }

    // 待机期优先走真 KWS：只把音频喂给关键词模型，不跑整段识别。
    // 这条路径下「唤醒」由声学模型直接判定，比「常驻识别 + 文本匹配」准得多，
    // 也省电得多（不需要一直做语音识别）。
    if next == .wake, kwsEnabled, let kws {
      try startKeywordCapture(kws: kws)
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if supportsOnDevice {
      // 必须显式要求本机识别：不然可能悄悄把音频送到 Apple 服务器。
      request.requiresOnDeviceRecognition = true
    }
    recognitionRequest = request
    producedFinal = false
    mode = next
    sessionId += 1
    let currentSession = sessionId

    // 没有输入设备时不要去碰 inputNode（无麦克风的机器上会抛异常）。
    guard AVCaptureDevice.default(for: .audio) != nil else {
      mode = .idle
      recognitionRequest = nil
      throw EngineError.noInputDevice
    }

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      mode = .idle
      recognitionRequest = nil
      throw EngineError.noInputDevice
    }

    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      request.append(buffer)
    }
    tapInstalled = true

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      tapInstalled = false
      mode = .idle
      recognitionRequest = nil
      throw EngineError.audioEngineFailed(error.localizedDescription)
    }

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      // 旧轮次的回调直接丢弃：切模式/停止时取消旧任务，它的回调可能落在新模式上。
      guard let self = self, self.sessionId == currentSession else { return }
      self.handle(result: result, error: error)
    }
    if debugEnabled {
      print("[voice] start mode=\(next.rawValue)")
    }
  }

  /// 待机期只做关键词检测：采集 → 重采样成 16kHz 单声道 → 喂给 KWS 进程。
  ///
  /// 命中与否由 KWS 进程判定并回报，这里不做任何文本处理。
  private func startKeywordCapture(kws: WhalePetKWS) throws {
    // 没有输入设备时不要去碰 inputNode（无麦克风的机器上会抛异常）。
    guard AVCaptureDevice.default(for: .audio) != nil else {
      throw EngineError.noInputDevice
    }

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw EngineError.noInputDevice
    }

    // 重采样器只在采集线程里用，跟着 tap 闭包一起活到 tap 被摘掉为止。
    let resampler = WhalePetAudioResampler(inputSampleRate: format.sampleRate)
    // 切回待机先复位关键词流，清掉上一轮的残留状态（聆听期不喂音频，
    // sherpa 的「静音自动复位」不会触发）。
    kws.reset()
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      let samples = resampler.process(buffer: buffer)
      if !samples.isEmpty {
        kws.feed(samples: samples)
      }
    }
    tapInstalled = true

    mode = .wake
    sessionId += 1

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      tapInstalled = false
      mode = .idle
      throw EngineError.audioEngineFailed(error.localizedDescription)
    }
    if debugEnabled {
      print("[voice] start mode=wake provider=kws")
    }
  }

  private func stopRecognition() {
    // 先切模式再取消：取消会触发任务回调，回调里看到的应该是「空闲」，
    // 否则待机模式会把「自己取消自己」当成一次需要续接的结束。
    mode = .idle
    // 让正在跑的旧任务回调立刻失效。
    sessionId += 1
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.reset()
    }
  }

  // MARK: - 识别结果

  private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
    let currentMode = mode
    guard currentMode != .idle else { return }

    if let result = result {
      let text = result.bestTranscription.formattedString
      if result.isFinal {
        producedFinal = true
        let segments = result.bestTranscription.segments
        let confidence: Double = segments.isEmpty ? 0 : Double(segments[segments.count - 1].confidence)
        emit([
          "type": "final",
          "mode": currentMode.rawValue,
          "text": text,
          "confidence": confidence,
        ])
      } else {
        emit([
          "type": "partial",
          "mode": currentMode.rawValue,
          "text": text,
        ])
      }
    }

    if let error = error {
      let nsError = error as NSError
      if isNoSpeech(nsError) {
        // 「没有检测到语音」是常态（用户还没开口），不该当成错误打扰用户。
        emit([
          "type": "error",
          "mode": currentMode.rawValue,
          "code": "no_speech",
          "message": "没听清",
          "retryable": true,
        ])
      } else {
        emit([
          "type": "error",
          "mode": currentMode.rawValue,
          "code": "recognition_failed",
          "message": error.localizedDescription,
          "retryable": true,
        ])
      }
    }

    // 任务结束后的续接策略：
    //   - 待机模式：必须常驻，任务结束就自动续上；
    //   - 聆听模式：只有「还没产出 final」才续（用户只是停了一下）；
    //     已经产出 final 说明这一轮说完了，交给协调器的聆听超时收尾。
    if currentMode == .wake || !producedFinal {
      scheduleRestart()
    }
  }

  /// kAFAssistantErrorDomain 203 = 没有检测到语音。
  private func isNoSpeech(_ error: NSError) -> Bool {
    return error.domain == "kAFAssistantErrorDomain" && error.code == 203
  }

  private func scheduleRestart() {
    guard !restartScheduled else { return }
    restartScheduled = true

    let now = Date()
    if now.timeIntervalSince(lastRestartAt) < 1.0 {
      restartCount += 1
    } else {
      restartCount = 0
    }
    lastRestartAt = now
    if restartCount > 3 {
      // 连续秒崩：不再自动续接，否则会变成事件风暴。
      restartScheduled = false
      emit([
        "type": "error",
        "mode": mode.rawValue,
        "code": "engine_stalled",
        "message": "语音引擎反复中断，已停止自动重试",
        "retryable": false,
      ])
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self else { return }
      self.restartScheduled = false
      guard self.mode != .idle else { return }
      do {
        try self.start(mode: self.mode)
      } catch {
        self.emit([
          "type": "error",
          "mode": self.mode.rawValue,
          "code": "mic_unavailable",
          "message": "\(error.localizedDescription)",
          "retryable": true,
        ])
      }
    }
  }

  private func emit(_ payload: [String: Any]) {
    guard let sink = eventSink else { return }
    if debugEnabled {
      print("[voice] event \(payload)")
    }
    // Flutter 通道只能在平台线程调用。
    if Thread.isMainThread {
      sink(payload)
    } else {
      DispatchQueue.main.async { sink(payload) }
    }
  }
}
