import Foundation

@main
struct HRVBaselineChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let historical = (1...6).map { days in
            HRVPoint(date: calendar.date(byAdding: .day, value: -days, to: today)!.addingTimeInterval(3600),
                milliseconds: 50)
        }
        let latest = HRVPoint(date: now.addingTimeInterval(-3600), milliseconds: 30)
        let assessed = HRVBaseline.evaluate(historical + [latest], now: now, calendar: calendar)
        precondition(assessed?.baselineDays == 6 && assessed?.baselineMilliseconds == 50)
        precondition(assessed?.isBelowPersonalBaseline == true)

        let sparse = HRVBaseline.evaluate(Array(historical.prefix(4)) + [latest], now: now, calendar: calendar)
        precondition(sparse?.baselineMilliseconds == nil && sparse?.isBelowPersonalBaseline == false)

        let repeatedDay = historical + [HRVPoint(date: historical[0].date.addingTimeInterval(60), milliseconds: 200), latest]
        let repeatedAssessment = HRVBaseline.evaluate(repeatedDay, now: now, calendar: calendar)
        precondition(repeatedAssessment?.baselineDays == 6)

        let staleNow = now.addingTimeInterval(2 * 86400)
        let stale = HRVBaseline.evaluate(historical + [latest], now: staleNow, calendar: calendar)
        precondition(stale?.isRecent == false && stale?.isBelowPersonalBaseline == false)
        print("HRV baseline checks passed")
    }
}
