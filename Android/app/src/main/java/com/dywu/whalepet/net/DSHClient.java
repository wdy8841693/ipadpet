package com.dywu.whalepet.net;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import org.json.JSONObject;

import java.io.IOException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okio.ByteString;

/**
 * DSH 桥接客户端：HTTP 健康检查 / 文本聊天 + WebSocket 语音通道。
 *
 * <p>协议与 iOS 版 {@code DSHClient} 完全一致：</p>
 * <pre>
 * GET  /api/health   Authorization: Bearer &lt;token&gt;  → {"ok":true,...}
 * POST /api/chat     {"session_id":"…","text":"…"}    → {"reply":"…"}
 * WS   /api/audio    hello / 16kHz PCM 二进制帧 / 控制文本
 * </pre>
 *
 * <p>所有回调都投递到主线程，调用方不必自己切线程。</p>
 */
public final class DSHClient {

    private static final String TAG = "WhalePetDSH";
    private static final MediaType JSON = MediaType.parse("application/json; charset=utf-8");

    /** 服务端事件（JSON 文本帧）。 */
    public interface Listener {
        void onReady();

        void onState(String value);

        void onWake();

        void onTranscript(String text);

        void onThinking();

        void onResponse(String text);

        void onError(String message);

        void onTask(String state, String text);

        void onReconnecting(int attempt, double delaySeconds);
    }

    public static final class Config {
        public final String baseURL;
        public final String token;
        public final String sessionID;
        public final String wakePhrase;

        public Config(String baseURL, String token, String sessionID, String wakePhrase) {
            this.baseURL = baseURL;
            this.token = token;
            this.sessionID = sessionID;
            this.wakePhrase = wakePhrase;
        }
    }

    /** 重连退避：1s、2s、4s、8s、16s、30s（封顶）。 */
    public static double reconnectDelay(int attempt) {
        int n = Math.max(1, attempt);
        return Math.min(30, Math.pow(2, n - 1));
    }

    /** 连续重连上限：超过后停止自动重连，等用户手动点麦克风重试。 */
    public static final int MAX_RECONNECT_ATTEMPTS = 10;

    public static boolean shouldGiveUpReconnect(int attempt) {
        return attempt >= MAX_RECONNECT_ATTEMPTS;
    }

    private final Config config;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final OkHttpClient httpClient;
    private final OkHttpClient wsClient;

    private volatile WebSocket socket;
    // 以下状态只在主线程读写。
    private boolean autoReconnect = false;
    private int reconnectAttempt = 0;
    private boolean reconnectScheduled = false;
    /** WebSocket 代际号：每次建连/断开都自增，用来丢弃旧连接迟到的回调。 */
    private volatile int wsGeneration = 0;

    private Listener listener;

    // 弱网背压：仅估算在途字节（语音实时性 > 完整性）。
    private final AtomicLong queuedBytes = new AtomicLong(0);
    private final AtomicLong lastDrainNanos = new AtomicLong(0);
    private static final long MAX_QUEUED_AUDIO_BYTES = 1_500_000L;

    public DSHClient(Config config) {
        this.config = config;
        this.httpClient = new OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .build();
        this.wsClient = new OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)   // WebSocket：不设读超时，靠 ping 探活
                .pingInterval(20, TimeUnit.SECONDS)
                .build();
    }

    public void setListener(Listener l) {
        this.listener = l;
    }

    // ---------------------------------------------------------------- HTTP

    public interface HealthCallback {
        void onResult(boolean ok, int statusCode, String message);
    }

    /** 健康检查。成功 ok=true；失败给出中文原因。 */
    public void healthCheck(final HealthCallback cb) {
        HttpUrl url = buildUrl("/api/health");
        if (url == null) {
            cb.onResult(false, 0, "服务器地址无效");
            return;
        }
        Request req = new Request.Builder()
                .url(url)
                .header("Authorization", "Bearer " + config.token)
                .get()
                .build();
        httpClient.newCall(req).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                post(() -> cb.onResult(false, 0, describe(e)));
            }

            @Override
            public void onResponse(Call call, Response response) {
                String body = "";
                try {
                    body = response.body() != null ? response.body().string() : "";
                } catch (IOException ignored) {
                }
                boolean ok = false;
                if (response.isSuccessful()) {
                    try {
                        ok = new JSONObject(body).optBoolean("ok", false);
                    } catch (Exception ignored) {
                    }
                }
                final int code = response.code();
                final boolean success = ok;
                final String bodyText = body;
                post(() -> {
                    if (success) {
                        cb.onResult(true, code, null);
                    } else if (code == 401 || code == 403) {
                        cb.onResult(false, code, "访问令牌无效");
                    } else if (code >= 200 && code < 300) {
                        cb.onResult(false, code, "服务器响应异常");
                    } else {
                        cb.onResult(false, code, "服务器错误(" + code + ")：" + brief(bodyText));
                    }
                });
            }
        });
    }

    public interface ChatCallback {
        void onResult(String reply, String error);
    }

    /** 文本聊天（调试 / 无语音时的备用通道）。 */
    public void chat(String text, final ChatCallback cb) {
        HttpUrl url = buildUrl("/api/chat");
        if (url == null) {
            cb.onResult(null, "服务器地址无效");
            return;
        }
        JSONObject payload = new JSONObject();
        try {
            payload.put("session_id", config.sessionID);
            payload.put("text", text);
        } catch (Exception ignored) {
        }
        Request req = new Request.Builder()
                .url(url)
                .header("Authorization", "Bearer " + config.token)
                .post(RequestBody.create(JSON, payload.toString()))
                .build();
        OkHttpClient slow = httpClient.newBuilder().readTimeout(600, TimeUnit.SECONDS).build();
        slow.newCall(req).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                post(() -> cb.onResult(null, describe(e)));
            }

            @Override
            public void onResponse(Call call, Response response) {
                String body = "";
                try {
                    body = response.body() != null ? response.body().string() : "";
                } catch (IOException ignored) {
                }
                String reply = null;
                String error = null;
                if (!response.isSuccessful()) {
                    error = "服务器错误(" + response.code() + ")：" + brief(body);
                } else {
                    try {
                        reply = new JSONObject(body).optString("reply", null);
                        if (reply == null) error = "服务器响应无法解析";
                    } catch (Exception e) {
                        error = "服务器响应无法解析";
                    }
                }
                final String r = reply;
                final String er = error;
                post(() -> cb.onResult(r, er));
            }
        });
    }

    // ---------------------------------------------------------------- WebSocket

    public boolean isSocketConnected() {
        return socket != null;
    }

    /** 连接 + 断线自动重连（含首次 health 检查）。 */
    public void startAutoConnect() {
        main.post(() -> {
            autoReconnect = true;
            reconnectAttempt = 0;
            reconnectScheduled = false;
            closeSocketOnly();
            attemptConnection();
        });
    }

    /** 立即建连（不做 health、不自动重连）。 */
    public void connectAudio() {
        main.post(() -> {
            autoReconnect = false;
            closeSocketOnly();
            openSocket();
        });
    }

    public void disconnectAudio() {
        main.post(() -> {
            autoReconnect = false;
            reconnectScheduled = false;
            closeSocketOnly();
        });
    }

    private void attemptConnection() {
        if (!autoReconnect) return;
        healthCheck((ok, code, message) -> {
            if (!autoReconnect) return;
            if (ok) {
                openSocket();
            } else if (code == 401 || code == 403) {
                autoReconnect = false;
                emitError("访问令牌无效，请到设置里更新");
            } else {
                scheduleReconnect(message);
            }
        });
    }

    private void openSocket() {
        HttpUrl http = buildUrl("/api/audio");
        if (http == null) {
            emitError("服务器地址无效");
            return;
        }
        HttpUrl ws = http.newBuilder().scheme(http.isHttps() ? "wss" : "ws").build();
        Request req = new Request.Builder()
                .url(ws)
                .header("Authorization", "Bearer " + config.token)
                .build();
        // 旧连接的回调必须失效：否则刚关掉的 socket 迟到的 onClosed 会触发一次多余的重连，
        // 结果是同时存在两条语音通道（ready 事件重复、两路音频）。用代际号屏蔽。
        WebSocket previous = socket;
        socket = null;
        if (previous != null) previous.cancel();
        int gen = ++wsGeneration;
        socket = wsClient.newWebSocket(req, new WsListener(gen));
    }

    private void closeSocketOnly() {
        wsGeneration++;          // 让所有在途回调失效
        WebSocket s = socket;
        socket = null;
        if (s != null) {
            try {
                s.close(1000, "client closing");
                s.cancel();
            } catch (Exception ignored) {
            }
        }
        queuedBytes.set(0);
    }

    private void scheduleReconnect(String reason) {
        if (!autoReconnect || reconnectScheduled) return;
        if (shouldGiveUpReconnect(reconnectAttempt)) {
            autoReconnect = false;
            Log.w(TAG, "重连放弃（已重试 " + reconnectAttempt + " 次，最后一次原因：" + reason + "）");
            emitError("连不上服务器（已重试 " + MAX_RECONNECT_ATTEMPTS + " 次），点麦克风按钮重试");
            return;
        }
        reconnectAttempt++;
        double delay = reconnectDelay(reconnectAttempt);
        emitReconnecting(reconnectAttempt, delay);
        reconnectScheduled = true;
        main.postDelayed(() -> {
            reconnectScheduled = false;
            attemptConnection();
        }, (long) (delay * 1000));
        Log.i(TAG, "语音通道断线（" + reason + "），" + (int) delay + "s 后第 " + reconnectAttempt + " 次重连");
    }

    private void handleSocketFailure(String message) {
        socket = null;
        queuedBytes.set(0);
        if (!autoReconnect) return;
        scheduleReconnect(message);
    }

    private final class WsListener extends WebSocketListener {
        private final int gen;

        WsListener(int gen) {
            this.gen = gen;
        }

        /** 旧连接（被替换/主动关闭）的回调一律丢弃。 */
        private boolean stale() {
            return gen != wsGeneration;
        }

        @Override
        public void onOpen(WebSocket webSocket, Response response) {
            if (stale()) return;
            sendHello(webSocket);
        }

        @Override
        public void onMessage(WebSocket webSocket, String text) {
            if (stale()) return;
            handleText(text);
        }

        @Override
        public void onMessage(WebSocket webSocket, ByteString bytes) {
            // 服务端目前不下发音频（TTS 在客户端本地播报）。
        }

        @Override
        public void onClosing(WebSocket webSocket, int code, String reason) {
            if (stale()) return;
            webSocket.close(1000, null);
        }

        @Override
        public void onClosed(WebSocket webSocket, int code, String reason) {
            if (stale()) return;
            main.post(() -> {
                if (stale()) return;
                handleSocketFailure("连接已关闭(" + code + ")");
            });
        }

        @Override
        public void onFailure(WebSocket webSocket, Throwable t, Response response) {
            if (stale()) return;
            String msg = t != null && t.getMessage() != null ? t.getMessage() : "连接失败";
            if (response != null && (response.code() == 401 || response.code() == 403)) {
                main.post(() -> {
                    autoReconnect = false;
                    emitError("访问令牌无效，请到设置里更新");
                });
                return;
            }
            main.post(() -> {
                if (stale()) return;
                handleSocketFailure(msg);
            });
        }
    }

    private void sendHello(WebSocket ws) {
        JSONObject o = new JSONObject();
        try {
            o.put("type", "hello");
            o.put("session_id", config.sessionID);
            o.put("wake_phrase", config.wakePhrase);
            o.put("sample_rate", 16000);
        } catch (Exception ignored) {
        }
        ws.send(o.toString());
    }

    private void handleText(String text) {
        String type;
        JSONObject o;
        try {
            o = new JSONObject(text);
            type = o.optString("type", "");
        } catch (Exception e) {
            return;
        }
        switch (type) {
            case "ready":
                main.post(() -> {
                    reconnectAttempt = 0;
                    if (listener != null) listener.onReady();
                });
                break;
            case "state":
                emit(l -> l.onState(o.optString("value", "")));
                break;
            case "wake":
                emit(Listener::onWake);
                break;
            case "transcript":
                emit(l -> l.onTranscript(o.optString("text", "")));
                break;
            case "thinking":
                emit(Listener::onThinking);
                break;
            case "response":
                emit(l -> l.onResponse(o.optString("text", "")));
                break;
            case "error":
                emitError(o.optString("message", "服务器错误"));
                break;
            case "task":
                emit(l -> l.onTask(o.optString("state", ""), o.optString("text", null)));
                break;
            default:
                break;
        }
    }

    // ---------------------------------------------------------------- 发送

    public void sendControl(String command) {
        WebSocket s = socket;
        if (s != null) s.send(command);
    }

    /** 发送 16kHz mono LE Int16 PCM（二进制帧）。可从任意线程调用。 */
    public void sendAudio(byte[] pcm) {
        WebSocket s = socket;
        if (s == null || pcm == null || pcm.length == 0) return;

        long now = System.nanoTime();
        long prev = lastDrainNanos.getAndSet(now);
        if (prev != 0) {
            // 估算这一小段时间内网络已排空的字节数（约 32KB/s @16kHz/16bit）
            long drained = (now - prev) / 1_000_000L * 32L;
            long remain = queuedBytes.addAndGet(-drained);
            if (remain < 0) queuedBytes.set(0);
        }
        if (queuedBytes.get() + pcm.length > MAX_QUEUED_AUDIO_BYTES) {
            return;   // 弱网背压：直接丢帧
        }
        queuedBytes.addAndGet(pcm.length);
        s.send(ByteString.of(pcm));
    }

    // ---------------------------------------------------------------- 内部工具

    private HttpUrl buildUrl(String path) {
        HttpUrl base = HttpUrl.parse(config.baseURL);
        if (base == null) return null;
        return base.newBuilder().encodedPath(path).query(null).fragment(null).build();
    }

    private void emit(EventFn fn) {
        main.post(() -> {
            if (listener != null) fn.apply(listener);
        });
    }

    private void emitError(String message) {
        emit(l -> l.onError(message));
    }

    private void emitReconnecting(int attempt, double delay) {
        emit(l -> l.onReconnecting(attempt, delay));
    }

    private interface EventFn {
        void apply(Listener l);
    }

    private void post(Runnable r) {
        main.post(r);
    }

    private static String brief(String body) {
        if (body == null) return "";
        return body.length() > 120 ? body.substring(0, 120) : body;
    }

    private static String describe(IOException e) {
        if (e instanceof SocketTimeoutException) return "连接超时，检查服务器是否在线";
        if (e instanceof UnknownHostException) return "无法解析服务器地址，检查地址与网络";
        String m = e.getMessage();
        if (m != null && m.contains("refused")) return "连接被拒绝，服务器没在运行？";
        return m != null ? m : "网络连接失败";
    }
}
