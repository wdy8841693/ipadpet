package com.dywu.whalepet.pet;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * 气泡台词库。按场景 + 数值状态选句子，避免连续重复。
 */
public final class Dialogue {

    private final Random rng = new Random();
    private String lastLine = "";

    public String line(PetState state, PetVitals.Wellbeing wellbeing, String name) {
        List<String> pool = new ArrayList<>(6);
        switch (state) {
            case EAT:
                pool.add("小鱼干！最喜欢了～");
                pool.add("唔姆唔姆……谢谢投喂！");
                pool.add("尾巴开心地摇起来了♪");
                break;
            case HAPPY:
                pool.add("嘿嘿，再摸摸嘛～");
                pool.add("咕噜咕噜……（发出鲸歌）");
                pool.add(name + "最喜欢你啦！");
                break;
            case SLEEP:
                pool.add("zzZ……梦见磷虾自助餐……");
                pool.add("呼……呼……");
                break;
            case DRAG:
                pool.add("哇啊啊——放我下来啦！");
                pool.add("晕、晕船了……");
                break;
            case PLAY:
                pool.add("泡泡球！看我的尾鳍扣杀！");
                pool.add("噗——吹个大泡泡！");
                break;
            case LISTENING:
                pool.add("我在听～");
                pool.add("嗯嗯，请说～");
                break;
            case THINKING:
                pool.add("让我想想……");
                pool.add("正在翻深海百科……");
                break;
            case SPEAKING:
                pool.add("听我说～");
                pool.add("是这样哒～");
                break;
            default:
                switch (wellbeing) {
                    case HUNGRY:
                        pool.add("肚子咕咕叫了……想吃小鱼干");
                        pool.add("投喂按钮在下方哦👉");
                        break;
                    case TIRED:
                        pool.add("好困……让我睡一会儿嘛");
                        pool.add("精力不足，需要充电zzZ");
                        break;
                    case SAD:
                        pool.add("有点寂寞……摸摸头好不好？");
                        pool.add("今天还没怎么陪我玩呢……");
                        break;
                    case GREAT:
                        pool.add("今天也是元气满满的鲸鱼娘！");
                        pool.add("要不要看我表演跃出水面？");
                        pool.add("DSH——Deep Sea Hug！");
                        break;
                    default:
                        pool.add("海里真安静呀～");
                        pool.add("你知道吗？鲸鱼会唱歌哦");
                        pool.add("手机也要好好保养哦（笑）");
                        pool.add("我是" + name + "，你的深海小宠物～");
                        break;
                }
                break;
        }
        String pick = pool.get(rng.nextInt(pool.size()));
        if (pick.equals(lastLine) && pool.size() > 1) {
            List<String> others = new ArrayList<>(pool);
            others.remove(pick);
            pick = others.get(rng.nextInt(others.size()));
        }
        lastLine = pick;
        return pick;
    }
}
