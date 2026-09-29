import Foundation

enum ListeningMode: String, CaseIterable, Identifiable {
    case focus
    case relax
    case move

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return "专注"
        case .relax: return "放松"
        case .move: return "活动"
        }
    }
}

enum ModeSelection: String, CaseIterable, Identifiable {
    case auto
    case focus
    case relax
    case move

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "随此刻"
        case .focus: return "专注"
        case .relax: return "放松"
        case .move: return "活动"
        }
    }
}

struct RecommendedTrack: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let coverURL: String?
    let source: String
    let reason: String?
    var durationSeconds: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, source, reason
        case coverURL = "cover_url"
        case durationSeconds = "duration_seconds"
    }
}

struct DecisionResponse: Decodable {
    let track: RecommendedTrack
    let items: [RecommendedTrack]
    let strategyVersion: String
    let recommendationID: String
    let provider: String
    let modeUsed: String
    let modeSource: String
    let modeExplanation: String
    let contextUsed: DecisionContext?

    enum CodingKeys: String, CodingKey {
        case track, items, provider
        case strategyVersion = "strategy_version"
        case recommendationID = "recommendation_id"
        case modeUsed = "mode_used"
        case modeSource = "mode_source"
        case modeExplanation = "mode_explanation"
        case contextUsed = "context_used"
    }
}

struct DecisionContext: Decodable {
    let scene: String?
}

struct DecisionRequest: Encodable {
    let mode: String
    let discovery: Int
    let excludeIDs: [String]
    let healthContext: HealthContext?
    let timeZone: String

    enum CodingKeys: String, CodingKey {
        case mode, discovery
        case excludeIDs = "exclude_ids"
        case healthContext = "health_context"
        case timeZone = "time_zone"
    }
}

struct PlaybackResponse: Decodable {
    let url: String?
}

enum ListeningIntent: String, Codable, CaseIterable {
    case focus, unwind, energize, accompany, explore, unknown
    var title: String {
        switch self {
        case .focus: return "专心做事"
        case .unwind: return "缓一缓"
        case .energize: return "提振状态"
        case .accompany: return "有人声或音乐陪伴"
        case .explore: return "探索新音乐"
        case .unknown: return "意图还不明确"
        }
    }
    var mode: String? {
        switch self { case .focus: return "focus"; case .unwind: return "relax"; case .energize: return "move"; default: return nil }
    }
}

enum SceneEvidenceSource: String, Codable {
    case visualHypothesis = "visual_hypothesis", userReport = "user_report", historyHypothesis = "history_hypothesis"
    var title: String {
        switch self { case .visualHypothesis: return "照片线索推测"; case .userReport: return "你的描述"; case .historyHypothesis: return "连续场景推测" }
    }
}

struct ListeningIntentHypothesis: Codable, Equatable {
    let intent: ListeningIntent
    let confidence: Double
    let evidence: String
    let source: SceneEvidenceSource
}

struct SceneUserReport: Codable, Equatable {
    let note: String
    let mood: String
    var source = "user_report"
}

enum VisualSceneCategory: String, Codable {
    case workStudy = "work_study", rest, movement, unknown
}

struct SceneResponse: Codable {
    let scene: String
    let mode: String
    let description: String
    var confidence: Double? = nil
    var sceneCategory: VisualSceneCategory? = nil
    var intentHypotheses: [ListeningIntentHypothesis]? = nil
    var temporalChange: String? = nil
    var imageCount: Int? = nil
    var userReport: SceneUserReport? = nil
}

struct EventPayload: Encodable {
    let trackID: String
    let event: String
    let mode: String
    let discovery: Int
    let playedSeconds: Double?
    let recommendationID: String?

    enum CodingKeys: String, CodingKey {
        case event, mode, discovery
        case trackID = "track_id"
        case playedSeconds = "played_seconds"
        case recommendationID = "recommendation_id"
    }
}

struct ImageAnalysisPayload: Encodable {
    let imageBase64: String
    let mimeType: String

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case mimeType = "mime_type"
    }
}
