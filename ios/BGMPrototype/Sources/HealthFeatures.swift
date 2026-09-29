import Foundation

struct HealthMetric: Codable {
    var value: Double?
    var measuredAt: Date?
    var unit: String
    var baseline: Double?
    var sampleCount: Int
    var quality: String
    var baselineDays: Int = 0
    var category: String? = nil
}

struct HealthContext: Codable {
    var observedAt: String
    var features: [String: HealthMetric]

    var explanation: String {
        let readable = features.values.filter { $0.value?.isFinite == true }.count
        return readable == 0 ? "暂无可读健康摘要；缺失值不作心理判断" : "已提供 \(readable) 项连续健康特征；根据记录时间降权，随听歌操作学习"
    }

    // These are bounded statistical inputs, not diagnoses or psychological cutoffs.
    // Preserve missingness and confidence rather than inventing measurements.
    func vector(at now: Date) -> [String: Double] {
        var result: [String: Double] = [:]
        func clipped(_ value: Double) -> Double { value.isFinite ? min(3, max(-3, value)) : 0 }
        func confidence(_ key: String, fresh: Double, expiry: Double) -> Double {
            guard let metric = features[key], let value = metric.value, value.isFinite,
                  let measured = metric.measuredAt, measured <= now.addingTimeInterval(60) else { return 0 }
            let age = max(0, now.timeIntervalSince(measured))
            let ageWeight = age <= fresh ? 1 : max(0, 1 - (age - fresh) / max(1, expiry - fresh))
            return ageWeight * (metric.quality == "limited" ? 0.5 : metric.quality == "missing" ? 0 : 1)
        }
        func add(_ name: String, metric key: String, fresh: Double, expiry: Double,
                 transform: (HealthMetric) -> Double?) {
            let metric = features[key]
            let value = metric.flatMap(transform)
            let q = value?.isFinite == true ? confidence(key, fresh: fresh, expiry: expiry) : 0
            result[name] = q > 0 ? clipped(value ?? 0) * q : 0
            result[name + "_quality"] = q
            result[name + "_missing"] = q > 0 ? 0 : 1
        }
        add("heart_rate", metric: "heart_rate", fresh: 1200, expiry: 7200) { $0.value.map { ($0 - 70) / 30 } }
        add("heart_relative", metric: "heart_rate", fresh: 1200, expiry: 7200) { metric in
            guard let value = metric.value, let baseline = metric.baseline, baseline > 0 else { return nil }
            return (value - baseline) / baseline
        }
        add("heart_trend", metric: "heart_trend", fresh: 1200, expiry: 7200) { $0.value.map { $0 / 20 } }
        for motion in ["active", "sedentary"] {
            add("heart_" + motion, metric: "heart_rate", fresh: 1200, expiry: 7200) { metric in
                guard let category = metric.category, category != "unknown" else { return nil }
                return category == motion ? 1 : 0
            }
        }
        add("hrv_relative", metric: "hrv_sdnn", fresh: 6 * 3600, expiry: 24 * 3600) { metric in
            guard let value = metric.value, value > 0, let baseline = metric.baseline, baseline > 0 else { return nil }
            return log(value / baseline)
        }
        add("resting_relative", metric: "resting_heart_rate", fresh: 36 * 3600, expiry: 7 * 86400) { metric in
            guard let value = metric.value, let baseline = metric.baseline, baseline > 0 else { return nil }
            return (value - baseline) / baseline
        }
        add("sleep_hours", metric: "sleep_hours", fresh: 24 * 3600, expiry: 48 * 3600) { $0.value.map { ($0 - 7) / 3 } }
        add("sleep_relative", metric: "sleep_hours", fresh: 24 * 3600, expiry: 48 * 3600) { metric in
            guard let value = metric.value, let baseline = metric.baseline else { return nil }
            return (value - baseline) / 3
        }
        add("sleep_continuity", metric: "sleep_continuity", fresh: 24 * 3600, expiry: 48 * 3600) { $0.value.map { ($0 - 0.8) * 2 } }
        add("hours_since_wake", metric: "hours_since_wake", fresh: 24 * 3600, expiry: 48 * 3600) { metric in
            metric.measuredAt.map { now.timeIntervalSince($0) / (16 * 3600) }
        }
        add("workout_minutes", metric: "workout_minutes", fresh: 12 * 3600, expiry: 3 * 86400) { $0.value.map { $0 / 60 } }
        add("workout_recency", metric: "hours_since_workout", fresh: 12 * 3600, expiry: 3 * 86400) { metric in
            metric.measuredAt.map { exp(-max(0, now.timeIntervalSince($0)) / (6 * 3600)) }
        }
        add("workout_load", metric: "workout_minutes_24h", fresh: 900, expiry: 3600) { $0.value.map { $0 / 90 } }
        for category in ["cardio", "strength", "mindbody"] {
            add("workout_" + category, metric: "workout_minutes", fresh: 12 * 3600, expiry: 3 * 86400) {
                $0.category.map { $0 == category ? 1 : 0 }
            }
        }
        let qualities = result.filter { $0.key.hasSuffix("_quality") }.map(\.value)
        result["health_coverage"] = qualities.isEmpty ? 0 : qualities.reduce(0, +) / Double(qualities.count)
        return result
    }
}

struct HealthSleepInterval {
    var start: Date
    var end: Date
    var source: String
    var asleep: Bool
    var staged: Bool
}

struct HealthSleepEpisode {
    var start: Date
    var end: Date
    var asleepSeconds: Double
    var source: String
    var sampleCount: Int
    var continuity: Double { min(1, asleepSeconds / max(1, end.timeIntervalSince(start))) }
}

enum HealthFeatureMath {
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let index = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[index - 1] + sorted[index]) / 2 : sorted[index]
    }

    static func unionDuration(_ intervals: [(Date, Date)]) -> Double {
        var end: Date?
        var total = 0.0
        for (start, stop) in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            total += max(0, stop.timeIntervalSince(max(start, end ?? start)))
            end = max(end ?? stop, stop)
        }
        return total
    }

    // Build each source's episodes separately, then choose one source per overlapping
    // episode. Staged sleep takes precedence over manually entered aggregate intervals.
    static func sleepEpisodes(_ intervals: [HealthSleepInterval]) -> [HealthSleepEpisode] {
        var candidates: [(HealthSleepEpisode, Bool)] = []
        for (source, rows) in Dictionary(grouping: intervals.filter { $0.end > $0.start }, by: \.source) {
            var groups: [[HealthSleepInterval]] = []
            for row in rows.sorted(by: { $0.start < $1.start }) {
                if let latest = groups.last, let end = latest.map(\.end).max(), row.start.timeIntervalSince(end) <= 90 * 60 {
                    groups[groups.count - 1].append(row)
                } else { groups.append([row]) }
            }
            for group in groups {
                let asleep = group.filter(\.asleep)
                guard let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max() else { continue }
                let duration = unionDuration(asleep.map { ($0.start, $0.end) })
                guard duration >= 90 * 60 else { continue } // Defines main-sleep candidates; excludes brief naps.
                candidates.append((HealthSleepEpisode(start: start, end: end, asleepSeconds: duration,
                    source: source, sampleCount: group.count), group.contains(where: \.staged)))
            }
        }
        let preferred = candidates.sorted {
            if $0.1 != $1.1 { return $0.1 && !$1.1 }
            if $0.0.sampleCount != $1.0.sampleCount { return $0.0.sampleCount > $1.0.sampleCount }
            return $0.0.source < $1.0.source
        }
        var selected: [HealthSleepEpisode] = []
        for (episode, _) in preferred where !selected.contains(where: { $0.start < episode.end && episode.start < $0.end }) {
            selected.append(episode)
        }
        return selected.sorted { $0.end > $1.end }
    }
}
