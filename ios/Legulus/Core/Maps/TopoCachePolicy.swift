import Foundation

/// Leaves the tile server alone for a while after a failure, so a
/// server that is down costs one deadline, not one per sample opened.
struct TopoFailureGate {
    let cooldown: TimeInterval
    private var failedAt: Date?

    init(cooldown: TimeInterval) {
        self.cooldown = cooldown
    }

    func allows(at now: Date) -> Bool {
        guard let failedAt else { return true }
        return now.timeIntervalSince(failedAt) >= cooldown
    }

    mutating func recordFailure(at now: Date) {
        failedAt = now
    }

    mutating func recordSuccess() {
        failedAt = nil
    }
}

/// One rendered map header on disk, for pruning the cache.
struct TopoCacheEntry: Equatable {
    let name: String
    let size: Int
    /// Last use: the file's modification date, touched on every read.
    let used: Date

    /// The names to delete so the rest fits `limit` bytes: least
    /// recently used first.
    static func toDelete(_ entries: [TopoCacheEntry], limit: Int) -> [String] {
        var total = entries.reduce(0) { $0 + $1.size }
        var names: [String] = []
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > limit {
            names.append(entry.name)
            total -= entry.size
        }
        return names
    }
}
