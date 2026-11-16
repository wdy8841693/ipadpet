package com.dywu.whalepet.ui;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.util.Log;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import com.dywu.whalepet.pet.Dialogue;
import com.dywu.whalepet.pet.PetBrain;
import com.dywu.whalepet.pet.PetState;
import com.dywu.whalepet.pet.PetStore;
import com.dywu.whalepet.pet.PetVitals;

import java.util.ArrayList;
import java.util.EnumMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Random;

/**
 * 主场景：海底背景 + 鲸鱼娘 + 气泡点缀 + 触摸交互 + 台词气泡 + HUD。
 *
 * <p>渲染策略对应 iOS 的 SpriteKit 版本：</p>
 * <ul>
 *   <li>SurfaceView + 独立渲染线程，目标 30fps（老机器省电、不发热）；</li>
 *   <li>立绘整图切换，运动全部是程序化变换（漂浮/摇摆/挤压/翻转），不用序列帧；</li>
 *   <li>所有坐标以 dp 为单位（等价于 iOS 的 point），绘制前 canvas 统一按 density 缩放。</li>
 * </ul>
 */
public final class PetView extends SurfaceView implements SurfaceHolder.Callback, Runnable {

    private static final String TAG = "WhalePetView";

    public interface Host {
        void onRenameRequest();

        void onMicRequest();

        void onSettingsRequest();
    }

    /** 立绘逻辑尺寸（dp）：素材统一为 420×420，锚点在底边中心（= 脚底）。 */
    private static final float NOMINAL = 420f;
    private static final float FLOOR_RATIO = 0.16f;
    private static final float FRAME_SECONDS = 1f / 30f;

    private final Object lock = new Object();
    private final float density;
    private final Host host;
    private final PetStore store;
    private final PetBrain brain;
    private final Dialogue dialogue = new Dialogue();
    private final Random rng = new Random();

    private final Map<PetState, Bitmap> petBitmaps = new EnumMap<>(PetState.class);
    private Bitmap bgBitmap;
    private Bitmap heartBitmap;
    private Bitmap fishBitmap;
    private String textureName = "pet_idle";

    private final Hud hud = new Hud();
    private final SpeechBubble bubble;

    // 画布（dp）
    private float sceneW = 0f;
    private float sceneH = 0f;

    // 宠物位置：脚底（场景坐标，y 向上）
    private float petX = 0f;
    private float petY = 0f;
    private float baseScale = 0.62f;
    private boolean facingRight = false;
    private boolean placed = false;

    private float stateElapsed = 0f;
    private float squishTime = 0f;

    private boolean hasTarget = false;
    private float targetX = 0f;
    private float targetY = 0f;

    private boolean dragging = false;
    private float dragOffsetX = 0f;
    private float dragOffsetY = 0f;
    private long touchDownTime = 0L;
    private float downX = 0f;
    private float downY = 0f;

    private float bubbleTimer = 6f;
    private float saveAccum = 0f;

    private static final int BUBBLE_COUNT = 12;
    private final float[] bubbleX = new float[BUBBLE_COUNT];
    private final float[] bubbleY = new float[BUBBLE_COUNT];
    private final float[] bubbleSpeed = new float[BUBBLE_COUNT];
    private final float[] bubbleR = new float[BUBBLE_COUNT];

    private final List<Fx> fxList = new ArrayList<>();

    // 绘制资源
    private final Paint bmpPaint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.DITHER_FLAG);
    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF tmpRect = new RectF();
    private final Rect srcRect = new Rect();

    private Thread renderThread;
    private volatile boolean running = false;
    private boolean surfaceReady = false;

    private String voiceText;
    private boolean voiceActive;

    public PetView(Context ctx, Host host, PetStore store) {
        super(ctx);
        this.host = host;
        this.store = store;
        this.density = getResources().getDisplayMetrics().density;
        this.bubble = new SpeechBubble(density);

        PetStore.SaveData data = store.data();
        PetVitals vitals = new PetVitals();
        vitals.satiety = data.vitals.satiety;
        vitals.mood = data.vitals.mood;
        vitals.energy = data.vitals.energy;
        brain = new PetBrain(vitals);
        brain.lastTick = data.lastTick;
        brain.settleOffline(System.currentTimeMillis());
        textureName = textureFor(brain.getState());

        hud.setListener(action -> handleHudAction(action));
        getHolder().addCallback(this);
        setFocusable(true);
        setKeepScreenOn(true);
        loadSprites();
    }

    // ---------------------------------------------------------------- 资源

    private void loadSprites() {
        String[] names = {
                "pet_idle", "pet_walk", "pet_swim", "pet_happy", "pet_eat",
                "pet_sleep", "pet_drag", "pet_play", "pet_greet", "pet_sad"
        };
        Map<String, Bitmap> byName = new java.util.HashMap<>();
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inScaled = false;
        opts.inPreferredConfig = Bitmap.Config.ARGB_8888;
        for (String name : names) {
            try {
                Bitmap b = BitmapFactory.decodeStream(getContext().getAssets().open("sprites/" + name + ".png"), null, opts);
                if (b != null) byName.put(name, b);
            } catch (Exception e) {
                Log.w(TAG, "立绘加载失败: " + name + " (" + e.getMessage() + ")");
            }
        }
        for (PetState s : PetState.values()) {
            Bitmap b = byName.get(textureFor(s));
            if (b == null) b = byName.get("pet_idle");
            if (b != null) petBitmaps.put(s, b);
        }
        bgBitmap = loadBitmap("bg_gradient");
        heartBitmap = loadBitmap("fx_heart");
        fishBitmap = loadBitmap("fx_fish");
    }

    private Bitmap loadBitmap(String name) {
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inScaled = false;
        try {
            return BitmapFactory.decodeStream(getContext().getAssets().open("sprites/" + name + ".png"), null, opts);
        } catch (Exception e) {
            Log.w(TAG, "素材加载失败: " + name);
            return null;
        }
    }

    private static String textureFor(PetState s) {
        switch (s) {
            case IDLE:      return "pet_idle";
            case WALK:      return "pet_walk";
            case SWIM:      return "pet_swim";
            case HAPPY:     return "pet_happy";
            case EAT:       return "pet_eat";
            case SLEEP:     return "pet_sleep";
            case DRAG:      return "pet_drag";
            case PLAY:      return "pet_play";
            case LISTENING: return "pet_happy";
            case THINKING:  return "pet_swim";
            case SPEAKING:  return "pet_greet";
            default:        return "pet_idle";
        }
    }

    /** 换立绘：低落时用委屈脸覆盖 idle/walk；心情极好时偶尔挥手代替脸红。 */
    private String pickTexture(PetState state) {
        String name = textureFor(state);
        PetVitals.Wellbeing w = brain.vitals.wellbeing();
        if ((state == PetState.IDLE || state == PetState.WALK)
                && (w == PetVitals.Wellbeing.SAD || w == PetVitals.Wellbeing.HUNGRY)) {
            name = "pet_sad";
        }
        if (state == PetState.HAPPY && w == PetVitals.Wellbeing.GREAT && rng.nextBoolean()) {
            name = "pet_greet";
        }
        return name;
    }

    // ---------------------------------------------------------------- 生命周期

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        surfaceReady = true;
        startRenderThread();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        synchronized (lock) {
            sceneW = width / density;
            sceneH = height / density;
            baseScale = Math.max(0.45f, Math.min(0.85f, sceneW / 768f * 0.62f));
            hud.layout(sceneW, sceneH);
            if (!placed) {
                petX = sceneW / 2f;
                petY = standY();
                placed = true;
            } else {
                clampPet();
            }
            // 旋转后尺寸变化，旧移动目标可能已出屏，直接放弃。
            hasTarget = false;
            initBubbles();
        }
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        stopRenderThread();
    }

    private void startRenderThread() {
        if (running) return;
        running = true;
        renderThread = new Thread(this, "whalepet-render");
        renderThread.start();
    }

    private void stopRenderThread() {
        running = false;
        Thread t = renderThread;
        renderThread = null;
        if (t != null) {
            try {
                t.join(500);
            } catch (InterruptedException ignored) {
            }
        }
    }

    public void release() {
        // 不主动 recycle：万一面还没销毁（部分机型 onDestroy 先于 surfaceDestroyed），
        // 渲染线程再画一帧就会踩到 "use a recycled bitmap"。交给 GC 更安全。
        stopRenderThread();
    }

    @Override
    public void run() {
        long last = 0L;
        while (running && surfaceReady) {
            long start = System.nanoTime();
            Canvas canvas = null;
            try {
                canvas = getHolder().lockCanvas();
            } catch (Exception ignored) {
            }
            if (canvas != null) {
                float dt = last == 0 ? 0f : (start - last) / 1_000_000_000f;
                last = start;
                synchronized (lock) {
                    if (sceneW > 0 && dt > 0) {
                        update(Math.min(dt, 0.1f));
                        renderFrame(canvas);
                    }
                }
                try {
                    getHolder().unlockCanvasAndPost(canvas);
                } catch (Exception ignored) {
                }
            }
            long spentMs = (System.nanoTime() - start) / 1_000_000L;
            long sleepMs = (long) (FRAME_SECONDS * 1000) - spentMs;
            if (sleepMs > 0) {
                try {
                    Thread.sleep(sleepMs);
                } catch (InterruptedException e) {
                    break;
                }
            }
        }
    }

    // ---------------------------------------------------------------- 帧更新

    private void update(float dt) {
        long now = System.currentTimeMillis();
        if (brain.tick(dt, now, rng)) {
            applyStateVisual();
            onStateChanged();
        }
        stateElapsed += dt;
        if (squishTime > 0) squishTime = Math.max(0f, squishTime - dt);

        updateMovement(dt);
        updateBubbles(dt);
        updateFx(dt);

        // 气泡台词：每 12~20 秒冒一句
        bubbleTimer -= dt;
        if (bubbleTimer <= 0) {
            bubbleTimer = 12f + rng.nextFloat() * 8f;
            showSpeech(dialogue.line(brain.getState(), brain.vitals.wellbeing(), store.data().petName), 4f);
        }

        // 每 15 秒自动存档
        saveAccum += dt;
        if (saveAccum > 15f) {
            saveAccum = 0f;
            store.save(brain);
        }

        bubble.update(dt);
    }

    /** 状态切换后的渲染副作用（换立绘 + 重置动作相位）。 */
    private void applyStateVisual() {
        stateElapsed = 0f;
        String name = pickTexture(brain.getState());
        if (!name.equals(textureName)) textureName = name;
    }

    private void onStateChanged() {
        PetState s = brain.getState();
        switch (s) {
            case WALK:
                hasTarget = true;
                targetX = 90f + rng.nextFloat() * Math.max(1f, sceneW - 180f);
                targetY = standY();
                break;
            case SWIM:
                hasTarget = true;
                targetX = 80f + rng.nextFloat() * Math.max(1f, sceneW - 160f);
                targetY = sceneH * 0.35f + rng.nextFloat() * (sceneH * 0.40f);
                break;
            case IDLE:
            case SLEEP:
            case EAT:
            case HAPPY:
            case PLAY:
                hasTarget = true;
                targetX = petX;
                targetY = standY();
                break;
            case DRAG:
            case LISTENING:
            case THINKING:
            case SPEAKING:
                hasTarget = false;
                break;
            default:
                hasTarget = false;
                break;
        }
        if (s != PetState.IDLE) {
            showSpeech(dialogue.line(s, brain.vitals.wellbeing(), store.data().petName), 4f);
        }
    }

    private void updateMovement(float dt) {
        if (dragging || !hasTarget) return;
        float speed = brain.getState() == PetState.SWIM ? 90f : 55f;
        float dx = targetX - petX;
        float dy = targetY - petY;
        float dist = (float) Math.hypot(dx, dy);
        if (dist < 4f) {
            hasTarget = false;
            return;
        }
        float step = Math.min(speed * dt, dist);
        petX += dx / dist * step;
        petY += dy / dist * step;
        if (Math.abs(dx) > 8f) {
            boolean right = dx > 0;
            facingRight = right;
        }
    }

    private void updateBubbles(float dt) {
        for (int i = 0; i < BUBBLE_COUNT; i++) {
            bubbleY[i] += bubbleSpeed[i] * dt;
            if (bubbleY[i] > sceneH + 12f) {
                bubbleX[i] = rng.nextFloat() * Math.max(sceneW, 1f);
                bubbleY[i] = -12f;
                bubbleSpeed[i] = 18f + rng.nextFloat() * 24f;
                bubbleR[i] = 3f + rng.nextFloat() * 6f;
            }
        }
    }

    private void updateFx(float dt) {
        Iterator<Fx> it = fxList.iterator();
        while (it.hasNext()) {
            Fx f = it.next();
            f.t += dt;
            if (f.t >= f.dur) it.remove();
        }
    }

    private void initBubbles() {
        for (int i = 0; i < BUBBLE_COUNT; i++) {
            bubbleR[i] = 3f + rng.nextFloat() * 6f;
            bubbleX[i] = rng.nextFloat() * Math.max(sceneW, 1f);
            bubbleY[i] = rng.nextFloat() * Math.max(sceneH, 1f);
            bubbleSpeed[i] = 18f + rng.nextFloat() * 24f;
        }
    }

    // ---------------------------------------------------------------- 绘制

    private void renderFrame(Canvas c) {
        c.save();
        c.scale(density, density);

        // 背景渐变（静态贴图，比实时渐变省电）
        if (bgBitmap != null) {
            srcRect.set(0, 0, bgBitmap.getWidth(), bgBitmap.getHeight());
            tmpRect.set(0, 0, sceneW, sceneH);
            c.drawBitmap(bgBitmap, srcRect, tmpRect, bmpPaint);
        } else {
            c.drawColor(Color.rgb(13, 41, 77));
        }

        // 海底沙地
        float floorH = sceneH * FLOOR_RATIO;
        fillPaint.setColor(Color.rgb(237, 217, 168));
        c.drawRect(0, sceneH - floorH, sceneW, sceneH, fillPaint);

        // 上浮的气泡
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeWidth(1f);
        for (int i = 0; i < BUBBLE_COUNT; i++) {
            float cy = sceneH - bubbleY[i];
            fillPaint.setColor(Color.argb(20, 255, 255, 255));
            c.drawCircle(bubbleX[i], cy, bubbleR[i], fillPaint);
            strokePaint.setColor(Color.argb(89, 255, 255, 255));
            c.drawCircle(bubbleX[i], cy, bubbleR[i], strokePaint);
        }

        drawPet(c);
        drawFx(c);

        // 台词气泡（贴在头顶，超出屏幕时改放脚边）
        float bw = bubble.width();
        float bh = bubble.height();
        float bx = Math.min(Math.max(petX, bw / 2f + 12f), Math.max(sceneW - bw / 2f - 12f, bw / 2f + 12f));
        float by = petY + NOMINAL * baseScale + 8f;
        float topLimit = sceneH - bh - 12f;
        if (by > topLimit) {
            by = Math.max(petY - bh - 16f, 12f);
        }
        bubble.draw(c, sceneH, bx, by);

        hud.draw(c, brain.vitals, brain.getState());
        c.restore();
    }

    private void drawPet(Canvas c) {
        double t = stateElapsed;
        float bobY = 0f;
        float rot = 0f;
        float sx = 1f;
        float sy = 1f;

        switch (brain.getState()) {
            case IDLE:
                bobY = 5f * (float) ((1 - Math.cos(2 * Math.PI * t / 2.6)) / 2);
                sy = breath(t, 1.5f);
                break;
            case WALK:
                bobY = 4f * (float) ((1 - Math.cos(2 * Math.PI * t / 0.55)) / 2);
                rot = 0.05f * (float) Math.sin(2 * Math.PI * t / 0.55);
                break;
            case SWIM:
                bobY = 12f * (float) ((1 - Math.cos(2 * Math.PI * t / 1.8)) / 2);
                rot = 0.10f * (float) Math.sin(2 * Math.PI * t / 1.8);
                break;
            case HAPPY: {
                float phase = (float) ((t % 0.5) / 0.5);
                bobY = 16f * (float) Math.sin(Math.PI * phase);
                float s = (float) Math.sin(2 * Math.PI * t / 0.5);
                sx = 1f + 0.03f * s;
                sy = 1f - 0.03f * s;
                break;
            }
            case EAT:
                rot = 0.04f * (float) Math.abs(Math.sin(2 * Math.PI * t / 0.44));
                break;
            case SLEEP:
                bobY = 2.5f * (float) ((1 - Math.cos(2 * Math.PI * t / 3.4)) / 2);
                sy = breath(t, 2.2f);
                break;
            case DRAG:
                rot = 0.12f * (float) Math.sin(2 * Math.PI * t / 0.6);
                break;
            case PLAY: {
                float phase = (float) ((t % 0.55) / 0.55);
                bobY = 20f * (float) Math.sin(Math.PI * phase);
                rot = 0.12f * (float) Math.sin(2 * Math.PI * t / 0.55);
                break;
            }
            case LISTENING:
                bobY = 8f * (float) ((1 - Math.cos(2 * Math.PI * t / 1.2)) / 2);
                sy = breath(t, 1.5f);
                break;
            case THINKING:
                bobY = 4f * (float) ((1 - Math.cos(2 * Math.PI * t / 2.0)) / 2);
                rot = 0.06f * (float) Math.sin(2 * Math.PI * t / 2.0);
                break;
            case SPEAKING:
                bobY = 6f * (float) ((1 - Math.cos(2 * Math.PI * t / 0.8)) / 2);
                sy = breath(t, 1.5f);
                break;
            default:
                break;
        }

        // 摸头一次性 Q 弹反馈（0.28s）
        if (squishTime > 0f) {
            float elapsed = 0.28f - squishTime;
            float qx;
            float qy;
            if (elapsed < 0.08f) {
                float k = elapsed / 0.08f;
                qx = lerp(1f, 1.08f, k);
                qy = lerp(1f, 0.90f, k);
            } else if (elapsed < 0.18f) {
                float k = (elapsed - 0.08f) / 0.10f;
                qx = lerp(1.08f, 0.96f, k);
                qy = lerp(0.90f, 1.05f, k);
            } else {
                float k = Math.min(1f, (elapsed - 0.18f) / 0.10f);
                qx = lerp(0.96f, 1f, k);
                qy = lerp(1.05f, 1f, k);
            }
            sx *= qx;
            sy *= qy;
        }

        Bitmap bmp = petBitmaps.get(brain.getState());
        if (bmp == null) bmp = petBitmaps.get(PetState.IDLE);
        if (bmp == null) return;

        float totalSx = baseScale * sx * (facingRight ? -1f : 1f);
        float totalSy = baseScale * sy;
        drawSprite(c, bmp, petX, petY + bobY, NOMINAL, NOMINAL, rot, totalSx, totalSy, 255);
    }

    private static float breath(double t, float halfPeriod) {
        return 1f + 0.006f * (float) (1 - Math.cos(Math.PI * t / halfPeriod));
    }

    private static float lerp(float a, float b, float k) {
        return a + (b - a) * k;
    }

    /**
     * 绘制一张"锚点在底边中心"的贴图。
     *
     * @param rot 弧度，正值 = 逆时针（与 iOS 的 zRotation 同向）
     */
    private void drawSprite(Canvas c, Bitmap bmp, float x, float yFoot, float w, float h,
                            float rot, float sx, float sy, int alpha) {
        int save = c.save();
        c.translate(x, sceneH - yFoot);
        if (rot != 0f) c.rotate((float) Math.toDegrees(-rot));
        c.scale(sx, sy);
        bmpPaint.setAlpha(alpha);
        tmpRect.set(-w / 2f, -h, w / 2f, 0f);
        c.drawBitmap(bmp, null, tmpRect, bmpPaint);
        bmpPaint.setAlpha(255);
        c.restoreToCount(save);
    }

    private void drawFx(Canvas c) {
        for (Fx f : fxList) {
            float k = f.t / f.dur;
            switch (f.kind) {
                case Fx.HEART: {
                    float x = f.x0 + f.dx * k;
                    float y = f.y0 + 90f * k;
                    int a = (int) (255 * (1f - k));
                    if (heartBitmap != null) {
                        drawSprite(c, heartBitmap, x, y, heartBitmap.getWidth(), heartBitmap.getHeight(),
                                0f, 0.7f, 0.7f, a);
                    }
                    break;
                }
                case Fx.FISH: {
                    if (fishBitmap == null) break;
                    if (k < 0.62f) {
                        float p = k / 0.62f;
                        float x = lerp(f.x0, f.x1, p);
                        float y = lerp(f.y0, f.y1, p);
                        drawSprite(c, fishBitmap, x, y, fishBitmap.getWidth(), fishBitmap.getHeight(),
                                0f, 1f, 1f, 255);
                    } else {
                        float p = (k - 0.62f) / 0.38f;
                        float s = lerp(1f, 0.1f, p);
                        drawSprite(c, fishBitmap, f.x1, f.y1, fishBitmap.getWidth(), fishBitmap.getHeight(),
                                0f, s, s, (int) (255 * (1f - p)));
                    }
                    break;
                }
                case Fx.BALL: {
                    float[] dxs = {60f, -50f, 40f};
                    float[] dys = {-80f, 90f, -70f};
                    int seg = Math.min((int) (f.t / 0.5f), 8);
                    float frac = (f.t % 0.5f) / 0.5f;
                    float x = f.x0;
                    float y = f.y0;
                    for (int i = 0; i < seg; i++) {
                        x += dxs[i % 3];
                        y += dys[i % 3];
                    }
                    x += dxs[seg % 3] * frac;
                    y += dys[seg % 3] * frac;
                    int alpha = k > 0.9f ? (int) (255 * (1f - (k - 0.9f) / 0.1f)) : 255;
                    float cy = sceneH - y;
                    fillPaint.setColor(Color.argb((int) (alpha * 0.25f), 153, 217, 255));
                    c.drawCircle(x, cy, 22f, fillPaint);
                    strokePaint.setStyle(Paint.Style.STROKE);
                    strokePaint.setStrokeWidth(2f);
                    strokePaint.setColor(Color.argb((int) (alpha * 0.7f), 255, 255, 255));
                    c.drawCircle(x, cy, 22f, strokePaint);
                    break;
                }
                default:
                    break;
            }
        }
    }

    // ---------------------------------------------------------------- 布局辅助

    private float floorY() {
        return sceneH * FLOOR_RATIO;
    }

    private float standY() {
        return floorY() + 4f;
    }

    private void clampPet() {
        float m = 80f;
        petX = Math.min(Math.max(petX, m), Math.max(sceneW - m, m));
        float h = NOMINAL * baseScale;
        float minY = standY() - 20f;
        float maxY = Math.max(sceneH - h - 20f, minY);
        petY = Math.min(Math.max(petY, minY), maxY);
    }

    private void showSpeech(String text, float duration) {
        if (text == null || text.trim().isEmpty()) return;
        bubble.show(text, duration);
    }

    // ---------------------------------------------------------------- 触摸

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        if (sceneW <= 0) return true;
        float sx = e.getX() / density;
        float sy = sceneH - e.getY() / density;

        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: {
                synchronized (lock) {
                    if (hud.handleTouch(sx, sy) != null) return true;
                    if (petHitTest(sx, sy)) {
                        dragging = true;
                        touchDownTime = System.currentTimeMillis();
                        downX = sx;
                        downY = sy;
                        dragOffsetX = petX - sx;
                        dragOffsetY = petY - sy;
                        brain.beginDrag();
                        applyStateVisual();
                        bubble.hide();
                    }
                }
                return true;
            }
            case MotionEvent.ACTION_MOVE: {
                synchronized (lock) {
                    if (dragging) {
                        petX = sx + dragOffsetX;
                        petY = sy + dragOffsetY;
                        clampPet();
                    }
                }
                return true;
            }
            case MotionEvent.ACTION_UP: {
                synchronized (lock) {
                    if (!dragging) return true;
                    dragging = false;
                    float moved = (float) Math.hypot(sx - downX, sy - downY);
                    boolean quick = System.currentTimeMillis() - touchDownTime < 350;
                    if (moved < 12f && quick) {
                        // 轻点 = 摸头
                        brain.petHead();
                        store.recordPet();
                        applyStateVisual();
                        squishTime = 0.28f;
                        spawnHearts();
                    } else {
                        brain.endDrag();
                        applyStateVisual();
                    }
                    onStateChanged();
                }
                return true;
            }
            case MotionEvent.ACTION_CANCEL: {
                synchronized (lock) {
                    if (dragging) {
                        dragging = false;
                        brain.endDrag();
                        applyStateVisual();
                    }
                }
                return true;
            }
            default:
                return true;
        }
    }

    private boolean petHitTest(float x, float y) {
        float s = baseScale;
        float dx = Math.abs(x - petX);
        float dy = y - petY;
        return dx < 130f * s && dy > -20f * s && dy < NOMINAL * s;
    }

    // ---------------------------------------------------------------- HUD 动作

    private void handleHudAction(Hud.Action action) {
        switch (action) {
            case FEED: {
                if (!brain.feed()) {
                    showSpeech("zzZ……（睡得香，吃不下）", 4f);
                    store.save(brain);
                    return;
                }
                store.recordFeed();
                spawnFish();
                break;
            }
            case PLAY: {
                if (!brain.playBall()) {
                    showSpeech("zzZ……（梦里已经在玩了）", 4f);
                    store.save(brain);
                    return;
                }
                spawnBubbleBall();
                break;
            }
            case SLEEP:
                brain.toggleSleep();
                break;
            case RENAME:
                if (host != null) host.onRenameRequest();
                break;
            case MIC:
                if (host != null) host.onMicRequest();
                break;
            case SETTINGS:
                if (host != null) host.onSettingsRequest();
                break;
            default:
                break;
        }
        applyStateVisual();
        onStateChanged();
        store.save(brain);
    }

    public void renamePet(String name) {
        store.rename(name);
        showSpeech("以后就叫我" + store.data().petName + "啦！", 4f);
    }

    public void appWillResign() {
        synchronized (lock) {
            store.save(brain);
        }
    }

    public void appDidBecomeActive() {
        synchronized (lock) {
            brain.settleOffline(System.currentTimeMillis());
            applyStateVisual();
            showSpeech(greeting(), 5f);
        }
    }

    private String greeting() {
        String name = store.data().petName;
        switch (brain.vitals.wellbeing()) {
            case HUNGRY: return name + "饿扁了……快投喂！";
            case TIRED:  return "呼啊……" + name + "好困……";
            case SAD:    return "你终于回来啦……" + name + "好想你……";
            default:     return "欢迎回来！" + name + "一直在等你哦～";
        }
    }

    // ---------------------------------------------------------------- 语音状态

    /**
     * @param petState    为 null 表示语音回闲置
     * @param displayText 右上角胶囊文字；null 时隐藏
     */
    public void setVoiceState(PetState petState, String displayText) {
        synchronized (lock) {
            if (petState != null) {
                if (brain.getState() != petState) brain.beginVoiceInteraction(petState);
                hasTarget = false;   // 说话/思考时站定
                applyStateVisual();
            } else if (brain.getState().isVoiceInteraction()) {
                brain.endVoiceInteraction();
                applyStateVisual();
                onStateChanged();
            }
            voiceText = displayText;
            voiceActive = displayText != null;
            hud.updateVoice(displayText, voiceActive);
        }
    }

    public void showVoiceTranscript(String text) {
        synchronized (lock) {
            showSpeech(text, 5f);
        }
    }

    public void showVoiceResponse(String text) {
        synchronized (lock) {
            showSpeech(text, 10f);
        }
    }

    public void showVoiceNotice(String text) {
        synchronized (lock) {
            showSpeech(text, 4f);
        }
    }

    public void showVoiceError(String message) {
        synchronized (lock) {
            showSpeech("（" + message + "）", 5f);
        }
    }

    // ---------------------------------------------------------------- 一次性特效

    private void spawnHearts() {
        for (int i = 0; i < 3; i++) {
            Fx f = new Fx();
            f.kind = Fx.HEART;
            f.x0 = petX + (i - 1) * 34f;
            f.y0 = petY + NOMINAL * baseScale * 0.75f;
            f.dx = (i - 1) * 16f;
            f.dur = 1.0f;
            fxList.add(f);
        }
    }

    private void spawnFish() {
        float mouthX = petX;
        float mouthY = petY + NOMINAL * baseScale * 0.68f;
        Fx f = new Fx();
        f.kind = Fx.FISH;
        f.x0 = mouthX + (facingRight ? -90f : 90f);
        f.y0 = mouthY + 20f;
        f.x1 = mouthX;
        f.y1 = mouthY;
        f.dur = 0.8f;
        fxList.add(f);
    }

    private void spawnBubbleBall() {
        Fx f = new Fx();
        f.kind = Fx.BALL;
        f.x0 = petX;
        f.y0 = petY + NOMINAL * baseScale * 0.9f;
        f.dur = 4.9f;
        fxList.add(f);
    }

    /** 一次性特效：爱心 / 小鱼干 / 泡泡球。 */
    private static final class Fx {
        static final int HEART = 0;
        static final int FISH = 1;
        static final int BALL = 2;

        int kind;
        float x0;
        float y0;
        float x1;
        float y1;
        float dx;
        float t;
        float dur;
    }
}
