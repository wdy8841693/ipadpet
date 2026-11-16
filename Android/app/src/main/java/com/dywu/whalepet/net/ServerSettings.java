package com.dywu.whalepet.net;

import android.content.Context;
import android.content.SharedPreferences;

import java.net.URI;
import java.util.Locale;
import java.util.UUID;

/**
 * 服务器连接配置：地址 / 会话 ID / 语音开关走 SharedPreferences。
 *
 * <p>与 iOS 的差异：Android 没有 Keychain，令牌存在私有 SharedPreferences 里
 * （未 root 的设备上其它应用读不到）。若需要更强保护，可后续接
 * androidx.security 的 EncryptedSharedPreferences。</p>
 */
public final class ServerSettings {

    public static final String DEFAULT_WAKE_PHRASE = "小鲸小鲸";

    private static final String PREFS = "whalepet";
    private static final String KEY_URL = "whalepet.serverURL";
    private static final String KEY_TOKEN = "whalepet.token";
    private static final String KEY_SESSION = "whalepet.sessionID";
    private static final String KEY_VOICE = "whalepet.voiceEnabled";

    private final SharedPreferences prefs;

    public ServerSettings(Context ctx) {
        prefs = ctx.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /**
     * 校验并规整服务器地址：只允许 http/https 且必须有主机名；
     * 去掉路径/查询/尾斜杠，只保留 scheme://host:port。
     *
     * @throws IllegalArgumentException 地址不合法（message 可直接展示给用户）
     */
    public static String normalizeServerURL(String raw) {
        if (raw == null) throw new IllegalArgumentException("服务器地址需形如 http://192.168.1.10:8787");
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) throw new IllegalArgumentException("服务器地址需形如 http://192.168.1.10:8787");
        URI uri;
        try {
            uri = new URI(trimmed);
        } catch (Exception e) {
            throw new IllegalArgumentException("服务器地址需形如 http://192.168.1.10:8787");
        }
        String scheme = uri.getScheme();
        String host = uri.getHost();
        if (scheme == null || host == null || host.isEmpty()) {
            throw new IllegalArgumentException("服务器地址需形如 http://192.168.1.10:8787");
        }
        scheme = scheme.toLowerCase(Locale.US);
        if (!scheme.equals("http") && !scheme.equals("https")) {
            throw new IllegalArgumentException("只支持 http:// 或 https:// 开头的地址");
        }
        int port = uri.getPort();
        // IPv6 字面量在 URI 里 getHost() 不带方括号，拼回去需要补。
        String hostPart = (host.indexOf(':') >= 0 && !host.startsWith("[")) ? "[" + host + "]" : host;
        return scheme + "://" + hostPart + (port > 0 ? ":" + port : "");
    }

    public String serverURL() {
        String raw = prefs.getString(KEY_URL, null);
        if (raw == null) return null;
        try {
            return normalizeServerURL(raw);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    public void setServerURL(String url) {
        if (url == null) {
            prefs.edit().remove(KEY_URL).apply();
        } else {
            prefs.edit().putString(KEY_URL, url).apply();
        }
    }

    public String token() {
        return prefs.getString(KEY_TOKEN, "");
    }

    public void setToken(String token) {
        prefs.edit().putString(KEY_TOKEN, token == null ? "" : token.trim()).apply();
    }

    /** 每台设备固定一个会话 id，保持 DSH 对话记忆连续。 */
    public String sessionID() {
        String existing = prefs.getString(KEY_SESSION, null);
        if (existing != null && !existing.isEmpty()) return existing;
        String fresh = "pet-" + UUID.randomUUID().toString().replace("-", "").substring(0, 8).toLowerCase(Locale.US);
        prefs.edit().putString(KEY_SESSION, fresh).apply();
        return fresh;
    }

    public String wakePhrase() {
        return DEFAULT_WAKE_PHRASE;
    }

    public boolean isVoiceEnabled() {
        return prefs.getBoolean(KEY_VOICE, false);
    }

    public void setVoiceEnabled(boolean enabled) {
        prefs.edit().putBoolean(KEY_VOICE, enabled).apply();
    }

    /** 配置完整（地址 + 令牌）才允许连接。 */
    public boolean isConfigured() {
        return serverURL() != null && !token().isEmpty();
    }
}
