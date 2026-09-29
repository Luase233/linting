import Foundation

@main
enum TempoEstimatorChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func clickTrack(bpm: Double, sampleRate: Double = 8_000, seconds: Double = 30) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { index in
            let time = Double(index) / sampleRate
            let phase = time.truncatingRemainder(dividingBy: 60 / bpm)
            let pulse = phase < 0.045 ? exp(-phase * 90) * sin(2 * .pi * 950 * phase) : 0
            return Float(pulse * 0.85 + sin(time * 2 * .pi * 220) * 0.01)
        }
    }

    static func main() throws {
        for bpm in [60.0, 72, 90, 100, 120, 137, 160, 180] {
            let result = TempoEstimator.estimate(samples: clickTrack(bpm: bpm), sampleRate: 8_000)
            require(result != nil, "Missing measurement for \(bpm) BPM")
            require(abs(result!.bpm - bpm) < 2, "Expected \(bpm), received \(result!.bpm)")
            require(result!.confidence >= 0.35 && result!.confidence <= 0.92, "Invalid confidence")
            print("\(bpm) BPM → \(result!.bpm), confidence \(String(format: "%.2f", result!.confidence))")
        }
        require(TempoEstimator.estimate(samples: [Float](repeating: 0, count: 240_000), sampleRate: 8_000) == nil,
            "Silence must remain unknown")
        require(TempoEstimator.estimate(samples: clickTrack(bpm: 120, seconds: 5), sampleRate: 8_000) == nil,
            "Short audio must remain unknown")
        let tone = (0..<240_000).map { Float(sin(Double($0) / 8_000 * 2 * .pi * 200) * 0.2) }
        require(TempoEstimator.estimate(samples: tone, sampleRate: 8_000) == nil,
            "A sustained tone is not a beat")
        for sampleRate in [8_000.0, 22_050, 44_100] {
            for frequency in [55.0, 73.5, 173.123, 220.7, 440.99, 1_000.3] {
                let carrier = (0..<Int(sampleRate * 20)).map {
                    Float(sin(Double($0) / sampleRate * 2 * .pi * frequency) * 0.2)
                }
                require(TempoEstimator.estimate(samples: carrier, sampleRate: sampleRate) == nil,
                    "Carrier/block aliasing is not musical tempo: \(frequency) Hz at \(sampleRate) Hz")
            }
        }
        var seed: UInt64 = 24
        let noise: [Float] = (0..<240_000).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) * 2 - 1) * 0.4
        }
        require(TempoEstimator.estimate(samples: noise, sampleRate: 8_000) == nil,
            "Uncorrelated noise must remain unknown")
        require(TempoEstimator.estimate(samples: tone, sampleRate: .nan) == nil, "Invalid sample rate")
        let windows = TempoEstimator.sampleWindows(duration: 240)
        require(windows.map(\.lowerBound) == [24, 108, 192], "Distributed windows should span the recording")
        require(TempoEstimator.sampleWindows(duration: 10).isEmpty, "Insufficient resource")
        require(TempoEstimator.sampleWindows(duration: 30).count == 2, "Short resources cannot fake three independent windows")
        func segment(_ bpm: Double, _ start: Double, confidence: Double = 0.9) -> TempoEstimator.SegmentEstimate {
            .init(startSeconds: start, endSeconds: start + 24, bpm: bpm, confidence: confidence, rhythmicStrength: 0.8)
        }
        let consistent = TempoEstimator.combine([segment(120, 24), segment(121, 108), segment(119, 192)], resourceDuration: 240, expectedDuration: 240)
        require(abs((consistent.bpm ?? 0) - 120) < 1 && consistent.status == "complete", "Weighted agreement")
        let ambiguous = TempoEstimator.combine([segment(60, 24), segment(120, 108), segment(120, 192)], resourceDuration: 240, expectedDuration: 240)
        require(ambiguous.bpm == 120 && ambiguous.halfDoubleAmbiguity && ambiguous.confidence < consistent.confidence,
            "Half/double-time agreement must be explicit and lower confidence")
        let conflicting = TempoEstimator.combine([segment(90, 24), segment(120, 108), segment(160, 192)], resourceDuration: 240)
        require(conflicting.bpm == nil && conflicting.status == "inconsistent", "Do not average incompatible tempi")
        let weakOutlier = TempoEstimator.combine([segment(120, 24), segment(120, 108), segment(170, 192, confidence: 0.36)], resourceDuration: 240)
        require(weakOutlier.bpm == 120 && weakOutlier.confidence < consistent.confidence, "Weight weak outlier without pretending unanimity")
        require(weakOutlier.status == "resource_only", "Unknown catalog duration must not assert complete-song coverage")
        let measured = AdaptivePreferenceModel.features(context: ["hour.sin": 1],
            music: ["tempo": 0.8, "tempo_confidence": 0.7, "bpm": 180], trackID: "1", artist: "A", sourceTag: "search", known: false)
        require(abs((measured["music.tempo"] ?? 0) - 0.6) < 0.00001, "Measured tempo enters feature vector")
        require(measured["cross.hour.sin*tempo"] != nil && measured["music_confidence.tempo"] == 0.7,
            "Measured tempo and confidence must participate in contextual learning")
        require(measured["music.bpm"] == nil, "Raw BPM must not saturate normalized feature scale")
        let unknown = AdaptivePreferenceModel.features(context: [:], music: [:], trackID: "1", artist: "A", sourceTag: "search", known: false)
        require(unknown["music.tempo"] == nil, "Unknown tempo must not be fabricated")
        for reason in ["manual_search", "manual_playlist"] {
            let now = Date()
            let evidence = PlaybackEvidence(id: reason, decisionID: nil, trackID: "1", startedAt: now, endedAt: now,
                duration: 200, renderedSeconds: 200, uniqueCoveredSeconds: 200, lastPosition: 200,
                startReason: reason, endReason: "natural_end", actions: [], contentKind: "full")
            require(AdaptiveEpisodeTargets.from(evidence).continuation == 1,
                "Intentional search/playlist play must continue learning")
        }
        print("Tempo checks passed: pulse rates, silence, tone, noise, short audio, confidence and manual-choice learning.")
    }
}
