package com.dywu.whalepet.pet;

import java.util.Random;

/**
 * 行为调度器：根据数值与随机权重挑选下一个自主行为。
 * 纯逻辑、不依赖 Android → 与 iOS 版共用同一套策略。
 */
public final class PetBrain {

    public PetVitals vitals;
    private PetState state = PetState.IDLE;
    private double stateRemaining = PetState.IDLE.baseDuration();

    /** 上一次结算的墙钟时间（epoch 毫秒），用于离线衰减。 */
    public long lastTick = System.currentTimeMillis();

    public PetBrain() {
        this(new PetVitals());
    }

    public PetBrain(PetVitals vitals) {
        this.vitals = vitals;
        this.stateRemaining = state.baseDuration();
    }

    public PetState getState() {
        return state;
    }

    public double getStateRemaining() {
        return stateRemaining;
    }

    // ---------------------------------------------------------------- 事件驱动

    public void beginDrag() {
        transition(PetState.DRAG);
    }

    public void endDrag() {
        vitals.pet(4);       // 被抱起来也算互动
        transition(PetState.HAPPY);
    }

    public void petHead() {
        vitals.pet();
        transition(PetState.HAPPY);
    }

    /** @return 是否真正执行；渲染层只在成功时播放特效并计数。 */
    public boolean feed() {
        if (state == PetState.SLEEP) return false;   // 睡着了不进食
        vitals.feed();
        transition(PetState.EAT);
        return true;
    }

    public boolean playBall() {
        if (state == PetState.SLEEP) return false;
        vitals.pet(8);
        vitals.energy -= 5;
        vitals.clamp();
        transition(PetState.PLAY);
        return true;
    }

    public void toggleSleep() {
        transition(state == PetState.SLEEP ? PetState.IDLE : PetState.SLEEP);
    }

    public void beginVoiceInteraction(PetState s) {
        if (!s.isVoiceInteraction()) return;
        transition(s);
    }

    public void endVoiceInteraction() {
        if (!state.isVoiceInteraction()) return;
        transition(PetState.IDLE);
    }

    // ---------------------------------------------------------------- 时间推进

    /**
     * 每帧调用。返回 true 表示状态发生了变化（渲染层据此换立绘/换动作）。
     */
    public boolean tick(double dtSeconds, long nowMillis, Random rng) {
        lastTick = nowMillis;
        vitals.advance(dtSeconds, state == PetState.SLEEP);
        stateRemaining -= dtSeconds;
        if (stateRemaining > 0 || state == PetState.DRAG) return false;
        transition(pickNextState(rng));
        return true;
    }

    /** 离线结算：退到后台/被杀后重新打开时调用一次。 */
    public void settleOffline(long nowMillis) {
        double dt = (nowMillis - lastTick) / 1000.0;
        if (dt <= 1) {
            lastTick = nowMillis;
            return;
        }
        vitals.advance(dt, state == PetState.SLEEP);
        lastTick = nowMillis;
        // 长时间离开后回来，先待机而不是继续睡觉/游动
        transition(PetState.IDLE);
    }

    // ---------------------------------------------------------------- 私有

    private void transition(PetState next) {
        state = next;
        stateRemaining = next.baseDuration();
    }

    /** 加权随机挑选下一个自主状态；数值差时倾向睡觉/待机。 */
    public PetState pickNextState(Random rng) {
        PetState[] states = {PetState.IDLE, PetState.WALK, PetState.SWIM, PetState.SLEEP};
        double[] weights = {
                40,
                25,
                25,
                vitals.energy < 35 ? 60 : 8,
        };
        if (vitals.satiety < 20 || vitals.mood < 20) {
            // 又饿又难过时没精神到处游
            for (int i = 0; i < states.length; i++) {
                if (states[i] == PetState.SWIM || states[i] == PetState.WALK) weights[i] = 6;
            }
        }
        double total = 0;
        for (double w : weights) total += w;
        double roll = rng.nextDouble() * total;
        for (int i = 0; i < states.length; i++) {
            roll -= weights[i];
            if (roll < 0) return states[i];
        }
        return PetState.IDLE;
    }
}
