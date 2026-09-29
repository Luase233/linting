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
    static var empty: Self { Self() }

    func visualQuality(at now: Date) -> Double {
        guard let observedAt, confidence.isFinite else { return 0 }
        return min(1, max(0, confidence)) * Self.freshness(observedAt, now: now, lifetime: 24 * 3600)
    }

    func vector(at now: Date, includeVisualIntent: Bool = true) -> [String: Double] {
        var result: [String: Double] = [:]
        let quality = visualQuality(at: now)
        if includeVisualIntent, let visualIntent, visualIntent != .unknown, quality > 0 {
            result["visual_intent." + visualIntent.rawValue] = quality
            result["visual_intent_confirmed"] = confirmed ? 1 : 0
        }
        if selfReportedMood != .unspecified, let observed = moodObservedAt {
            let quality = Self.freshness(observed, now: now, lifetime: 6 * 3600)
            if quality > 0 { result["self_reported_mood." + selfReportedMood.rawValue] = quality }
        }
        if let placeCategory, ["home", "school", "work", "other", "transit"].contains(placeCategory), let observed = placeObservedAt {
            let quality = Self.freshness(observed, now: now, lifetime: 1800)
            if quality > 0 { result["place." + placeCategory] = quality }
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
        case .explore: signal = known ? -1 : 1
        case .unknown: signal = 0
        }
        return (confirmed ? 0.45 : 0.2) * visualQuality(at: now) * min(1, max(-1, signal))
    }

    func moodPrior(music: [String: Double], at now: Date) -> Double {
        guard let moodObservedAt else { return 0 }
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
        return 0.12 * Self.freshness(moodObservedAt, now: now, lifetime: 6 * 3600) * min(1, max(-1, signal))
    }

    private static func centered(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return 2 * min(1, max(0, value)) - 1
    }
    private static func freshness(_ date: Date, now: Date, lifetime: Double) -> Double {
        max(0, 1 - max(0, now.timeIntervalSince(date)) / lifetime)
    }
}
