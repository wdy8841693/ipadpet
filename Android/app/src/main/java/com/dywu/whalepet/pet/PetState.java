package com.dywu.whalepet.pet;

import java.util.Random;

/**
 * 鲸鱼娘的行为状态（与 iOS 版 PetState 一一对应）。
 * 纯枚举状态机，无物理引擎：状态切换 + 程序化运动，老设备也扛得住。
 */
public enum PetState {
    /** 待机：漂浮 + 眨眼 + 尾巴摆动 */
    IDLE,
    /** 沿"海底地面"散步 */
    WALK,
    /** 全屏游动 */
    SWIM,
    /** 被摸头：冒爱心 */
    HAPPY,
    /** 投喂：吃小鱼干 */
    EAT,
    /** 睡觉：zzZ */
    SLEEP,
    /** 被拖拽：四肢摊开 */
    DRAG,
    /** 玩泡泡球 */
    PLAY,
    /** 唤醒成功，正在聆听指令 */
    LISTENING,
    /** 已发送给 DSH，等待回答 */
    THINKING,
    /** 正在播报回答 */
    SPEAKING;

    private static final Random RNG = new Random();

    /**
     * 该状态的基础时长（秒）。{@link Double#POSITIVE_INFINITY} 表示由外部事件结束（如被拖拽）。
     */
    public double baseDuration() {
        switch (this) {
            case IDLE:  return 4.0 + RNG.nextDouble() * 5.0;    // 4 ~ 9
            case WALK:  return 5.0 + RNG.nextDouble() * 5.0;    // 5 ~ 10
            case SWIM:  return 6.0 + RNG.nextDouble() * 6.0;    // 6 ~ 12
            case HAPPY: return 2.6;
            case EAT:   return 3.2;
            case SLEEP: return 20.0 + RNG.nextDouble() * 20.0;  // 20 ~ 40
            case PLAY:  return 6.0;
            default:    return Double.POSITIVE_INFINITY;        // DRAG / LISTENING / THINKING / SPEAKING
        }
    }

    /** 是否允许自动行为调度器切换到该状态。 */
    public boolean isAutonomous() {
        switch (this) {
            case IDLE:
            case WALK:
            case SWIM:
            case SLEEP:
                return true;
            default:
                return false;
        }
    }

    /** 语音交互由 VoiceController 结束，不参与随机行为调度。 */
    public boolean isVoiceInteraction() {
        return this == LISTENING || this == THINKING || this == SPEAKING;
    }
}
