import Foundation

@main
enum AdaptivePreferenceModelChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    @MainActor static func main() throws {
        let now = Date()
        let music = ["energy": 0.9, "attention_demand": 0.2]
        let low = AdaptivePreferenceModel.features(context: ["health.hrv_relative": -1], music: music,
            trackID: "1", artist: "A", sourceTag: "electronic", known: false)
        let high = AdaptivePreferenceModel.features(context: ["health.hrv_relative": 1], music: music,
            trackID: "1", artist: "A", sourceTag: "electronic", known: false)
        require(low["cross.health.hrv_relative*energy"] != nil, "health/music interaction missing")
        var model = AdaptivePreferenceModel()
        for _ in 0..<60 {
            model.acceptance.update(features: low, target: 0, confidence: 1)
            model.acceptance.update(features: high, target: 1, confidence: 1)
        }
        require(model.acceptance.probability(high) > model.acceptance.probability(low) + 0.4,
            "opposite context feedback should produce different predictions")
        let probabilities = AdaptivePreferenceModel.softmax([-10, 0, 10])
        require(abs(probabilities.reduce(0, +) - 1) < 0.00001 && probabilities.allSatisfy { $0 > 0 },
            "logged exploration probabilities must form a full distribution")

        func episode(_ id: String, end: String = "user_next", seconds: Double = 12, covered: Double = 12,
                     kind: String = "full", actions: [PlaybackAction] = [], start: String = "automatic") -> PlaybackEvidence {
            PlaybackEvidence(id: id, decisionID: "d1", trackID: "1", startedAt: now, endedAt: now.addingTimeInterval(seconds),
                duration: 200, renderedSeconds: seconds, uniqueCoveredSeconds: covered, lastPosition: 180,
                startReason: start, endReason: end, actions: actions, contentKind: kind)
        }
        let early = AdaptiveEpisodeTargets.from(episode("early"))
        let late = AdaptiveEpisodeTargets.from(episode("late", seconds: 190, covered: 190))
        require(early.continuation == 0 && early.confidence > 0, "full rendition early skip is a failed continuation window")
        require(early.skipStrength == 1 && late.skipStrength == 0 && late.continuation == 1,
            "a skip after observing the fixed window must not undo actual continuation")
        require(AdaptiveEpisodeTargets.from(episode("auto", end: "natural_end", seconds: 200, covered: 200)).acceptance == nil,
            "unattended completion must not become a like")
        require(AdaptiveEpisodeTargets.from(episode("error", end: "playback_error")).confidence == 0,
            "playback errors cannot be negative preference")
        let backwardSeek = PlaybackAction(kind: "seek", at: now, position: 40, targetPosition: 10, source: "app")
        require(AdaptiveEpisodeTargets.from(episode("drag-only", end: "natural_end", seconds: 40, covered: 40,
            actions: [backwardSeek])).replay == nil, "moving a slider alone cannot become a positive preference")
        require(AdaptiveEpisodeTargets.from(episode("section-replay", end: "natural_end", seconds: 70, covered: 40,
            actions: [backwardSeek])).replay != nil, "deliberate replay with actual repeated audio should supply weak evidence")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bgm-adaptive-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = AdaptiveDecisionStore(fileURL: url)
        let candidate = AdaptiveCandidateSnapshot(trackID: "1", sourceTag: "electronic", features: low,
            score: 0, predictions: [:], probability: 1)
        try store.transaction { $0.decisions.append(AdaptiveDecisionSnapshot(id: "d1", at: now, chosenTrackID: "1",
            candidates: [candidate], selection: "softmax", policyVersion: "test", context: [:])) }
        try store.recordEpisode(episode("e1"))
        let count = store.state.model.continuation.updates
        try store.recordEpisode(episode("e1"))
        require(store.state.episodeCount == 1 && store.state.model.continuation.updates == count, "episode must train once")
        try store.recordFeedback(trackID: "1", decisionID: "d1", episodeID: "e2", kind: "unsuitable")
        let unsuitableWeights = store.state.model.fit.weights
        require(unsuitableWeights["item.1"] == nil && unsuitableWeights["artist.a"] == nil,
            "context unsuitable must not globally punish track or artist")
        let explicitCount = store.state.model.fit.updates
        try store.recordFeedback(trackID: "1", decisionID: "d1", episodeID: "e2", kind: "unsuitable")
        try store.recordEpisode(episode("e2", end: "context_unsuitable"))
        require(store.state.model.fit.updates == explicitCount, "explicit feedback and episode cannot double train")
        let replay = PlaybackAction(kind: "replay", at: now, position: 20, targetPosition: 0, source: "app")
        try store.recordAction(replay, trackID: "1", decisionID: "d1", episodeID: "e3")
        try store.recordAction(replay, trackID: "1", decisionID: "d1", episodeID: "e3")
        try store.recordEpisode(episode("e3", end: "manual_replay", actions: [replay]))
        require(store.state.model.replay.updates == 0, "leaving an old episode must not reward it for selecting another track")
        let started = PlaybackAction(kind: "started", at: now, position: 1, targetPosition: nil, source: "system")
        try store.recordAction(started, trackID: "1", decisionID: "d1", episodeID: "e3")
        try store.recordAction(started, trackID: "1", decisionID: "d1", episodeID: "e3")
        let duplicateStarted = PlaybackAction(kind: "started", at: now, position: 2, targetPosition: nil, source: "system")
        try store.recordAction(duplicateStarted, trackID: "1", decisionID: "d1", episodeID: "e3")
        require(store.state.trackStarts["1"] == 1, "actual starts must be counted once per episode")
        let beforeError = store.state.model.continuation.updates
        let coverageBeforeError = store.state.recentCoverage
        try store.recordEpisode(episode("e4", end: "playback_error"))
        require(store.state.model.continuation.updates == beforeError, "error episode cannot change preference")
        require(store.state.recentCoverage == coverageBeforeError, "censored failures cannot alter session adaptation context")
        require(store.state.effectiveEvidence(trackID: "1")["continuation"] == 1,
            "track evidence must count qualified episodes only")
        require(store.state.effectiveEvidence(trackID: "1")["fit"] == 1 && store.state.effectiveEvidence(trackID: "unseen").isEmpty,
            "a global update count cannot become evidence for an unseen song")
        try store.recordFeedback(trackID: "1", decisionID: "d1", episodeID: "e2", kind: "suitable")
        require(store.state.effectiveEvidence(trackID: "1")["fit"] == 1,
            "correcting feedback in one episode does not manufacture an additional observation")
        require(store.state.model.acceptance.updates == 0 && store.state.model.rejection.updates == 0,
            "v2 observations cannot alter historical soft-label heads")
        require(store.state.model.affinity.updates == 0, "listening and contextual fit do not mean liking")
        let restored = AdaptiveDecisionStore(fileURL: url)
        require(restored.state.episodeCount == store.state.episodeCount, "counts must survive relaunch")
        require(restored.state.model.continuation.weights == store.state.model.continuation.weights, "learned weights must survive relaunch")
        try restored.recordEpisode(episode("e1"))
        require(restored.state.episodeCount == store.state.episodeCount, "relaunch must preserve idempotency")
        let beforeDiagnosticCounts = restored.state.model.updateCounts
        let beforeDiagnosticCoverage = restored.state.recentCoverage
        let beforeDiagnosticStarts = restored.state.trackStarts
        let beforeDiagnosticLast = restored.state.trackLastStarted
        let beforeDiagnosticSources = restored.state.recentSourceTags
        let beforeDiagnosticEpisodes = restored.state.episodeCount
        let beforeDiagnosticSkips = restored.state.recentSkipRun
        let diagnosticStarted = PlaybackAction(kind: "started", at: now, position: 0, targetPosition: nil, source: "diagnostic")
        try restored.recordAction(diagnosticStarted, trackID: "1", decisionID: "d1", episodeID: "diagnostic")
        try restored.recordEpisode(episode("diagnostic", end: "natural_end", seconds: 200, covered: 200, start: "diagnostic"))
        require(restored.state.model.updateCounts == beforeDiagnosticCounts && restored.state.recentCoverage == beforeDiagnosticCoverage,
            "diagnostic completion cannot train or alter session coverage")
        require(restored.state.trackStarts == beforeDiagnosticStarts && restored.state.trackLastStarted == beforeDiagnosticLast && restored.state.recentSourceTags == beforeDiagnosticSources,
            "diagnostic starts cannot change recency or source adaptation")
        require(restored.state.episodeCount == beforeDiagnosticEpisodes && restored.state.recentSkipRun == beforeDiagnosticSkips,
            "diagnostic playback cannot change real session counters")
        require(restored.state.episodes.last?.id == "diagnostic" && restored.state.journal.last?.action?.id == diagnosticStarted.id,
            "diagnostic evidence must still be available for audit")
        // Simulate a v1 archive without the new fields, retain its original model and data.
        var legacyState = AdaptiveLearningState()
        legacyState.model.acceptance.weights = ["legacy": 1.23]
        legacyState.model.acceptance.updates = 99
        legacyState.episodes = [episode("old-raw")]
        legacyState.decisions = store.state.decisions
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyState)) as! [String: Any]
        var legacyModel = legacyJSON["model"] as! [String: Any]
        for key in ["continuation", "fit", "labelVersion"] { legacyModel.removeValue(forKey: key) }
        legacyJSON["model"] = legacyModel
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyURL)
        let migrated = AdaptiveDecisionStore(fileURL: legacyURL)
        require(migrated.isReady && migrated.state.model.acceptance.weights["legacy"] == 1.23,
            "migration must preserve historical labels and weights")
        require(migrated.state.model.continuation.updates == 0 && migrated.state.model.fit.updates == 0,
            "new observed objectives start clean rather than reuse old soft targets")
        require(migrated.state.episodes.map(\.id) == ["old-raw"] && migrated.state.decisions.count == legacyState.decisions.count,
            "migration must retain original raw observations and decisions")
        require(FileManager.default.fileExists(atPath: legacyURL.path), "migration keeps recovery archive")
        print("Adaptive preference checks passed: contextual learning, probabilities, observation quality, idempotency, failure isolation and persistence")
    }
}
