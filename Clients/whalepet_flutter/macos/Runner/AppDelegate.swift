import AVFoundation
import Cocoa
import FlutterMacOS

/// 应用代理：桌宠的平台能力落点（docs/CROSS_PLATFORM.md §10.2）。
///
/// 职责：
///   - 不进 Dock（`.accessory`），菜单栏常驻一个 🐳 状态项（显示 / 退出）；
///   - `whalepet/window` 通道：Dart 侧 `MacOSDesktopWindow` 的全部指令；
///   - 退出前通知 Dart 落盘（`whalepet/lifecycle` → `terminating`）。
///
/// 坐标约定：Dart 侧一律「逻辑像素 + 左上角原点」的全局屏幕坐标；
/// Cocoa 的「左下角原点」换算全部封在这里。
///
/// 注意：初始化放在 `applicationWillFinishLaunching`，而不是
/// `applicationDidFinishLaunching`。FlutterAppDelegate 的 `didFinishLaunching`
/// 只在协议里声明，Swift 重写不会挂到 `applicationDidFinishLaunching:` 这个
/// ObjC 入口上（实测：通知照发、方法不被调用）；`willFinishLaunching` 正常生效，
/// 且此时 nib 已加载完，主窗口与 FlutterViewController 都已存在。
@main
class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {
  private var statusItem: NSStatusItem?
  private var lifecycleChannel: FlutterMethodChannel?
  private var speechChannel: FlutterMethodChannel?
  private var voiceChannel: FlutterMethodChannel?
  private var windowChannel: FlutterMethodChannel?
  private var synthesizer: AVSpeechSynthesizer?
  private var voiceEngine: WhalePetVoiceEngine?
  private var screenObserver: NSObjectProtocol?
  private var currentUtteranceId: String?
  private var bootstrapped = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false  // 桌宠窗口永不关闭；退出走菜单栏状态项。
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    bootstrap()
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    bootstrap()  // 幂等兜底：哪个回调先到都能把能力装上。
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // Dart 侧注册了 persistNow 处理器；给一点时间让写盘完成。
    lifecycleChannel?.invokeMethod("terminating", arguments: nil)
    voiceEngine?.dispose()
    if let observer = screenObserver {
      NotificationCenter.default.removeObserver(observer)
      screenObserver = nil
    }
    Thread.sleep(forTimeInterval: 0.15)
    super.applicationWillTerminate(notification)
  }

  // -- 初始化 ----------------------------------------------------------------

  private func bootstrap() {
    if bootstrapped { return }

    // 对应 Windows 的 setSkipTaskbar：不占 Dock、不进 Cmd+Tab。
    NSApp.setActivationPolicy(.accessory)

    guard
      let window = NSApplication.shared.windows.first,
      let controller = window.contentViewController as? FlutterViewController
    else {
      // 窗口还没就绪时留给下一个回调重试。
      return
    }
    bootstrapped = true

    let messenger = controller.engine.binaryMessenger
    let channel = FlutterMethodChannel(name: "whalepet/window", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleWindowCall(call, result: result, window: window)
    }
    windowChannel = channel
    observeScreenChanges()

    lifecycleChannel =
        FlutterMethodChannel(name: "whalepet/lifecycle", binaryMessenger: messenger)

    let speech = FlutterMethodChannel(name: "whalepet/speech", binaryMessenger: messenger)
    speech.setMethodCallHandler { [weak self] call, result in
      self?.handleSpeechCall(call, result: result)
    }
    speechChannel = speech

    // 本地语音引擎（§7.4、§10.2）：采集 + 识别都在原生层，Dart 只收事件。
    let voice = FlutterMethodChannel(name: "whalepet/voice", binaryMessenger: messenger)
    voice.setMethodCallHandler { [weak self] call, result in
      self?.handleVoiceCall(call, result: result)
    }
    voiceChannel = voice
    voiceEngine = WhalePetVoiceEngine()

    setupStatusItem()
  }

  // -- whalepet/speech 通道（AVSpeechSynthesizer）------------------------------

  private func handleSpeechCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      if synthesizer == nil {
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
      }
      result(nil)
    case "speak":
      guard
        let args = call.arguments as? [String: Any],
        let text = args["text"] as? String
      else {
        result(nil)
        return
      }
      let utteranceId = (args["utteranceId"] as? String) ?? UUID().uuidString
      let synth = synthesizer ?? {
        let s = AVSpeechSynthesizer()
        s.delegate = self
        synthesizer = s
        return s
      }()
      // 上一句没播完时直接打断，语义等同 SpeechQueue 的最新优先。
      if synth.isSpeaking {
        synth.stopSpeaking(at: .immediate)
      }
      currentUtteranceId = utteranceId
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate
      synth.speak(utterance)
      result(nil)
    case "stop":
      synthesizer?.stopSpeaking(at: .immediate)
      result(nil)
    case "dispose":
      synthesizer?.stopSpeaking(at: .immediate)
      synthesizer?.delegate = nil
      synthesizer = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func emitSpeechEvent(_ kind: String) {
    let id = currentUtteranceId ?? ""
    speechChannel?.invokeMethod("event", arguments: ["utteranceId": id, "kind": kind])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                         didStart utterance: AVSpeechUtterance) {
    emitSpeechEvent("started")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                         didFinish utterance: AVSpeechUtterance) {
    emitSpeechEvent("finished")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                         didCancel utterance: AVSpeechUtterance) {
    emitSpeechEvent("cancelled")
  }

  // -- whalepet/voice 通道（本地识别）--------------------------------------

  /// Dart 侧 `MacOSVoiceEngine` 的全部指令。
  ///
  /// 事件方向相反：原生层用 `invokeMethod("event", ...)` 把识别结果推给 Dart。
  private func handleVoiceCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let engine = voiceEngine else {
      result(FlutterError(code: "voice_not_ready",
                          message: "语音引擎还没初始化",
                          details: nil))
      return
    }
    switch call.method {
    case "initialize":
      let args = call.arguments as? [String: Any] ?? [:]
      let locale = (args["culture"] as? String) ?? "zh-CN"
      // 唤醒词（主词 + 别名）：能转成 sherpa 关键词时，原生层会拉起本地 KWS
      // 进程做真正的关键词检测；转不了就退回「系统识别 + 文本匹配」。
      let wakePhrases = (args["wake_phrases"] as? [String]) ?? []
      engine.initialize(
        locale: locale,
        wakePhrases: wakePhrases,
        eventSink: { [weak self] payload in
          self?.voiceChannel?.invokeMethod("event", arguments: payload)
        },
        completion: { outcome in
          // 权限回调不一定在主线程，FlutterResult 必须在平台线程调用。
          DispatchQueue.main.async {
            switch outcome {
            case .success(let info):
              result(info.asDictionary)
            case .failure(let error):
              result(FlutterError(code: "voice_init_failed",
                                  message: error.localizedDescription,
                                  details: nil))
            }
          }
        })
    case "startWakeListening":
      do {
        try engine.startWakeListening()
        result(nil)
      } catch {
        result(FlutterError(code: "voice_start_failed",
                            message: error.localizedDescription,
                            details: nil))
      }
    case "startManualListening":
      do {
        try engine.startManualListening()
        result(nil)
      } catch {
        result(FlutterError(code: "voice_start_failed",
                            message: error.localizedDescription,
                            details: nil))
      }
    case "stopListening":
      engine.stopListening()
      result(nil)
    case "dispose":
      engine.dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // -- 菜单栏状态项 ----------------------------------------------------------

  private func setupStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.title = "🐳"
    item.button?.toolTip = "鲸鱼娘 DSH"

    let menu = NSMenu()
    let show = NSMenuItem(title: "显示鲸鱼娘", action: #selector(showPet), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出鲸鱼娘…", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  @objc private func showPet() {
    guard let window = NSApplication.shared.windows.first else { return }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  // -- whalepet/window 通道 --------------------------------------------------

  private func handleWindowCall(_ call: FlutterMethodCall, result: @escaping FlutterResult,
                                window: NSWindow) {
    switch call.method {
    case "initialize":
      result(nil)
    case "workArea":
      let screen = referenceScreen(for: window)
      let visible = screen.visibleFrame
      result([
        "left": visible.minX,
        "top": screen.frame.maxY - visible.maxY,
        "width": visible.width,
        "height": visible.height,
      ])
    case "bounds":
      let screen = referenceScreen(for: window)
      let frame = window.frame
      result([
        "left": frame.minX,
        "top": screen.frame.maxY - frame.maxY,
        "width": frame.width,
        "height": frame.height,
      ])
    case "setPosition":
      guard let args = call.arguments as? [String: Any] else { result(nil); return }
      let left = double(args["left"])
      let top = double(args["top"])
      let screen = referenceScreen(for: window)
      let frame = window.frame
      window.setFrameOrigin(NSPoint(x: left, y: screen.frame.maxY - top - frame.height))
      result(nil)
    case "setBounds":
      guard let args = call.arguments as? [String: Any] else { result(nil); return }
      let left = double(args["left"])
      let top = double(args["top"])
      let width = double(args["width"])
      let height = double(args["height"])
      let screen = referenceScreen(for: window)
      let rect = NSRect(x: left, y: screen.frame.maxY - top - height, width: width, height: height)
      window.setFrame(rect, display: true)
      result(nil)
    case "setAlwaysOnTop":
      let enabled = bool((call.arguments as? [String: Any])?["enabled"], default: true)
      window.level = enabled ? .floating : .normal
      result(nil)
    case "setSkipTaskbar":
      let enabled = bool((call.arguments as? [String: Any])?["enabled"], default: true)
      NSApp.setActivationPolicy(enabled ? .accessory : .regular)
      result(nil)
    case "setClickThrough":
      let enabled = bool((call.arguments as? [String: Any])?["enabled"], default: false)
      window.ignoresMouseEvents = enabled
      result(nil)
    case "setVisible":
      // 托盘/菜单栏「显示宠物」：隐藏用 orderOut，显示用 orderFront（不抢焦点）。
      let visible = bool((call.arguments as? [String: Any])?["visible"], default: true)
      if visible {
        window.orderFrontRegardless()
      } else {
        window.orderOut(nil)
      }
      result(nil)
    case "startNativeDrag":
      // 只在鼠标按下/拖动事件里有效；与 isMovableByWindowBackground 互补。
      if let event = NSApplication.shared.currentEvent,
         event.type == .leftMouseDragged || event.type == .leftMouseDown {
        window.performDrag(with: event)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // -- 显示器变化 -------------------------------------------------------------

  /// 插拔显示器 / 改分辨率 / 换主屏之后，工作区会变，桌宠必须重新约束回
  /// 可见区域（§10.2）。这里只发一个「变了」的信号，具体位置由 Dart 侧重算。
  private func observeScreenChanges() {
    guard screenObserver == nil else { return }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.windowChannel?.invokeMethod("screensChanged", arguments: nil)
    }
  }

  // -- 坐标工具 ---------------------------------------------------------------

  /// 窗口所在屏幕（多显示器时取窗口所在的那块）。
  private func referenceScreen(for window: NSWindow) -> NSScreen {
    return window.screen
      ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
      ?? NSScreen.main
      ?? NSScreen.screens.first!
  }

  private func double(_ value: Any?) -> Double {
    return (value as? NSNumber)?.doubleValue ?? 0
  }

  private func bool(_ value: Any?, default fallback: Bool) -> Bool {
    guard let number = value as? NSNumber else { return fallback }
    return number.boolValue
  }
}
