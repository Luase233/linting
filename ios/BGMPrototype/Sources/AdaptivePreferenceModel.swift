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

    var acceptance = Head()
    var rejection = Head()
    var affinity = Head()
    var replay = Head()

    func predictions(_ features: [String: Double]) -> [String: Double] {
        ["acceptance": acceptance.probability(features), "rejection": rejection.probability(features),
         "affinity": affinity.probability(features), "replay": replay.probability(features)]
    }

    var updateCounts: [String: Int] {
        ["acceptance": acceptance.updates, "rejection": rejection.updates,
         "affinity": affinity.updates, "replay": replay.updates]
    }

    func score(_ features: [String: Double]) -> Double {
        RecommendationScoreDefinition.modelContributions(predictions(features)).values.reduce(0, +)
    }

    /// No bare item/artist terms: an unsuitable choice must not become a global dislike.
    static func contextualFeatures(_ features: [String: Double]) -> [String: Double] {
        features.filter { $0.key.hasPrefix("context.") || $0.key.hasPrefix("cross.") }
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
    var acceptance: Double?
    var rejection: Double?
    var replay: Double?
    var confidence: Double = 0
    var acceptanceConfidence: Double? = nil
    var rejectionConfidence: Double? = nil
    var replayConfidence: Double? = nil
    var skipStrength: Double = 0

    func confidence(for head: String) -> Double {
        switch head {
        case "acceptance": return acceptanceConfidence ?? confidence
        case "rejection": return rejectionConfidence ?? confidence
        case "replay": return replayConfidence ?? confidence
        default: return confidence
        }
    }

    static func from(_ evidence: PlaybackEvidence, recentSkipRun: Int = 0) -> AdaptiveEpisodeTargets {
        var result = AdaptiveEpisodeTargets()
        let ending = evidence.endReason.lowercased()
        let unusable = ["error", "failed", "failure", "interrupt", "disconnect", "network", "unavailable", "cancel"]
        guard !unusable.contains(where: { ending.contains($0) }), evidence.renderedSeconds.isFinite,
              evidence.renderedSeconds >= 1, evidence.uniqueCoveredSeconds.isFinite,
              evidence.lastPosition.isFinite else { return result }
        let measuredDuration = evidence.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let duration = max(1, measuredDuration ?? max(evidence.renderedSeconds, evidence.lastPosition))
        let coverage = min(1, max(0, evidence.uniqueCoveredSeconds / duration))
        let skipActions = evidence.actions.filter {
            ["next", "skip", "next_track", "manual_next", "manual_previous", "select_candidate", "select_track"].contains($0.kind)
        }
        let activeSkip = skipActions.contains { $0.source == "app" }
            || (["user_next", "user_selected_other", "skipped", "skip", "manual_next", "selected_other", "next"].contains(ending)
                && !skipActions.contains { ["automatic", "system"].contains($0.source) })
        if activeSkip {
            // Absolute time and fractional coverage both matter. Browsing runs reduce confidence.
            let noveltyJudgement = exp(-evidence.renderedSeconds / 75)
            result.skipStrength = min(1, max(0.05, 0.55 * (1 - coverage) + 0.45 * noveltyJudgement))
            result.rejection = result.skipStrength
            result.acceptance = 1 - result.skipStrength
            result.confidence = 0.65 / (1 + Double(min(5, max(0, recentSkipRun))) * 0.25)
            if evidence.contentKind == "preview" { result.confidence *= 0.35 }
            if evidence.contentKind == "unknown" { result.confidence *= 0.65 }
            if skipActions.contains(where: { $0.source == "remote" }) { result.confidence *= 0.25 }
            if coverage > 0.85 { result.confidence *= 0.35 }
        } else if ["completed", "ended", "natural_end", "track_done"].contains(ending) {
            let activelyStarted = ["manual", "selected", "search", "playlist", "manual_search", "manual_playlist", "replay", "manual_selection", "manual_candidate", "manual_replay", "manual_previous", "user"].contains(evidence.startReason)
            // Automatic completion is an observation, not a positive preference label.
            if activelyStarted && coverage >= 0.5 && evidence.contentKind == "full" {
                result.acceptance = 0.8
                result.rejection = 0.2
                result.confidence = 0.2
            }
        }
        if result.acceptance != nil { result.acceptanceConfidence = result.confidence }
        if result.rejection != nil { result.rejectionConfidence = result.confidence }
        if ["manual_replay", "manual_previous"].contains(evidence.startReason), evidence.renderedSeconds >= 12 {
            result.replay = evidence.startReason == "manual_replay" ? 0.8 : 0.65
            result.replayConfidence = evidence.contentKind == "preview" ? 0.08 : 0.2
            result.confidence = max(result.confidence, result.replayConfidence ?? 0)
        }
        let returns = evidence.actions.filter {
            $0.kind == "seek" && $0.source == "app" &&
            ($0.position ?? 0) - ($0.targetPosition ?? .infinity) >= 3
        }
        // Repeated sections need both a deliberate backward seek and real repeated audio.
        // Merely moving the slider never earns a positive label.
        if !returns.isEmpty, evidence.renderedSeconds - evidence.uniqueCoveredSeconds >= 8 {
            result.replay = max(result.replay ?? 0, 0.75)
            result.replayConfidence = max(result.replayConfidence ?? 0, 0.2)
            result.confidence = max(result.confidence, 0.2)
        }
        return result
    }
}


/// Shared by ranking and explanation. These multipliers are hand-set ranking priorities, not
/// calibrated likelihood weights; heads can be correlated and priors intentionally add to them.
/// This relative utility is not a probability. The explicit risk deduction is algebraically
/// identical to the historic centered formula, so stored weights and rankings remain comparable.
enum RecommendationScoreDefinition {
    static let temperature = 0.55
    static let exploration = 0.08
    static let baseline = -1.45
    static let modelKeys: Set<String> = ["acceptance", "rejection", "affinity", "replay", "baseline"]

    static func modelContributions(_ predictions: [String: Double]) -> [String: Double] {
        func tendency(_ key: String) -> Double {
            guard let value = predictions[key], value.isFinite else { return 0.5 }
            return min(1, max(0, value))
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
