import Foundation

@main
enum SongAnalysisBudgetChecks {
    static func main() throws {
func require(_ yes: @autoclosure () -> Bool, _ label: String) { if !yes() { fatalError(label) } }
var ledger = SongBudgetLedger()
let reserve = SongAnalysisPolicy.reservationMicros
try ledger.reserve(id: "first", day: "2026-09-25")
require(ledger.totalMicros == reserve, "request must be reserved before network")
let afterFailure = try JSONDecoder().decode(SongBudgetLedger.self, from: JSONEncoder().encode(ledger))
require(afterFailure.totalMicros == reserve && afterFailure.reservations["first"] != nil, "unknown failure and restart retain full reservation")
require(ledger.settle(id: "first", inputTokens: 2000, outputTokens: 600), "known usage settles")
let paid = SongAnalysisPolicy.costMicros(input: 2000, output: 600)
require(ledger.totalMicros == paid, "known usage refunds only unused reservation")
require(ledger.settle(id: "first", inputTokens: 2000, outputTokens: 600), "duplicate settlement benign")
require(ledger.totalMicros == paid, "duplicate settlement must not refund twice")
var daily = SongBudgetLedger()
var n = 0
while (try? daily.reserve(id: "request-\(n)", day: "2026-09-25")) != nil { n += 1 }
require(daily.totalMicros <= 1_000_000 && daily.totalMicros + reserve > 1_000_000, "daily cap admits no extra request")
var total = SongBudgetLedger()
for day in 1...20 {
    for attempt in 0..<100 {
        _ = try? total.reserve(id: "\(day)-\(attempt)", day: "day-\(day)")
    }
}
require(total.totalMicros <= 8_000_000 && total.totalMicros + reserve > 8_000_000, "lifetime cap survives new days")
var mismatch = SongBudgetLedger()
try mismatch.reserve(id: "bad", day: "2026-09-25")
require(!mismatch.settle(id: "bad", inputTokens: 65537, outputTokens: 600), "unbounded usage fails closed")
require(mismatch.pricingMismatch && mismatch.totalMicros == reserve, "mismatch retains reservation")
require((try? mismatch.reserve(id: "later", day: "2026-09-26")) == nil, "mismatch blocks future requests")
let legacyJSON = """
{"totalMicros":\(reserve),"dailyMicros":{"2026-09-25":\(reserve)},"reservations":{"old":{"day":"2026-09-25","amountMicros":\(reserve)}},"pricingMismatch":false}
"""
var migrated = try JSONDecoder().decode(SongBudgetLedger.self, from: Data(legacyJSON.utf8))
require(migrated.totalMicros == reserve, "adding photos must preserve old spent/reserved totals")
require(migrated.settle(id: "old", inputTokens: 2000, outputTokens: 600), "old reservation settles using song pricing")
require(migrated.totalMicros == paid, "legacy settlement must not invent a new budget")
try migrated.reserve(id: "photo", day: "2026-09-28", purpose: .photoContext)
require(migrated.totalMicros == paid + CloudVisionPolicy.reservationMicros, "photo and song share lifetime total")
let restored = try JSONDecoder().decode(SongBudgetLedger.self, from: JSONEncoder().encode(migrated))
require(restored.reservations["photo"]?.purpose == .photoContext, "photo accounting survives relaunch")
require(migrated.settle(id: "photo", inputTokens: 1500, outputTokens: 200), "photo settles using its limits")
require(migrated.totalMicros == paid + CloudVisionPolicy.costMicros(input: 1500, output: 200), "mixed known usage exact")
var mixed = SongBudgetLedger()
var attempts = 0
while true {
    let purpose: CloudAnalysisPurpose = attempts % 2 == 0 ? .songText : .photoContext
    guard (try? mixed.reserve(id: "mixed-\(attempts)", day: "today", purpose: purpose)) != nil else { break }
    attempts += 1
}
require(mixed.totalMicros <= SongAnalysisPolicy.dailyLimitMicros, "mixed requests enforce one daily cap")
while (try? mixed.reserve(id: "extra-photo-\(attempts)", day: "today", purpose: .photoContext)) != nil { attempts += 1 }
require(mixed.totalMicros <= SongAnalysisPolicy.dailyLimitMicros &&
        mixed.totalMicros + min(reserve, CloudVisionPolicy.reservationMicros) > SongAnalysisPolicy.dailyLimitMicros,
        "shared daily cap cannot be bypassed by switching modalities")
var badPhoto = SongBudgetLedger()
try badPhoto.reserve(id: "photo", day: "today", purpose: .photoContext)
require(!badPhoto.settle(id: "photo", inputTokens: CloudVisionPolicy.reservedInputTokens + 1, outputTokens: 100),
        "photo cannot cross the verified pricing tier")
require((try? badPhoto.reserve(id: "song", day: "tomorrow")) == nil, "photo pricing anomaly blocks songs as well")
var oldPhoto = SongBudgetLedger()
try oldPhoto.reserve(id: "old-photo", day: "today", purpose: .photoScene)
require(oldPhoto.totalMicros == CloudVisionPolicy.costMicros(input: 32768, output: 512), "legacy photo retains original reservation after multi-image upgrade")
require(oldPhoto.settle(id: "old-photo", inputTokens: 1500, outputTokens: 200), "legacy photo reservation remains settleable")
var canceled = SongBudgetLedger()
try canceled.reserve(id: "cancel", day: "today", purpose: .photoContext)
let canceledAfterRestart = try JSONDecoder().decode(SongBudgetLedger.self, from: JSONEncoder().encode(canceled))
require(canceledAfterRestart.totalMicros == CloudVisionPolicy.reservationMicros,
        "canceled or unknown photo requests keep their complete reservation")
print("Budget checks passed: durable reservation, unknown failure, exact usage, caps, legacy migration, mixed modalities, and fail-closed photo pricing.")

    }
}
