import Foundation

struct HRVPoint {
    let date: Date
    let milliseconds: Double
}

struct HRVAssessment {
    let latest: HRVPoint
    let baselineMilliseconds: Double?
    let baselineDays: Int
    let isRecent: Bool
    let isBelowPersonalBaseline: Bool
}

enum HRVBaseline {
    // Use a median per day so frequent samples on one day do not dominate a personal baseline.
    static func evaluate(_ points: [HRVPoint], now: Date, calendar: Calendar = .current) -> HRVAssessment? {
        let valid = points.filter {
            $0.milliseconds.isFinite && $0.milliseconds > 0 &&
            $0.date <= now && $0.date >= now.addingTimeInterval(-15 * 86400)
        }
        guard let latest = valid.max(by: { $0.date < $1.date }) else { return nil }
        let latestDay = calendar.startOfDay(for: latest.date)
        let todayValues = valid.filter { calendar.startOfDay(for: $0.date) == latestDay }
            .map(\.milliseconds)
        let currentMedian = median(todayValues)
        let previous = Dictionary(grouping: valid.filter { calendar.startOfDay(for: $0.date) < latestDay }) {
            calendar.startOfDay(for: $0.date)
        }
        let dailyMedians = previous.values.compactMap { median($0.map(\.milliseconds)) }
        let baseline = dailyMedians.count >= 5 ? median(dailyMedians) : nil
        let recent = now.timeIntervalSince(latest.date) <= 86400
        let lower = recent && baseline.flatMap { base in
            currentMedian.map { current in current < base * 0.8 }
        } == true
        return HRVAssessment(latest: latest, baselineMilliseconds: baseline,
            baselineDays: dailyMedians.count, isRecent: recent,
            isBelowPersonalBaseline: lower)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
