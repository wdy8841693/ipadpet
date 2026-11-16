package com.dywu.whalepet.voice;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Build;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.util.Log;

import com.dywu.whalepet.net.DSHClient;
import com.dywu.whalepet.net.ServerSettings;
import com.dywu.whalepet.pet.PetState;

import java.util.Locale;

/**
 * 语音控制器：麦克风采集 → 服务器（VAD/唤醒/ASR/DSH）→ 本地 TTS 播报。
 * 只在 App 前台运行；退后台自动停止。
 *
 * <p>与 iOS 版的对应关系：AVAudioEngine → AudioRecord，AVSpeechSynthesizer → TextToSpeech，
 * URLSessionWebSocketTask → OkHttp WebSocket。上行统一为 16kHz / 单声道 / 16bit LE PCM。</p>
 */
public final class VoiceController implements DSHClient.Listener {

    private static final String TAG = "WhalePetVoice";
    private static final int TARGET_RATE = 16000;

    public enum Kind { DISABLED, CONNECTING, RECONNECTING, WAITING, LISTENING, THINKING, SPEAKING, ERROR }

    public interface Callbacks {
        void onStateChanged(VoiceController c);

        void onTranscript(String text);

        void onResponse(String text);

        void onTaskNotice(String text);

        void onReconnectNotice(String text);

        void onError(String message);
    }

    private final Context ctx;
    private final ServerSettings settings;
    private Callbacks callbacks;

    private Kind kind = Kind.DISABLED;
    private int reconnectAttempt = 0;
    private String errorMessage = "";

    private DSHClient client;

    // 采集
    private AudioRecord recorder;
    private Thread captureThread;
    private volatile boolean capturing = false;
    private int captureRate = TARGET_RATE;
    private Resampler resampler;

    // TTS
    private TextToSpeech tts;
    private boolean ttsReady = false;
    private volatile boolean speaking = false;
    private String pendingSpeech;

    public VoiceController(Context ctx, ServerSettings settings) {
        this.ctx = ctx.getApplicationContext();
        this.settings = settings;
    }

    public void setCallbacks(Callbacks cb) {
        this.callbacks = cb;
    }

    // ---------------------------------------------------------------- 状态

    public Kind getKind() {
        return kind;
    }

    public String displayText() {
        switch (kind) {
            case DISABLED:     return "语音已关闭";
            case CONNECTING:   return "正在连接服务器…";
            case RECONNECTING: return "正在重连（第 " + reconnectAttempt + " 次）…";
            case WAITING:      return "待唤醒（说\"小鲸小鲸\"）";
            case LISTENING:    return "在听，请说指令…";
            case THINKING:     return "思考中…";
            case SPEAKING:     return "回答中…";
            case ERROR:        return "语音异常：" + errorMessage;
            default:           return "";
        }
    }

    /** 映射到宠物的行为状态；无专属动画时返回 null。 */
    public PetState petState() {
        switch (kind) {
            case LISTENING: return PetState.LISTENING;
            case THINKING:  return PetState.THINKING;
            case SPEAKING:  return PetState.SPEAKING;
            default:        return null;
        }
    }

    private void setKind(Kind k) {
        if (kind == k) {
            if (callbacks != null) callbacks.onStateChanged(this);
            return;
        }
        kind = k;
        if (callbacks != null) callbacks.onStateChanged(this);
    }

    private void setError(String message) {
        errorMessage = message;
        kind = Kind.ERROR;
        if (callbacks != null) callbacks.onStateChanged(this);
    }

    // ---------------------------------------------------------------- 生命周期

    public boolean hasPermission() {
        if (Build.VERSION.SDK_INT < 23) return true;
        return ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    }

    /** 开启语音（配置校验 → 拆旧连接 → 建连）。幂等：重复调用只保留最后一次连接。 */
    public void start() {
        if (!settings.isConfigured()) {
            setError("请先在设置里填写服务器地址和访问令牌");
            return;
        }
        String base = settings.serverURL();
        if (base == null) {
            setError("服务器地址无效");
            return;
        }
        if (!hasPermission()) {
            setError("麦克风权限被拒绝，请到系统设置开启");
            return;
        }
        teardownConnection();
        startSession(base);
    }

    public void stop() {
        teardownConnection();
        stopSpeaking();
        setKind(Kind.DISABLED);
    }

    private void teardownConnection() {
        if (client != null) {
            client.setListener(null);
            client.disconnectAudio();
            client = null;
        }
        teardownAudio();
    }

    /** 手动触发一次指令聆听（点按钮，免唤醒词兜底）。 */
    public void startManualCommand() {
        if (client == null) {
            if (callbacks != null) callbacks.onError("语音未开启");
            return;
        }
        setKind(Kind.LISTENING);
        client.sendControl("manual_start");
    }

    public void cancelCurrent() {
        if (client != null) client.sendControl("cancel");
        stopSpeaking();
        setKind(Kind.WAITING);
    }

    private void startSession(String baseURL) {
        setKind(Kind.CONNECTING);
        if (client != null) {
            client.setListener(null);
            client.disconnectAudio();
            client = null;
        }
        DSHClient.Config cfg = new DSHClient.Config(
                baseURL, settings.token(), settings.sessionID(), settings.wakePhrase());
        DSHClient c = new DSHClient(cfg);
        c.setListener(this);
        client = c;
        c.startAutoConnect();
    }

    // ---------------------------------------------------------------- 服务端事件

    @Override
    public void onReady() {
        startCapture();
    }

    @Override
    public void onState(String value) {
        switch (value) {
            case "listening":
                setKind(Kind.LISTENING);
                break;
            case "waiting":
                if (kind == Kind.SPEAKING) break;   // 播报结束/超时回等待，但不打断 speaking
                setKind(Kind.WAITING);
                break;
            case "thinking":
            case "speaking":
                if (kind == Kind.SPEAKING) break;   // 任务提醒播报期间不要打回"思考中"
                setKind(Kind.THINKING);
                break;
            default:
                break;
        }
    }

    @Override
    public void onWake() {
        setKind(Kind.LISTENING);
    }

    @Override
    public void onTranscript(String text) {
        if (callbacks != null) callbacks.onTranscript(text);
        setKind(Kind.THINKING);
    }

    @Override
    public void onThinking() {
        if (kind == Kind.SPEAKING) return;
        setKind(Kind.THINKING);
    }

    @Override
    public void onResponse(String text) {
        if (callbacks != null) callbacks.onResponse(text);
        speak(text);
    }

    @Override
    public void onError(String message) {
        if (callbacks != null) callbacks.onError(message);
        setError(message);
    }

    @Override
    public void onReconnecting(int attempt, double delaySeconds) {
        if (kind == Kind.SPEAKING) return;   // 播报中不要用"正在重连"盖掉 speaking 动画
        reconnectAttempt = attempt;
        setKind(Kind.RECONNECTING);
        if (attempt == 1 && callbacks != null) callbacks.onReconnectNotice("和服务器断开了，我在自动重连…");
    }

    @Override
    public void onTask(String state, String text) {
        switch (state) {
            case "started": {
                String msg = text != null && !text.isEmpty() ? text : "开始执行，我这就去办";
                setKind(Kind.THINKING);
                if (callbacks != null) callbacks.onTaskNotice(msg);
                speak(msg);
                break;
            }
            case "approval": {
                String msg = text != null && !text.isEmpty() ? text : "有个操作需要你在 DSH 里确认一下";
                if (callbacks != null) callbacks.onTaskNotice(msg);
                speak(msg);
                break;
            }
            case "interrupted": {
                String msg = text != null && !text.isEmpty() ? text : "连接恢复了，任务还在后台继续";
                setKind(Kind.THINKING);
                if (callbacks != null) callbacks.onTaskNotice(msg);
                speak(msg);
                break;
            }
            case "finished":
                // 结果由 response 播报；这里只上气泡，避免把刚要念的结果打断。
                if (callbacks != null) callbacks.onTaskNotice("做完了");
                break;
            case "failed":
                if (callbacks != null) callbacks.onTaskNotice("出错了");
                speak("这个任务出错了");
                break;
            default:
                break;
        }
    }

    // ---------------------------------------------------------------- 麦克风采集

    private void startCapture() {
        if (speaking) {
            setKind(Kind.SPEAKING);
            return;
        }
        if (!hasPermission()) {
            setError("麦克风权限被拒绝，请到系统设置开启");
            return;
        }
        teardownAudio();
        AudioRecord rec = createRecorder();
        if (rec == null) {
            setError("无法启动麦克风：设备不支持录音");
            return;
        }
        recorder = rec;
        resampler = new Resampler(captureRate, TARGET_RATE);
        capturing = true;
        try {
            rec.startRecording();
        } catch (Exception e) {
            teardownAudio();
            setError("无法启动麦克风：" + e.getMessage());
            return;
        }
        final AudioRecord r = rec;
        final int chunkSamples = Math.max(captureRate / 10, 800);   // ~100ms
        captureThread = new Thread(() -> {
            byte[] buf = new byte[chunkSamples * 2];
            while (capturing && recorder == r) {
                int n;
                try {
                    n = r.read(buf, 0, buf.length);
                } catch (Exception e) {
                    break;
                }
                if (n <= 0) continue;
                DSHClient c = client;
                if (c == null) break;
                byte[] out = resampler.process(buf, n);
                if (out.length > 0) c.sendAudio(out);
            }
        }, "whalepet-capture");
        captureThread.setPriority(Thread.NORM_PRIORITY + 1);
        captureThread.start();
        setKind(Kind.WAITING);
    }

    private AudioRecord createRecorder() {
        int[] rates = {TARGET_RATE, 44100, 48000};
        int[] sources = {MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC};
        for (int source : sources) {
            for (int rate : rates) {
                int minBuf = AudioRecord.getMinBufferSize(rate,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                if (minBuf <= 0) continue;
                AudioRecord rec = null;
                try {
                    rec = new AudioRecord(source, rate, AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT, Math.max(minBuf * 2, 8192));
                } catch (Exception e) {
                    Log.w(TAG, "AudioRecord(" + rate + ") 创建失败: " + e.getMessage());
                }
                if (rec != null && rec.getState() == AudioRecord.STATE_INITIALIZED) {
                    captureRate = rate;
                    Log.i(TAG, "采集启动：" + rate + "Hz source=" + source);
                    return rec;
                }
                if (rec != null) rec.release();
            }
        }
        return null;
    }

    private void pauseCapture() {
        AudioRecord r = recorder;
        if (r == null) return;
        try {
            if (r.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) r.stop();
        } catch (Exception ignored) {
        }
    }

    private void resumeCapture() {
        AudioRecord r = recorder;
        if (r == null) return;
        try {
            if (r.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) r.startRecording();
        } catch (Exception ignored) {
        }
    }

    private void teardownAudio() {
        capturing = false;
        AudioRecord r = recorder;
        recorder = null;
        if (r != null) {
            try {
                r.stop();
            } catch (Exception ignored) {
            }
            try {
                r.release();
            } catch (Exception ignored) {
            }
        }
        Thread t = captureThread;
        captureThread = null;
        if (t != null) t.interrupt();
    }

    // ---------------------------------------------------------------- TTS

    private void ensureTts() {
        if (tts != null) return;
        tts = new TextToSpeech(ctx, status -> {
            if (status != TextToSpeech.SUCCESS) {
                Log.w(TAG, "TTS 初始化失败");
                return;
            }
            tts.setLanguage(Locale.SIMPLIFIED_CHINESE);
            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                @Override
                public void onStart(String utteranceId) {
                }

                @Override
                public void onDone(String utteranceId) {
                    onSpeechEnded();
                }

                @Override
                public void onError(String utteranceId) {
                    onSpeechEnded();
                }

                @Override
                public void onStop(String utteranceId, boolean interrupted) {
                    // 被 stop()/音频焦点抢占时也要把麦克风还回来
                    onSpeechEnded();
                }
            });
            ttsReady = true;
            if (pendingSpeech != null) {
                String text = pendingSpeech;
                pendingSpeech = null;
                doSpeak(text);
            }
        });
    }

    private void speak(String text) {
        String trimmed = text == null ? "" : text.trim();
        if (trimmed.isEmpty()) {
            setKind(Kind.WAITING);
            return;
        }
        pauseCapture();
        if (client != null) client.sendControl("playback_start");
        stopSpeaking();
        speaking = true;
        setKind(Kind.SPEAKING);
        ensureTts();
        if (ttsReady) {
            doSpeak(trimmed);
        } else {
            pendingSpeech = trimmed;
        }
    }

    private void doSpeak(String text) {
        if (tts == null) return;
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "whalepet-" + System.nanoTime());
    }

    private void stopSpeaking() {
        // 先清标志：stop() 触发的 onStop/onDone 走到 onSpeechEnded() 会直接返回，
        // 免得"主动停止"被当成"自然播完"再补发一次 playback_end。
        speaking = false;
        if (tts != null && tts.isSpeaking()) {
            try {
                tts.stop();
            } catch (Exception ignored) {
            }
        }
    }

    /** 播报结束（正常完成 / 出错 / 被打断）后恢复采集。 */
    private void onSpeechEnded() {
        if (!speaking) return;      // 已经被 stopSpeaking() 收尾过，别重复恢复
        speaking = false;
        if (client != null) client.sendControl("playback_end");
        if (captureThread == null) {
            // 播报期间发生重连时采集尚未恢复（startCapture 在 speaking 时直接返回），这里补启动。
            startCapture();
        } else {
            resumeCapture();
            setKind(Kind.WAITING);
        }
    }

    public void release() {
        stop();
        if (tts != null) {
            try {
                tts.shutdown();
            } catch (Exception ignored) {
            }
            tts = null;
            ttsReady = false;
        }
    }

    // ---------------------------------------------------------------- 重采样

    /** 任意采样率 → 16kHz 的线性重采样器（跨块保持相位连续）。 */
    private static final class Resampler {
        private final double step;
        private double pos = 0;

        Resampler(int from, int to) {
            this.step = (double) from / (double) to;
        }

        /** @param in 小端 16bit PCM 字节；返回 16kHz 小端字节 */
        byte[] process(byte[] in, int length) {
            int count = length / 2;
            short[] src = new short[count];
            for (int i = 0; i < count; i++) {
                src[i] = (short) ((in[i * 2] & 0xFF) | (in[i * 2 + 1] << 8));
            }
            int maxOut = (int) (count / step) + 4;
            short[] out = new short[maxOut];
            int produced = 0;
            while (pos + 1 < count) {
                int i = (int) pos;
                double f = pos - i;
                double v = src[i] * (1 - f) + src[i + 1] * f;
                if (produced < maxOut) out[produced++] = (short) Math.max(-32768, Math.min(32767, v));
                pos += step;
            }
            pos -= count;
            if (pos < 0) pos = 0;

            byte[] bytes = new byte[produced * 2];
            for (int i = 0; i < produced; i++) {
                bytes[i * 2] = (byte) (out[i] & 0xFF);
                bytes[i * 2 + 1] = (byte) ((out[i] >> 8) & 0xFF);
            }
            return bytes;
        }
    }
}
