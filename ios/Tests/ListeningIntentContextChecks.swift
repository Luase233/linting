import Foundation

@main struct ListeningIntentContextChecks {
    static func main() {
        func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quiet = ["attention_demand": 0.1, "energy": 0.2, "rhythmic_strength": 0.2]
        let busy = ["attention_demand": 0.9, "energy": 0.8, "rhythmic_strength": 0.9]
        var context = RecommendationListeningContext(visualIntent: .focus, confidence: 0.7, observedAt: now)
        let quietScore = context.visualPrior(selection: .auto, music: quiet, known: false, at: now)
        let busyScore = context.visualPrior(selection: .auto, music: busy, known: false, at: now)
        require(quietScore > busyScore, "focus hypothesis must change relative candidate scores")
        require(abs(quietScore) <= 0.2 * 0.7 && abs(busyScore) <= 0.2 * 0.7,
            "automatic visual hypothesis must remain bounded by confidence")
        require(context.visualPrior(selection: .move, music: quiet, known: false, at: now) == 0,
            "explicit listening mode must override visual intent")
        require(context.vector(at: now, includeVisualIntent: false).keys.allSatisfy { !$0.hasPrefix("visual_intent") },
            "explicit modes must also suppress conflicting inferred-intent model features")
        require(context.visualPrior(selection: .auto, music: [:], known: false, at: now) == 0,
            "missing music evidence must not fabricate intent fit")
        context.confirmed = true
        require(context.visualPrior(selection: .auto, music: quiet, known: false, at: now) > quietScore,
            "a listener confirmation must carry more weight than the same image hypothesis")
        require(context.visualPrior(selection: .auto, music: quiet, known: false, at: now.addingTimeInterval(86400)) == 0,
            "expired images must not steer the next recommendation")
        context.visualIntent = .explore
        require(context.visualPrior(selection: .auto, music: [:], known: false, at: now) > context.visualPrior(selection: .auto, music: [:], known: true, at: now),
            "explore intent must favor previously unheard candidates")
        require(context.vector(at: now).keys.allSatisfy { !$0.hasPrefix("self_reported_mood.") },
            "visual context must never invent a self-reported mood")
        context.selfReportedMood = .lowEnergy; context.moodObservedAt = now
        require(context.moodPrior(music: quiet, at: now) > context.moodPrior(music: busy, at: now),
            "a deliberate low-energy report must affect scoring immediately")
        require(context.moodPrior(music: quiet, at: now.addingTimeInterval(21600)) == 0,
            "old self-reports must decay rather than become permanent labels")
        context.placeCategory = "home"; context.placeObservedAt = now
        require(context.vector(at: now)["place.home"] == 1, "fresh user-defined place category must enter the context")
        context.placeCategory = "private arbitrary address"
        require(context.vector(at: now).keys.allSatisfy { !$0.hasPrefix("place.") }, "free-form addresses must never become model features")
        print("Listening intent checks passed: real score influence, confidence bounds, explicit precedence, expiry, self-report provenance and stable places")
    }
}
