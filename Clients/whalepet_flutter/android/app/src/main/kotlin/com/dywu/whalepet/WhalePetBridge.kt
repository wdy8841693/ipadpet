package com.dywu.whalepet

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/**
 * Android 原生能力桥（对应 Dart 侧 `lib/platform/android/native_bridge.dart`）。
 *
 * 职责边界来自 docs/CROSS_PLATFORM.md：
 * - §7.4 PCM 不穿越 MethodChannel：采集/识别都在系统语音服务里，Dart 只收文本事件；
 * - §10.1 系统 TTS 用 TextToSpeech，等 utterance 完成回调再恢复唤醒；
 * - §11.2 令牌用 Android Keystore（AES-GCM）加密后落 SharedPreferences。
 *
 * 通道：
 * - MethodChannel `whalepet/native`
 * - EventChannel  `whalepet/native/events`
 */
class WhalePetBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "WhalePetNative"
        private const val METHOD_CHANNEL = "whalepet/native"
        private const val EVENT_CHANNEL = "whalepet/native/events"
        private const val KEY_ALIAS = "whalepet_token_key"
        private const val PREFS = "whalepet_secure"
        private const val MIC_REQUEST_CODE = 4711
    }

    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)

    private var sink: EventChannel.EventSink? = null
    private var pendingMicResult: MethodChannel.Result? = null

    // TTS
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsInitializing = false
    private val ttsWaiters = mutableListOf<MethodChannel.Result>()

    // ASR
    private var recognizer: SpeechRecognizer? = null
    private var asrRunning = false
    private var asrWakeMode = false
    private var consecutiveErrors = 0

    // 音频焦点 / 来电（§10.1）
    private val audioManager: AudioManager by lazy {
        activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    private var focusRequest: AudioFocusRequest? = null
    private var focusHeld = false

    /** 采集是否被外部打断（来电、其它应用抢走音频）。 */
    private var interrupted = false

    private var lastAudioMode: String? = null
    private var modePoller: Runnable? = null

    fun register() {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        stopAsr(force = true)
        tts?.shutdown()
        tts = null
        ttsReady = false
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    /** Flutter 侧进入后台：停采集（§10.1「退后台默认停止采集」）。 */
    fun onActivityPause() {
        // 退后台一律彻底放手：焦点、轮询、打断标记都清掉；
        // 回来时 Dart 侧会按用户设置重新起。
        stopAsr(force = true)
    }

    // -- EventChannel ---------------------------------------------------------

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(payload: Map<String, Any?>) {
        main.post { sink?.success(payload) }
    }

    // -- MethodChannel --------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "appRootDir" -> result.success(activity.filesDir.absolutePath)
                "hasMicPermission" -> result.success(hasMicPermission())
                "requestMicPermission" -> requestMicPermission(result)
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }
                "secureRead" -> {
                    val key = call.argument<String>("key") ?: ""
                    result.success(secureRead(key))
                }
                "secureWrite" -> {
                    val key = call.argument<String>("key") ?: ""
                    val value = call.argument<String>("value") ?: ""
                    secureWrite(key, value)
                    result.success(null)
                }
                "ttsInit" -> ensureTts(result)
                "ttsSpeak" -> {
                    val id = call.argument<String>("id") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    val rate = call.argument<Double>("rate") ?: 0.55
                    speakTts(id, text, rate, result)
                }
                "ttsStop" -> {
                    tts?.stop()
                    result.success(null)
                }
                "asrAvailable" -> result.success(
                    SpeechRecognizer.isRecognitionAvailable(activity)
                )
                "asrStart" -> {
                    startAsr(call.argument<Boolean>("wakeMode") ?: false)
                    result.success(null)
                }
                "asrStop" -> {
                    stopAsr(force = call.argument<Boolean>("force") ?: false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            Log.w(TAG, "method ${call.method} failed: ${error.message}")
            result.error("native_error", error.message ?: error.toString(), null)
        }
    }

    // -- 权限 -----------------------------------------------------------------

    private fun hasMicPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestMicPermission(result: MethodChannel.Result) {
        if (hasMicPermission()) {
            result.success(true)
            return
        }
        pendingMicResult?.success(false)
        pendingMicResult = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.RECORD_AUDIO),
            MIC_REQUEST_CODE,
        )
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != MIC_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingMicResult?.success(granted)
        pendingMicResult = null
    }

    private fun openAppSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", activity.packageName, null),
        )
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
    }

    // -- 安全存储（Android Keystore + AES-GCM，§11.2） -------------------------

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun secureWrite(key: String, value: String) {
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (value.isEmpty()) {
            prefs.edit().remove(key).apply()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val blob = ByteArray(1 + iv.size + cipherText.size)
        blob[0] = iv.size.toByte()
        System.arraycopy(iv, 0, blob, 1, iv.size)
        System.arraycopy(cipherText, 0, blob, 1 + iv.size, cipherText.size)
        prefs.edit()
            .putString(key, Base64.encodeToString(blob, Base64.NO_WRAP))
            .apply()
    }

    private fun secureRead(key: String): String? {
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val encoded = prefs.getString(key, null) ?: return null
        return try {
            val blob = Base64.decode(encoded, Base64.NO_WRAP)
            if (blob.isEmpty()) return null
            val ivSize = blob[0].toInt()
            if (ivSize <= 0 || 1 + ivSize >= blob.size) return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(128, blob, 1, ivSize),
            )
            String(
                cipher.doFinal(blob, 1 + ivSize, blob.size - 1 - ivSize),
                Charsets.UTF_8,
            )
        } catch (error: Throwable) {
            Log.w(TAG, "令牌解密失败（可能换机或密钥被清）: ${error.message}")
            null
        }
    }

    // -- TTS ------------------------------------------------------------------

    private fun ensureTts(result: MethodChannel.Result) {
        if (ttsReady) {
            result.success(true)
            return
        }
        ttsWaiters.add(result)
        if (ttsInitializing) return
        ttsInitializing = true
        tts = TextToSpeech(activity) { status ->
            ttsInitializing = false
            val ok = status == TextToSpeech.SUCCESS
            if (ok) {
                val engine = tts
                engine?.setLanguage(Locale.SIMPLIFIED_CHINESE)
                engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        emit(mapOf("type" to "tts", "kind" to "started", "id" to utteranceId))
                    }

                    override fun onDone(utteranceId: String?) {
                        emit(mapOf("type" to "tts", "kind" to "finished", "id" to utteranceId))
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        emit(
                            mapOf(
                                "type" to "tts",
                                "kind" to "failed",
                                "id" to utteranceId,
                                "message" to "系统播报失败",
                            ),
                        )
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        emit(
                            mapOf(
                                "type" to "tts",
                                "kind" to "failed",
                                "id" to utteranceId,
                                "message" to "系统播报失败（$errorCode）",
                            ),
                        )
                    }

                    // 被别的应用抢音频焦点 / 主动 stop()：也回一个失败，
                    // 否则 Dart 侧的协调器会一直以为「还在播报」。
                    override fun onStop(utteranceId: String?, interrupted: Boolean) {
                        emit(
                            mapOf(
                                "type" to "tts",
                                "kind" to "failed",
                                "id" to utteranceId,
                                "message" to if (interrupted) "播报被打断" else "播报已停止",
                            ),
                        )
                    }
                })
                ttsReady = true
            } else {
                Log.w(TAG, "TTS 初始化失败 status=$status")
            }
            ttsWaiters.forEach { it.success(ok) }
            ttsWaiters.clear()
        }
    }

    private fun speakTts(
        id: String,
        text: String,
        rate: Double,
        result: MethodChannel.Result,
    ) {
        if (text.isBlank()) {
            result.success(null)
            return
        }
        if (!ttsReady) {
            // 还没初始化完：先初始化，成功后再播（失败就只上屏不朗读）。
            ensureTts(object : MethodChannel.Result {
                override fun success(payload: Any?) {
                    if (payload == true) {
                        tts?.setSpeechRate(rate.toFloat())
                        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
                    }
                    result.success(null)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    result.success(null)
                }

                override fun notImplemented() {
                    result.success(null)
                }
            })
            return
        }
        tts?.setSpeechRate(rate.toFloat())
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
        result.success(null)
    }

    // -- 语音识别 -------------------------------------------------------------

    private fun startAsr(wakeMode: Boolean) {
        asrWakeMode = wakeMode
        asrRunning = true
        consecutiveErrors = 0
        interrupted = false
        if (wakeMode) {
            // 待机唤醒不占音频焦点（§7.6）：把聆听时留下的还回去。
            abandonAudioFocus()
        } else {
            requestAudioFocus()
        }
        ensureRecognizer()
        startListeningInternal()
        startModePolling()
    }

    private fun ensureRecognizer(): SpeechRecognizer {
        recognizer?.let { return it }
        val created = SpeechRecognizer.createSpeechRecognizer(activity)
        created.setRecognitionListener(recognitionListener)
        recognizer = created
        return created
    }

    private fun startListeningInternal() {
        if (!asrRunning) return
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "zh-CN")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            // 判停参数（§7.3）：尾部静音约 0.9s 收句，最短输入 1.2s 避免误触发。
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 900L)
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                900L,
            )
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 1200L)
        }
        try {
            recognizer?.cancel()
            recognizer?.startListening(intent)
        } catch (error: Throwable) {
            Log.w(TAG, "startListening 失败: ${error.message}")
            emit(
                mapOf(
                    "type" to "error",
                    "code" to "start_failed",
                    "message" to (error.message ?: "语音识别启动失败"),
                ),
            )
        }
    }

    /**
     * 停止采集。
     *
     * [force] = true 表示用户明确停止（关语音 / 退后台 / 释放）：释放音频焦点、
     * 停掉来电轮询、清掉打断标记。
     *
     * 打断期间的自动停采集传 false：只停识别器，**焦点请求和来电轮询要留着**。
     * 待机唤醒本来就不占焦点，来电恢复只能靠 `startModePolling()` 报 `normal`；
     * 如果这里把轮询也停了，Dart 会永远卡在 error 等一个不会来的恢复事件（§10.1）。
     */
    private fun stopAsr(force: Boolean = false) {
        asrRunning = false
        stopRecognizer()
        if (interrupted && !force) return
        interrupted = false
        abandonAudioFocus()
        stopModePolling()
    }

    private fun stopRecognizer() {
        try {
            recognizer?.cancel()
            recognizer?.destroy()
        } catch (ignored: Throwable) {
        }
        recognizer = null
    }

    // -- 音频焦点 / 来电（§10.1） ---------------------------------------------

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                focusHeld = true
                if (interrupted) {
                    interrupted = false
                    emit(mapOf("type" to "audio_focus", "state" to "gain"))
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                focusHeld = false
                markInterrupted("麦克风被其它应用接管")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                markInterrupted("麦克风被暂时占用")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 只是要求把音量压低，不算中断。
            }
        }
    }

    /**
     * 采集被打断：先停掉识别（别往一个已经不可用的通道里继续写），
     * 再把原因告诉 Dart，由协调器决定怎么提示用户、什么时候恢复。
     */
    private fun markInterrupted(message: String) {
        if (interrupted) return
        interrupted = true
        asrRunning = false
        stopRecognizer()
        emit(
            mapOf(
                "type" to "audio_focus",
                "state" to "loss",
                "message" to message,
            ),
        )
    }

    /**
     * 申请音频焦点。
     *
     * **只在主动聆听时申请**：用户正在跟宠物说话，这时候让其它应用暂时让路
     * 是合理的。待机唤醒不申请——低功耗守门器不该打扰用户正在听的音乐
     * （§7.6）；待机时麦克风被占由识别器自己的报错（ERROR_RECOGNIZER_BUSY）兜底。
     */
    private fun requestAudioFocus() {
        if (focusHeld) return
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        focusHeld = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(focusListener, main)
                .setWillPauseWhenDucked(true)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            requestAudioFocusLegacy(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
    }

    /** API 26 以下的旧版焦点申请（用 streamType 表达）。 */
    @Suppress("DEPRECATION")
    private fun requestAudioFocusLegacy(duration: Int): Boolean =
        audioManager.requestAudioFocus(
            focusListener,
            AudioManager.STREAM_VOICE_CALL,
            duration,
        ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED

    private fun abandonAudioFocus() {
        if (!focusHeld && focusRequest == null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            abandonAudioFocusLegacy()
        }
        focusHeld = false
    }

    /** API 26 以下的旧版放弃焦点。 */
    @Suppress("DEPRECATION")
    private fun abandonAudioFocusLegacy() {
        audioManager.abandonAudioFocus(focusListener)
    }

    /**
     * 轮询音频模式，识别「来电 / 通话中」。
     *
     * 用 AudioManager.mode 而不是 READ_PHONE_STATE：不需要敏感权限，
     * 也能覆盖绝大多数来电场景。
     */
    private fun startModePolling() {
        if (modePoller != null) return
        val poller = object : Runnable {
            override fun run() {
                val mode = currentAudioMode()
                if (mode != lastAudioMode) {
                    lastAudioMode = mode
                    // 先报模式变化，再报中断：Dart 侧据此区分「来电」和
                    // 「别的应用抢了麦克风」，提示文案才说得准。
                    emit(mapOf("type" to "audio_mode", "mode" to mode))
                    if (mode == "in_call" || mode == "ringtone" || mode == "in_communication") {
                        markInterrupted("检测到来电/通话")
                    }
                }
                main.postDelayed(this, 500)
            }
        }
        modePoller = poller
        main.postDelayed(poller, 500)
    }

    private fun stopModePolling() {
        modePoller?.let { main.removeCallbacks(it) }
        modePoller = null
    }

    private fun currentAudioMode(): String = when (audioManager.mode) {
        AudioManager.MODE_NORMAL -> "normal"
        AudioManager.MODE_RINGTONE -> "ringtone"
        AudioManager.MODE_IN_CALL -> "in_call"
        AudioManager.MODE_IN_COMMUNICATION -> "in_communication"
        else -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                audioManager.mode == AudioManager.MODE_CALL_SCREENING
            ) {
                "call_screening"
            } else {
                "unknown"
            }
        }
    }

    private fun restartSoon(delayMs: Long) {
        main.postDelayed({
            if (asrRunning) startListeningInternal()
        }, delayMs)
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}

        override fun onPartialResults(partialResults: Bundle?) {
            if (asrWakeMode) return
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isEmpty()) return
            emit(mapOf("type" to "partial", "text" to text))
        }

        override fun onResults(results: Bundle?) {
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            val confidence = results
                ?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
                ?.firstOrNull()
                ?: 0f
            consecutiveErrors = 0
            emit(
                mapOf(
                    "type" to "final",
                    "text" to text,
                    "confidence" to confidence.toDouble(),
                ),
            )
            // 常驻唤醒：一条说完继续听下一条
            if (asrRunning && asrWakeMode) restartSoon(250)
        }

        override fun onError(error: Int) {
            // 打断期间 recognizer 补的收尾错误不是真错误（我们已经主动停掉了）。
            if (interrupted) return
            consecutiveErrors++
            emit(
                mapOf(
                    "type" to "error",
                    "code" to errorCodeName(error),
                    "message" to errorMessage(error),
                ),
            )
            if (asrRunning && asrWakeMode) {
                // 常驻唤醒时「没听清」是常态，退避后续听，避免疯狂重启把电池打光
                val delay = if (consecutiveErrors > 8) 2000L else 400L
                restartSoon(delay)
            } else if (asrRunning && error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) {
                // 上一次 startListening 还没完全释放（唤醒→应答→聆听切得很快时会遇到），
                // 稍等再起一次，别让用户以为「点麦没反应」。
                restartSoon(400)
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun errorCodeName(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        SpeechRecognizer.ERROR_CLIENT -> "client"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "insufficient_permissions"
        SpeechRecognizer.ERROR_NETWORK -> "network"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network_timeout"
        SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "recognizer_busy"
        SpeechRecognizer.ERROR_SERVER -> "server"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech_timeout"
        else -> "unknown"
    }

    private fun errorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "录音出错"
        SpeechRecognizer.ERROR_CLIENT -> "识别客户端出错"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "没有麦克风权限"
        SpeechRecognizer.ERROR_NETWORK -> "识别服务网络不可用"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "识别服务超时"
        SpeechRecognizer.ERROR_NO_MATCH -> "没听清"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "识别服务忙（可能其它应用正在用麦克风）"
        SpeechRecognizer.ERROR_SERVER -> "识别服务返回错误"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "没有检测到说话"
        else -> "语音识别出错（$error）"
    }
}
