import Foundation
import CryptoKit

enum SceneMemoryPolicy: String, Codable, CaseIterable, Identifiable {
    case recent2h, recent24h, summariesOnly
    var id: String { rawValue }
    var title: String {
        switch self { case .recent2h: return "近 2 小时 · 3 张"; case .recent24h: return "近 24 小时 · 5 张"; case .summariesOnly: return "只保留场景摘要" }
    }
    var detail: String {
        switch self {
        case .recent2h: return "下一次主动分析时，连同近 2 小时最多 3 张照片一起分析。"
        case .recent24h: return "下一次主动分析时，连同近 24 小时最多 5 张照片一起分析。"
        case .summariesOnly: return "每次只上传当前照片与近 24 小时场景摘要，手机不保留照片副本。"
        }
    }
    var retention: TimeInterval { self == .recent2h ? 7200 : 86400 }
    var maximumImages: Int { self == .recent2h ? 3 : (self == .recent24h ? 5 : 1) }
    var maximumEntries: Int { self == .recent2h ? 3 : 5 }
}

struct SceneImageTime: Codable, Equatable, Identifiable {
    let imageID: String
    let capturedAt: Date?
    let selectedAt: Date
    let captureTimeLabel: String?
    let isCurrent: Bool
    var id: String { imageID }
    var orderingDate: Date { capturedAt ?? selectedAt }
}

struct VisualMemorySnapshot {
    let photoCount: Int
    let summaryCount: Int
    let oldestSelectedAt: Date?
    let policy: SceneMemoryPolicy
}

struct VisualContextFrame {
    let timing: SceneImageTime
    let jpeg: Data
    let imageHash: String
}

struct VisualContextSummary: Codable {
    let selectedAt: Date
    let capturedAt: Date?
    let captureTimeLabel: String?
    let scene: String
    let description: String
    let confidence: Double
    let intentHypotheses: [ListeningIntentHypothesis]
    let userReport: SceneUserReport?
}

struct VisualContextBatch {
    let frames: [VisualContextFrame]
    let summaries: [VisualContextSummary]
    let generation: UUID
    let policy: SceneMemoryPolicy
    let selectedAt: Date
}

enum VisualMemoryError: LocalizedError {
    case unavailable, contextCleared
    var errorDescription: String? {
        switch self {
        case .unavailable: return "近期照片记忆暂不可读，请清除近期照片后重试。"
        case .contextCleared: return "近期场景已清除或设置已改变，本次结果不再使用。"
        }
    }
}

/// Only explicitly submitted images enter this private cache. No original library
/// asset URLs, EXIF, coordinates or credentials are kept. Expiry is enforced before
/// every read/upload and on scheduled cleanup while the app is running.
actor VisualContextMemory {
    static let shared = VisualContextMemory()
    private struct Entry: Codable {
        let id: String
        let selectedAt: Date
        let capturedAt: Date?
        let captureTimeLabel: String?
        let imageHash: String
        var hasPhoto: Bool
        let summary: VisualContextSummary
    }
    private struct Archive: Codable { var version = 1; var policy: SceneMemoryPolicy = .recent24h; var entries: [Entry] = [] }
    private let directory: URL
    private var archive = Archive()
    private var loaded = false
    private var generation = UUID()
    private var expiryTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("visual-context-v2", isDirectory: true)
    }

    func snapshot(policy: SceneMemoryPolicy = .recent24h, at date: Date = Date()) throws -> VisualMemorySnapshot {
        try prepare(policy: policy, at: date)
        return VisualMemorySnapshot(photoCount: archive.entries.filter(\.hasPhoto).count,
            summaryCount: archive.entries.count, oldestSelectedAt: archive.entries.map(\.selectedAt).min(), policy: policy)
    }

    func applyPolicy(_ policy: SceneMemoryPolicy) throws { try prepare(policy: policy, at: Date()) }

    func clear() throws {
        generation = UUID(); expiryTask?.cancel(); expiryTask = nil
        // A corrupt index must not prevent clearing the private cache.
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        archive.entries = []; loaded = true
    }

    func batch(current: VisualContextFrame, policy: SceneMemoryPolicy, at date: Date = Date()) throws -> VisualContextBatch {
        try prepare(policy: policy, at: date)
        var frames: [VisualContextFrame] = []
        if policy != .summariesOnly {
            for entry in archive.entries.filter({ $0.hasPhoto && $0.imageHash != current.imageHash }).suffix(policy.maximumImages - 1) {
                let bytes = try Data(contentsOf: imageURL(entry.id))
                guard bytes.count <= CloudVisionPolicy.maximumImageBytes,
                      Self.hash(bytes) == entry.imageHash else { throw VisualMemoryError.unavailable }
                frames.append(VisualContextFrame(timing: SceneImageTime(imageID: entry.id, capturedAt: entry.capturedAt,
                    selectedAt: entry.selectedAt, captureTimeLabel: entry.captureTimeLabel, isCurrent: false), jpeg: bytes, imageHash: entry.imageHash))
            }
        }
        frames.append(current)
        frames.sort { $0.timing.orderingDate == $1.timing.orderingDate
            ? $0.timing.selectedAt < $1.timing.selectedAt : $0.timing.orderingDate < $1.timing.orderingDate }
        return VisualContextBatch(frames: frames, summaries: archive.entries.suffix(policy.maximumEntries).map(\.summary),
            generation: generation, policy: policy, selectedAt: date)
    }

    func validate(_ batch: VisualContextBatch) throws {
        guard generation == batch.generation else { throw VisualMemoryError.contextCleared }
    }

    func record(current: VisualContextFrame, analysis: CloudSceneAnalysis, batch: VisualContextBatch) throws {
        try Task.checkCancellation()
        try validate(batch)
        try prepare(policy: batch.policy, at: Date())
        guard generation == batch.generation else { throw VisualMemoryError.contextCleared }
        let timing = current.timing
        let summary = VisualContextSummary(selectedAt: timing.selectedAt, capturedAt: timing.capturedAt,
            captureTimeLabel: timing.captureTimeLabel, scene: analysis.scene, description: analysis.description,
            confidence: analysis.confidence, intentHypotheses: analysis.intentHypotheses ?? [], userReport: analysis.userReport)
        let entry = Entry(id: timing.imageID, selectedAt: timing.selectedAt, capturedAt: timing.capturedAt,
            captureTimeLabel: timing.captureTimeLabel, imageHash: current.imageHash,
            hasPhoto: batch.policy != .summariesOnly, summary: summary)
        let previous = archive
        archive.entries.removeAll { $0.imageHash == current.imageHash }
        archive.entries.append(entry)
        archive.entries.sort { $0.selectedAt < $1.selectedAt }
        archive.entries = Array(archive.entries.suffix(batch.policy.maximumEntries))
        do {
            try ensureDirectory()
            if entry.hasPhoto { try writeProtected(current.jpeg, to: imageURL(entry.id)) }
            try persist()
        } catch {
            archive = previous
            try? FileManager.default.removeItem(at: imageURL(entry.id))
            throw error
        }
        try removeUnreferencedPhotos()
        scheduleExpiry()
    }

    private func prepare(policy: SceneMemoryPolicy, at date: Date) throws {
        if !loaded {
            let url = directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 128_000 else { throw VisualMemoryError.unavailable }
                    archive = try JSONDecoder().decode(Archive.self, from: data)
                    guard archive.version == 1, archive.entries.count <= 5,
                          archive.entries.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.selectedAt.timeIntervalSince1970.isFinite }) else {
                        throw VisualMemoryError.unavailable
                    }
                } catch { throw VisualMemoryError.unavailable }
            }
            loaded = true
        }
        var changed = false
        if archive.policy != policy { archive.policy = policy; generation = UUID(); changed = true }
        let oldCount = archive.entries.count
        archive.entries.removeAll { date.timeIntervalSince($0.selectedAt) > policy.retention || $0.selectedAt > date.addingTimeInterval(300) }
        archive.entries = Array(archive.entries.sorted { $0.selectedAt < $1.selectedAt }.suffix(policy.maximumEntries))
        changed = changed || oldCount != archive.entries.count
        if policy == .summariesOnly {
            for index in archive.entries.indices where archive.entries[index].hasPhoto { archive.entries[index].hasPhoto = false; changed = true }
        }
        if changed { try persist() }
        try removeUnreferencedPhotos()
        scheduleExpiry()
    }

    private func persist() throws {
        try ensureDirectory()
        try writeProtected(JSONEncoder().encode(archive), to: directory.appendingPathComponent("index.json"))
    }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    private func imageURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".jpg") }
    private func removeUnreferencedPhotos() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let retained = Set(archive.entries.filter(\.hasPhoto).map { $0.id + ".jpg" })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "jpg" && !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let oldest = archive.entries.map(\.selectedAt).min() else { return }
        let delay = max(1, oldest.addingTimeInterval(archive.policy.retention + 1).timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.expire()
        }
    }
    private func expire() {
        try? prepare(policy: archive.policy, at: Date())
        scheduleExpiry()
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
