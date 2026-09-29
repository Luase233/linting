import Foundation

// Offline service doubles. Retrieval orchestration, policy, scoring, snapshots and SQLite are production code.
struct MusicHistoryRow {
    let id: String; let title: String; let artist: String
    let playCount: Int; let liked: Bool; let recent: Bool
}

private actor CatalogProbe {
    static let shared = CatalogProbe()
    private(set) var queries: [String] = []
    private(set) var detailRequests: [[String]] = []
    func search(_ query: String, limit: Int, offset: Int) async throws -> [RecommendedTrack] {
        queries.append(query)
        await Task.yield()
        let base = query.utf8.reduce(0) { $0 + Int($1) } * 100 + offset
        return (0..<limit).map { index in
            RecommendedTrack(id: String(base + index), title: "Fixture \(base + index)", artist: query,
                album: nil, coverURL: nil, source: "netease", reason: nil, durationSeconds: 180)
        }
    }
    func details(_ ids: [String]) -> [RecommendedTrack] {
        detailRequests.append(ids)
        return ids.map { RecommendedTrack(id: $0, title: "Recovered \($0)", artist: "Favorite artist",
            album: nil, coverURL: nil, source: "netease", reason: nil, durationSeconds: 180) }
    }
}

struct NetEaseDirectClient {
    func search(_ query: String, limit: Int, offset: Int) async throws -> [RecommendedTrack] {
        try await CatalogProbe.shared.search(query, limit: limit, offset: offset)
    }
    func songDetails(ids: [String]) async throws -> [RecommendedTrack] { await CatalogProbe.shared.details(ids) }
}

@MainActor final class TrackProfileStore {
    static let shared = TrackProfileStore()
    func features(for track: RecommendedTrack, seedTags: [String]) -> [String: Double] {
        precondition(seedTags.isEmpty, "Recall provenance must not be mislabeled as musical features")
        let value = Double((Int(track.id) ?? 0) % 10) / 10
        return ["energy": value, "attention_demand": value, "rhythmic_strength": 1 - value]
    }
    func evidenceSummary(for trackID: String) -> String { "offline fixture" }
}

@main struct RecommendationPreparationChecks {
    static func main() {
        setbuf(stdout, nil)
        Task.detached {
            do { try await runChecks(); exit(0) }
            catch { fatalError("Integration checks failed: \(error)") }
        }
        RunLoop.main.run()
    }

    @MainActor static func runChecks() async throws {
        func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linting-preparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        print("Preparing offline recommendation fixture")
        let store = AdaptiveDecisionStore(fileURL: folder.appendingPathComponent("learning.json"))
        let engine = LocalRecommendationEngine(localStateURL: folder.appendingPathComponent("local.json"), learningStore: store)
        let history = [MusicHistoryRow(id: "10", title: "", artist: "", playCount: 0, liked: true, recent: false)]
            + (1...3).map { MusicHistoryRow(id: String($0), title: "Known \($0)", artist: "Artist \($0)", playCount: 8, liked: true, recent: false) }
        @MainActor @Sendable func preview(_ selection: ModeSelection = .auto) async throws -> DecisionResponse {
            try await engine.previewDecision(selection: selection, discovery: 1, scene: nil,
                health: nil, history: history, excludeIDs: [])
        }
        print("Checking concurrent catalog preparation")
        let a = Task { try await preview() }
        let b = Task { try await preview() }
        let first = try await a.value
        let concurrent = try await b.value
        print("Checking final policy and exact snapshots")
        let queries = await CatalogProbe.shared.queries
        require(queries.count == 5, "concurrent previews must coalesce: three artists and two small discovery lanes")
        require(queries.filter { $0.hasPrefix("Artist ") }.count == 3, "multiple favorite artists must participate in recall")
        require(await CatalogProbe.shared.detailRequests == [["10"]], "blank imported favorite metadata must be hydrated in one bounded batch")
        require(first.track.id == concurrent.track.id, "previews preserve the pending independent draw")
        require(store.state.decisionCount == 0 && store.state.episodeCount == 0 && store.state.journal.isEmpty,
            "preparing metadata and candidates must not create decision or playback evidence")
        let decision = try await engine.nextDecision(selection: .auto, discovery: 1, scene: nil,
            health: nil, history: history, excludeIDs: [], parentDecisionID: "failed-parent")
        require(await CatalogProbe.shared.queries.count == queries.count, "warm next must not await another catalog search")
        require(decision.track.id == first.track.id, "unchanged evidence consumes the prepared warm choice")
        require(store.state.decisionCount == 1 && store.state.trackStarts.isEmpty, "selection is not an actual playback start")
        let snapshot = engine.decisionSnapshot(id: decision.recommendationID)!
        require(snapshot.parentDecisionID == "failed-parent", "unplayable retry lineage must be retained")
        require(snapshot.samplingTemperature == 0.25 && snapshot.uniformExploration == 0,
            "actual bounded-policy parameters accompany the snapshot")
        require(snapshot.candidates.contains { $0.trackID == "10" && $0.title == "Recovered 10" },
            "a favorite absent from recent listening must survive recall with a readable title")
        require(snapshot.candidates.allSatisfy { $0.title?.isEmpty == false && $0.artist?.isEmpty == false },
            "all ranked candidates retain display metadata, including unchosen top eight")
        require(snapshot.candidates.allSatisfy { $0.scoreFactors?["discovery"] == nil && ($0.scoreFactors?["variety"] ?? 0) == 0 },
            "novelty is not an additive score and recall channels are not artist-repeat penalties")
        require(abs(snapshot.candidates.compactMap(\.probability).reduce(0, +) - 1) < 0.000001,
            "logged probabilities cover the exact final choice distribution")
        require(snapshot.candidates.filter { ($0.probability ?? 0) > 0 }.count <= 6,
            "the whole candidate tail must not receive an unconditional sampling probability")
        require(snapshot.candidates.allSatisfy { abs(($0.mainProbability ?? 0) + ($0.explorationProbability ?? 0) - ($0.probability ?? 0)) < 0.000001 },
            "main and exploration attribution must sum to final probability")
        require(snapshot.candidates.allSatisfy { abs(($0.scoreFactors?.values.reduce(0, +) ?? .infinity) - $0.score) < 0.000001 },
            "explanation factors add up to the real score")
        require(snapshot.contextInfluences?.count == 3 && snapshot.contextInfluences?.allSatisfy { $0.candidateEffects.count == snapshot.candidates.count } == true,
            "all candidates have separate visual/place/health ablations")
        require(snapshot.contextInfluences?.allSatisfy { $0.totalVariation == 0 && !$0.rankingChanged } == true,
            "missing context in an untrained model must not claim a benefit")

        try engine.recordFeedback(trackID: decision.track.id, decisionID: decision.recommendationID,
            episodeID: "actual-episode", kind: "disliked")
        let afterFeedback = try await preview(.focus)
        require(afterFeedback.items.allSatisfy { $0.id != decision.track.id }, "latest dislike excludes a prepared song")
        require(await CatalogProbe.shared.queries.contains { $0.contains("Artist") && $0.contains("instrumental") },
            "explicit intent contributes a recall lane anchored to an interest artist")
        require(await CatalogProbe.shared.detailRequests.count == 1, "persisted metadata avoids fetching blank favorite IDs again")
        let manual = engine.registerManualSelection(track: afterFeedback.track, from: decision.recommendationID, reason: "manual_replay")!
        require(engine.decisionSnapshot(id: manual)?.candidate(afterFeedback.track.id)?.probability == nil,
            "manual choices have unknown propensity")
        require(store.state.model.replay.updates == 0 && store.state.trackStarts.isEmpty,
            "clicking replay before audio renders creates no reward")

        // Train a synthetic health interaction and verify actual per-candidate counterfactuals.
        try store.transaction { $0.model.continuation.weights["cross.health.heart_rate*energy"] = 3 }
        let now = Date()
        let health = HealthContext(observedAt: "fixture", features: ["heart_rate": HealthMetric(value: 100,
            measuredAt: now, unit: "bpm", baseline: 70, sampleCount: 4, quality: "good")])
        let withHealth = try await engine.nextDecision(selection: .auto, discovery: 1, scene: nil,
            health: health, history: history, excludeIDs: [])
        let healthSnapshot = engine.decisionSnapshot(id: withHealth.recommendationID)!
        let effect = healthSnapshot.contextInfluences!.first { $0.source == "health" }!
        require(effect.coverage > 0 && effect.candidateEffects.contains { abs($0.scoreDelta) > 0.01 },
            "observed health associations must expose their real score changes")
        require(effect.totalVariation.isFinite && (0...1).contains(effect.totalVariation),
            "counterfactual policy distance must be a valid total variation")
        for _ in 0..<4 { await engine.prepareCandidates(history: history, force: true) }
        require(engine.cachedCandidateCount <= 80, "retrieval remains bounded across a long session")
        let beforeCancellation = store.state.decisionCount
        let cancelled = Task { try await preview() }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled preparation must not be consumed") }
        catch is CancellationError { }
        require(store.state.decisionCount == beforeCancellation, "cancelled preview cannot produce evidence")
        print("Recommendation integration checks passed: multi-channel recall, favorite hydration, cache/coalescing, bounded sampling, exact snapshots, context ablations and no phantom learning")
    }
}
