import Foundation

/// 气泡台词库。按场景 + 数值状态选句子，避免连续重复。
struct Dialogue {
    private var lastLine: String = ""

    mutating func line(for state: PetState, wellbeing: PetVitals.Wellbeing, name: String) -> String? {
        let pool: [String]
        switch (state, wellbeing) {
        case (.eat, _):
            pool = ["小鱼干！最喜欢了～", "唔姆唔姆……谢谢投喂！", "尾巴开心地摇起来了♪"]
        case (.happy, _):
            pool = ["嘿嘿，再摸摸嘛～", "咕噜咕噜……（发出鲸歌）", "\(name)最喜欢你啦！"]
        case (.sleep, _):
            pool = ["zzZ……梦见磷虾自助餐……", "呼……呼……"]
        case (.drag, _):
            pool = ["哇啊啊——放我下来啦！", "晕、晕船了……"]
        case (.play, _):
            pool = ["泡泡球！看我的尾鳍扣杀！", "噗——吹个大泡泡！"]
        case (.listening, _):
            pool = ["我在听～", "嗯嗯，请说～"]
        case (.thinking, _):
            pool = ["让我想想……", "正在翻深海百科……"]
        case (.speaking, _):
            pool = ["听我说～", "是这样哒～"]
        case (_, .hungry):
            pool = ["肚子咕咕叫了……想吃小鱼干", "投喂按钮在右下角哦👉"]
        case (_, .tired):
            pool = ["好困……让我睡一会儿嘛", "精力不足，需要充电zzZ"]
        case (_, .sad):
            pool = ["有点寂寞……摸摸头好不好？", "今天还没怎么陪我玩呢……"]
        case (_, .great):
            pool = ["今天也是元气满满的鲸鱼娘！", "要不要看我表演跃出水面？", "DSH——Deep Sea Hug！"]
        default:
            pool = ["海里真安静呀～", "你知道吗？鲸鱼会唱歌哦", "iPad mini 4 也要好好保养哦（笑）",
                    "我是\(name)，你的深海小宠物～"]
        }
        guard var pick = pool.randomElement() else { return nil }
        if pick == lastLine, pool.count > 1 {
            pick = pool.filter { $0 != lastLine }.randomElement() ?? pick
        }
        lastLine = pick
        return pick
    }
}