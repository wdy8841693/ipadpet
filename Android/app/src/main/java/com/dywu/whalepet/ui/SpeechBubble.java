package com.dywu.whalepet.ui;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;

/**
 * 台词气泡：圆角矩形 + 小尾巴 + 自动换行文本（最多 2 行）。
 * 全部用 Canvas 绘制，随屏幕旋转自适应。
 *
 * <p>坐标约定：调用方传入"场景坐标"（y 向上，原点在左下角），内部换算成设备坐标。</p>
 */
final class SpeechBubble {

    private static final float MAX_TEXT_WIDTH = 260f;
    private static final float FONT_SIZE = 17f;
    private static final float PAD_X = 14f;
    private static final float PAD_Y = 9f;

    private final TextPaint textPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final Paint bgPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path tailPath = new Path();
    private final RectF rect = new RectF();

    private StaticLayout layout;
    private float boxWidth;
    private float boxHeight;

    private float alpha = 0f;
    private long hideAt = 0;

    SpeechBubble(float density) {
        textPaint.setColor(Color.rgb(38, 64, 102));
        textPaint.setTextSize(FONT_SIZE);
        textPaint.setTypeface(android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL));
        textPaint.setTextAlign(Paint.Align.LEFT);

        bgPaint.setColor(Color.argb(240, 255, 255, 255));
        bgPaint.setStyle(Paint.Style.FILL);

        strokePaint.setColor(Color.rgb(89, 140, 191));
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeWidth(2f);
    }

    float width() {
        return boxWidth;
    }

    float height() {
        return boxHeight;
    }

    boolean isVisible() {
        return alpha > 0.01f;
    }

    void show(String text, float durationSeconds) {
        if (text == null) return;
        String t = text.trim();
        if (t.isEmpty()) return;

        // 先量一遍：短句就直接按实际宽度排版（居中对齐才不会被撑成大框），
        // 超过上限才按 260dp 折行。
        float measured = textPaint.measureText(t);
        int layoutWidth = measured <= MAX_TEXT_WIDTH
                ? (int) Math.ceil(measured) + 2
                : (int) Math.ceil(MAX_TEXT_WIDTH);
        layout = build(t, layoutWidth);

        if (layout.getLineCount() > 2) {
            // 最多两行：超出部分用省略号收尾（服务端回复可能很长）
            String clipped = t;
            while (clipped.length() > 1) {
                clipped = clipped.substring(0, clipped.length() - 2);
                StaticLayout probe = build(clipped + "…", layoutWidth);
                if (probe.getLineCount() <= 2) {
                    layout = probe;
                    break;
                }
            }
        }

        float maxLine = 0f;
        for (int i = 0; i < layout.getLineCount(); i++) {
            maxLine = Math.max(maxLine, layout.getLineWidth(i));
        }
        boxWidth = Math.max(maxLine + PAD_X * 2, 60f);
        boxHeight = Math.max(layout.getHeight() + PAD_Y * 2, 40f);
        hideAt = System.currentTimeMillis() + (long) (durationSeconds * 1000);
    }

    private StaticLayout build(String text, int width) {
        return new StaticLayout(text, textPaint, width,
                Layout.Alignment.ALIGN_CENTER, 1.0f, 0f, true);
    }

    void hide() {
        hideAt = 0;
    }

    void update(float dt) {
        boolean shouldShow = hideAt > 0 && System.currentTimeMillis() < hideAt;
        float target = shouldShow ? 1f : 0f;
        // 淡入 0.18s / 淡出 0.4s
        float speed = target > alpha ? 5.5f : 2.5f;
        alpha += (target - alpha) * Math.min(1f, speed * dt);
        if (alpha < 0.01f) alpha = 0f;
        if (hideAt > 0 && System.currentTimeMillis() >= hideAt) hideAt = 0;
    }

    /**
     * @param sceneH  场景高度（dp），用于把 y 向上换算成设备 y
     * @param centerX 气泡水平中心（场景坐标）
     * @param bottomY 气泡底边（场景坐标，即贴着宠物头顶）
     */
    void draw(Canvas c, float sceneH, float centerX, float bottomY) {
        if (alpha <= 0.01f || layout == null) return;
        int save = c.save();
        c.scale(1, 1);
        c.translate(0, 0);

        float left = centerX - boxWidth / 2f;
        float bottom = sceneH - bottomY;      // 设备坐标：y 向下
        float top = bottom - boxHeight;

        rect.set(left, top, left + boxWidth, bottom);

        int a = (int) (alpha * 255);
        bgPaint.setAlpha(a);
        strokePaint.setAlpha(a);

        c.drawRoundRect(rect, 12f, 12f, bgPaint);
        c.drawRoundRect(rect, 12f, 12f, strokePaint);

        // 小尾巴（向下 12dp）
        tailPath.reset();
        tailPath.moveTo(centerX - 8f, bottom - 1f);
        tailPath.lineTo(centerX, bottom + 12f);
        tailPath.lineTo(centerX + 8f, bottom - 1f);
        tailPath.close();
        c.drawPath(tailPath, bgPaint);

        int layoutSave = c.save();
        c.translate(left + PAD_X, top + PAD_Y);
        layout.draw(c);
        c.restoreToCount(layoutSave);

        c.restoreToCount(save);
    }
}
