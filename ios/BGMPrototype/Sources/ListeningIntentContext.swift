import Foundation

enum SelfReportedMood: String, Codable, CaseIterable, Identifiable {
    case unspecified, calm, lowEnergy, energetic, tense, lowMood
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unspecified: return "暂不填写"
        case .calm: return "平静"
        case .lowEnergy: return "有点累"
        case .energetic: return "有精神"
        case .tense: return "有点紧绷"
        case .lowMood: return "有点低落"
        }
    }
}

enum InferredIntentPolicy: String, Codable, CaseIterable, Identifiable {
    case automatic, confirmOnly
    var id: String { rawValue }
    var title: String { self == .automatic ? "自动轻量参考" : "确认后再参考" }
}

/// Only declared, stable context categories enter the online model. Notes and image prose do not
/// become feature names; mood is always provided by the listener, never inferred from an image.
struct RecommendationListeningContext {
    var visualIntent: ListeningIntent? = nil
    var confidence = 0.0
    var confirmed = false
    var observedAt: Date? = nil
    var selfReportedMood: SelfReportedMood = .unspecified
    var moodObservedAt: Date? = nil
    var placeCategory: String? = nil
    var placeObservedAt: Date? = nil
    var placeConfidence = 0.0
    var visualSource: SceneEvidenceSource? = nil
    /// Semantic provenance of the location actually supplied to this image request. No coordinates.
    var visualPlaceCategory: String? = nil
    var visualPlaceObservedAt: Date? = nil
    var visualIncludesPlaceEvidence = false
    /// A later observed move/category transition invalidates an earlier visual hypothesis.
    var contextChangedAt: Date? = nil
    static var empty: Self { Self() }

    // Conservative engineering defaults for short-lived activities, not empirically calibrated
    // psychological durations. Photo-cache retention (24 hours) is deliberately unrelated.
    static let inferredVisualLifetime: TimeInterval = 30 * 60
    static let explicitIntentLifetime: TimeInterval = 2 * 3600
    static let reportedMoodLifetime: TimeInterval = 2 * 3600
    static let placeLifetime: TimeInterval = 15 * 60
    static let transitLifetime: TimeInterval = 5 * 60

    var isExplicitIntent: Bool { confirmed || visualSource == .userReport }

    func visualQuality(at now: Date) -> Double {
        guard let observedAt, confidence.isFinite else { return 0 }
        if !isExplicitIntent {
            // A direct report of the listener's current state has priority over an image guess.
            guard moodQuality(at: now) == 0, !visualContextChanged(since: observedAt, at: now) else { return 0 }
        }
        return Self.unit(confidence) * Self.freshness(observedAt, now: now,
            lifetime: isExplicitIntent ? Self.explicitIntentLifetime : Self.inferredVisualLifetime)
    }

    func sceneQuality(confidence: Double, observedAt: Date?, at now: Date) -> Double {
        guard let observedAt, !visualContextChanged(since: observedAt, at: now) else { return 0 }
        return Self.unit(confidence) * Self.freshness(observedAt, now: now, lifetime: Self.inferredVisualLifetime)
    }

    func placeQuality(at now: Date) -> Double {
        guard let placeCategory, Self.placeCategories.contains(placeCategory), let observed = placeObservedAt else { return 0 }
        return Self.unit(placeConfidence) * Self.freshness(observed, now: now,
            lifetime: placeCategory == "transit" ? Self.transitLifetime : Self.placeLifetime)
    }

    func moodQuality(at now: Date) -> Double {
        guard selfReportedMood != .unspecified, let moodObservedAt else { return 0 }
        return Self.freshness(moodObservedAt, now: now, lifetime: Self.reportedMoodLifetime)
    }

    func usesSharedPlaceEvidence(at now: Date, includeVisualIntent: Bool = true,
                                 includeSceneEvidence: Bool = false) -> Bool {
        guard visualIncludesPlaceEvidence, let visualPlaceCategory,
              visualPlaceCategory == placeCategory, let visualPlaceObservedAt,
              Self.freshness(visualPlaceObservedAt, now: now, lifetime: Self.placeLifetime) > 0,
              placeQuality(at: now) > 0 else { return false }
        let inferredIntentActive = includeVisualIntent && !isExplicitIntent && visualIntent != nil &&
            visualIntent != .unknown && visualQuality(at: now) > 0
        // The scene flag must describe a scene feature actually included by the caller.
        return includeSceneEvidence || inferredIntentActive
    }

    func vector(at now: Date, includeVisualIntent: Bool = true, includeSceneEvidence: Bool = false) -> [String: Double] {
        var result: [String: Double] = [:]
        let quality = visualQuality(at: now)
        if includeVisualIntent, let visualIntent, visualIntent != .unknown, quality > 0 {
            result["visual_intent." + visualIntent.rawValue] = quality
            result["visual_intent_confirmed"] = confirmed ? 1 : 0
        }
        let mood = moodQuality(at: now)
        if mood > 0 {
            result["self_reported_mood." + selfReportedMood.rawValue] = mood
        }
        let place = placeQuality(at: now)
        if let placeCategory, place > 0,
           !usesSharedPlaceEvidence(at: now, includeVisualIntent: includeVisualIntent, includeSceneEvidence: includeSceneEvidence) {
            result["place." + placeCategory] = place
        }
        return result
    }

    func visualPrior(selection: ModeSelection, music: [String: Double], known: Bool, at now: Date) -> Double {
        // The listener's explicit mode takes precedence over the visual hypothesis.
        guard selection == .auto, let visualIntent else { return 0 }
        let signal: Double
        switch visualIntent {
        case .focus: signal = -Self.centered(music["attention_demand"])
        case .unwind: signal = -Self.centered(music["energy"])
        case .energize: signal = Self.centered(music["rhythmic_strength"])
        case .accompany:
            signal = -0.75 * Self.centered(music["attention_demand"]) - 0.25 * abs(Self.centered(music["energy"]))
        // Exploration belongs to the bounded selection budget; it must not also award
        // unknown tracks an extra score bonus here.
        case .explore: signal = 0
        case .unknown: signal = 0
        }
        return (isExplicitIntent ? 0.45 : 0.2) * visualQuality(at: now) * min(1, max(-1, signal))
    }

    func moodPrior(music: [String: Double], at now: Date) -> Double {
        let energy = Self.centered(music["energy"])
        let attention = Self.centered(music["attention_demand"])
        let signal: Double
        switch selfReportedMood {
        case .unspecified: signal = 0
        case .calm: signal = -abs(energy)
        case .lowEnergy: signal = -0.5 * attention - 0.5 * energy
        case .energetic: signal = Self.centered(music["rhythmic_strength"])
        case .tense: signal = -0.65 * energy - 0.35 * attention
        case .lowMood: signal = -attention
        }
        // A small, correctable starting preference; low mood never selects sad music by fiat.
        return 0.12 * moodQuality(at: now) * min(1, max(-1, signal))
    }

    private static let placeCategories: Set<String> = ["home", "school", "work", "other", "transit"]

    private func visualContextChanged(since observation: Date, at now: Date) -> Bool {
        if let contextChangedAt, contextChangedAt > observation, contextChangedAt <= now { return true }
        // Also protects callers restoring semantic provenance without a transition history.
        if let visualPlaceCategory, let placeCategory, visualPlaceCategory != placeCategory,
           placeQuality(at: now) >= 0.4, let placeObservedAt, placeObservedAt > observation { return true }
        return false
    }

    private static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    private static func centered(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return 2 * min(1, max(0, value)) - 1
    }
    private static func freshness(_ date: Date, now: Date, lifetime: Double) -> Double {
        let age = now.timeIntervalSince(date)
        guard age.isFinite, age >= -5 else { return 0 }
        return max(0, 1 - max(0, age) / lifetime)
    }
}
