package com.dywu.whalepet;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.dywu.whalepet.net.DSHClient;
import com.dywu.whalepet.net.ServerSettings;
import com.dywu.whalepet.pet.PetStore;
import com.dywu.whalepet.ui.PetView;
import com.dywu.whalepet.voice.VoiceController;

/**
 * 全屏容器：SurfaceView 场景 + 语音控制器 + 两个弹窗（改名 / 服务器设置）。
 * 对应 iOS 版的 PetViewController。
 */
public final class MainActivity extends Activity
        implements PetView.Host, VoiceController.Callbacks {

    private static final int REQ_MIC = 1001;

    private PetView petView;
    private ServerSettings settings;
    private VoiceController voice;
    private PetStore store;
    /** 权限只主动申请一次，用户拒绝后不再每次回前台都弹窗打扰。 */
    private boolean micRequested = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        settings = new ServerSettings(this);
        store = PetStore.get(getFilesDir());
        petView = new PetView(this, this, store);
        setContentView(petView);
        hideSystemUi();

        voice = new VoiceController(this, settings);
        voice.setCallbacks(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        hideSystemUi();
        if (petView != null) petView.appDidBecomeActive();
        // 已配置过则自动恢复语音；首次使用等用户在设置里填好再开。
        if (settings.isVoiceEnabled() && settings.isConfigured()
                && voice.getKind() == VoiceController.Kind.DISABLED) {
            ensureMicThenStart();
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (voice != null) voice.stop();
        if (petView != null) {
            petView.setVoiceState(null, null);
            petView.appWillResign();
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (voice != null) voice.release();
        if (petView != null) petView.release();
    }

    private void hideSystemUi() {
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
    }

    // ---------------------------------------------------------------- 权限

    private void ensureMicThenStart() {
        if (voice.hasPermission()) {
            voice.start();
            return;
        }
        if (Build.VERSION.SDK_INT >= 23 && !micRequested) {
            micRequested = true;
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_MIC);
        } else if (Build.VERSION.SDK_INT >= 23) {
            Toast.makeText(this, "麦克风权限被拒绝，请到系统设置里开启", Toast.LENGTH_LONG).show();
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQ_MIC) return;
        boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        if (granted) {
            voice.start();
        } else {
            Toast.makeText(this, "需要麦克风权限才能语音唤醒", Toast.LENGTH_LONG).show();
        }
    }

    // ---------------------------------------------------------------- PetView.Host

    /** 全屏主题下直接用 Builder(this) 弹窗样式会怪，显式指定一个浮动对话框主题。 */
    private AlertDialog.Builder dialogBuilder() {
        return new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert);
    }

    @Override
    public void onRenameRequest() {
        final EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setText(store.data().petName);
        input.setHint("小鲸");
        input.setSelection(input.getText().length());

        dialogBuilder()
                .setTitle("给鲸鱼娘改名")
                .setMessage("最多 12 个字符")
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton("确定", (d, w) -> petView.renamePet(input.getText().toString()))
                .show();
    }

    @Override
    public void onMicRequest() {
        switch (voice.getKind()) {
            case DISABLED:
            case ERROR:
                // 关闭态、以及"重连放弃/出错"后都允许点麦克风重新连接。
                if (!settings.isConfigured()) {
                    presentServerSettings();
                    return;
                }
                settings.setVoiceEnabled(true);
                ensureMicThenStart();
                break;
            default:
                voice.startManualCommand();
                break;
        }
    }

    @Override
    public void onSettingsRequest() {
        presentServerSettings();
    }

    // ---------------------------------------------------------------- 服务器设置

    private void presentServerSettings() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (getResources().getDisplayMetrics().density * 20);
        box.setPadding(pad, pad / 2, pad, 0);

        final EditText urlInput = new EditText(this);
        urlInput.setHint("http://192.168.1.10:8787");
        urlInput.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        String existing = settings.serverURL();
        if (existing != null) urlInput.setText(existing);
        box.addView(urlInput);

        final EditText tokenInput = new EditText(this);
        tokenInput.setHint("访问令牌（~/.dsh/whalepet/ipad-token）");
        tokenInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        tokenInput.setText(settings.token());
        box.addView(tokenInput);

        TextView hint = new TextView(this);
        hint.setText("令牌在运行 DSH 的机器上：cat ~/.dsh/whalepet/ipad-token");
        hint.setTextSize(12f);
        box.addView(hint);

        dialogBuilder()
                .setTitle("语音服务器")
                .setMessage("填写内网桥接服务器地址与访问令牌")
                .setView(box)
                .setNegativeButton("取消", null)
                .setPositiveButton("保存并测试", (d, w) ->
                        saveServerSettings(urlInput.getText().toString(), tokenInput.getText().toString()))
                .show();
    }

    private void saveServerSettings(String urlText, String tokenText) {
        String normalized;
        try {
            normalized = ServerSettings.normalizeServerURL(urlText);
        } catch (IllegalArgumentException e) {
            showSettingsResult(null, e.getMessage());
            return;
        }
        settings.setServerURL(normalized);
        settings.setToken(tokenText);
        testConnection();
    }

    private void testConnection() {
        final String base = settings.serverURL();
        if (base == null) return;
        DSHClient client = new DSHClient(new DSHClient.Config(
                base, settings.token(), settings.sessionID(), settings.wakePhrase()));
        client.healthCheck((ok, code, message) -> {
            if (ok) {
                showSettingsResult("连接成功！可以说\"小鲸小鲸\"唤醒啦", null);
                settings.setVoiceEnabled(true);
                ensureMicThenStart();
            } else {
                showSettingsResult(null, message);
            }
        });
    }

    private void showSettingsResult(String success, String failure) {
        String message = success != null ? success : (failure != null ? failure : "");
        dialogBuilder()
                .setTitle(success != null ? "服务器" : "连接失败")
                .setMessage(message)
                .setPositiveButton("好", null)
                .show();
    }

    // ---------------------------------------------------------------- VoiceController.Callbacks

    @Override
    public void onStateChanged(VoiceController c) {
        if (petView == null) return;
        String text = c.getKind() == VoiceController.Kind.DISABLED ? null : c.displayText();
        petView.setVoiceState(c.petState(), text);
    }

    @Override
    public void onTranscript(String text) {
        if (petView != null) petView.showVoiceTranscript(text);
    }

    @Override
    public void onResponse(String text) {
        if (petView != null) petView.showVoiceResponse(text);
    }

    @Override
    public void onTaskNotice(String text) {
        if (petView != null) petView.showVoiceNotice(text);
    }

    @Override
    public void onReconnectNotice(String text) {
        if (petView != null) petView.showVoiceNotice(text);
    }

    @Override
    public void onError(String message) {
        if (petView != null) petView.showVoiceError(message);
    }
}
