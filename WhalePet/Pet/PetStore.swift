import Foundation

/// 持久化：JSON 落盘到 Application Support（比 UserDefaults 更适合结构化数据，
/// 且方便以后导出存档）。写入采用原子替换，避免掉电损坏。
final class PetStore {
    struct SaveData: Codable {
        var vitals: PetVitals
        var lastTick: Date
        var petName: String
        var totalFeeds: Int
        var totalPets: Int
        var bornAt: Date
    }

    static let shared = PetStore()

    private let fileURL: URL
    private(set) var data: SaveData

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("whalepet-save.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(SaveData.self, from: raw) {
            data = decoded
        } else {
            data = SaveData(vitals: PetVitals(), lastTick: Date(), petName: "小鲸",
                            totalFeeds: 0, totalPets: 0, bornAt: Date())
        }
    }

    func save(brain: PetBrain) {
        data.vitals = brain.vitals
        data.lastTick = brain.lastTick
        persist()
    }

    func recordFeed() { data.totalFeeds += 1; persist() }
    func recordPet() { data.totalPets += 1; persist() }
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        data.petName = String(trimmed.prefix(12))
        persist()
    }

    private func persist() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }
}