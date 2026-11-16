package com.dywu.whalepet.ui;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.text.TextPaint;
import android.text.TextUtils;

import com.dywu.whalepet.pet.PetState;
import com.dywu.whalepet.pet.PetVitals;

/**
 * 顶部状态条 + 右上语音胶囊 + 底部操作按钮。
 * 只负责布局/绘制/命中测试，动作通过 {@link Listener} 抛给 PetView。
 *
 * <p>绘制坐标：设备坐标（dp，y 向下）；命中测试用场景坐标（y 向上），内部换算。</p>
 */
final class Hud {

    enum Action { FEED, PLAY, SLEEP, MIC, SETTINGS, RENAME }

    interface Listener {
        void onHudAction(Action action);
    }

    private static final float BAR_W = 96f;
    private static final float BAR_H = 10f;
    private static final float BAR_X = 46f;
    private static final float BUTTONS_Y = 64f;     // 距底边
    private static final float PANEL_H = 96f;
    private static final float MAX_SPACING = 86f;
    private static final float MAX_RADIUS = 27f;

    private static final String[] TITLES = {"投喂", "玩耍", "睡觉", "说话", "设置", "改名"};
    private static final String[] ICONS = {"🐟", "🎈", "🌙", "🎙️", "⚙️", "✏️"};
    private static final Action[] ACTIONS = {
            Action.FEED, Action.PLAY, Action.SLEEP, Action.MIC, Action.SETTINGS, Action.RENAME
    };
    private static final int[] BAR_COLORS = {
            Color.argb(242, 255, 158, 89),   // 饱食：橙
            Color.argb(242, 115, 191, 255),  // 心情：蓝
            Color.argb(242, 255, 217, 102),  // 精力：黄
    };

    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint panelPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint textPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint emojiPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint pillPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();

    private Listener listener;

    private float sceneW = 768f;
    private float sceneH = 1024f;
    private float spacing = MAX_SPACING;
    private float radius = MAX_RADIUS;
    private float startX;

    private final int[] lastBars = {-1, -1, -1};

    private String voiceText;
    private boolean voiceActive;

    Hud() {
        fillPaint.setStyle(Paint.Style.FILL);
        panelPaint.setStyle(Paint.Style.FILL);
        panelPaint.setColor(Color.argb(56, 0, 0, 0));
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeWidth(2f);

        textPaint.setColor(Color.argb(230, 255, 255, 255));
        textPaint.setTextSize(12f);
        textPaint.setTextAlign(Paint.Align.CENTER);
        textPaint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));

        emojiPaint.setTextSize(24f);
        emojiPaint.setTextAlign(Paint.Align.CENTER);

        pillPaint.setColor(Color.argb(242, 255, 255, 255));
        pillPaint.setTextSize(13f);
        pillPaint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
    }

    void setListener(Listener l) {
        listener = l;
    }

    void layout(float width, float height) {
        boolean changed = Math.abs(width - sceneW) > 1f || Math.abs(height - sceneH) > 1f;
        sceneW = width;
        sceneH = height;
        spacing = Math.min(MAX_SPACING, (width - 32f) / (ICONS.length - 1));
        radius = Math.min(MAX_RADIUS, spacing * 0.32f);
        startX = width / 2f - spacing * (ICONS.length - 1) / 2f;
        if (changed) {
            lastBars[0] = lastBars[1] = lastBars[2] = -1;
        }
    }

    void updateVoice(String text, boolean active) {
        voiceText = text;
        voiceActive = active;
    }

    void draw(Canvas c, PetVitals vitals, PetState state) {
        // ---- 左上三根状态条 ----
        float barH = BAR_H;
        double[] values = {vitals.satiety, vitals.mood, vitals.energy};
        for (int i = 0; i < 3; i++) {
            float top = 44f + i * 26f - barH / 2f;
            int quantized = (int) Math.round(values[i]);
            if (quantized != lastBars[i]) {
                lastBars[i] = quantized;
            }
            // 底槽
            fillPaint.setColor(Color.argb(46, 255, 255, 255));
            rect.set(BAR_X, top, BAR_X + BAR_W, top + barH);
            c.drawRoundRect(rect, 5, 5, fillPaint);
            // 填充
            float w = Math.max(4f, (float) (BAR_W * values[i] / 100.0));
            fillPaint.setColor(BAR_COLORS[i]);
            rect.set(BAR_X, top, BAR_X + w, top + barH);
            c.drawRoundRect(rect, 5, 5, fillPaint);
            // 图标
            Paint.FontMetrics fm = emojiPaint.getFontMetrics();
            float baseline = top + barH / 2f - (fm.ascent + fm.descent) / 2f;
            c.drawText(ICONS[i], BAR_X - 18f, baseline, emojiPaint);
        }

        // ---- 右上语音胶囊 ----
        if (voiceActive && voiceText != null && !voiceText.isEmpty()) {
            pillPaint.setTextSize(13f);
            String text = TextUtils.ellipsize(voiceText, pillPaint, sceneW * 0.55f, TextUtils.TruncateAt.END).toString();
            float textW = pillPaint.measureText(text);
            float w = Math.max(textW + 28f, 80f);
            float h = 26f;
            float right = sceneW - 20f;
            float left = right - w;
            float top = 39f;
            rect.set(left, top, right, top + h);
            fillPaint.setColor(Color.argb(90, 0, 0, 0));
            c.drawRoundRect(rect, 13, 13, fillPaint);
            strokePaint.setColor(Color.argb(128, 255, 255, 255));
            c.drawRoundRect(rect, 13, 13, strokePaint);

            Paint.FontMetrics fm = pillPaint.getFontMetrics();
            float baseline = top + h / 2f - (fm.ascent + fm.descent) / 2f;
            c.drawText(text, left + 14f, baseline, pillPaint);
        }

        // ---- 底部按钮面板 ----
        float panelLeft = startX - 44f;
        float panelRight = startX + spacing * (ICONS.length - 1) + 44f;
        float panelBottom = sceneH - BUTTONS_Y + PANEL_H / 2f;
        rect.set(panelLeft, panelBottom - PANEL_H, panelRight, panelBottom);
        c.drawRoundRect(rect, 20, 20, panelPaint);

        for (int i = 0; i < ICONS.length; i++) {
            float cx = startX + i * spacing;
            float cy = sceneH - BUTTONS_Y;

            fillPaint.setColor(Color.argb(235, 255, 255, 255));
            c.drawCircle(cx, cy, radius, fillPaint);
            strokePaint.setColor(Color.rgb(89, 140, 191));
            c.drawCircle(cx, cy, radius, strokePaint);

            String icon = ICONS[i];
            if (ACTIONS[i] == Action.SLEEP) icon = state == PetState.SLEEP ? "☀️" : "🌙";
            Paint.FontMetrics fm = emojiPaint.getFontMetrics();
            float baseline = cy + 4f - (fm.ascent + fm.descent) / 2f;
            c.drawText(icon, cx, baseline, emojiPaint);

            c.drawText(TITLES[i], cx, cy + radius + 14f, textPaint);
        }
    }

    /**
     * @param x 场景坐标（dp，原点左下）
     * @param y 场景坐标
     * @return 命中的动作；未命中返回 null
     */
    Action handleTouch(float x, float y) {
        float cy = BUTTONS_Y;
        for (int i = 0; i < ACTIONS.length; i++) {
            float cx = startX + i * spacing;
            float dx = x - cx;
            float dy = y - cy;
            if (Math.hypot(dx, dy) < Math.max(34f, radius + 7f)) {
                if (listener != null) listener.onHudAction(ACTIONS[i]);
                return ACTIONS[i];
            }
        }
        return null;
    }
}
