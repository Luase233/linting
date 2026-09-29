import Foundation

/// Small, regularized online heads. The targets are observed listening choices, not emotion labels.
struct AdaptivePreferenceModel: Codable {
    struct Head: Codable {
        var weights: [String: Double] = [:]
        var updates = 0

        func probability(_ features: [String: Double]) -> Double {
            let value = features.reduce(0.0) { total, feature in
                guard feature.value.isFinite else { return total }
                let weight = weights[feature.key] ?? 0
                return total + (weight.isFinite ? weight : 0) * min(3, max(-3, feature.value))
            }
            return 1 / (1 + exp(-min(20, max(-20, value))))
        }

        mutating func update(features: [String: Double], target: Double, confidence: Double,
                             updatingKeys: Set<String>? = nil) {
            guard confidence.isFinite, confidence > 0, target.isFinite else { return }
            let clean = Self.clean(features)
            let gradient = clean.filter { updatingKeys?.contains($0.key) ?? true }
            guard !gradient.isEmpty else { return }
            // Predict with the same full feature vector used at recommendation time. A contextual
            // correction restricts which weights change, not which prediction supplies its residual.
            let residual = min(1, max(0, target)) - probability(clean)
            let norm = max(1, sqrt(gradient.values.reduce(0) { $0 + $1 * $1 }))
            let learningRate = 0.45 / sqrt(1 + Double(max(0, updates)) / 80)
            for (key, value) in gradient {
                let previous = weights[key] ?? 0
                let old = previous.isFinite ? previous : 0
                weights[key] = min(4, max(-4, old * 0.999 + learningRate * min(1, confidence) * residual * value / norm))
            }
            updates += 1
        }

        mutating func updateContextually(features: [String: Double], target: Double, confidence: Double) {
            update(features: features, target: target, confidence: confidence,
                updatingKeys: Set(AdaptivePreferenceModel.contextualFeatures(features).keys))
        }

        private static func clean(_ features: [String: Double]) -> [String: Double] {
            features.filter { $0.value.isFinite }.mapValues { min(3, max(-3, $0)) }
        }
    }

    static let targetVersion = "observed-listening-fit-v2"
    // Legacy soft-label heads remain readable for audit; never train them with v2 labels.
    var acceptance = Head()
    var rejection = Head()
    var affinity = Head()
    var replay = Head()
    var continuation = Head()
    var fit = Head()
    var labelVersion = Self.targetVersion

    init() {}
    private enum CodingKeys: String, CodingKey { case acceptance, rejection, affinity, replay, continuation, fit, labelVersion }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        acceptance = try values.decodeIfPresent(Head.self, forKey: .acceptance) ?? Head()
        rejection = try values.decodeIfPresent(Head.self, forKey: .rejection) ?? Head()
        affinity = try values.decodeIfPresent(Head.self, forKey: .affinity) ?? Head()
        replay = try values.decodeIfPresent(Head.self, forKey: .replay) ?? Head()
        // v1 had no definition-compatible observations for these targets. Start fresh instead of
        // relabeling old acceptance/rejection weights or reconstructing missing context.
        continuation = try values.decodeIfPresent(Head.self, forKey: .continuation) ?? Head()
        fit = try values.decodeIfPresent(Head.self, forKey: .fit) ?? Head()
        labelVersion = try values.decodeIfPresent(String.self, forKey: .labelVersion) ?? Self.targetVersion
    }

    func predictions(_ features: [String: Double]) -> [String: Double] {
        ["acceptance": acceptance.probability(features), "rejection": rejection.probability(features),
         "affinity": affinity.probability(features), "replay": replay.probability(features),
         "continuation": continuation.probability(features), "fit": fit.probability(Self.fitFeatures(features))]
    }

    var updateCounts: [String: Int] {
        ["acceptance": acceptance.updates, "rejection": rejection.updates,
         "affinity": affinity.updates, "replay": replay.updates,
         "continuation": continuation.updates, "fit": fit.updates]
    }

    func score(_ features: [String: Double]) -> Double {
        RecommendationScoreDefinition.modelContributions(predictions(features)).values.reduce(0, +)
    }

    /// No bare item/artist terms: an unsuitable choice must not become a global dislike.
    static func contextualFeatures(_ features: [String: Double]) -> [String: Double] {
        features.filter { $0.key.hasPrefix("context.") || $0.key.hasPrefix("cross.") }
    }

    /// Fit feedback is item-specific in its current context. No source-wide or artist-wide
    /// gradient is allowed. A fixed 4096-bucket dictionary bounds this interaction head.
    static func fitFeatures(_ features: [String: Double]) -> [String: Double] {
        features.filter { $0.key.hasPrefix("item_context.") }
    }

    private static func interactionBucket(_ text: String) -> Int {
        var value: UInt64 = 14695981039346656037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return Int(value % 4096)
    }

    static func features(context: [String: Double], music: [String: Double], trackID: String,
                         artist: String, sourceTag: String, known: Bool) -> [String: Double] {
        var result: [String: Double] = ["bias": 1, "item." + trackID: 1,
            "artist." + artist.lowercased(): 1, "source." + sourceTag: 0.5, "known": known ? 1 : 0]
        let cleanContext = context.filter { $0.value.isFinite }
        for (key, value) in cleanContext { result["context." + key] = min(3, max(-3, value)) }
        for key in ["energy", "valence", "vocalness", "rhythmic_strength", "attention_demand", "tempo"] {
            guard let raw = music[key], raw.isFinite else { continue }
            let value = 2 * min(1, max(0, raw)) - 1
            result["music." + key] = value
            result["music_known." + key] = 1
            for (contextKey, contextValue) in cleanContext {
                result["cross." + contextKey + "*" + key] = min(3, max(-3, contextValue)) * value
            }
        }
        if let confidence = music["tempo_confidence"], confidence.isFinite, music["tempo"] != nil {
            result["music_confidence.tempo"] = min(1, max(0, confidence))
        }
        for key in cleanContext.keys.sorted().prefix(64) {
            let value = min(3, max(-3, cleanContext[key] ?? 0))
            guard value != 0 else { continue }
            let bucket = "item_context." + String(interactionBucket(trackID + "|" + key))
            result[bucket] = min(3, max(-3, (result[bucket] ?? 0) + value))
        }
        // Recall labels remain uncertain source labels, but can learn contextual fit even before audio analysis.
        for (key, value) in cleanContext { result["cross." + key + "*source." + sourceTag] = value * 0.35 }
        return result
    }

    static func softmax(_ scores: [Double], temperature: Double = RecommendationScoreDefinition.temperature,
                        exploration: Double = RecommendationScoreDefinition.exploration) -> [Double] {
        guard !scores.isEmpty else { return [] }
        // Invalid model output is neutral evidence, never an infinite advantage.
        let clean = scores.map { $0.isFinite ? $0 : 0 }
        let peak = clean.max() ?? 0
        let scale = temperature.isFinite ? max(0.05, temperature) : RecommendationScoreDefinition.temperature
        let weights = clean.map { exp(max(-50, ($0 - peak) / scale)) }
        let total = weights.reduce(0, +)
        let epsilon = exploration.isFinite ? min(1, max(0, exploration)) : RecommendationScoreDefinition.exploration
        return weights.map { (1 - epsilon) * $0 / total + epsilon / Double(scores.count) }
    }

    static func sampledIndex(probabilities: [Double], uniform: Double) -> Int {
        guard !probabilities.isEmpty else { return 0 }
        let clean = probabilities.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = clean.reduce(0, +)
        let unit = uniform.isFinite ? min(1.nextDown, max(0, uniform)) : 0.5
        guard total > 0 else { return min(clean.count - 1, Int(unit * Double(clean.count))) }
        let threshold = unit * total
        var cumulative = 0.0
        for (index, probability) in clean.enumerated() {
            cumulative += probability
            if threshold < cumulative { return index }
        }
        return clean.lastIndex(where: { $0 > 0 }) ?? 0
    }

}

struct AdaptiveEpisodeTargets {
    static let observationSeconds = 60.0
    // Kept for source compatibility and old archive explanations, never generated by v2.
    var acceptance: Double? = nil
    var rejection: Double? = nil
    var continuation: Double? = nil
    var replay: Double? = nil
    var confidence: Double = 0
    var replayConfidence: Double? = nil
    var skipStrength: Double = 0
    var censorReason: String? = nil
    let labelVersion = AdaptivePreferenceModel.targetVersion

    func confidence(for head: String) -> Double { head == "replay" ? (replayConfidence ?? confidence) : confidence }

    static func from(_ evidence: PlaybackEvidence, recentSkipRun: Int = 0) -> AdaptiveEpisodeTargets {
        var result = AdaptiveEpisodeTargets()
        let ending = evidence.endReason.lowercased()
        guard !evidence.isDiagnostic else {
            result.censorReason = "diagnostic_playback"; return result
        }
        let unusable = ["error", "failed", "failure", "interrupt", "disconnect", "network", "unavailable", "cancel", "diagnostic", "system"]
        let interrupted = evidence.actions.contains {
            ["interruption", "route_change", "playback_error"].contains($0.kind) && $0.source == "system"
        }
        guard !interrupted, !unusable.contains(where: { ending.contains($0) }) else {
            result.censorReason = "interrupted_or_failed"; return result
        }
        guard evidence.contentKind == "full" else { result.censorReason = "rendition_" + evidence.contentKind; return result }
        guard evidence.renderedSeconds.isFinite, evidence.renderedSeconds >= 0,
              evidence.uniqueCoveredSeconds.isFinite, evidence.uniqueCoveredSeconds >= 0,
              evidence.uniqueCoveredSeconds <= evidence.renderedSeconds + 0.5,
              let duration = evidence.duration, duration.isFinite, duration >= observationSeconds else {
            result.censorReason = "invalid_or_short_observation"; return result
        }
        let switches = evidence.actions.filter {
            ["next", "skip", "next_track", "manual_next", "manual_previous", "select_candidate", "select_track"].contains($0.kind)
        }
        let deliberateSwitch = switches.contains { ["app", "remote"].contains($0.source) }
        let systemSwitch = !switches.isEmpty && !deliberateSwitch
        guard !systemSwitch else { result.censorReason = "system_switch"; return result }
        let skipEnding = ["user_next", "user_selected_other", "skipped", "skip", "manual_next", "selected_other", "next"].contains(ending)
        let activeSkip = skipEnding && (switches.isEmpty || deliberateSwitch)
        let validEnding = activeSkip || ["completed", "ended", "natural_end", "track_done", "manual_replay", "manual_previous", "context_unsuitable"].contains(ending)
        guard validEnding else { result.censorReason = "incomplete_observation"; return result }
        // This target describes audible coverage of a fixed observation window, not attention,
        // liking, or subjective contextual fit. Automatic and manual starts have identical rules.
        if evidence.renderedSeconds >= observationSeconds && evidence.uniqueCoveredSeconds >= observationSeconds {
            result.continuation = 1
            result.confidence = 1
        } else if activeSkip && evidence.renderedSeconds >= 1 {
            result.continuation = 0
            result.confidence = 1 / (1 + Double(min(5, max(0, recentSkipRun))) * 0.25)
            result.skipStrength = 1
        } else { result.censorReason = "window_not_observed" }
        if ["manual_replay", "manual_previous"].contains(evidence.startReason), evidence.renderedSeconds >= 12 {
            result.replay = evidence.startReason == "manual_replay" ? 0.8 : 0.65
            result.replayConfidence = 0.2
        }
        let returns = evidence.actions.filter {
            $0.kind == "seek" && $0.source == "app" && ($0.position ?? 0) - ($0.targetPosition ?? .infinity) >= 3
        }
        if !returns.isEmpty, evidence.renderedSeconds - evidence.uniqueCoveredSeconds >= 8 {
            result.replay = max(result.replay ?? 0, 0.75)
            result.replayConfidence = 0.2
        }
        result.confidence = max(result.confidence, result.replayConfidence ?? 0)
        return result
    }
}

/// Quality-gated, bounded exploration. Probabilities are the only sampling distribution and
/// each candidate belongs to exactly one pool, making a chosen exploration auditable.
enum RecommendationExplorationPolicy {
    struct Candidate {
        let score: Double
        let evidenceCount: Int
        let interestRelated: Bool
    }
    struct Result {
        let probabilities: [Double]
        let explorationEligible: [Bool]
        let explorationBudget: Double
        let mainProbabilities: [Double]
        let explorationProbabilities: [Double]
    }
    static func distribution(candidates: [Candidate], discovery: Double, recentSkipRun: Int) -> Result {
        let count = candidates.count
        var main = [Double](repeating: 0, count: count)
        var exploration = main
        var eligible = [Bool](repeating: false, count: count)
        let ranked = candidates.indices.filter { candidates[$0].score.isFinite }.sorted {
            candidates[$0].score == candidates[$1].score ? $0 < $1 : candidates[$0].score > candidates[$1].score
        }
        guard let first = ranked.first else {
            if count > 0 { main[0] = 1 }
            return Result(probabilities: main, explorationEligible: eligible, explorationBudget: 0,
                          mainProbabilities: main, explorationProbabilities: exploration)
        }
        let peak = candidates[first].score
        let mainPool = Array(ranked.filter { peak - candidates[$0].score <= 0.75 }.prefix(3))
        let mainSet = Set(mainPool)
        let explorePool = Array(ranked.filter {
            !mainSet.contains($0) && peak - candidates[$0].score <= 0.9 &&
            candidates[$0].interestRelated && candidates[$0].evidenceCount < 3
        }.prefix(3))
        let cleanDiscovery = discovery.isFinite ? min(1, max(0, discovery)) : 0
        let budget = explorePool.isEmpty || recentSkipRun >= 3 ? 0 :
            0.1 * cleanDiscovery / (1 + Double(max(0, recentSkipRun)))
        for (index, probability) in zip(mainPool, AdaptivePreferenceModel.softmax(mainPool.map { candidates[$0].score }, temperature: 0.25, exploration: 0)) {
            main[index] = (1 - budget) * probability
        }
        if budget > 0 {
            for (index, probability) in zip(explorePool, AdaptivePreferenceModel.softmax(explorePool.map { candidates[$0].score }, temperature: 0.25, exploration: 0)) {
                exploration[index] = budget * probability; eligible[index] = true
            }
        }
        return Result(probabilities: zip(main, exploration).map(+), explorationEligible: eligible,
                      explorationBudget: budget, mainProbabilities: main, explorationProbabilities: exploration)
    }
}


/// Shared by ranking and explanation. These multipliers are hand-set ranking priorities, not
/// calibrated likelihood weights; heads can be correlated and priors intentionally add to them.
/// This relative utility is not a probability. New-target snapshots use separately defined
/// continuation and explicit fit utilities. Legacy snapshots retain their historical formula.
enum RecommendationScoreDefinition {
    static let temperature = 0.55
    static let exploration = 0.0
    static let baseline = -1.45
    static let modelKeys: Set<String> = ["acceptance", "rejection", "continuation", "fit", "affinity", "replay", "baseline"]

    static func modelContributions(_ predictions: [String: Double]) -> [String: Double] {
        func tendency(_ key: String) -> Double {
            guard let value = predictions[key], value.isFinite else { return 0.5 }
            return min(1, max(0, value))
        }
        if predictions["continuation"] != nil || predictions["fit"] != nil {
            // Centered utilities keep an untrained head neutral. Different measured objectives
            // must never be advertised as calibrated contextual-match probabilities.
            return ["continuation": 1.4 * (tendency("continuation") - 0.5),
                    "fit": 2.4 * (tendency("fit") - 0.5),
                    "affinity": 2 * (tendency("affinity") - 0.5),
                    "replay": 0.8 * (tendency("replay") - 0.5), "baseline": 0]
        }
        return ["acceptance": 2.4 * tendency("acceptance"), "rejection": -3 * tendency("rejection"),
            "affinity": 2 * tendency("affinity"), "replay": 1.5 * tendency("replay"), "baseline": baseline]
    }

    /// Old snapshots keep their original score and predictions. Re-express only the four model
    /// terms; any historical remainder stays visible instead of silently inventing an explanation.
    static func explanationFactors(score: Double, predictions: [String: Double],
                                   storedFactors: [String: Double]?) -> [String: Double] {
        var result = (storedFactors ?? [:]).filter { !modelKeys.contains($0.key) && $0.value.isFinite }
        result.merge(modelContributions(predictions)) { _, value in value }
        let remainder = score - result.values.reduce(0, +)
        if remainder.isFinite, abs(remainder) > 0.00000001 { result["historical_remainder", default: 0] += remainder }
        return result
    }
}

enum PlaybackRenditionClassifier {
    /// Only compare independently supplied catalog and playable-media durations. A 30-second
    /// preview of a long song cannot become a completed full song merely because AVPlayer ended.
    static func kind(catalogDuration: Double?, mediaDuration: Double?) -> String {
        guard let expected = catalogDuration, let actual = mediaDuration,
              expected.isFinite, actual.isFinite, expected > 0, actual > 0 else { return "unknown" }
        if abs(actual - expected) <= max(3, expected * 0.02) { return "full" }
        if expected - actual >= 8, actual < expected * 0.9 { return "preview" }
        return "unknown"
    }
}
