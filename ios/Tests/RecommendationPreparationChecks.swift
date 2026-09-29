import Foundation

// Deliberately offline boundary doubles; scoring, candidate caching and persistence are production code.
struct MusicHistoryRow {
    let id: String; let title: String; let artist: String
    let playCount: Int; let liked: Bool; let recent: Bool
}

private actor CatalogProbe {
    static let shared = CatalogProbe()
    private(set) var searches = 0
    func search(_ query: String, limit: Int, offset: Int) async throws -> [RecommendedTrack] {
        searches += 1
        try await Task.sleep(nanoseconds: 10_000_000)
        let base = query.utf8.reduce(0) { $0 + Int($1) } * 100 + offset
        return (0..<limit).map { index in
            RecommendedTrack(id: String(base + index), title: "Fixture \(base + index)", artist: "Artist",
                album: nil, coverURL: nil, source: "netease", reason: nil, durationSeconds: 180)
        }
    }
}

struct NetEaseDirectClient {
    func search(_ query: String, limit: Int, offset: Int) async throws -> [RecommendedTrack] {
        try await CatalogProbe.shared.search(query, limit: limit, offset: offset)
    }
}

@MainActor final class TrackProfileStore {
    static let shared = TrackProfileStore()
    func features(for track: RecommendedTrack, seedTags: [String]) -> [String: Double] {
        ["energy": 0.7, "attention_demand": 0.8, "rhythmic_strength": 0.65]
    }
    func evidenceSummary(for trackID: String) -> String { "offline fixture" }
}

@main struct RecommendationPreparationChecks {
    static func main() {
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { fatalError("Recommendation preparation checks failed: \(error)") }
        }
        dispatchMain()
    }

    @MainActor static func runChecks() async throws {
        func require(_ value: Bool, _ message: String) {
            if !value { fatalError(message) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linting-preparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("local.json")
        let store = AdaptiveDecisionStore(fileURL: folder.appendingPathComponent("learning.json"))
        let engine = LocalRecommendationEngine(localStateURL: legacy, learningStore: store)
        @MainActor @Sendable func preview(_ selection: ModeSelection = .auto) async throws -> DecisionResponse {
            return try await engine.previewDecision(selection: selection, discovery: 1, scene: nil,
                health: nil, history: [], excludeIDs: [])
        }
        async let a = preview()
        async let b = preview()
        let (first, concurrent) = try await (a, b)
        let searchesAfterWarmup = await CatalogProbe.shared.searches
        require(searchesAfterWarmup == 5, "concurrent previews must coalesce into one five-query retrieval")
        require(first.track.id == concurrent.track.id, "read-only previews must preserve the pending independent exploration draw")
        require(store.state.decisionCount == 0 && store.state.episodeCount == 0 && store.state.journal.isEmpty,
            "preparing candidates must not create decision/playback/feedback evidence")
        require(!FileManager.default.fileExists(atPath: legacy.path), "preview must not write the legacy catalog")

        let decision = try await engine.nextDecision(selection: .auto, discovery: 1, scene: nil,
            health: nil, history: [], excludeIDs: [])
        require(await CatalogProbe.shared.searches == searchesAfterWarmup, "warm next must not await another catalog search")
        require(decision.track.id == first.track.id, "unchanged evidence must consume the prepared warm choice")
        require(store.state.decisionCount == 1 && store.state.trackStarts.isEmpty, "selection is not an actual playback start")
        let snapshot = engine.decisionSnapshot(id: decision.recommendationID)!
        require(snapshot.samplingTemperature == RecommendationScoreDefinition.temperature && snapshot.uniformExploration == RecommendationScoreDefinition.exploration,
            "actual sampling parameters must accompany the final decision snapshot")
        require(snapshot.candidates.allSatisfy { ($0.scoreFactors?["rejection"] ?? 1) <= 0 },
            "new decision snapshots must store risk as an explicit deduction")
        require(abs(snapshot.candidates.compactMap(\.probability).reduce(0, +) - 1) < 0.000001,
            "logged exploration probabilities must cover the full candidate pool")
        require(snapshot.candidates.allSatisfy { abs(($0.scoreFactors?.values.reduce(0, +) ?? .infinity) - $0.score) < 0.000001 },
            "displayed score factors must add up to the actual ranking score")

        try engine.recordFeedback(trackID: decision.track.id, decisionID: decision.recommendationID,
            episodeID: "actual-episode", kind: "disliked")
        let afterFeedback = try await preview(.focus)
        require(afterFeedback.items.allSatisfy { $0.id != decision.track.id }, "latest dislike must exclude a previously prepared song")
        require(store.state.decisionCount == 1, "reranking a preview must not log a new decision")
        let manual = engine.registerManualSelection(track: afterFeedback.track, from: decision.recommendationID,
            reason: "manual_replay")!
        require(engine.decisionSnapshot(id: manual)?.candidate(afterFeedback.track.id)?.probability == nil,
            "manual choices have unknown propensity")
        require(store.state.model.replay.updates == 0 && store.state.trackStarts.isEmpty,
            "clicking replay before audio renders must not create reward or a start")

        for _ in 0..<4 { await engine.prepareCandidates(history: [], force: true) }
        require(engine.cachedCandidateCount <= 80, "candidate retrieval must remain bounded across a long session")
        let beforeCancellation = store.state.decisionCount
        let cancelled = Task { try await preview() }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled preparation must not be consumed") }
        catch is CancellationError { }
        require(store.state.decisionCount == beforeCancellation, "cancelled preparation cannot produce evidence")
        print("Recommendation preparation checks passed: coalescing, warm switching, latest feedback, bounded cache, exact score factors and no phantom learning")
    }
}
