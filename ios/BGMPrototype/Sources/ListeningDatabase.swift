import Foundation
import SQLite3

/// One serial writer. No encoding, migration or SQLite I/O runs on the UI actor.
final class ListeningDatabase: @unchecked Sendable {
    static let shared = ListeningDatabase()
    static let failureNotification = Notification.Name("ListeningDatabaseWriteFailed")
    let fileURL: URL
    private let queue = DispatchQueue(label: "linting.database", qos: .utility)
    private var connection: OpaquePointer?
    private var decisionIDs = Set<String>()
    private var episodeIDs = Set<String>()
    private var eventIDs = Set<String>()
    private var loadedIDs = false
    private var writes = 0
    private var writeFailures: [String: Error] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linting-v2.sqlite")
    }

    deinit { if let connection { sqlite3_close(connection) } }

    func loadLearning(legacyURL: URL) async throws -> AdaptiveLearningState {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.loadLearningOnQueue(legacyURL: legacyURL)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func loadLearningSynchronously(legacyURL: URL) throws -> AdaptiveLearningState {
        try queue.sync { try loadLearningOnQueue(legacyURL: legacyURL) }
    }

    private func loadLearningOnQueue(legacyURL: URL) throws -> AdaptiveLearningState {
        try open()
        if try dataRow("SELECT payload FROM model_state WHERE id='online'") == nil {
            var original = AdaptiveLearningState()
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                original = try decoder.decode(AdaptiveLearningState.self, from: Data(contentsOf: legacyURL))
                guard original.version == 1 else { throw DatabaseError.message("学习档案版本无法迁移，原文件已保留。") }
            }
            // All old decisions migrate in one transaction; the source is kept as a recovery copy.
            try persistLearning(original)
        }
        guard let payload = try dataRow("SELECT payload FROM model_state WHERE id='online'") else {
            throw DatabaseError.message("学习数据库缺少模型状态。")
        }
        var state = try decoder.decode(AdaptiveLearningState.self, from: payload)
        state.decisions = try rows("SELECT payload FROM (SELECT at,payload FROM decisions ORDER BY at DESC LIMIT 32) ORDER BY at")
            .map { try decoder.decode(AdaptiveDecisionSnapshot.self, from: $0) }
        state.episodes = try rows("SELECT payload FROM (SELECT at,payload FROM playback_episodes ORDER BY at DESC LIMIT 320) ORDER BY at")
            .map { try decoder.decode(PlaybackEvidence.self, from: $0) }
        state.journal = try rows("SELECT payload FROM (SELECT at,payload FROM feedback_events ORDER BY at DESC LIMIT 1200) ORDER BY at")
            .map { try decoder.decode(AdaptiveJournalEvent.self, from: $0) }
        return state
    }

    func saveLearning(_ state: AdaptiveLearningState) {
        queue.async { self.performWrite(key: "learning") { try self.persistLearning(state) } }
    }

    func saveLearningSynchronously(_ state: AdaptiveLearningState) throws {
        try queue.sync { try persistLearning(state) }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let error = self.writeFailures.values.first { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Records contain metadata only; callers must never pass photos, credentials or audio bytes.
    func saveDocument<T: Encodable>(collection: String, id: String, value: T) {
        queue.async {
            self.performWrite(key: "document:\(collection):\(id)") {
                try self.open()
                try self.execute("INSERT OR REPLACE INTO documents(collection,id,updated_at,payload) VALUES(?,?,?,?)",
                    [.text(collection), .text(id), .number(Date().timeIntervalSince1970), .data(try self.encoder.encode(value))])
            }
        }
    }

    func document<T: Decodable>(collection: String, id: String, as type: T.Type) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.open()
                    let data = try self.rows("SELECT payload FROM documents WHERE collection=? AND id=?", [.text(collection), .text(id)]).first
                    continuation.resume(returning: try data.map { try self.decoder.decode(type, from: $0) })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func deleteDocuments(collection: String, id: String? = nil) {
        queue.async { self.performWrite {
            try self.open()
            if let id { try self.execute("DELETE FROM documents WHERE collection=? AND id=?", [.text(collection), .text(id)]) }
            else { try self.execute("DELETE FROM documents WHERE collection=?", [.text(collection)]) }
        } }
    }

    func saveScene<T: Encodable>(_ scene: T) {
        saveDocument(collection: "scene_analysis", id: UUID().uuidString, value: scene)
        queue.async { self.performWrite {
            try self.execute("DELETE FROM documents WHERE collection='scene_analysis' AND id NOT IN (SELECT id FROM documents WHERE collection='scene_analysis' ORDER BY updated_at DESC LIMIT 64)")
        } }
    }

    func recordMetric(_ name: String, milliseconds: Double, detail: String = "") {
        guard milliseconds.isFinite else { return }
        queue.async { self.performWrite(key: "metrics") {
            try self.open()
            try self.execute("INSERT INTO performance_events(at,name,milliseconds,detail) VALUES(?,?,?,?)",
                [.number(Date().timeIntervalSince1970), .text(name), .number(milliseconds), .text(String(detail.prefix(160)))])
            try self.execute("DELETE FROM performance_events WHERE id NOT IN (SELECT id FROM performance_events ORDER BY id DESC LIMIT 2000)")
        } }
    }

    private func performWrite(key: String = "maintenance", _ operation: () throws -> Void) {
        do { try operation(); writeFailures.removeValue(forKey: key) }
        catch {
            writeFailures[key] = error
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.failureNotification, object: nil,
                    userInfo: ["message": "本机数据保存失败，近期操作可能未落盘：\(error.localizedDescription)"])
            }
        }
    }

    private func persistLearning(_ state: AdaptiveLearningState) throws {
        let started = ProcessInfo.processInfo.systemUptime
        try open()
        if !loadedIDs {
            decisionIDs = Set(try strings("SELECT id FROM decisions"))
            episodeIDs = Set(try strings("SELECT id FROM playback_episodes"))
            eventIDs = Set(try strings("SELECT id FROM feedback_events"))
            loadedIDs = true
        }
        let newDecisions = state.decisions.filter { !decisionIDs.contains($0.id) }
        let newEpisodes = state.episodes.filter { !episodeIDs.contains($0.id) }
        let newEvents = state.journal.filter { !eventIDs.contains(Self.eventID($0)) }
        try execute("BEGIN IMMEDIATE")
        do {
            for item in newDecisions {
                try execute("INSERT OR IGNORE INTO decisions(id,at,track_id,selection,policy_version,payload) VALUES(?,?,?,?,?,?)",
                    [.text(item.id), .number(item.at.timeIntervalSince1970), .text(item.chosenTrackID), .text(item.selection), .text(item.policyVersion), .data(try encoder.encode(item))])
            }
            for item in newEpisodes {
                try execute("INSERT OR IGNORE INTO playback_episodes(id,at,track_id,decision_id,end_reason,payload) VALUES(?,?,?,?,?,?)",
                    [.text(item.id), .number(item.startedAt.timeIntervalSince1970), .text(item.trackID), .text(item.decisionID ?? ""), .text(item.endReason), .data(try encoder.encode(item))])
            }
            for item in newEvents {
                try execute("INSERT OR IGNORE INTO feedback_events(id,at,track_id,decision_id,kind,payload) VALUES(?,?,?,?,?,?)",
                    [.text(Self.eventID(item)), .number(item.at.timeIntervalSince1970), .text(item.trackID), .text(item.decisionID ?? ""), .text(item.kind), .data(try encoder.encode(item))])
            }
            var model = state
            model.decisions = []; model.episodes = []; model.journal = []
            try execute("INSERT OR REPLACE INTO model_state(id,payload) VALUES('online',?)", [.data(try encoder.encode(model))])
            // Bound disk growth without evicting an unfinished episode's current decision.
            try execute("DELETE FROM decisions WHERE id NOT IN (SELECT id FROM decisions ORDER BY at DESC LIMIT 512)")
            try execute("DELETE FROM playback_episodes WHERE id NOT IN (SELECT id FROM playback_episodes ORDER BY at DESC LIMIT 2000)")
            try execute("DELETE FROM feedback_events WHERE id NOT IN (SELECT id FROM feedback_events ORDER BY at DESC LIMIT 10000)")
            // Instrumentation belongs to this same durable transaction: avoid two
            // additional FULL-synchronous autocommits for every playback action.
            // This work duration excludes instrumentation SQL and the final COMMIT;
            // callers/benchmarks time save + flush for complete durability latency.
            try execute("INSERT INTO performance_events(at,name,milliseconds,detail) VALUES(?,?,?,?)",
                [.number(Date().timeIntervalSince1970), .text("database_write_work"),
                 .number((ProcessInfo.processInfo.systemUptime - started) * 1000),
                 .text("decisions=\(newDecisions.count),episodes=\(newEpisodes.count),events=\(newEvents.count)")])
            try execute("DELETE FROM performance_events WHERE id NOT IN (SELECT id FROM performance_events ORDER BY id DESC LIMIT 2000)")
            try execute("COMMIT")
            decisionIDs.formUnion(newDecisions.map(\.id)); episodeIDs.formUnion(newEpisodes.map(\.id))
            eventIDs.formUnion(newEvents.map(Self.eventID))
            writes += 1
            if writes % 100 == 0 { loadedIDs = false }
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private static func eventID(_ event: AdaptiveJournalEvent) -> String {
        event.action?.id ?? "\(event.episodeID)|\(event.kind)|\(event.at.timeIntervalSinceReferenceDate)"
    }

    private func open() throws {
        guard connection == nil else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(fileURL.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }; connection = nil
            throw DatabaseError.message("无法打开本机数据库。")
        }
        do {
            sqlite3_busy_timeout(connection, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA wal_autocheckpoint=256")
            let version = try strings("PRAGMA user_version").first ?? "0"
            guard version == "0" || version == "2" else { throw DatabaseError.message("数据库版本比当前应用更新，已停止写入。") }
            try execute("CREATE TABLE IF NOT EXISTS model_state(id TEXT PRIMARY KEY,payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS decisions(id TEXT PRIMARY KEY,at REAL NOT NULL,track_id TEXT,selection TEXT,policy_version TEXT,payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS playback_episodes(id TEXT PRIMARY KEY,at REAL NOT NULL,track_id TEXT,decision_id TEXT,end_reason TEXT,payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS feedback_events(id TEXT PRIMARY KEY,at REAL NOT NULL,track_id TEXT,decision_id TEXT,kind TEXT,payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS documents(collection TEXT NOT NULL,id TEXT NOT NULL,updated_at REAL NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(collection,id))")
            try execute("CREATE TABLE IF NOT EXISTS performance_events(id INTEGER PRIMARY KEY,at REAL,name TEXT,milliseconds REAL,detail TEXT)")
            for table in ["decisions", "playback_episodes", "feedback_events"] {
                try execute("CREATE INDEX IF NOT EXISTS \(table)_time ON \(table)(at)")
                try execute("CREATE INDEX IF NOT EXISTS \(table)_track ON \(table)(track_id,at)")
            }
            try execute("CREATE INDEX IF NOT EXISTS documents_updated ON documents(collection,updated_at)")
            try execute("PRAGMA user_version=2")
            #if os(iOS)
            for suffix in ["", "-wal", "-shm"] {
                let path = fileURL.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
                }
            }
            #endif
            var secured = fileURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? secured.setResourceValues(values)
        } catch { sqlite3_close(connection); connection = nil; throw error }
    }

    private enum Value { case text(String), number(Double), data(Data) }
    private func statement(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .number(let number): status = sqlite3_bind_double(statement, index, number)
            case .data(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            }
            if status != SQLITE_OK { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    private func execute(_ sql: String, _ bindings: [Value] = []) throws {
        let statement = try statement(sql, bindings); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func rows(_ sql: String, _ bindings: [Value] = []) throws -> [Data] {
        let statement = try statement(sql, bindings); defer { sqlite3_finalize(statement) }
        var results: [Data] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW else { throw failure() }
            if let bytes = sqlite3_column_blob(statement, 0) {
                results.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
        }
    }
    private func dataRow(_ sql: String) throws -> Data? { try rows(sql).first }
    private func strings(_ sql: String) throws -> [String] {
        let statement = try statement(sql, []); defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        }
    }
    private func failure() -> DatabaseError {
        .message(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库不可用")
    }
}

enum DatabaseError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
