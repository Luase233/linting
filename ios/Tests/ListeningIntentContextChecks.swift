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
        require(abs(context.visualQuality(at: now.addingTimeInterval(900)) - 0.35) < 0.0001,
            "unconfirmed short activity must lose half of its weight within 15 minutes")
        require(context.visualQuality(at: now.addingTimeInterval(1800)) == 0,
            "photo retention must not keep an activity hypothesis alive for 24 hours")
        require(context.visualQuality(at: now.addingTimeInterval(-60)) == 0,
            "future-dated observations must not become fresh evidence")
        context.confirmed = true
        require(context.visualPrior(selection: .auto, music: quiet, known: false, at: now) > quietScore,
            "a listener confirmation must carry more weight than the same image hypothesis")
        require(context.visualPrior(selection: .auto, music: quiet, known: false, at: now.addingTimeInterval(86400)) == 0,
            "expired images must not steer the next recommendation")
        require(context.visualQuality(at: now.addingTimeInterval(3600)) > 0 && context.visualQuality(at: now.addingTimeInterval(7200)) == 0,
            "confirmation lasts longer than a guess, but remains session scoped")
        context.visualIntent = .explore
        require(context.visualPrior(selection: .auto, music: [:], known: false, at: now) == 0 && context.visualPrior(selection: .auto, music: [:], known: true, at: now) == 0,
            "exploration must use its single bounded selection budget instead of an extra novelty score")
        require(context.vector(at: now).keys.allSatisfy { !$0.hasPrefix("self_reported_mood.") },
            "visual context must never invent a self-reported mood")
        context.selfReportedMood = .lowEnergy; context.moodObservedAt = now
        require(context.moodPrior(music: quiet, at: now) > context.moodPrior(music: busy, at: now),
            "a deliberate low-energy report must affect scoring immediately")
        require(context.moodPrior(music: quiet, at: now.addingTimeInterval(21600)) == 0,
            "old self-reports must decay rather than become permanent labels")
        context.placeCategory = "home"; context.placeObservedAt = now; context.placeConfidence = 1
        require(context.vector(at: now)["place.home"] == 1, "fresh user-defined place category must enter the context")
        context.placeConfidence = 0.2
        require(context.vector(at: now)["place.home"] == 0.2, "location quality must actually reach the scoring vector")
        require(abs((context.vector(at: now.addingTimeInterval(450))["place.home"] ?? -1) - 0.1) < 0.0001,
            "place evidence must multiply quality by freshness")
        require(context.vector(at: now.addingTimeInterval(900))["place.home"] == nil, "stale place must disappear")
        context.placeCategory = "transit"
        require(context.vector(at: now.addingTimeInterval(300))["place.transit"] == nil, "travel expires earlier than a saved place")
        context.placeConfidence = .nan
        require(context.vector(at: now)["place.transit"] == nil, "invalid quality must not poison model features")
        context.placeCategory = "private arbitrary address"
        require(context.vector(at: now).keys.allSatisfy { !$0.hasPrefix("place.") }, "free-form addresses must never become model features")

        var moved = RecommendationListeningContext(visualIntent: .focus, confidence: 0.8, observedAt: now,
            placeCategory: "transit", placeObservedAt: now.addingTimeInterval(60), placeConfidence: 0.8,
            visualPlaceCategory: "home", visualPlaceObservedAt: now, visualIncludesPlaceEvidence: true,
            contextChangedAt: now.addingTimeInterval(60))
        let later = now.addingTimeInterval(61)
        require(moved.visualQuality(at: later) == 0, "a reliable observed move must invalidate the earlier image guess")
        require(moved.sceneQuality(confidence: 0.8, observedAt: now, at: later) == 0,
            "a moved image scene must not survive through the other scene feature path")
        moved.contextChangedAt = nil
        require(moved.visualQuality(at: later) == 0, "semantic provenance protects without in-memory transition history")
        moved.placeConfidence = 0.1
        require(moved.visualQuality(at: later) > 0, "a weak location cannot overturn otherwise fresh evidence")
        moved.contextChangedAt = now.addingTimeInterval(60)
        moved.confirmed = true
        require(moved.visualQuality(at: later) > 0, "observed movement must not overwrite a listener's explicit intent")
        moved.confirmed = false; moved.visualSource = .userReport
        require(moved.visualQuality(at: later) > 0, "a direct user report must not be demoted to an image guess")
        moved.visualSource = .visualHypothesis; moved.contextChangedAt = nil; moved.placeCategory = "home"
        moved.selfReportedMood = .lowEnergy; moved.moodObservedAt = later
        require(moved.visualQuality(at: later) == 0 && moved.moodPrior(music: quiet, at: later) > 0,
            "self-report must take priority over contradictory unconfirmed image intent")

        var shared = RecommendationListeningContext(visualIntent: .focus, confidence: 0.8, observedAt: now,
            placeCategory: "home", placeObservedAt: now, placeConfidence: 0.9,
            visualPlaceCategory: "home", visualPlaceObservedAt: now, visualIncludesPlaceEvidence: true)
        require(shared.usesSharedPlaceEvidence(at: now), "remember that location was already sent with this image")
        require(shared.vector(at: now)["place.home"] == nil && shared.vector(at: now)["visual_intent.focus"] != nil,
            "shared place and photo inputs must not be counted as independent evidence")
        require(shared.vector(at: now, includeVisualIntent: false)["place.home"] == 0.9,
            "if no image signal is used, place evidence must remain available")
        require(shared.vector(at: now, includeVisualIntent: false, includeSceneEvidence: true)["place.home"] == nil,
            "a scene-only image can also consume the same place evidence")
        shared.visualIncludesPlaceEvidence = false
        require(shared.vector(at: now)["place.home"] == 0.9, "independently obtained place evidence is available")
        print("Listening intent checks passed: short activity freshness, location quality, movement invalidation, explicit priority and shared-evidence handling")
    }
}
