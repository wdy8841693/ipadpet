import Foundation

/// 本地唤醒词常驻进程（sherpa-onnx KWS）的 Swift 侧封装。
///
/// 为什么不把 sherpa-onnx 直接链进 App：
///
///   - 运行时（onnxruntime 约 31MB）+ 模型（约 5MB）要随包带，链进 App 会让
///     Xcode 构建强依赖「先跑过拉取脚本」，没跑过的机器直接编译不过；
///   - 独立进程崩了不会带走桌宠：App 侧发现进程没了就退回「系统识别 + 文本
///     匹配唤醒」，是功能降级而不是整个 App 起不来。
///
/// 这也是架构文档 §7.4「采集/KWS/ASR 全在常驻子进程，Dart 只收事件」的做法。
///
/// 协议（stdin → stdout）：
///   stdin ：4 字节小端 int32 采样数 + 采样数 × float32（16kHz 单声道）
///   stdout：每行一个 JSON 事件，例如 {"type":"wake","keyword":"小鲸小鲸"}
final class WhalePetKWS {

  enum Event {
    /// 进程就绪，可以喂音频了。
    case ready
    /// 命中唤醒词。
    case wake(keyword: String)
    /// 进程起不来或中途退出。
    case failure(String)
  }

  struct Configuration {
    var executableURL: URL
    var modelDirectory: URL
    /// sherpa 关键词串：拼音 token（空格分隔）+ `@` + 中文文本。
    var keywords: String
    /// 声学触发阈值：越大越保守。0.08 是按 TTS 音频标出来的初值，
    /// 真机复验时按实际误触发率再调。
    var threshold: Float = 0.08
    /// 关键词加分。
    var score: Float = 4.0
  }

  /// App 包内的载荷目录：构建脚本把 `macos/.sherpa` 拷到 `Contents/Resources/kws`。
  static var bundledPayloadDirectory: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let candidate = resources.appendingPathComponent("kws", isDirectory: true)
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  /// 开发期可以用环境变量指到仓库里的 `macos/.sherpa`。
  static var developmentPayloadDirectory: URL? {
    guard let path = ProcessInfo.processInfo.environment["WHALEPET_KWS_DIR"] else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private let onEvent: (Event) -> Void
  private let writeQueue = DispatchQueue(label: "com.whalepet.kws.write")
  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?

  /// 进程是否还活着（用它判断要不要退回文本匹配路径）。
  private(set) var isRunning = false

  init(onEvent: @escaping (Event) -> Void) {
    self.onEvent = onEvent
  }

  /// 组装配置：优先用开发目录，其次用 App 包内目录。
  /// 都没有就返回 nil —— 说明这台机器没装 KWS 载荷，调用方应走文本匹配路径。
  static func makeConfiguration(keywords: String) -> Configuration? {
    let payload = developmentPayloadDirectory ?? bundledPayloadDirectory
    guard let payload else { return nil }
    let executable = payload.appendingPathComponent("bin/whalepet-kws")
    let model = payload.appendingPathComponent("model", isDirectory: true)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
    guard FileManager.default.fileExists(atPath: model.appendingPathComponent("tokens.txt").path) else {
      return nil
    }
    return Configuration(
      executableURL: executable,
      modelDirectory: model,
      keywords: keywords
    )
  }

  /// 启动常驻进程。返回 false 表示起不来（调用方应退回文本匹配路径）。
  @discardableResult
  func start(configuration: Configuration) -> Bool {
    stop()

    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = [
      "--model", configuration.modelDirectory.path,
      "--keywords", configuration.keywords,
      "--threshold", String(configuration.threshold),
      "--score", String(configuration.score),
    ]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.standardError

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let self else { return }
      self.handle(output: data)
    }

    process.terminationHandler = { [weak self] finished in
      guard let self else { return }
      self.isRunning = false
      let reason = finished.terminationReason
      let message =
        reason == .uncaughtSignal
        ? "唤醒词进程异常退出（信号 \(finished.terminationStatus)）"
        : "唤醒词进程已退出（状态 \(finished.terminationStatus)）"
      self.onEvent(.failure(message))
    }

    do {
      try process.run()
    } catch {
      onEvent(.failure("启动唤醒词进程失败：\(error.localizedDescription)"))
      return false
    }

    self.process = process
    self.inputPipe = inputPipe
    self.outputPipe = outputPipe
    isRunning = true
    return true
  }

  /// 喂一段 16kHz 单声道 Float32 音频。
  func feed(samples: [Float]) {
    guard isRunning, !samples.isEmpty, let handle = inputPipe?.fileHandleForWriting else { return }
    var payload = Data()
    var count = Int32(samples.count).littleEndian
    withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
    samples.withUnsafeBufferPointer { ptr in
      payload.append(UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
    }
    write(payload: payload, to: handle)
  }

  /// 复位关键词流。
  ///
  /// 切回待机时调用：上一轮（聆听期）不在关键词流里喂音频，sherpa 的
  /// 「1.5 秒静音自动复位」不会触发，残留状态可能造成误唤醒。
  func reset() {
    guard isRunning, let handle = inputPipe?.fileHandleForWriting else { return }
    var count = Int32(-1).littleEndian
    var payload = Data()
    withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
    write(payload: payload, to: handle)
  }

  private func write(payload: Data, to handle: FileHandle) {
    writeQueue.async {
      do {
        try handle.write(contentsOf: payload)
      } catch {
        // 管道断了：进程多半已经退出，交给 terminationHandler 报。
      }
    }
  }

  /// 停止进程并清理管道。
  func stop() {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    try? inputPipe?.fileHandleForWriting.close()
    inputPipe = nil
    outputPipe = nil
    if let process, process.isRunning {
      process.terminate()
    }
    process = nil
    isRunning = false
  }

  // MARK: - 输出解析

  private var pendingLine = Data()

  private func handle(output data: Data) {
    pendingLine.append(data)
    while let newlineIndex = pendingLine.firstIndex(of: 0x0A) {
      let lineData = pendingLine.subdata(in: pendingLine.startIndex..<newlineIndex)
      pendingLine.removeSubrange(pendingLine.startIndex...newlineIndex)
      handle(line: lineData)
    }
  }

  private func handle(line data: Data) {
    guard !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data),
      let payload = object as? [String: Any],
      let type = payload["type"] as? String
    else { return }

    switch type {
    case "ready":
      onEvent(.ready)
    case "wake":
      let keyword = payload["keyword"] as? String ?? ""
      onEvent(.wake(keyword: keyword))
    case "error":
      let message = payload["message"] as? String ?? "未知错误"
      onEvent(.failure(message))
    default:
      break
    }
  }
}
