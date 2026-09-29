import Foundation

struct PlaybackAction: Codable {
    var id = UUID().uuidString
    let kind: String
    let at: Date
    let position: Double?
    let targetPosition: Double?
    let source: String
}

struct PlaybackEvidence: Codable {
    let id: String
    let decisionID: String?
    let trackID: String
    let startedAt: Date
    let endedAt: Date
    let duration: Double?
    let renderedSeconds: Double
    let uniqueCoveredSeconds: Double
    let lastPosition: Double
    let startReason: String
    let endReason: String
    let actions: [PlaybackAction]
    let contentKind: String
    var labelVersion: String? = nil
    var continuationTarget: Double? = nil
    var continuationCensorReason: String? = nil

    var isDiagnostic: Bool {
        let reason = startReason.lowercased()
        return reason.contains("diagnostic") || reason.contains("smoke") || reason == "system"
    }
}

/// Accumulates actual forward playback, not playhead position. No claim of human attention.
struct PlaybackTracker {
    let id = UUID().uuidString
    let decisionID: String?
    let trackID: String
    let startedAt: Date
    let startReason: String
    var duration: Double?
    var contentKind = "unknown"
    private(set) var renderedSeconds = 0.0
    private(set) var lastPosition = 0.0
    private(set) var actions: [PlaybackAction] = []
    private var intervals: [ClosedRange<Double>] = []
    private var lastTick: Double?
    private var advancing = false

    init(decisionID: String?, trackID: String, startedAt: Date = Date(), startReason: String,
         duration: Double? = nil) {
        self.decisionID = decisionID; self.trackID = trackID; self.startedAt = startedAt
        self.startReason = startReason; self.duration = duration
    }

    var uniqueCoveredSeconds: Double { intervals.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    mutating func sample(position: Double, monotonic: Double, isPlaying: Bool, duration: Double? = nil) {
        if let duration, duration.isFinite, duration > 0 { self.duration = duration }
        guard position.isFinite, position >= 0, monotonic.isFinite else { return }
        if let previous = lastTick, advancing {
            let wallDelta = monotonic - previous
            let delta = position - lastPosition
            // Seek jumps, backward movement and clock discontinuities are not listening time.
            if wallDelta > 0, delta > 0, delta <= wallDelta * 1.5 + 0.25 {
                let played = min(delta, wallDelta)
                renderedSeconds += played
                merge((position - played)...position)
            }
        }
        lastTick = monotonic; lastPosition = position; advancing = isPlaying
    }

    mutating func resetPosition(_ position: Double, monotonic: Double, isPlaying: Bool) {
        guard position.isFinite, position >= 0 else { return }
        lastPosition = position; lastTick = monotonic; advancing = isPlaying
    }

    mutating func append(_ action: PlaybackAction) {
        actions.append(action)
        // A bounded per-episode event trace; aggregated coverage survives compaction.
        if actions.count > 512 { actions.removeFirst(actions.count - 512) }
    }

    func evidence(endedAt: Date = Date(), reason: String) -> PlaybackEvidence {
        PlaybackEvidence(id: id, decisionID: decisionID, trackID: trackID, startedAt: startedAt,
            endedAt: endedAt, duration: duration, renderedSeconds: renderedSeconds,
            uniqueCoveredSeconds: uniqueCoveredSeconds, lastPosition: lastPosition,
            startReason: startReason, endReason: reason, actions: actions, contentKind: contentKind)
    }

    private mutating func merge(_ range: ClosedRange<Double>) {
        let sorted = (intervals + [range]).sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for value in sorted {
            if let last = merged.last, value.lowerBound <= last.upperBound + 0.02 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, value.upperBound)
            } else { merged.append(value) }
        }
        intervals = merged
    }
}

enum PlaybackCheckpoint {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("active-playback.json")
    }
    static func save(_ evidence: PlaybackEvidence) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(evidence).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func recover() -> PlaybackEvidence? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlaybackEvidence.self, from: data)
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}
