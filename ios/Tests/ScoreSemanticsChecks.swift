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
        require(abs(probabilities.reduce(0, +) - 1) < 1e-12 && probabilities.allSatisfy { $0 >= 0 },
            "softmax helper must normalize without uniform exploration by default")
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
        require(completed.continuation == 1 && completed.acceptance == nil && completed.rejection == nil && completed.confidence == 1,
            "manual completion supplies observed continuation independently of old soft targets")
        require(AdaptiveEpisodeTargets.from(evidence("manual_search", "natural_end", "preview", 30)).acceptance == nil,
            "preview ending cannot earn full-song completion evidence")
        let automatic = AdaptiveEpisodeTargets.from(evidence("automatic", "natural_end", "full", 200))
        require(automatic.continuation == 1 && automatic.acceptance == nil && automatic.rejection == nil,
            "automatic playback supplies observed continuation without inferring liking or fit")
        require(AdaptiveEpisodeTargets.from(evidence("manual_replay", "user_next", "full", 2)).replay == nil,
            "a replay click without real repeat listening cannot earn replay reward")
        let repeatedThenSkipped = AdaptiveEpisodeTargets.from(evidence("manual_replay", "user_next", "full", 15))
        require(repeatedThenSkipped.replay != nil,
            "deliberate replay with actual listening should finally reach the replay head")
        require(repeatedThenSkipped.confidence(for: "replay") <= 0.2 && repeatedThenSkipped.confidence > 0.2,
            "stronger skip evidence must not inflate a weak replay reward")
        require(AdaptiveEpisodeTargets.from(evidence("automatic", "user_next", "full", 15, source: "system")).confidence == 0,
            "diagnostic/system switching must not teach dislike")

        for start in ["diagnostic", "system", "device_smoke"] {
            let diagnostic = AdaptiveEpisodeTargets.from(evidence(start, "natural_end", "full", 200))
            require(diagnostic.continuation == nil && diagnostic.replay == nil && diagnostic.confidence == 0,
                "diagnostic natural completion cannot teach a preference or continuation target")
        }
        for kind in ["preview", "unknown"] {
            let censored = AdaptiveEpisodeTargets.from(evidence("automatic", "natural_end", kind, 200))
            require(censored.continuation == nil && censored.confidence == 0 && censored.censorReason != nil,
                "incomplete/unknown renditions remain censored even after long playback")
        }
        require(AdaptiveEpisodeTargets.from(evidence("automatic", "playback_error", "full", 120)).continuation == nil,
            "a failure cannot receive a positive or negative preference target")
        require(AdaptiveEpisodeTargets.from(evidence("automatic", "user_next", "full", 59.9)).continuation == 0,
            "below the fixed observation window an explicit skip is negative")
        require(AdaptiveEpisodeTargets.from(evidence("automatic", "user_next", "full", 60)).continuation == 1,
            "the exact completed window is positive")
        require(AdaptiveEpisodeTargets.from(evidence("automatic", "unknown", "full", 120)).continuation == nil,
            "unknown recovery endpoints are censored")
        let itemA = AdaptivePreferenceModel.features(context: ["place.home": 1], music: [:], trackID: "song-a", artist: "A", sourceTag: "same", known: false)
        let itemB = AdaptivePreferenceModel.features(context: ["place.home": 1], music: [:], trackID: "song-b", artist: "A", sourceTag: "same", known: false)
        var fitModel = AdaptivePreferenceModel()
        fitModel.fit.update(features: AdaptivePreferenceModel.fitFeatures(itemA), target: 0, confidence: 1)
        require(fitModel.fit.probability(AdaptivePreferenceModel.fitFeatures(itemA)) < 0.5 && fitModel.fit.probability(AdaptivePreferenceModel.fitFeatures(itemB)) == 0.5,
            "one unsuitable track cannot lower every song from its source or artist")
        require(fitModel.fit.weights.keys.allSatisfy { $0.hasPrefix("item_context.") }, "fit gradients must be item-context only")
        let newNeutral = ["continuation": 0.5, "fit": 0.5, "affinity": 0.5, "replay": 0.5]
        require(RecommendationScoreDefinition.modelContributions(newNeutral).values.reduce(0, +) == 0, "new untrained heads are neutral")
        require(RecommendationScoreDefinition.modelContributions(newNeutral)["acceptance"] == nil, "new scores cannot reuse old target semantics")

        let policyCandidates = (0..<200).map { index in
            RecommendationExplorationPolicy.Candidate(score: index < 6 ? 1 - Double(index) * 0.1 : -10, evidenceCount: 0, interestRelated: index != 4)
        }
        let policy = RecommendationExplorationPolicy.distribution(candidates: policyCandidates, discovery: 1, recentSkipRun: 0)
        require(abs(policy.probabilities.reduce(0, +) - 1) < 1e-12 && policy.explorationBudget == 0.1, "bounded distribution must normalize")
        require(policy.probabilities.dropFirst(6).allSatisfy { $0 == 0 } && policy.probabilities[4] == 0,
            "hundreds of low-quality or unrelated tracks cannot gain aggregate exploration mass")
        require(zip(policy.mainProbabilities, policy.explorationProbabilities).allSatisfy { $0 == 0 || $1 == 0 }, "pools are disjoint and logged role is unambiguous")
        require(zip(policy.probabilities, zip(policy.mainProbabilities, policy.explorationProbabilities)).allSatisfy { abs($0 - $1.0 - $1.1) < 1e-12 }, "probability components must reconcile")
        for skipRun in [1, 2, 3, 8] {
            let tightened = RecommendationExplorationPolicy.distribution(candidates: policyCandidates, discovery: 1, recentSkipRun: skipRun)
            require(tightened.explorationBudget < policy.explorationBudget, "early-skip run must tighten exploration")
            if skipRun >= 3 { require(tightened.explorationBudget == 0, "three consecutive early skips suspend exploration") }
        }
        require(RecommendationExplorationPolicy.distribution(candidates: policyCandidates, discovery: 0, recentSkipRun: 0).explorationBudget == 0, "zero discovery means no exploration")
        var policyObserved = [Int](repeating: 0, count: policyCandidates.count)
        for index in 0..<10000 { policyObserved[AdaptivePreferenceModel.sampledIndex(probabilities: policy.probabilities, uniform: (Double(index) + 0.5) / 10000)] += 1 }
        require(zip(policyObserved, policy.probabilities).allSatisfy { abs(Double($0) / 10000 - $1) <= 0.00011 }, "gated sampling must match logged probabilities exactly")

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
