import Foundation
import Security
import SwiftUI
import WebKit

struct MusicProfile: Codable { let id: String; let nickname: String }
struct MusicHistoryRow: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let playCount: Int
    let liked: Bool
    let recent: Bool
}
private struct MusicLibrarySnapshot: Codable { let userID: String; let rows: [MusicHistoryRow] }

enum MusicSessionVault {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.luase233.bgmprototype.netease", kSecAttrAccount as String: "session"]
    static func load() -> [String: String] {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }
    static func save(_ cookies: [String: String]) throws {
        let data = try JSONEncoder().encode(cookies)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw VaultError.failed }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VaultError.failed }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.failed }
    }
    static func filtered(_ cookies: [HTTPCookie]) -> [String: String] {
        cookies.reduce(into: [:]) { result, cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard domain == "music.163.com" || domain.hasSuffix(".music.163.com"),
                  ["MUSIC_U", "__csrf", "MUSIC_A"].contains(cookie.name),
                  cookie.expiresDate.map({ $0 > Date() }) ?? true,
                  !cookie.value.isEmpty, !cookie.value.contains(where: { $0 == ";" || $0.isNewline }) else { return }
            result[cookie.name] = cookie.value
        }
    }
    private enum VaultError: LocalizedError {
        case failed
        var errorDescription: String? { "网易云登录凭据未能存入设备钥匙串，请解锁手机后重试。" }
    }
}

@MainActor
final class MusicAccount: ObservableObject {
    @Published private(set) var profile: MusicProfile?
    @Published private(set) var status = "网易云尚未在这台手机登录"
    @Published private(set) var busy = false
    @Published private(set) var historyCount = 0
    private(set) var listeningRows: [MusicHistoryRow] = []
    @Published private(set) var sentAt: Date?
    private let client = NetEaseDirectClient()
    private var restored = false
    private var generation = 0
    var hasSession: Bool { !MusicSessionVault.load().isEmpty }
    private var snapshotURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("netease-history.json")
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        guard hasSession else { return }
        busy = true
        defer { busy = false }
        do {
            let profile = try await client.profile()
            self.profile = profile
            if let data = try? Data(contentsOf: snapshotURL),
               let snapshot = try? JSONDecoder().decode(MusicLibrarySnapshot.self, from: data), snapshot.userID == profile.id {
                listeningRows = snapshot.rows
                historyCount = snapshot.rows.count
            }
            status = "已连接 \(profile.nickname) · 手机独立登录"
        } catch NetEaseDirectError.loginRequired {
            status = "网易云登录已失效，请重新登录。"
        } catch { status = "已有本机登录凭据，暂未能验证：\(error.localizedDescription)" }
    }

    func sendCode(phone: String, country: String) async {
        guard !busy else { return }
        if let sentAt, Date().timeIntervalSince(sentAt) < 60 { status = "请等待 60 秒再发送验证码。"; return }
        guard Self.valid(phone: phone, country: country) else { status = "请填写正确的国家区号和手机号。"; return }
        busy = true
        defer { busy = false }
        do {
            try await client.sendCode(phone: phone, country: country)
            sentAt = Date()
            status = "验证码已发送，请在手机中填写。"
        } catch { status = error.localizedDescription }
    }

    func login(phone: String, country: String, code: String) async {
        guard !busy else { return }
        guard Self.valid(phone: phone, country: country), (4...8).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            status = "请填写手机号和短信验证码。"; return
        }
        busy = true
        defer { busy = false }
        do {
            let cookies = try await client.login(phone: phone, country: country, code: code)
            try await accept(cookies)
        } catch { status = error.localizedDescription }
    }

    func completeWebLogin(_ cookies: [HTTPCookie]) async {
        guard !busy else { return }
        let credentials = MusicSessionVault.filtered(cookies)
        guard credentials["MUSIC_U"] != nil else { status = "尚未读到登录结果，请在官方页面完成登录。"; return }
        busy = true
        defer { busy = false }
        do { try await accept(credentials) }
        catch { status = error.localizedDescription }
    }

    private func accept(_ credentials: [String: String]) async throws {
        let verified = try await client.profile(credentials: credentials)
        try MusicSessionVault.save(credentials)
        // A profile snapshot belongs to one account only.
        if profile?.id != verified.id { try? FileManager.default.removeItem(at: snapshotURL); historyCount = 0; listeningRows = [] }
        profile = verified
        generation += 1
        status = "已连接 \(verified.nickname)；正在同步听歌偏好…"
        await importHistory()
    }

    func syncHistory() async {
        guard !busy, profile != nil else { return }
        busy = true
        defer { busy = false }
        await importHistory()
    }

    private func importHistory() async {
        guard let profile else { return }
        let currentGeneration = generation
        do {
            let rows = try await client.listeningHistory(userID: profile.id)
            guard generation == currentGeneration else { return }
            let url = snapshotURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(MusicLibrarySnapshot(userID: profile.id, rows: rows)).write(to: url, options: [.atomic, .completeFileProtection])
            var excluded = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            historyCount = rows.count
            listeningRows = rows
            status = "已连接 \(profile.nickname)，手机保存了 \(rows.count) 条排行／喜欢记录。"
        } catch { status = "已登录；偏好同步暂未完成：\(error.localizedDescription)" }
    }

    func logout() {
        guard !busy else { return }
        do {
            try MusicSessionVault.clear()
            try? FileManager.default.removeItem(at: snapshotURL)
            generation += 1
            profile = nil
            historyCount = 0
            listeningRows = []
            status = "已清除 BGM 的登录凭据和本机听歌画像。"
        } catch { status = error.localizedDescription }
    }

    private static func valid(phone: String, country: String) -> Bool {
        (5...15).contains(phone.count) && (1...4).contains(country.count) &&
        (phone + country).allSatisfy { $0.isASCII && $0.isNumber }
    }
}

struct MusicAccountCard: View {
    @ObservedObject var account: MusicAccount
    @State private var showingLogin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("网易云账号", systemImage: "person.crop.circle").font(.headline)
            Text(account.status).font(.subheadline)
            if account.profile != nil {
                Text("手机号登录态在本机钥匙串；播放和选曲直接使用此账号，听歌偏好保存在手机。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("同步听歌偏好") { Task { await account.syncHistory() } }
                    Spacer()
                    Button("退出本机账号", role: .destructive) { account.logout() }
                }.disabled(account.busy)
            } else {
                Button("在手机上登录（无需扫码）") { showingLogin = true }.buttonStyle(.borderedProminent)
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showingLogin) { MusicLoginView(account: account) }
        .task { await account.restore() }
    }
}

private struct MusicLoginView: View {
    @ObservedObject var account: MusicAccount
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var country = "86"
    @State private var code = ""
    @State private var showingWeb = false
    var body: some View {
        NavigationStack {
            Form {
                Section("短信验证码登录") {
                    TextField("国家区号", text: $country).keyboardType(.numberPad)
                    TextField("手机号", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    Button("发送验证码") { Task { await account.sendCode(phone: phone, country: country) } }
                        .disabled(account.busy)
                    TextField("短信验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button(account.busy ? "正在处理…" : "登录网易云") {
                        Task { await account.login(phone: phone, country: country, code: code); if account.profile != nil { code = "" } }
                    }.disabled(account.busy)
                    Text("手机号和验证码直接提交网易云，BGM 不保存它们。").font(.caption)
                }
                Section {
                    Button("打开网易云官方网页登录") { showingWeb = true }
                    Text("若短信接口要求安全验证，可在官方页面选择手机号登录，亲自完成验证后读取登录结果。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { Text(account.status).font(.subheadline) }
            }
            .navigationTitle("网易云登录")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { code = ""; dismiss() } } }
            .sheet(isPresented: $showingWeb) { MusicWebLoginView(account: account) }
        }
    }
}

private struct MusicWebLoginView: View {
    @ObservedObject var account: MusicAccount
    @Environment(\.dismiss) private var dismiss
    @State private var readRequest = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(account.status).font(.caption).padding(8)
                MusicWebPage(readRequest: readRequest) { cookies in Task { await account.completeWebLogin(cookies) } }
            }
            .navigationTitle("music.163.com 官方登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("读取登录结果") { readRequest += 1 }.disabled(account.busy) }
            }
        }
    }
}

private struct MusicWebPage: UIViewRepresentable {
    let readRequest: Int
    let completed: ([HTTPCookie]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
        view.load(URLRequest(url: URL(string: "https://music.163.com/")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastRead != readRequest else { return }
        context.coordinator.lastRead = readRequest
        view.configuration.websiteDataStore.httpCookieStore.getAllCookies(completed)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRead = 0
        let completed: ([HTTPCookie]) -> Void
        init(completed: @escaping ([HTTPCookie]) -> Void) { self.completed = completed }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            // Credentials are entered into the official page, never intercepted by BGM.
            if url.scheme == "https" || url.absoluteString == "about:blank" { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
    }
}
