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
                     kind: String = "unknown", actions: [PlaybackAction] = []) -> PlaybackEvidence {
            PlaybackEvidence(id: id, decisionID: "d1", trackID: "1", startedAt: now, endedAt: now.addingTimeInterval(seconds),
                duration: 200, renderedSeconds: seconds, uniqueCoveredSeconds: covered, lastPosition: 180,
                startReason: "automatic", endReason: end, actions: actions, contentKind: kind)
        }
        let early = AdaptiveEpisodeTargets.from(episode("early"))
        let late = AdaptiveEpisodeTargets.from(episode("late", seconds: 190, covered: 190))
        require(early.rejection != nil && early.confidence > 0, "unknown rendition should still learn observed user skip")
        require(early.skipStrength > late.skipStrength && late.confidence < early.confidence,
            "late fadeout skip must be weaker than early skip")
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
        let count = store.state.model.rejection.updates
        try store.recordEpisode(episode("e1"))
        require(store.state.episodeCount == 1 && store.state.model.rejection.updates == count, "episode must train once")
        try store.recordFeedback(trackID: "1", decisionID: "d1", episodeID: "e2", kind: "unsuitable")
        let unsuitableWeights = store.state.model.rejection.weights
        require(unsuitableWeights["item.1"] == nil && unsuitableWeights["artist.a"] == nil,
            "context unsuitable must not globally punish track or artist")
        let explicitCount = store.state.model.rejection.updates
        try store.recordFeedback(trackID: "1", decisionID: "d1", episodeID: "e2", kind: "unsuitable")
        try store.recordEpisode(episode("e2", end: "context_unsuitable"))
        require(store.state.model.rejection.updates == explicitCount, "explicit feedback and episode cannot double train")
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
        let beforeError = store.state.model.rejection.updates
        try store.recordEpisode(episode("e4", end: "playback_error"))
        require(store.state.model.rejection.updates == beforeError, "error episode cannot change preference")
        let restored = AdaptiveDecisionStore(fileURL: url)
        require(restored.state.episodeCount == store.state.episodeCount, "counts must survive relaunch")
        require(restored.state.model.rejection.weights == store.state.model.rejection.weights, "learned weights must survive relaunch")
        try restored.recordEpisode(episode("e1"))
        require(restored.state.episodeCount == store.state.episodeCount, "relaunch must preserve idempotency")
        print("Adaptive preference checks passed: contextual learning, probabilities, observation quality, idempotency, failure isolation and persistence")
    }
}
