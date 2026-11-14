import Foundation

/// 服务器连接配置：URL 走 UserDefaults，令牌走 Keychain。
/// class（引用语义）：ViewController 与 VoiceController 共享同一份配置。
/// 纯 Foundation，可单元测试（Keychain 通过协议注入）。
final class ServerSettings {
    struct ValidationError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// 校验并规整服务器地址：只允许 http/https 且必须有主机名。
    /// - Returns: 规整后的 URL（去掉路径与尾斜杠）；不合法则抛错。
    static func normalizeServerURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw ValidationError(message: "服务器地址需形如 http://192.168.1.10:8787")
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port { components.port = port }
        // 丢弃 path/query/fragment，只保留 scheme://host:port
        guard let base = components.url else {
            throw ValidationError(message: "服务器地址无法解析")
        }
        return base
    }

    static let defaultWakePhrase = "小鲸小鲸"

    // MARK: - 存储

    private let defaults: UserDefaults
    private let keychain: KeychainReading

    init(defaults: UserDefaults = .standard, keychain: KeychainReading = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private static let serverURLKey = "whalepet.serverURL"
    private static let sessionIDKey = "whalepet.sessionID"
    private static let voiceEnabledKey = "whalepet.voiceEnabled"

    var serverURL: URL? {
        get {
            guard let raw = defaults.string(forKey: Self.serverURLKey) else { return nil }
            return try? Self.normalizeServerURL(raw)
        }
        set {
            if let url = newValue {
                defaults.set(url.absoluteString, forKey: Self.serverURLKey)
            } else {
                defaults.removeObject(forKey: Self.serverURLKey)
            }
        }
    }

    /// 访问令牌存 Keychain，不进 UserDefaults（避免 iTunes 备份明文）。
    var token: String {
        get { keychain.readString(service: "whalepet", account: "serverToken") ?? "" }
        set { keychain.writeString(newValue, service: "whalepet", account: "serverToken") }
    }

    /// 每台 iPad 固定一个会话 id，保持 DSH 对话记忆连续。
    var sessionID: String {
        if let existing = defaults.string(forKey: Self.sessionIDKey),
           !existing.isEmpty {
            return existing
        }
        let fresh = "pet-" + UUID().uuidString.prefix(8).lowercased()
        defaults.set(fresh, forKey: Self.sessionIDKey)
        return fresh
    }

    var wakePhrase: String { Self.defaultWakePhrase }

    var isVoiceEnabled: Bool {
        get { defaults.bool(forKey: Self.voiceEnabledKey) }
        set { defaults.set(newValue, forKey: Self.voiceEnabledKey) }
    }

    /// 配置完整（地址 + 令牌）才允许连接。
    var isConfigured: Bool {
        serverURL != nil && !token.isEmpty
    }
}

/// 轻量 Keychain 封装；抽象成协议便于测试。
protocol KeychainReading {
    func readString(service: String, account: String) -> String?
    func writeString(_ value: String, service: String, account: String)
}

struct KeychainStore: KeychainReading {
    func readString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeString(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
