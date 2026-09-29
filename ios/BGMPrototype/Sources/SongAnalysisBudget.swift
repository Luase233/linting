import Foundation

// Beijing snapshot pricing verified 2026-09-25. No cache/free-quota discount is assumed.
// https://help.aliyun.com/zh/model-studio/qwen-flash
enum SongAnalysisPolicy {
    static let model = "qwen-flash-2025-07-28"
    static let promptVersion = "song-text-v1"
    static let schemaVersion = "1"
    static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    static let maximumOutputTokens = 1024
    static let maximumRequestBytes = 24_000
    // UTF-8 request bytes plus substantial message framing headroom; remains in <=128k tier.
    static let reservedInputTokens = 65_536
    static let dailyLimitMicros: Int64 = 1_000_000
    static let totalLimitMicros: Int64 = 8_000_000
    static func costMicros(input: Int, output: Int) -> Int64 {
        Int64(ceil(Double(input) * 0.15 + Double(output) * 1.5))
    }
    static var reservationMicros: Int64 {
        costMicros(input: reservedInputTokens, output: maximumOutputTokens)
    }
}

// Fixed Beijing snapshot, verified 2026-09-28 against Alibaba's model-pricing and
// qwen-api-via-openai-chat-completions documentation. No free/cache discount.
enum CloudVisionPolicy {
    static let model = "qwen3-vl-flash-2026-01-22"
    static let promptVersion = "photo-context-v4-layered-intent"
    static let maximumOutputTokens = 1024
    static let reservedInputTokens = 32_768
    static let maximumImageBytes = 800_000
    static let maximumImageDimension = 1024
    static let maximumRequestBytes = 5_500_000
    static let maximumResponseBytes = 64_000
    static func costMicros(input: Int, output: Int) -> Int64 {
        Int64(ceil(Double(input) * 0.15 + Double(output) * 1.5))
    }
    static var reservationMicros: Int64 {
        costMicros(input: reservedInputTokens, output: maximumOutputTokens)
    }
}

enum CloudAnalysisPurpose: String, Codable {
    case songText = "song_text_v1"
    case photoScene = "photo_scene_v1"
    case photoContext = "photo_context_v2"

    var reservedInputTokens: Int {
        self == .songText ? SongAnalysisPolicy.reservedInputTokens : CloudVisionPolicy.reservedInputTokens
    }
    var maximumOutputTokens: Int {
        switch self {
        case .songText: return SongAnalysisPolicy.maximumOutputTokens
        case .photoScene: return 512 // Existing durable reservations retain their original envelope.
        case .photoContext: return CloudVisionPolicy.maximumOutputTokens
        }
    }
    var reservationMicros: Int64 {
        costMicros(input: reservedInputTokens, output: maximumOutputTokens)
    }
    func costMicros(input: Int, output: Int) -> Int64 {
        self == .songText ? SongAnalysisPolicy.costMicros(input: input, output: output)
            : CloudVisionPolicy.costMicros(input: input, output: output)
    }
}

struct SongBudgetReservation: Codable {
    let day: String
    let amountMicros: Int64
    // Missing on legacy budget-v1 entries: those are always song-text requests.
    var purpose: CloudAnalysisPurpose? = nil
}

struct SongBudgetLedger: Codable {
    var totalMicros: Int64 = 0
    var dailyMicros: [String: Int64] = [:]
    var reservations: [String: SongBudgetReservation] = [:]
    var pricingMismatch = false

    mutating func reserve(id: String, day: String, purpose: CloudAnalysisPurpose = .songText) throws {
        guard !pricingMismatch else { throw SongAnalysisError.usageMismatch }
        guard reservations[id] == nil else { throw SongAnalysisError.secureStorage }
        let amount = purpose.reservationMicros
        guard totalMicros + amount <= SongAnalysisPolicy.totalLimitMicros,
              dailyMicros[day, default: 0] + amount <= SongAnalysisPolicy.dailyLimitMicros else {
            throw SongAnalysisError.budgetExhausted
        }
        totalMicros += amount
        dailyMicros[day, default: 0] += amount
        reservations[id] = SongBudgetReservation(day: day, amountMicros: amount, purpose: purpose)
    }

    mutating func settle(id: String, inputTokens: Int, outputTokens: Int) -> Bool {
        guard let reserved = reservations[id] else { return true }
        let purpose = reserved.purpose ?? .songText
        guard inputTokens >= 0, inputTokens <= purpose.reservedInputTokens,
              outputTokens >= 0, outputTokens <= purpose.maximumOutputTokens else {
            pricingMismatch = true
            return false
        }
        let actual = purpose.costMicros(input: inputTokens, output: outputTokens)
        let refund = max(0, reserved.amountMicros - actual)
        totalMicros -= refund
        dailyMicros[reserved.day, default: 0] -= refund
        reservations.removeValue(forKey: id)
        return true
    }
}

enum SongAnalysisError: LocalizedError {
    case secureStorage, notConfigured, budgetExhausted, invalidResponse, http(Int), usageMismatch, oversizedInput
    var errorDescription: String? {
        switch self {
        case .secureStorage: return "安全存储不可用，云端分析已暂停；解锁手机后重试。"
        case .notConfigured: return "云端分析尚未配置密钥，或歌曲自动分析未启用。"
        case .budgetExhausted: return "已达到歌曲与照片共用的云端预算，继续使用已有档案。"
        case .invalidResponse: return "本次歌曲分析没有返回可用结构，已保留记账且不自动重试。"
        case .http(let code): return "歌曲分析服务返回状态 \(code)，本次不自动重试。"
        case .usageMismatch: return "服务返回的计费信息超出预留边界，已停止新云端请求。"
        case .oversizedInput: return "歌曲资料超过本次分析长度限制。"
        }
    }
}
