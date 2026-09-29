import Foundation
import SQLite3
import CryptoKit

@main enum ListeningDatabaseChecks {
    private static var failures: [String] = []
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private static func check(_ value: Bool, _ message: String) {
        if !value { failures.append(message); print("FAIL: \(message)") }
    }
    private static func connection(_ url: URL) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_open_v2(url.path, &result, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let result else {
            throw DatabaseError.message("Test could not inspect database")
        }
        sqlite3_busy_timeout(result, 5000); return result
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.message(String(cString: sqlite3_errmsg(db)))
        }
    }
    private static func strings(_ db: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.message(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        }
        return result
    }
    private static func count(_ db: OpaquePointer, _ table: String) throws -> Int {
        Int(try strings(db, "SELECT count(*) FROM \(table)").first ?? "-1") ?? -1
    }
    private static func digest(_ db: OpaquePointer, _ table: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) ORDER BY id", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.message("Cannot inspect payloads")
        }
        defer { sqlite3_finalize(statement) }
        var hash = SHA256()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) {
                hash.update(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func percentile(_ numbers: [Double], _ p: Double) -> Double {
        let sorted = numbers.sorted(); return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * p)]
    }
    private static func modelEqual(_ a: AdaptivePreferenceModel, _ b: AdaptivePreferenceModel) -> Bool {
        a.acceptance.weights == b.acceptance.weights && a.acceptance.updates == b.acceptance.updates &&
        a.rejection.weights == b.rejection.weights && a.rejection.updates == b.rejection.updates &&
        a.affinity.weights == b.affinity.weights && a.affinity.updates == b.affinity.updates &&
        a.replay.weights == b.replay.weights && a.replay.updates == b.replay.updates
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : root.appendingPathComponent("diagnostics/2026-09-28/before/adaptive-decisions-v1.json")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("linting-db-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copied = temp.appendingPathComponent("adaptive-decisions-v1.json")
        try FileManager.default.copyItem(at: source, to: copied)
        let originalData = try Data(contentsOf: copied)
        let originalHash = SHA256.hash(data: originalData)
        let original = try JSONDecoder().decode(AdaptiveLearningState.self, from: originalData)
        let databaseURL = temp.appendingPathComponent("migrated.sqlite")
        let database = ListeningDatabase(fileURL: databaseURL)
        let started = ProcessInfo.processInfo.systemUptime
        var live = try await database.loadLearning(legacyURL: copied)
        let migrationMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let db = try connection(databaseURL); defer { sqlite3_close(db) }
        check(try count(db, "decisions") == original.decisions.count, "all real legacy decisions migrated")
        check(try count(db, "playback_episodes") == original.episodes.count, "all real legacy episodes migrated")
        check(try count(db, "feedback_events") == original.journal.count, "all real legacy events migrated")
        check(live.decisions.count == min(32, original.decisions.count), "in-memory decision window bounded")
        check(live.episodes.count == min(320, original.episodes.count) && live.journal.count == min(1200, original.journal.count), "in-memory event windows bounded")
        check(live.decisionCount == original.decisionCount && live.episodeCount == original.episodeCount &&
              live.explicitFeedbackCount == original.explicitFeedbackCount && live.learnedEpisodes == original.learnedEpisodes, "lifetime counters preserved")
        check(modelEqual(live.model, original.model), "every learned weight and head update counter preserved exactly")
        check(live.trackStarts == original.trackStarts && live.feedbackState == original.feedbackState &&
              live.processedEpisodes == original.processedEpisodes && live.trainedHeads == original.trainedHeads, "feedback and idempotency state preserved")
        check(SHA256.hash(data: try Data(contentsOf: copied)) == originalHash, "legacy source preserved byte for byte")
        let beforeDigest = try digest(db, "decisions")
        let beforeBytes = try strings(db, "SELECT sum(length(payload)) FROM decisions").first
        let updates = 120
        let writesStarted = ProcessInfo.processInfo.systemUptime
        for index in 0..<updates {
            let action = PlaybackAction(kind: "test_incremental", at: Date().addingTimeInterval(Double(index) / 1000),
                position: Double(index), targetPosition: nil, source: "database-regression")
            live.journal.append(AdaptiveJournalEvent(at: action.at, episodeID: "regression", trackID: "regression",
                decisionID: live.decisions.last?.id, kind: action.kind, action: action))
            live.explicitFeedbackCount += 1
            database.saveLearning(live)
        }
        try await database.flush()
        let writeBatchMS = (ProcessInfo.processInfo.systemUptime - writesStarted) * 1000
        let details = try strings(db, "SELECT detail FROM performance_events WHERE name='database_write_work' ORDER BY id DESC LIMIT \(updates)")
        let durations = try strings(db, "SELECT milliseconds FROM performance_events WHERE name='database_write_work' ORDER BY id DESC LIMIT \(updates)").compactMap(Double.init)
        check(details.count == updates && details.allSatisfy { $0 == "decisions=0,episodes=0,events=1" }, "incremental events do not re-encode any historical decision or episode")
        check(try digest(db, "decisions") == beforeDigest, "old decision payload bytes unchanged by incremental events")
        check(try strings(db, "SELECT sum(length(payload)) FROM decisions").first == beforeBytes, "old decision storage does not expand during feedback")
        check(try count(db, "feedback_events") == original.journal.count + updates, "serial writer persists every increment exactly once")
        let reloaded = try await database.loadLearning(legacyURL: copied)
        check(reloaded.explicitFeedbackCount == live.explicitFeedbackCount && modelEqual(reloaded.model, original.model), "last queued model snapshot wins without losing weights")
        let second = ListeningDatabase(fileURL: databaseURL)
        let restarted = try await second.loadLearning(legacyURL: copied)
        check(restarted.explicitFeedbackCount == live.explicitFeedbackCount, "restart loads sqlite rather than remigrating old JSON")

        let corruptSource = temp.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("{\"version\":1,\"model\": incomplete".utf8)
        try corruptBytes.write(to: corruptSource)
        let corruptURL = temp.appendingPathComponent("corrupt.sqlite")
        let corruptDB = ListeningDatabase(fileURL: corruptURL)
        do { _ = try await corruptDB.loadLearning(legacyURL: corruptSource); check(false, "corrupt migration must fail") } catch {}
        let corruptConnection = try connection(corruptURL); defer { sqlite3_close(corruptConnection) }
        check(try Data(contentsOf: corruptSource) == corruptBytes, "corrupt source preserved for recovery")
        check(try count(corruptConnection, "model_state") == 0 && count(corruptConnection, "decisions") == 0, "failed migration cannot replace learning with empty success")
        try encoder.encode(AdaptiveLearningState()).write(to: corruptSource)
        _ = try await corruptDB.loadLearning(legacyURL: corruptSource)
        check(try count(corruptConnection, "model_state") == 1, "uncommitted migration can recover after source repair")

        // Reproduce a learning transaction failure followed by a successful unrelated metric.
        try execute(db, "CREATE TRIGGER fail_learning BEFORE INSERT ON model_state BEGIN SELECT RAISE(FAIL,'injected learning write failure'); END")
        var failedState = live
        let failedEvent = AdaptiveJournalEvent(at: Date(), episodeID: "failed-event", trackID: "failed-track", decisionID: nil, kind: "liked", action: nil)
        failedState.journal.append(failedEvent)
        failedState.explicitFeedbackCount += 1
        database.saveLearning(failedState)
        database.recordMetric("successful_after_failed_learning", milliseconds: 1)
        var reportedFailure = false
        do { try await database.flush() } catch { reportedFailure = true }
        check(reportedFailure, "unrelated successful writes must not erase an unresolved learning failure")
        check(try count(db, "feedback_events") == original.journal.count + updates, "failed learning transaction rolled back its event")
        try execute(db, "DROP TRIGGER fail_learning")
        database.saveLearning(failedState)
        try await database.flush()
        check(try count(db, "feedback_events") == original.journal.count + updates + 1, "later complete snapshot recovers failed event once")

        // These timings surround a completed durable save, including queue wait,
        // JSON work, instrumentation SQL, COMMIT and FULL-synchronous fsync.
        var durableDurations: [Double] = []
        var timingState = failedState
        for index in 0..<20 {
            timingState.journal.append(AdaptiveJournalEvent(at: Date(), episodeID: "durability-\(index)", trackID: "timing",
                decisionID: nil, kind: "test_durable_timing", action: nil))
            let start = ProcessInfo.processInfo.systemUptime
            try database.saveLearningSynchronously(timingState)
            durableDurations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }

        // Disk retention limits are tested with small synthetic records, avoiding large re-encoding.
        let boundedURL = temp.appendingPathComponent("bounded.sqlite")
        let boundedDB = ListeningDatabase(fileURL: boundedURL)
        var bounded = AdaptiveLearningState()
        for index in 0..<530 {
            bounded.decisions.append(AdaptiveDecisionSnapshot(id: "d\(index)", at: Date(timeIntervalSince1970: Double(index)), chosenTrackID: "track",
                candidates: [], selection: "test", policyVersion: "test", context: [:]))
        }
        for index in 0..<2020 {
            bounded.episodes.append(PlaybackEvidence(id: "e\(index)", decisionID: "d529", trackID: "track", startedAt: Date(timeIntervalSince1970: Double(index)),
                endedAt: Date(timeIntervalSince1970: Double(index + 1)), duration: 10, renderedSeconds: 1, uniqueCoveredSeconds: 1,
                lastPosition: 1, startReason: "test", endReason: "test", actions: [], contentKind: "test"))
        }
        for index in 0..<10020 {
            bounded.journal.append(AdaptiveJournalEvent(at: Date(timeIntervalSince1970: Double(index)), episodeID: "j\(index)", trackID: "track",
                decisionID: "d529", kind: "test", action: nil))
        }
        try boundedDB.saveLearningSynchronously(bounded)
        let boundedConnection = try connection(boundedURL); defer { sqlite3_close(boundedConnection) }
        check(try count(boundedConnection, "decisions") == 512 && count(boundedConnection, "playback_episodes") == 2000 && count(boundedConnection, "feedback_events") == 10000,
              "on-disk learning tables obey retention bounds")
        for index in 0..<70 { boundedDB.saveScene(["scene": "scene \(index)"]) }
        try await boundedDB.flush()
        check(try count(boundedConnection, "documents") == 64, "scene history bounded to 64 metadata records")

        let coalescingFolder = temp.appendingPathComponent("coalescing")
        try FileManager.default.createDirectory(at: coalescingFolder, withIntermediateDirectories: true)
        let coalescingLegacy = coalescingFolder.appendingPathComponent("legacy.json")
        var coalescingState = AdaptiveLearningState(); coalescingState.decisionCount = 17
        try encoder.encode(coalescingState).write(to: coalescingLegacy)
        let store = AdaptiveDecisionStore(fileURL: coalescingLegacy, synchronous: false)
        check(!store.isReady, "async store initialization does not block main actor on disk")
        do { try store.transaction { $0.decisionCount = -1 }; check(false, "mutation before preparation must fail") } catch {}
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 { group.addTask { try await store.prepare() } }
            try await group.waitForAll()
        }
        check(store.isReady && store.state.decisionCount == 17, "concurrent prepare callers receive one migrated state")
        let coalescingDB = try connection(coalescingLegacy.deletingPathExtension().appendingPathExtension("sqlite"))
        defer { sqlite3_close(coalescingDB) }
        check(try count(coalescingDB, "performance_events") == 1, "concurrent prepare performs one migration commit")
        try store.transaction { $0.decisionCount = 18 }
        try await store.prepare()
        check(store.state.decisionCount == 18, "subsequent prepare never overwrites newer in-memory updates")

        #if OPTIMIZED_CHECKS
        let compiler = "swiftc -O"
        #else
        let compiler = "swiftc default optimization"
        #endif
        let report: [String: Any] = ["source_bytes": originalData.count, "source_decisions": original.decisions.count,
            "source_episodes": original.episodes.count, "source_events": original.journal.count,
            "runtime": "macOS desktop", "compiler": compiler,
            "migration_full_durability_ms": migrationMS, "incremental_writes": updates, "incremental_batch_full_durability_ms": writeBatchMS,
            "instrumentation_metric": "database_write_work",
            "instrumentation_scope": "encoding and SQL before metric insertion; excludes instrumentation SQL and final COMMIT/fsync",
            "incremental_work_p50_ms": percentile(durations, 0.5), "incremental_work_p95_ms": percentile(durations, 0.95),
            "sequential_durable_samples": durableDurations.count,
            "sequential_full_durability_p50_ms": percentile(durableDurations, 0.5),
            "sequential_full_durability_p95_ms": percentile(durableDurations, 0.95),
            "old_decision_payloads_unchanged": beforeDigest == (try digest(db, "decisions")), "failures": failures]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        print(String(data: reportData, encoding: .utf8)!)
        if CommandLine.arguments.count > 2 { try reportData.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic) }
        if !failures.isEmpty { throw DatabaseError.message("\(failures.count) database regression check(s) failed") }
        print("Listening database checks passed: real-device migration, exact learned-state preservation, incremental persistence, failure recovery, and bounded tables.")
    }
}
