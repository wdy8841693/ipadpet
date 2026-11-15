import Foundation

/// DSH 桥接客户端：HTTP 健康检查 / 文本聊天 + WebSocket 语音通道。
/// iOS 15 兼容（URLSessionWebSocketTask），无第三方依赖。
final class DSHClient {

    enum ClientError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "请先在设置里填写服务器地址和访问令牌"
            case .badURL: return "服务器地址无效"
            case .http(let code, let body): return "服务器错误(\(code))：\(body)"
            case .transport(let message): return "网络连接失败：\(message)"
            }
        }
    }

    /// 服务端事件（JSON 文本帧）。
    enum VoiceEvent {
        case ready
        case state(String)          // waiting / listening / thinking / speaking
        case wake
        case transcript(String)
        case thinking
        case response(String)
        case error(String)
        /// 任务进度提醒：started / approval / finished / failed（服务端 `task` 事件）。
        case task(state: String, text: String?)
        /// 断线自动重连：第 attempt 次、delay 秒后重试。
        case reconnecting(attempt: Int, delay: TimeInterval)
    }

    struct Configuration {
        var baseURL: URL
        var token: String
        var sessionID: String
        var wakePhrase: String
        var requestTimeout: TimeInterval = 30
        var pingInterval: TimeInterval = 20
        var maxQueuedAudioBytes: Int = 1_500_000   // 约 47s @16kHz Int16，防弱网内存堆积

        init(baseURL: URL, token: String, sessionID: String,
             wakePhrase: String = ServerSettings.defaultWakePhrase) {
            self.baseURL = baseURL
            self.token = token
            self.sessionID = sessionID
            self.wakePhrase = wakePhrase
        }
    }

    private let config: Configuration
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var receiveLoopActive = false
    private let audioQueue = DispatchQueue(label: "whalepet.audio-send")
    private var queuedAudioBytes = 0

    // 断线自动重连状态。只在主线程读写。
    private var autoReconnect = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?

    /// 重连退避：1s、2s、4s、8s、16s、30s（封顶）。
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        return min(30, pow(2, Double(n - 1)))
    }

    var onEvent: ((VoiceEvent) -> Void)?

    init(config: Configuration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - URL 组装

    private func url(path: String) -> URL? {
        var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url
    }

    private var authHeader: [String: String] {
        ["Authorization": "Bearer \(config.token)"]
    }

    private func webSocketURL() -> URL? {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/audio"
        return components.url
    }

    // MARK: - HTTP

    /// 健康检查。成功返回 nil，失败返回错误描述。
    func checkHealth(completion: @escaping (String?) -> Void) {
        healthRequest { [weak self] result in
            switch result {
            case .success:
                completion(nil)
            case .failure(let error):
                completion(self?.describe(error) ?? "服务器响应异常")
            }
        }
    }

    /// 健康检查的结构化版本：重连逻辑需要区分鉴权失败（不可重试）与网络故障。
    private func healthRequest(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = url(path: "/api/health") else {
            completion(.failure(ClientError.badURL)); return
        }
        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.allHTTPHeaderFields = authHeader
        runDataTask(request) { result in
            switch result {
            case .success(let body):
                if let data = body.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   obj["ok"] as? Bool == true {
                    completion(.success(()))
                } else {
                    completion(.failure(ClientError.transport("服务器响应异常")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 文本聊天（无语音时的备用通道 / 调试）。
    /// completion 参数：成功时 (reply, nil)，失败时 (nil, 错误描述)。
    func chat(text: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = url(path: "/api/chat") else {
            completion(nil, ClientError.badURL.localizedDescription); return
        }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = authHeader
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = ["session_id": config.sessionID, "text": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        runDataTask(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let body):
                guard let data = body.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let reply = obj["reply"] as? String else {
                    completion(nil, "服务器响应无法解析")
                    return
                }
                completion(reply, nil)
            case .failure(let error):
                completion(nil, self.describe(error))
            }
        }
    }

    private func runDataTask(_ request: URLRequest, completion: @escaping (Result<String, Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error)); return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ClientError.transport("无响应"))); return
            }
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(ClientError.http(http.statusCode, Self.brief(body))))
                return
            }
            completion(.success(body))
        }.resume()
    }

    private func describe(_ error: Error) -> String {
        if let clientError = error as? ClientError { return clientError.localizedDescription }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时，检查服务器是否在线"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "无法连接到服务器，检查地址与网络"
            case NSURLErrorNetworkConnectionLost: return "网络连接中断"
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func brief(_ body: String) -> String {
        String(body.prefix(120))
    }

    // MARK: - WebSocket 语音通道

    var isSocketConnected: Bool { socket != nil }

    /// App 层用：连接 + 断线自动重连（含首次 health 检查）。
    func startAutoConnect() {
        autoReconnect = true
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeSocketOnly()
        attemptConnection()
    }

    /// 兼容旧调用：立即建连（不做 health、不自动重连）。
    func connectAudio() {
        autoReconnect = false
        closeSocketOnly()
        openSocket()
    }

    func disconnectAudio() {
        autoReconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeSocketOnly()
    }

    /// health 通过后再建 WebSocket；失败按退避重试，鉴权失败则停止。
    private func attemptConnection() {
        guard autoReconnect else { return }
        healthRequest { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.autoReconnect else { return }
                switch result {
                case .success:
                    self.openSocket()
                case .failure(let error):
                    if self.isAuthFailure(error) {
                        self.autoReconnect = false
                        self.emit(.error("访问令牌无效，请到设置里更新"))
                    } else {
                        self.scheduleReconnect(reason: self.describe(error))
                    }
                }
            }
        }
    }

    private func openSocket() {
        guard let url = webSocketURL() else {
            emit(.error(ClientError.badURL.localizedDescription)); return
        }
        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.allHTTPHeaderFields = authHeader
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveLoopActive = true
        receiveLoop()
        sendHello()
        startPing()
    }

    private func closeSocketOnly() {
        receiveLoopActive = false
        pingTimer?.invalidate(); pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        audioQueue.sync { queuedAudioBytes = 0 }
    }

    private func scheduleReconnect(reason: String) {
        guard autoReconnect, reconnectWorkItem == nil else { return }
        reconnectAttempt += 1
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        emit(.reconnecting(attempt: reconnectAttempt, delay: delay))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.attemptConnection()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        NSLog("WhalePet: 语音通道断线（%@），%ds 后第 %d 次重连", reason, Int(delay), reconnectAttempt)
    }

    private func handleSocketFailure(_ message: String) {
        guard autoReconnect else { return }
        closeSocketOnly()
        scheduleReconnect(reason: message)
    }

    private func isAuthFailure(_ error: Error) -> Bool {
        if case ClientError.http(let code, _) = error {
            return code == 401 || code == 403
        }
        return false
    }

    private func sendHello() {
        let hello: [String: Any] = [
            "type": "hello",
            "session_id": config.sessionID,
            "wake_phrase": config.wakePhrase,
            "sample_rate": 16000,
        ]
        sendJSON(hello)
    }

    func sendControl(_ command: String) {
        sendText(command)
    }

    /// 发送 16kHz mono LE Int16 PCM。二进制帧。
    func sendAudio(_ pcm: Data) {
        guard let socket else { return }
        audioQueue.sync {
            // 弱网背压：超过上限直接丢帧（语音实时性 > 完整性）。
            guard queuedAudioBytes + pcm.count <= config.maxQueuedAudioBytes else { return }
            queuedAudioBytes += pcm.count
        }
        socket.send(.data(pcm)) { [weak self] _ in
            self?.audioQueue.sync {
                guard let self else { return }
                // 断连会重置计数；迟到的旧回调不得把它减成负数。
                self.queuedAudioBytes = max(0, self.queuedAudioBytes - pcm.count)
            }
        }
    }

    private func sendText(_ text: String) {
        socket?.send(.string(text)) { _ in }
    }

    private func sendJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            sendText(text)
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: config.pingInterval, repeats: true) { [weak self] _ in
            self?.socket?.sendPing { error in
                guard let self, error != nil else { return }
                DispatchQueue.main.async { self.handleSocketFailure("ping 超时") }
            }
        }
        pingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func receiveLoop() {
        guard receiveLoopActive, let socket else { return }
        socket.receive { [weak self] result in
            guard let self, self.receiveLoopActive else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveLoop()
            case .failure(let error):
                DispatchQueue.main.async {
                    self.handleSocketFailure(error.localizedDescription)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            switch type {
            case "ready":
                reconnectAttempt = 0
                emit(.ready)
            case "state": emit(.state(obj["value"] as? String ?? ""))
            case "wake": emit(.wake)
            case "transcript": emit(.transcript(obj["text"] as? String ?? ""))
            case "thinking": emit(.thinking)
            case "response": emit(.response(obj["text"] as? String ?? ""))
            case "error": emit(.error(obj["message"] as? String ?? "服务器错误"))
            case "task":
                emit(.task(state: obj["state"] as? String ?? "", text: obj["text"] as? String))
            default: break
            }
        default:
            break
        }
    }

    private func emit(_ event: VoiceEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
