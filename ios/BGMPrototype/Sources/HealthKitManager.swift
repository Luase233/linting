import Foundation
import HealthKit

// A query completion can race its five-second timeout. Resume exactly once.
private final class HealthQueryResult<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    func finish(_ result: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

@MainActor
final class HealthKitManager: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "healthReadingEnabled")
    @Published private(set) var isRefreshing = false
    @Published private(set) var status = "健康数据尚未读取"
    @Published private(set) var heartText = "心率：暂无可读记录"
    @Published private(set) var hrvText = "心率变异性：暂无可读记录"
    @Published private(set) var restingHeartText = "静息心率：暂无可读记录"
    @Published private(set) var workoutText = "健身记录：暂无可读记录"
    @Published private(set) var sleepText = "最近主睡眠：暂无可读记录"
    @Published private(set) var summary = "未使用健康摘要"
    @Published private(set) var updatedAt: Date?
    private let store = HKHealthStore()
    private var generation = 0
    private var context: HealthContext?
    private var refreshTask: Task<HealthContext?, Never>?
    private var baselineCache: Baselines?
    private let bpm = HKUnit.count().unitDivided(by: .minute())
    private let milliseconds = HKUnit.secondUnit(with: .milli)

    private struct Reference {
        var median: Double
        var days: Int
    }
    private struct Baselines {
        var createdAt: Date
        var references: [String: Reference]
    }

    func enable() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "这台设备不支持 Apple 健康数据。"
            return
        }
        let types: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKWorkoutType.workoutType(), HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        do {
            let requestedGeneration = generation
            try await store.requestAuthorization(toShare: [], read: types)
            guard requestedGeneration == generation else { return }
            generation += 1
            refreshTask?.cancel()
            refreshTask = nil
            isRefreshing = false
            enabled = true
            UserDefaults.standard.set(true, forKey: "healthReadingEnabled")
            baselineCache = nil
            context = nil
            updatedAt = nil
            _ = await refresh()
        } catch { status = "健康授权未完成，请在系统设置检查权限。" }
    }

    func disable() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        enabled = false
        UserDefaults.standard.set(false, forKey: "healthReadingEnabled")
        context = nil
        baselineCache = nil
        updatedAt = nil
        heartText = "心率：未读取"
        hrvText = "心率变异性：未读取"
        restingHeartText = "静息心率：未读取"
        workoutText = "健身记录：未读取"
        sleepText = "最近主睡眠：未读取"
        summary = "未使用健康摘要"
        status = "已停用；之后的选曲不再使用健康摘要。"
    }

    func refresh() async -> HealthContext? {
        guard enabled, HKHealthStore.isHealthDataAvailable() else { return nil }
        let requestedGeneration = generation
        if let task = refreshTask {
            let value = await task.value
            return enabled && generation == requestedGeneration ? value : nil
        }
        // Reuse a real snapshot for one minute; never move its observation timestamp.
        if let updatedAt, Date().timeIntervalSince(updatedAt) < 60, let context { return context }
        isRefreshing = true
        let task = Task { await self.collect(now: Date(), generation: requestedGeneration) }
        refreshTask = task
        let value = await task.value
        guard enabled, generation == requestedGeneration else { return nil }
        refreshTask = nil
        isRefreshing = false
        return value
    }

    private func collect(now: Date, generation requestedGeneration: Int) async -> HealthContext? {
        async let heartRows = samples(.quantityType(forIdentifier: .heartRate)!, since: now.addingTimeInterval(-86400), until: now, limit: 2000)
        async let hrvRows = samples(.quantityType(forIdentifier: .heartRateVariabilitySDNN)!, since: now.addingTimeInterval(-86400), until: now, limit: 200)
        async let restingRows = samples(.quantityType(forIdentifier: .restingHeartRate)!, since: now.addingTimeInterval(-7 * 86400), until: now, limit: 100)
        async let workoutRows = samples(HKWorkoutType.workoutType(), since: now.addingTimeInterval(-7 * 86400), until: now, limit: 100)
        async let sleepRows = samples(.categoryType(forIdentifier: .sleepAnalysis)!, since: now.addingTimeInterval(-3 * 86400), until: now, limit: 2000)
        async let references = baselines(now: now)
        let (hearts, hrvs, resting, workouts, sleeps, baseline) = await (heartRows, hrvRows, restingRows, workoutRows, sleepRows, references)
        guard enabled, generation == requestedGeneration, !Task.isCancelled else { return nil }
        baselineCache = baseline
        var features: [String: HealthMetric] = [:]
        func missing(_ unit: String) -> HealthMetric {
            HealthMetric(value: nil, measuredAt: nil, unit: unit, baseline: nil, sampleCount: 0, quality: "missing")
        }
        func quantity(_ rows: [HKSample]?, unit: HKUnit, label: String, key: String, maxAge: Double,
                      needSedentary: Bool = false) -> HealthMetric {
            let valid = (rows ?? []).compactMap { $0 as? HKQuantitySample }.filter {
                let value = $0.quantity.doubleValue(for: unit)
                return value.isFinite && value > 0 && $0.endDate <= now
            }
            guard let latest = valid.first else { return missing(label) }
            let referenceKey = Self.referenceKey(key, sample: latest, withTime: key != "resting")
            let reference = !needSedentary || Self.motion(latest) == HKHeartRateMotionContext.sedentary.rawValue
                ? baseline?.references[referenceKey] : nil
            let quality = now.timeIntervalSince(latest.endDate) > maxAge ? "stale" : "good"
            return HealthMetric(value: latest.quantity.doubleValue(for: unit), measuredAt: latest.endDate,
                unit: label, baseline: reference?.median, sampleCount: valid.count, quality: quality,
                baselineDays: reference?.days ?? 0,
                category: needSedentary ? Self.motionName(latest) : nil)
        }
        let heart = quantity(hearts, unit: bpm, label: "bpm", key: "heart", maxAge: 1200, needSedentary: true)
        features["heart_rate"] = heart
        features["hrv_sdnn"] = quantity(hrvs, unit: milliseconds, label: "ms", key: "hrv", maxAge: 6 * 3600)
        features["resting_heart_rate"] = quantity(resting, unit: bpm, label: "bpm", key: "resting", maxAge: 36 * 3600)
        features["heart_trend"] = missing("bpm/hour")
        let validHearts = (hearts ?? []).compactMap { $0 as? HKQuantitySample }
        if let latest = validHearts.first, Self.motion(latest) != HKHeartRateMotionContext.notSet.rawValue {
            let comparable = validHearts.filter {
                $0.endDate >= latest.endDate.addingTimeInterval(-3600) &&
                    Self.source($0) == Self.source(latest) && Self.motion($0) == Self.motion(latest) &&
                    $0.quantity.doubleValue(for: bpm).isFinite
            }
            if comparable.count >= 3, let earliest = comparable.last,
               latest.endDate.timeIntervalSince(earliest.endDate) >= 600 {
                // Least-squares slope uses the whole hour rather than noisy endpoints.
                let points = comparable.map { ($0.endDate.timeIntervalSince(earliest.endDate) / 3600, $0.quantity.doubleValue(for: bpm)) }
                let meanX = points.map { $0.0 }.reduce(0, +) / Double(points.count)
                let meanY = points.map { $0.1 }.reduce(0, +) / Double(points.count)
                let denominator = points.map { pow($0.0 - meanX, 2) }.reduce(0, +)
                let numerator = points.map { ($0.0 - meanX) * ($0.1 - meanY) }.reduce(0, +)
                if denominator > 0 {
                    features["heart_trend"] = HealthMetric(value: numerator / denominator, measuredAt: latest.endDate,
                        unit: "bpm/hour", baseline: nil, sampleCount: points.count, quality: heart.quality, category: Self.motionName(latest))
                }
            }
        }
        let sleepEpisodes = HealthFeatureMath.sleepEpisodes(Self.sleepIntervals(sleeps ?? [], until: now))
            .filter { now.timeIntervalSince($0.end) <= 36 * 3600 }
        let mainSleep = sleepEpisodes.first(where: { $0.asleepSeconds >= 3 * 3600 }) ?? sleepEpisodes.max(by: { $0.asleepSeconds < $1.asleepSeconds })
        if let sleep = mainSleep {
            let reference = baseline?.references["sleep|" + sleep.source]
            features["sleep_hours"] = HealthMetric(value: sleep.asleepSeconds / 3600, measuredAt: sleep.end,
                unit: "hours", baseline: reference?.median, sampleCount: sleep.sampleCount, quality: "good", baselineDays: reference?.days ?? 0)
            features["sleep_continuity"] = HealthMetric(value: sleep.continuity, measuredAt: sleep.end,
                unit: "fraction", baseline: nil, sampleCount: sleep.sampleCount, quality: sleep.sampleCount > 1 ? "good" : "limited")
            features["hours_since_wake"] = HealthMetric(value: now.timeIntervalSince(sleep.end) / 3600, measuredAt: sleep.end,
                unit: "hours", baseline: nil, sampleCount: sleep.sampleCount, quality: "limited")
            sleepText = String(format: "最近主睡眠：%.1f 小时 · 连续性 %.0f%%", sleep.asleepSeconds / 3600, sleep.continuity * 100) +
                " · 结束于 \(sleep.end.formatted(date: .abbreviated, time: .shortened))"
        } else {
            features["sleep_hours"] = missing("hours")
            features["sleep_continuity"] = missing("fraction")
            features["hours_since_wake"] = missing("hours")
            sleepText = "最近主睡眠：暂无完整可读记录"
        }
        let validWorkouts = Self.deduplicatedWorkouts(workouts ?? [], until: now)
        if let latest = validWorkouts.first {
            let category = Self.workoutCategory(latest.workoutActivityType)
            features["workout_minutes"] = HealthMetric(value: latest.duration / 60, measuredAt: latest.endDate,
                unit: "minutes", baseline: nil, sampleCount: 1, quality: "good", category: category)
            features["hours_since_workout"] = HealthMetric(value: now.timeIntervalSince(latest.endDate) / 3600, measuredAt: latest.endDate,
                unit: "hours", baseline: nil, sampleCount: 1, quality: "good", category: category)
            let recent = validWorkouts.filter { $0.endDate > now.addingTimeInterval(-86400) }
            let union = HealthFeatureMath.unionDuration(recent.map { (max($0.startDate, now.addingTimeInterval(-86400)), $0.endDate) }) / 60
            // Recorded workout durations exclude pauses. Cap interval union by active duration.
            let total = min(union, recent.map { $0.duration / 60 }.reduce(0, +))
            features["workout_minutes_24h"] = HealthMetric(value: total, measuredAt: now, unit: "minutes",
                baseline: nil, sampleCount: recent.count, quality: "good")
            workoutText = "最近健身：\(Self.workoutName(latest.workoutActivityType)) · \(Int(latest.duration / 60)) 分钟 · \(latest.endDate.formatted(date: .abbreviated, time: .shortened))"
        } else {
            features["workout_minutes"] = missing("minutes")
            features["hours_since_workout"] = missing("hours")
            features["workout_minutes_24h"] = missing("minutes")
            workoutText = "近 7 天健身记录：暂无可读记录"
        }
        heartText = Self.quantityText("心率", metric: features["heart_rate"], unit: "次/分")
        hrvText = Self.quantityText("HRV（SDNN）", metric: features["hrv_sdnn"], unit: "ms")
        restingHeartText = Self.quantityText("静息心率", metric: features["resting_heart_rate"], unit: "次/分")
        let next = HealthContext(observedAt: ISO8601DateFormatter().string(from: now), features: features)
        context = next
        summary = next.explanation
        updatedAt = now
        let readable = features.values.contains { $0.value != nil }
        status = readable ? "健康特征参与个人模型；数据来自已同步记录，缺失和较早数据会降权。" :
            "未获得可读数据：可能尚未同步或未授予权限，无法区分；选曲仍可继续。"
        return next
    }

    private func baselines(now: Date) async -> Baselines? {
        if let baselineCache, now.timeIntervalSince(baselineCache.createdAt) < (baselineCache.references.isEmpty ? 900 : 4 * 3600) { return baselineCache }
        let end = Calendar.current.startOfDay(for: now)
        let start = end.addingTimeInterval(-28 * 86400)
        async let heartRows = samples(.quantityType(forIdentifier: .heartRate)!, since: start, until: end, limit: 20000)
        async let hrvRows = samples(.quantityType(forIdentifier: .heartRateVariabilitySDNN)!, since: start, until: end, limit: 3000)
        async let restingRows = samples(.quantityType(forIdentifier: .restingHeartRate)!, since: start, until: end, limit: 1000)
        // Read through now to recognize complete overnight episodes; clipping at
        // midnight would turn the first part of last night's sleep into a baseline day.
        async let sleepRows = samples(.categoryType(forIdentifier: .sleepAnalysis)!, since: start, until: now, limit: 12000)
        let (hearts, hrvs, resting, sleep) = await (heartRows, hrvRows, restingRows, sleepRows)
        guard !Task.isCancelled else { return nil }
        var grouped: [String: [(Date, Double)]] = [:]
        for (prefix, rows, unit) in [("heart", hearts, bpm), ("hrv", hrvs, milliseconds), ("resting", resting, bpm)] {
            for row in (rows ?? []).compactMap({ $0 as? HKQuantitySample }) {
                guard row.endDate < end else { continue }
                if prefix == "heart" && Self.motion(row) != HKHeartRateMotionContext.sedentary.rawValue { continue }
                let value = row.quantity.doubleValue(for: unit)
                guard value.isFinite, value > 0 else { continue }
                grouped[Self.referenceKey(prefix, sample: row, withTime: prefix != "resting"), default: []].append((row.endDate, value))
            }
        }
        let episodes = HealthFeatureMath.sleepEpisodes(Self.sleepIntervals(sleep ?? [], until: now)).filter { $0.end < end }
        for (source, sourceEpisodes) in Dictionary(grouping: episodes, by: \.source) {
            // Only the longest episode of each wake day contributes to main-sleep baseline.
            let days = Dictionary(grouping: sourceEpisodes, by: { Calendar.current.startOfDay(for: $0.end) })
            for (day, candidates) in days {
                if let main = candidates.max(by: { $0.asleepSeconds < $1.asleepSeconds }) {
                    grouped["sleep|" + source, default: []].append((day, main.asleepSeconds / 3600))
                }
            }
        }
        var references: [String: Reference] = [:]
        for (key, values) in grouped {
            let days = Dictionary(grouping: values, by: { Calendar.current.startOfDay(for: $0.0) })
            let medians = days.values.compactMap { HealthFeatureMath.median($0.map { $0.1 }) }
            if medians.count >= 5, let median = HealthFeatureMath.median(medians) { references[key] = Reference(median: median, days: medians.count) }
        }
        // Persist only small derived summaries in memory; raw HealthKit rows are released.
        return Baselines(createdAt: now, references: references)
    }

    private func samples(_ type: HKSampleType, since: Date, until: Date, limit: Int) async -> [HKSample]? {
        await withCheckedContinuation { continuation in
            let result = HealthQueryResult<[HKSample]>(continuation)
            let predicate = HKQuery.predicateForSamples(withStart: since, end: until, options: [])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, rows, error in
                result.finish(error == nil ? rows : nil)
            }
            store.execute(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [store] in
                store.stop(query)
                result.finish(nil)
            }
        }
    }

    private static func source(_ sample: HKSample) -> String {
        sample.sourceRevision.source.bundleIdentifier + "|" + (sample.device?.model ?? "unknown")
    }
    private static func motion(_ sample: HKSample) -> Int {
        (sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber)?.intValue ?? HKHeartRateMotionContext.notSet.rawValue
    }
    private static func motionName(_ sample: HKSample) -> String {
        switch motion(sample) {
        case HKHeartRateMotionContext.sedentary.rawValue: return "sedentary"
        case HKHeartRateMotionContext.active.rawValue: return "active"
        default: return "unknown"
        }
    }
    private static func referenceKey(_ prefix: String, sample: HKSample, withTime: Bool) -> String {
        prefix + "|" + source(sample) + (withTime ? "|\(Calendar.current.component(.hour, from: sample.endDate) / 6)" : "")
    }
    private static func quantityText(_ title: String, metric: HealthMetric?, unit: String) -> String {
        guard let metric, let value = metric.value, let date = metric.measuredAt else { return title + "：暂无可读记录" }
        let reference = metric.baseline.map { String(format: " · 个人基线 %.0f", $0) } ?? " · 基线不足"
        return String(format: "%@：%.0f %@", title, value, unit) + " · \(date.formatted(date: .abbreviated, time: .shortened))" + reference + (metric.quality == "stale" ? "（记录较早）" : "")
    }
    private static func sleepIntervals(_ rows: [HKSample], until: Date) -> [HealthSleepInterval] {
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let staged: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        return rows.compactMap { row in
            guard let sample = row as? HKCategorySample, sample.startDate < until,
                  asleep.contains(sample.value) || sample.value == HKCategoryValueSleepAnalysis.awake.rawValue else { return nil }
            return HealthSleepInterval(start: sample.startDate, end: min(sample.endDate, until), source: source(sample),
                asleep: asleep.contains(sample.value), staged: staged.contains(sample.value))
        }
    }
    private static func deduplicatedWorkouts(_ rows: [HKSample], until: Date) -> [HKWorkout] {
        var selected: [HKWorkout] = []
        for workout in rows.compactMap({ $0 as? HKWorkout }).filter({ $0.endDate <= until && $0.duration > 0 }) {
            let duplicate = selected.contains {
                abs($0.startDate.timeIntervalSince(workout.startDate)) < 120 &&
                    abs($0.endDate.timeIntervalSince(workout.endDate)) < 120 && $0.workoutActivityType == workout.workoutActivityType
            }
            if !duplicate { selected.append(workout) }
        }
        return selected
    }
    private static func workoutCategory(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running, .walking, .cycling, .swimming, .hiking, .elliptical, .rowing: return "cardio"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength"
        case .yoga, .mindAndBody, .pilates: return "mindbody"
        default: return "other"
        }
    }
    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "跑步"
        case .walking: return "步行训练"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .yoga: return "瑜伽"
        case .hiking: return "徒步"
        default: return "训练"
        }
    }
}
