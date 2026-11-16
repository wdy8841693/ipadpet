package com.dywu.whalepet.pet;

/**
 * 宠物数值（0~100）。饱食/心情随时间衰减，睡眠恢复精力。
 * 与 iOS 版 PetVitals 完全同构，存档可互读。
 */
public final class PetVitals {

    public static final double MIN = 0;
    public static final double MAX = 100;

    public double satiety = 80;  // 饱食度
    public double mood = 80;     // 心情
    public double energy = 90;   // 精力

    public enum Wellbeing { HUNGRY, TIRED, SAD, OK, GREAT }

    public void clamp() {
        satiety = Math.min(Math.max(satiety, MIN), MAX);
        mood = Math.min(Math.max(mood, MIN), MAX);
        energy = Math.min(Math.max(energy, MIN), MAX);
    }

    /**
     * 按经过的秒数衰减。速率刻意放缓：宠物是陪伴，不是负担。
     * <ul>
     *   <li>satiety：约 4 小时从 100 → 0</li>
     *   <li>mood：约 6 小时从 100 → 0（饱食度低时加倍）</li>
     *   <li>energy：清醒约 5 小时耗尽；睡眠时每秒 +1.2</li>
     * </ul>
     */
    public void advance(double dtSeconds, boolean sleeping) {
        if (dtSeconds <= 0) return;
        double capped = Math.min(dtSeconds, 6 * 3600);   // 离线最多结算 6 小时
        satiety -= capped * (100.0 / (4 * 3600));
        double moodRate = satiety < 25 ? 2.0 : 1.0;
        mood -= capped * moodRate * (100.0 / (6 * 3600));
        if (sleeping) {
            energy += capped * 1.2;
        } else {
            energy -= capped * (100.0 / (5 * 3600));
        }
        clamp();
    }

    public void feed() {
        feed(22);
    }

    public void feed(double amount) {
        satiety += amount;
        mood += 6;
        clamp();
    }

    public void pet() {
        pet(10);
    }

    public void pet(double amount) {
        mood += amount;
        clamp();
    }

    /** 综合状态等级，用于表情与气泡文案选择。 */
    public Wellbeing wellbeing() {
        if (satiety < 20) return Wellbeing.HUNGRY;
        if (energy < 15) return Wellbeing.TIRED;
        if (mood < 25) return Wellbeing.SAD;
        if (mood > 75 && satiety > 50) return Wellbeing.GREAT;
        return Wellbeing.OK;
    }
}
