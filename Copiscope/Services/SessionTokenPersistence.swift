import Foundation

// MARK: - Persisted token data for a single session

struct PersistedTokenData: Codable, Equatable {
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCachedTokens: Int
    var totalReasoningTokens: Int
    var estimatedCost: Double
    var premiumRequestCount: Int
    var primaryModel: String?
    var vendor: String?
    var modelBreakdown: [PersistedModelBreakdown]
}

struct PersistedModelBreakdown: Codable, Equatable {
    var model: String
    var vendor: String
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var reasoningTokens: Int
    var estimatedCost: Double
    var spanCount: Int
}

// MARK: - Persistence helper

/// Loads and saves a JSON dictionary of session-ID → token data to disk.
/// Stored at ~/Library/Application Support/Copiscope/sessionTokens.json
struct SessionTokenPersistence {
    private let fileURL: URL

    static let shared = SessionTokenPersistence()

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Copiscope")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sessionTokens.json")
    }

    func load() -> [String: PersistedTokenData] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: PersistedTokenData].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ cache: [String: PersistedTokenData]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
