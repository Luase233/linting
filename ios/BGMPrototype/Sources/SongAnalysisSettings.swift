import Foundation
import Security
import SwiftUI

enum SongAnalysisVault {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.luase233.bgmprototype.song-analysis",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw SongAnalysisError.secureStorage }
        return data
    }

    static func write(_ data: Data, account: String) throws {
        let key = query(account)
        let code = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecSuccess { return }
        guard code == errSecItemNotFound else { throw SongAnalysisError.secureStorage }
        var request = key
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw SongAnalysisError.secureStorage }
    }

    static func removeKey() throws {
        let code = SecItemDelete(query("api-key") as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw SongAnalysisError.secureStorage }
        // The budget ledger deliberately survives key removal and key replacement.
    }
}

@MainActor
final class SongAnalysisSettings: ObservableObject {
    static let shared = SongAnalysisSettings()
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "songAnalysisEnabled") }
    }
    @Published private(set) var hasKey = false
    @Published private(set) var message = "歌曲发送歌名、艺人和歌词摘要；照片只在手动选择分析时上传。"
    @Published private(set) var budgetSummary = "今日上限 ¥1 · 本轮总上限 ¥8"
    private var storageIssue = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "songAnalysisEnabled")
        hasKey = (try? SongAnalysisVault.read("api-key")) != nil
        refreshBudgetDisplay()
    }

    func saveAPIKey(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count >= 16, !key.contains(where: { $0.isWhitespace }) else {
            message = "请填写北京地域的阿里百炼 API Key。"
            return
        }
        do {
            try SongAnalysisVault.write(Data(key.utf8), account: "api-key")
            hasKey = true
            enabled = true
            message = "密钥已保存在本机钥匙串，歌曲分析已启用。"
        } catch { message = error.localizedDescription }
    }

    func removeAPIKey() {
        do {
            try SongAnalysisVault.removeKey()
            hasKey = false
            enabled = false
            message = "密钥已移除；已有歌曲档案和预算记账保留。"
        } catch { message = error.localizedDescription }
    }

    func apiKey(for purpose: CloudAnalysisPurpose = .songText) throws -> String {
        // Disabling automatic song enrichment does not disable an explicitly chosen photo.
        guard (purpose == .photoScene || enabled), let data = try SongAnalysisVault.read("api-key"),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw SongAnalysisError.notConfigured
        }
        return key
    }

    // Called synchronously on MainActor before any network request. A durable reservation
    // covers crashes, cancellations, transport failures and missing usage without refunds.
    func reserveBudget(for purpose: CloudAnalysisPurpose = .songText) throws -> String {
        guard !storageIssue else { throw SongAnalysisError.secureStorage }
        var ledger = try readLedger()
        let day = Self.dayKey()
        let id = UUID().uuidString
        try ledger.reserve(id: id, day: day, purpose: purpose)
        try writeLedger(ledger)
        refreshBudgetDisplay()
        return id
    }

    func settleBudget(_ id: String, inputTokens: Int, outputTokens: Int) throws {
        var ledger = try readLedger()
        let valid = ledger.settle(id: id, inputTokens: inputTokens, outputTokens: outputTokens)
        try writeLedger(ledger)
        refreshBudgetDisplay()
        if !valid { throw SongAnalysisError.usageMismatch }
    }

    func refreshBudgetDisplay() {
        do {
            let ledger = try readLedger()
            let today = max(0, SongAnalysisPolicy.dailyLimitMicros - ledger.dailyMicros[Self.dayKey(), default: 0])
            let total = max(0, SongAnalysisPolicy.totalLimitMicros - ledger.totalMicros)
            budgetSummary = String(format: "今日可用预算 ¥%.3f / ¥1 · 累计可用预算 ¥%.3f / ¥8", Double(today) / 1_000_000, Double(total) / 1_000_000)
            if ledger.pricingMismatch { budgetSummary += " · 计费信息异常，已停用新请求" }
            storageIssue = false
        } catch {
            storageIssue = true
            budgetSummary = "预算记录暂不可读，已停止新云端请求。"
        }
    }

    private func readLedger() throws -> SongBudgetLedger {
        guard let data = try SongAnalysisVault.read("budget-v1") else { return SongBudgetLedger() }
        let ledger = try JSONDecoder().decode(SongBudgetLedger.self, from: data)
        guard (0...SongAnalysisPolicy.totalLimitMicros).contains(ledger.totalMicros),
              ledger.dailyMicros.values.allSatisfy({ (0...SongAnalysisPolicy.dailyLimitMicros).contains($0) }),
              ledger.dailyMicros.values.reduce(0, +) == ledger.totalMicros,
              ledger.reservations.values.allSatisfy({ item in
                  item.amountMicros == (item.purpose ?? .songText).reservationMicros &&
                  item.amountMicros <= ledger.dailyMicros[item.day, default: 0]
              }),
              ledger.reservations.values.reduce(Int64(0), { $0 + $1.amountMicros }) <= ledger.totalMicros else {
            throw SongAnalysisError.secureStorage
        }
        return ledger
    }

    private func writeLedger(_ ledger: SongBudgetLedger) throws {
        try SongAnalysisVault.write(JSONEncoder().encode(ledger), account: "budget-v1")
    }

    private static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

struct SongAnalysisCard: View {
    @ObservedObject private var settings = SongAnalysisSettings.shared
    @ObservedObject private var profiles = TrackProfileStore.shared
    @State private var key = ""
    @State private var showingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("歌曲与照片理解", systemImage: "sparkles").font(.headline)
            Toggle("逐首积累歌曲档案", isOn: $settings.enabled)
                .disabled(!settings.hasKey)
            Text(profiles.status).font(.subheadline)
            Text(settings.budgetSummary).font(.caption.monospacedDigit())
            Text("歌曲资料与手动选择的照片由阿里云分析，共用上述预算。照片先去除位置等元数据；健康、听歌记录和网易云凭据不发送。BPM 在手机测量，可信结果进入歌曲档案。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(settings.hasKey ? "更新云端密钥" : "设置云端密钥", isExpanded: $showingKey) {
                SecureField("北京地域百炼 API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Button("保存并启用") {
                        settings.saveAPIKey(key)
                        key = ""
                        profiles.resumePending()
                    }
                    .disabled(key.isEmpty)
                    if settings.hasKey {
                        Spacer()
                        Button("移除密钥", role: .destructive) { settings.removeAPIKey() }
                    }
                }
                Text(settings.message).font(.caption)
            }
            Text("预算按本机记录的本轮调用计；失败且费用未知时保留预留金额，不计入其他应用的调用。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { settings.refreshBudgetDisplay() }
        .onChange(of: settings.enabled) { _, value in if value { profiles.resumePending() } }
    }
}
