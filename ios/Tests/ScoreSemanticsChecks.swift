import Foundation

@main struct ScoreSemanticsChecks {
    static func main() throws {
        func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let keys = ["acceptance", "rejection", "affinity", "replay"]
        let neutral = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0.5) })
        require(abs(RecommendationScoreDefinition.modelContributions(neutral).values.reduce(0, +)) < 1e-12,
            "neutral predictions must sum to zero after baseline correction")
        for i in 0...100 {
            let r = Double(i) / 100
            let p = ["acceptance": 0.63, "rejection": r, "affinity": 0.44, "replay": 0.72]
            let old = 2.4 * (0.63 - 0.5) - 3 * (r - 0.5) + 2 * (0.44 - 0.5) + 1.5 * (0.72 - 0.5)
            let contributions = RecommendationScoreDefinition.modelContributions(p)
            require(abs(contributions.values.reduce(0, +) - old) < 1e-12, "readable formula must preserve historical ordering and scores")
            require((contributions["rejection"] ?? 1) <= 0, "risk must always be represented as a penalty")
            if i > 0 {
                var previous = p; previous["rejection"] = r - 0.01
                require(contributions.values.reduce(0, +) < RecommendationScoreDefinition.modelContributions(previous).values.reduce(0, +),
                    "increasing risk must strictly lower the final score")
            }
        }
        let legacyPredictions = ["acceptance": 0.3, "rejection": 0.8, "affinity": 0.6, "replay": 0.5]
        let historical = ["rejection": -0.9, "acceptance": -0.48, "affinity": 0.2, "replay": 0, "favorite": 0.75]
        let legacyScore = historical.values.reduce(0, +)
        let reexpressed = RecommendationScoreDefinition.explanationFactors(score: legacyScore,
            predictions: legacyPredictions, storedFactors: historical)
        require(abs(reexpressed.values.reduce(0, +) - legacyScore) < 1e-12,
            "old snapshots must reconcile without changing stored scores")
        require(abs((reexpressed["rejection"] ?? 0) + 2.4) < 1e-12, "legacy risk must be reexpressed using the raw negative coefficient")
        let unrecorded = RecommendationScoreDefinition.explanationFactors(score: 1.234, predictions: neutral, storedFactors: nil)
        require(abs(unrecorded.values.reduce(0, +) - 1.234) < 1e-12 && unrecorded["historical_remainder"] != nil,
            "missing historic detail must remain explicit and still reconcile")

        let scores = [-2.0, 0.1, 1.2, 0.5]
        let probabilities = AdaptivePreferenceModel.softmax(scores)
        let shifted = AdaptivePreferenceModel.softmax(scores.map { $0 + 100 })
        require(abs(probabilities.reduce(0, +) - 1) < 1e-12 && probabilities.allSatisfy { $0 >= 0.08 / 4 },
            "exploration distribution must sum to one and include every candidate")
        require(zip(probabilities, shifted).allSatisfy { abs($0 - $1) < 1e-12 }, "baseline offsets cannot change sampling probability")
        var observed = [Int](repeating: 0, count: 4)
        for i in 0..<10_000 {
            observed[AdaptivePreferenceModel.sampledIndex(probabilities: probabilities, uniform: (Double(i) + 0.5) / 10_000)] += 1
        }
        require(zip(observed, probabilities).allSatisfy { abs(Double($0) / 10_000 - $1) <= 0.00011 },
            "the sampler must actually implement the logged distribution")
        require(AdaptivePreferenceModel.sampledIndex(probabilities: [0, 1, 0], uniform: 0) == 1,
            "zero-probability candidates cannot be selected at a boundary")
        require(AdaptivePreferenceModel.softmax([.nan, .infinity, -.infinity]).allSatisfy(\.isFinite),
            "invalid model output must not corrupt the candidate distribution")

        var head = AdaptivePreferenceModel.Head(weights: ["item.1": 4], updates: 0)
        let features = ["item.1": 1.0, "context.intent.auto": 1.0]
        let before = head.probability(features)
        head.updateContextually(features: features, target: 1, confidence: 1)
        require(head.weights["item.1"] == 4, "a contextual correction must not change global song identity")
        require(head.probability(features) > before && (head.weights["context.intent.auto"] ?? 1) < 0.02,
            "contextual gradients must use the real full-vector residual, not a masked prediction")
        let updates = head.updates
        head.update(features: ["bad": .nan], target: 1, confidence: 1)
        head.update(features: features, target: .nan, confidence: 1)
        require(head.updates == updates && head.probability(["bad": .nan]).isFinite,
            "nonfinite observations cannot become training updates")

        require(PlaybackRenditionClassifier.kind(catalogDuration: 240, mediaDuration: 239) == "full", "matched resource duration should confirm a full rendition")
        require(PlaybackRenditionClassifier.kind(catalogDuration: 240, mediaDuration: 30) == "preview", "30-second previews must not count as full-song completion")
        require(PlaybackRenditionClassifier.kind(catalogDuration: nil, mediaDuration: 30) == "unknown", "unknown catalog length cannot be guessed")
        let now = Date()
        func evidence(_ start: String, _ end: String, _ kind: String, _ seconds: Double, source: String? = nil) -> PlaybackEvidence {
            let actions = source.map { [PlaybackAction(kind: "manual_next", at: now, position: seconds, targetPosition: nil, source: $0)] } ?? []
            return PlaybackEvidence(id: UUID().uuidString, decisionID: nil, trackID: "1", startedAt: now,
                endedAt: now.addingTimeInterval(seconds), duration: 200, renderedSeconds: seconds,
                uniqueCoveredSeconds: seconds, lastPosition: seconds, startReason: start,
                endReason: end, actions: actions, contentKind: kind)
        }
        let completed = AdaptiveEpisodeTargets.from(evidence("manual_search", "natural_end", "full", 200))
        require(completed.acceptance == 0.8 && completed.rejection == 0.2 && completed.confidence == 0.2,
            "verified manual completion supplies weak continuation and low-rejection evidence")
        require(AdaptiveEpisodeTargets.from(evidence("manual_search", "natural_end", "preview", 30)).acceptance == nil,
            "preview ending cannot earn full-song completion evidence")
        let automatic = AdaptiveEpisodeTargets.from(evidence("automatic", "natural_end", "full", 200))
        require(automatic.acceptance == nil && automatic.rejection == nil,
            "unattended automatic completion remains an observation, not an inferred preference")
        require(AdaptiveEpisodeTargets.from(evidence("manual_replay", "user_next", "full", 2)).replay == nil,
            "a replay click without real repeat listening cannot earn replay reward")
        let repeatedThenSkipped = AdaptiveEpisodeTargets.from(evidence("manual_replay", "user_next", "full", 15))
        require(repeatedThenSkipped.replay != nil,
            "deliberate replay with actual listening should finally reach the replay head")
        require(repeatedThenSkipped.confidence(for: "replay") <= 0.2 && repeatedThenSkipped.confidence > 0.2,
            "stronger skip evidence must not inflate a weak replay reward")
        require(AdaptiveEpisodeTargets.from(evidence("automatic", "user_next", "full", 15, source: "system")).confidence == 0,
            "diagnostic/system switching must not teach dislike")

        struct LegacyRow: Decodable { let score: Double; let predictions: [String: Double]; let scoreFactors: [String: Double]? }
        if CommandLine.arguments.count > 1 {
            let rows = try JSONDecoder().decode([LegacyRow].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            for row in rows {
                let factors = RecommendationScoreDefinition.explanationFactors(score: row.score, predictions: row.predictions, storedFactors: row.scoreFactors)
                require(abs(factors.values.reduce(0, +) - row.score) < 1e-9, "actual device snapshot explanation must exactly reconcile")
                require((factors["rejection"] ?? 0) <= 0, "actual device snapshot risk must display as a deduction")
            }
            print("Reconciled \(rows.count) historical device candidate scores without rewriting any snapshot")
        }
        print("Score semantics checks passed: monotonic directions, preserved baseline, truthful sampling, contextual gradients, real-listening targets and historical reconciliation")
    }
}
