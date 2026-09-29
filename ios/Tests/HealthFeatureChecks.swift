import Foundation

@main
struct HealthFeatureChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func metric(_ value: Double?, at date: Date? = nil, baseline: Double? = nil) -> HealthMetric {
            HealthMetric(value: value, measuredAt: date ?? now, unit: "test", baseline: baseline,
                sampleCount: value == nil ? 0 : 1, quality: value == nil ? "missing" : "good")
        }
        let context = HealthContext(observedAt: ISO8601DateFormatter().string(from: now), features: [
            "heart_rate": metric(90, baseline: 60), "hrv_sdnn": metric(25, baseline: 50),
            "sleep_hours": metric(6, baseline: 7), "hours_since_wake": metric(2, at: now.addingTimeInterval(-7200))
        ])
        let vector = context.vector(at: now)
        precondition(abs(vector["heart_relative"]! - 0.5) < 1e-9)
        precondition(abs(vector["hrv_relative"]! - log(0.5)) < 1e-9)
        precondition(vector["hrv_relative_missing"] == 0)
        precondition(vector["workout_minutes_missing"] == 1)
        precondition(vector["heart_active_missing"] == 1) // Missing motion cannot become sedentary.
        precondition(context.vector(at: now.addingTimeInterval(8000))["heart_rate_missing"] == 1)
        precondition(context.vector(at: now.addingTimeInterval(90000))["hrv_relative_missing"] == 1)
        precondition(context.vector(at: now.addingTimeInterval(3600))["hours_since_wake"]! > vector["hours_since_wake"]!)
        let noBaseline = HealthContext(observedAt: context.observedAt, features: ["hrv_sdnn": metric(30)])
        precondition(noBaseline.vector(at: now)["hrv_relative_missing"] == 1)
        let malformed = HealthContext(observedAt: context.observedAt, features: ["heart_rate": metric(.nan)])
        precondition(malformed.vector(at: now).values.allSatisfy(\.isFinite))
        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(HealthContext.self, from: encoded)
        precondition(decoded.vector(at: now) == vector)
        let start = now.addingTimeInterval(-8 * 3600)
        let intervals = [
            HealthSleepInterval(start: start, end: start.addingTimeInterval(3 * 3600), source: "watch", asleep: true, staged: true),
            HealthSleepInterval(start: start.addingTimeInterval(3 * 3600), end: start.addingTimeInterval(4 * 3600), source: "watch", asleep: false, staged: false),
            HealthSleepInterval(start: start.addingTimeInterval(4 * 3600), end: now, source: "watch", asleep: true, staged: true),
            HealthSleepInterval(start: start, end: now, source: "manual", asleep: true, staged: false)
        ]
        let sleep = HealthFeatureMath.sleepEpisodes(intervals)
        precondition(sleep.count == 1 && sleep[0].source == "watch")
        precondition(abs(sleep[0].asleepSeconds - 7 * 3600) < 1e-9)
        precondition(abs(sleep[0].continuity - 7.0 / 8) < 1e-9)
        precondition(HealthFeatureMath.sleepEpisodes(intervals + intervals).first?.asleepSeconds == 7 * 3600)
        precondition(HealthFeatureMath.unionDuration([(start, now), (start, now)]) == 8 * 3600)
        precondition(HealthFeatureMath.median([1, 2, 100, .nan]) == 2)
        print("Health feature checks passed: source selection, overlap union, missingness, freshness, continuous baselines, serialization.")
    }
}
