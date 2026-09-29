import Foundation

/// Deterministic audio DSP. No title, lyrics, tags or model output enter this measurement.
/// This measures periodic onsets; half/double-time interpretations remain ambiguous.
enum TempoEstimator {
    static let version = "distributed-onset-consensus-v2"
    static let minimumSeconds = 12.0
    static let maximumSeconds = 45.0

    struct Estimate: Equatable {
        let bpm: Double
        let confidence: Double
        let rhythmicStrength: Double
        let seconds: Double
    }

    struct SegmentEstimate: Codable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
        let bpm: Double?
        let confidence: Double
        let rhythmicStrength: Double?
        var seconds: Double { max(0, endSeconds - startSeconds) }
    }

    struct RecordingEstimate: Codable, Equatable {
        let bpm: Double?
        let confidence: Double
        let rhythmicStrength: Double?
        let segments: [SegmentEstimate]
        let resourceDurationSeconds: Double
        let expectedTrackDurationSeconds: Double?
        let sampledSeconds: Double
        let coverageFraction: Double
        let sampledSpanFraction: Double
        let agreement: Double
        let halfDoubleAmbiguity: Bool
        let scope: String
        let status: String
    }

    /// Windows are measured in decoded time, never guessed from compressed byte offsets.
    /// Short resources are split into non-overlapping >=12s windows; long ones sample
    /// early/middle/late at 15/50/85 percent, with at most 72 seconds decoded in total.
    static func sampleWindows(duration: Double) -> [Range<Double>] {
        guard duration.isFinite, duration >= minimumSeconds, duration < 10_000_000_000 else { return [] }
        if duration < 24 { return [0..<duration] }
        if duration < 36 { return [0..<(duration / 2), (duration / 2)..<duration] }
        if duration < 72 {
            return (0..<3).map { (Double($0) * duration / 3)..<(Double($0 + 1) * duration / 3) }
        }
        return [0.15, 0.5, 0.85].map { fraction in
            let start = min(duration - 24, max(0, duration * fraction - 12))
            return start..<(start + 24)
        }
    }

    /// A disagreement is not averaged into an invented tempo. Octave-related pulses
    /// are grouped but explicitly marked ambiguous and downweighted.
    static func combine(_ segments: [SegmentEstimate], resourceDuration: Double,
                        expectedDuration: Double? = nil) -> RecordingEstimate {
        let expected = expectedDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let ordered = segments.filter {
            $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds
        }.sorted { $0.startSeconds < $1.startSeconds }
        var uniqueSeconds = 0.0, previousEnd = 0.0
        for segment in ordered {
            uniqueSeconds += max(0, segment.endSeconds - max(previousEnd, segment.startSeconds))
            previousEnd = max(previousEnd, segment.endSeconds)
        }
        let sampled = ordered.reduce(0) { $0 + $1.seconds }
        let span = max(0, (ordered.last?.endSeconds ?? 0) - (ordered.first?.startSeconds ?? 0)) / max(1, resourceDuration)
        let incomplete = expected.map { resourceDuration + 3 < $0 * 0.9 || resourceDuration > $0 * 1.15 + 3 } ?? false
        let scope = incomplete ? "partial_resource" : expected == nil ? "resource_duration_only" : "recording_distributed"
        let valid = ordered.filter {
            guard let bpm = $0.bpm else { return false }
            return bpm.isFinite && (55...200).contains(bpm) && $0.confidence.isFinite
                && (0.35...1).contains($0.confidence) && $0.seconds >= minimumSeconds - 0.05
        }
        func weight(_ segment: SegmentEstimate) -> Double { segment.seconds * segment.confidence }
        func aligned(_ bpm: Double, to anchor: Double) -> Double {
            [bpm / 2, bpm, bpm * 2].min { abs(log2($0 / anchor)) < abs(log2($1 / anchor)) } ?? bpm
        }
        func matches(_ bpm: Double, _ anchor: Double) -> Bool { abs(log2(aligned(bpm, to: anchor) / anchor)) <= 0.06 }
        let totalWeight = valid.reduce(0) { $0 + weight($1) }
        let anchor = valid.max { left, right in
            func support(_ value: SegmentEstimate) -> Double {
                valid.reduce(0) { sum, row in
                    let exact = abs(log2(row.bpm! / value.bpm!)) <= 0.06
                    return sum + (matches(row.bpm!, value.bpm!) ? weight(row) : 0) + (exact ? weight(row) * 0.01 : 0)
                }
            }
            return support(left) < support(right)
        }
        let agreeing = anchor.map { anchor in valid.filter { matches($0.bpm!, anchor.bpm!) } } ?? []
        let agreeingWeight = agreeing.reduce(0) { $0 + weight($1) }
        let agreement = totalWeight > 0 ? agreeingWeight / totalWeight : 0
        let ambiguous = anchor.map { anchor in agreeing.contains { abs(log2($0.bpm! / anchor.bpm!)) > 0.5 } } ?? false
        let enough = valid.count >= min(2, ordered.count) && !valid.isEmpty
        let consistent = enough && agreement >= 0.75 && agreeing.count >= min(2, ordered.count)
        var confidence = sampled > 0 ? agreeingWeight / sampled : 0
        confidence *= 0.75 + 0.25 * min(1, span / 0.7)
        if ambiguous { confidence *= 0.75 }
        if ordered.count == 1 { confidence *= 0.7 }
        if incomplete { confidence = min(0.45, confidence * sqrt(min(1, resourceDuration / max(1, expected ?? resourceDuration)))) }
        confidence = min(0.92, max(0, confidence))
        let value: Double? = consistent && confidence >= 0.25 ? anchor.flatMap { anchor -> Double? in
            let weighted = agreeing.reduce(0) { $0 + aligned($1.bpm!, to: anchor.bpm!) * weight($1) } / agreeingWeight
            let result = (weighted * 10).rounded() / 10
            return (55...200).contains(result) ? result : nil
        } : nil
        let strength = value == nil ? nil : agreeing.reduce(0) { $0 + ($1.rhythmicStrength ?? 0) * weight($1) } / max(1, agreeingWeight)
        let status = value != nil ? (incomplete ? "partial_coverage" : expected == nil ? "resource_only" : "complete")
            : enough && agreement < 0.75 ? "inconsistent" : "low_confidence"
        return RecordingEstimate(bpm: value, confidence: confidence, rhythmicStrength: strength, segments: ordered,
            resourceDurationSeconds: resourceDuration, expectedTrackDurationSeconds: expected,
            sampledSeconds: sampled, coverageFraction: min(1, uniqueSeconds / max(1, expected ?? resourceDuration)),
            sampledSpanFraction: min(1, span), agreement: agreement, halfDoubleAmbiguity: ambiguous, scope: scope, status: status)
    }

    /// RMS blocks retain both broadband and bass transients without retaining full PCM.
    struct Envelope {
        private let blockFrames: Int
        let framesPerSecond: Double
        private var count = 0
        private var sum = 0.0
        private var bassSum = 0.0
        private var bass = 0.0
        private let bassAlpha: Double
        private(set) var values: [Double] = []

        init(sampleRate: Double) {
            blockFrames = max(1, Int((sampleRate / 100).rounded()))
            framesPerSecond = sampleRate / Double(blockFrames)
            bassAlpha = 1 - exp(-2 * .pi * 180 / sampleRate)
        }

        mutating func append(_ sample: Float) {
            let value = sample.isFinite ? Double(sample) : 0
            bass += bassAlpha * (value - bass)
            sum += value * value
            bassSum += bass * bass
            count += 1
            if count == blockFrames {
                values.append(0.45 * sqrt(sum / Double(count)) + 0.55 * sqrt(bassSum / Double(count)))
                count = 0; sum = 0; bassSum = 0
            }
        }
    }

    static func estimate(samples: [Float], sampleRate: Double) -> Estimate? {
        guard sampleRate.isFinite, sampleRate >= 1_000, sampleRate <= 192_000 else { return nil }
        var envelope = Envelope(sampleRate: sampleRate)
        for sample in samples.prefix(Int(maximumSeconds * sampleRate)) { envelope.append(sample) }
        return estimate(envelope: envelope.values, framesPerSecond: envelope.framesPerSecond)
    }

    static func estimate(envelope: [Double], framesPerSecond: Double) -> Estimate? {
        guard framesPerSecond.isFinite, framesPerSecond > 0,
              Double(envelope.count) / framesPerSecond >= minimumSeconds,
              envelope.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let meanLevel = envelope.reduce(0, +) / Double(envelope.count)
        guard meanLevel > 0.0001 else { return nil }
        // Smooth carrier/block-boundary ripple before onset extraction. A steady note
        // can otherwise alias into a very periodic envelope and falsely look like BPM.
        let smoothing = max(3, Int((framesPerSecond * 0.05).rounded()))
        var levels = [Double](repeating: 0, count: envelope.count)
        var rolling = 0.0
        for index in envelope.indices {
            rolling += envelope[index]
            if index >= smoothing { rolling -= envelope[index - smoothing] }
            levels[index] = rolling / Double(min(index + 1, smoothing))
        }
        let sortedLevels = levels.sorted()
        let contrast = sortedLevels[Int(Double(levels.count - 1) * 0.95)]
            - sortedLevels[Int(Double(levels.count - 1) * 0.1)]
        guard contrast / meanLevel >= 0.12 else { return nil }
        // Positive log-energy difference suppresses sustained notes and level variation.
        var onset = [Double](repeating: 0, count: envelope.count)
        for index in 2..<envelope.count {
            onset[index] = max(0, log1p(levels[index] * 30) - log1p(levels[index - 2] * 30))
        }
        // Local subtraction removes slowly changing beds and intro/outro volume ramps.
        let radius = max(1, Int(framesPerSecond / 4))
        var prefix = [Double](repeating: 0, count: onset.count + 1)
        for index in onset.indices { prefix[index + 1] = prefix[index] + onset[index] }
        for index in onset.indices {
            let lower = max(0, index - radius), upper = min(onset.count, index + radius + 1)
            onset[index] = max(0, onset[index] - (prefix[upper] - prefix[lower]) / Double(upper - lower))
        }
        guard let peak = dominantPeriod(onset, framesPerSecond: framesPerSecond), peak.correlation >= 0.18 else { return nil }
        let half = onset.count / 2
        let segments = [Array(onset[..<half]), Array(onset[half...])]
        let agreement = segments.compactMap { dominantPeriod($0, framesPerSecond: framesPerSecond) }
            .filter { abs(log2($0.bpm / peak.bpm)) < 0.055 }.count
        // Confidence is a measurement quality indicator, not a calibrated probability.
        // Never publish weak/nonperiodic audio as a numeric BPM.
        let confidence = min(0.92, max(0, peak.correlation * 0.7 + Double(agreement) * 0.1))
        guard confidence >= 0.35, agreement >= 1 else { return nil }
        return Estimate(bpm: (peak.bpm * 10).rounded() / 10, confidence: confidence,
            rhythmicStrength: min(1, max(0, peak.correlation)), seconds: Double(envelope.count) / framesPerSecond)
    }

    private struct Peak { let bpm: Double; let correlation: Double }

    private static func dominantPeriod(_ onset: [Double], framesPerSecond: Double) -> Peak? {
        let minimumLag = max(2, Int((framesPerSecond * 60 / 200).rounded(.up)))
        let maximumLag = min(onset.count / 3, Int((framesPerSecond * 60 / 55).rounded(.down)))
        guard maximumLag > minimumLag else { return nil }
        let mean = onset.reduce(0, +) / Double(onset.count)
        let centered = onset.map { $0 - mean }
        let totalEnergy = centered.reduce(0) { $0 + $1 * $1 }
        guard totalEnergy > 0.00001 else { return nil }
        var correlations = [Double](repeating: 0, count: maximumLag + 2)
        for lag in (minimumLag - 1)...(maximumLag + 1) {
            var cross = 0.0, left = 0.0, right = 0.0
            for index in lag..<centered.count {
                let a = centered[index], b = centered[index - lag]
                cross += a * b; left += a * a; right += b * b
            }
            correlations[lag] = cross / max(0.000000001, sqrt(left * right))
        }
        let maxima = (minimumLag...maximumLag).filter {
            correlations[$0] >= correlations[$0 - 1] && correlations[$0] > correlations[$0 + 1]
        }
        guard let strongest = maxima.max(by: {
            // A small duration penalty breaks exact harmonic ties in favor of the
            // shortest supported pulse; it does not infer a genre-specific tempo.
            correlations[$0] - Double($0) * 0.0004 < correlations[$1] - Double($1) * 0.0004
        }) else { return nil }
        // Integer-lag quantization can make a double-length period score higher than
        // its real pulse (e.g. 37.5 frames vs 75). Retain a supported shorter harmonic
        // when its own onset correlation is strong, rather than halving that tempo.
        let winner = maxima.filter { lag in
            let multiple = Double(strongest) / Double(lag)
            return lag <= strongest && correlations[lag] >= correlations[strongest] * 0.7
                && ((1.95...2.05).contains(multiple) || (2.92...3.08).contains(multiple) || lag == strongest)
        }.min() ?? strongest
        let left = correlations[winner - 1], center = correlations[winner], right = correlations[winner + 1]
        let denominator = left - 2 * center + right
        let adjustment = abs(denominator) > 0.000001 ? min(0.5, max(-0.5, 0.5 * (left - right) / denominator)) : 0
        let bpm = 60 * framesPerSecond / (Double(winner) + adjustment)
        guard (55...200).contains(bpm) else { return nil }
        return Peak(bpm: bpm, correlation: max(0, center))
    }
}
