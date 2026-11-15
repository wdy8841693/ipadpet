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
        guard let url = url(path: "/api/health") else {
            completion(ClientError.badURL.localizedDescription); return
        }
        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.allHTTPHeaderFields = authHeader
        runDataTask(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let body):
                // 严格解析 {"ok":true,...}；{"ok":false} 也算失败。
                if let data = body.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   obj["ok"] as? Bool == true {
                    completion(nil)
                } else {
                    completion("服务器响应异常")
                }
            case .failure(let error):
                completion(self.describe(error))
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

    func connectAudio() {
        disconnectAudio()
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

    func disconnectAudio() {
        receiveLoopActive = false
        pingTimer?.invalidate(); pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        audioQueue.sync { queuedAudioBytes = 0 }
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
                if error != nil { self?.emit(.error("语音通道已断开")) }
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
                self.emit(.error("语音通道断开：\(error.localizedDescription)"))
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
            case "ready": emit(.ready)
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
