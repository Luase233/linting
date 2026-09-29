import CommonCrypto
import CryptoKit
import Foundation
import Security

private final class NetEaseRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward an account cookie outside the original HTTPS API origin.
        guard let original = task.originalRequest?.url, let next = request.url,
              next.scheme == "https", next.host?.lowercased() == original.host?.lowercased() else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

/// Session metadata cache only: no account cookies, playback URLs or listening labels.
private actor NetEaseTrackMetadataCache {
    static let shared = NetEaseTrackMetadataCache()
    private var rows: [String: (RecommendedTrack, Date)] = [:]
    func cached(ids: [String], now: Date = Date()) -> [String: RecommendedTrack] {
        var result: [String: RecommendedTrack] = [:]
        for id in ids {
            if let row = rows[id], now.timeIntervalSince(row.1) < 24 * 3600 { result[id] = row.0 }
        }
        return result
    }
    func insert(_ tracks: [RecommendedTrack], now: Date = Date()) {
        for track in tracks where !track.title.isEmpty && !track.artist.isEmpty { rows[track.id] = (track, now) }
        if rows.count > 2000 {
            let old = rows.sorted { $0.value.1 < $1.value.1 }.prefix(rows.count - 2000).map(\.key)
            for id in old { rows.removeValue(forKey: id) }
        }
    }
}

// Ordinary endpoints, following api-enhanced's request format. No unlock routes.
struct NetEaseDirectClient {
    enum Crypto { case eapi, weapi }
    struct Reply { let body: [String: Any]; let cookies: [String: String] }
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: NetEaseRedirectGuard(), delegateQueue: nil)
    }()
    private var session: URLSession { Self.sharedSession }

    func search(_ query: String, limit: Int = 8, offset: Int = 0) async throws -> [RecommendedTrack] {
        let response = try await request(path: "/api/cloudsearch/pc", values: [
            "s": query, "type": 1, "limit": limit, "offset": offset, "total": true
        ])
        let result = response.body["result"] as? [String: Any]
        let tracks = (result?["songs"] as? [[String: Any]] ?? []).compactMap(Self.track)
        await NetEaseTrackMetadataCache.shared.insert(tracks)
        return tracks
    }

    func playlists(userID: String, offset: Int = 0) async throws -> (items: [MusicPlaylist], more: Bool, nextOffset: Int) {
        guard Self.validID(userID), offset >= 0 else { throw NetEaseDirectError.invalidResponse }
        let response = try await request(path: "/api/user/playlist", values: [
            "uid": userID, "limit": 100, "offset": offset, "includeVideo": false
        ], crypto: .weapi)
        guard let rows = response.body["playlist"] as? [[String: Any]] else { throw NetEaseDirectError.invalidResponse }
        let items = rows.compactMap { row -> MusicPlaylist? in
            guard let id = row["id"] as? NSNumber, let name = row["name"] as? String else { return nil }
            let creator = row["creator"] as? [String: Any]
            return MusicPlaylist(id: id.stringValue, name: name, coverURL: row["coverImgUrl"] as? String,
                trackCount: row["trackCount"] as? Int ?? 0, creator: creator?["nickname"] as? String ?? "",
                updatedAt: (row["updateTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        return (items, !rows.isEmpty && ((response.body["more"] as? Bool) ?? (rows.count == 100)), offset + rows.count)
    }

    func playlistTrackIDs(_ id: String) async throws -> [String] {
        guard Self.validID(id) else { throw NetEaseDirectError.invalidResponse }
        let response = try await request(path: "/api/v6/playlist/detail", values: ["id": id, "n": 100000, "s": 0])
        guard let playlist = response.body["playlist"] as? [String: Any],
              let rows = playlist["trackIds"] as? [[String: Any]] else { throw NetEaseDirectError.invalidResponse }
        var seen = Set<String>()
        return rows.compactMap { ($0["id"] as? NSNumber)?.stringValue }.filter { seen.insert($0).inserted }
    }

    func songDetails(ids: [String]) async throws -> [RecommendedTrack] {
        guard !ids.isEmpty, ids.count <= 100, ids.allSatisfy(Self.validID) else { throw NetEaseDirectError.invalidResponse }
        var byID = await NetEaseTrackMetadataCache.shared.cached(ids: ids)
        let missing = ids.filter { byID[$0] == nil }
        if !missing.isEmpty {
            let reply = try await request(path: "/api/v3/song/detail", values: ["c": try Self.json(missing.map { ["id": $0] })], crypto: .weapi)
            guard let songs = reply.body["songs"] as? [[String: Any]] else { throw NetEaseDirectError.invalidResponse }
            let tracks = songs.compactMap(Self.track)
            await NetEaseTrackMetadataCache.shared.insert(tracks)
            for track in tracks { byID[track.id] = track }
        }
        return ids.compactMap { byID[$0] }
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 24 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func track(_ song: [String: Any]) -> RecommendedTrack? {
        guard let id = song["id"] as? NSNumber, let title = song["name"] as? String else { return nil }
        let artists = (song["ar"] as? [[String: Any]]) ?? (song["artists"] as? [[String: Any]]) ?? []
        let album = (song["al"] as? [String: Any]) ?? (song["album"] as? [String: Any]) ?? [:]
        let durationMilliseconds = (song["dt"] as? NSNumber)?.doubleValue ?? (song["duration"] as? NSNumber)?.doubleValue
        let duration = durationMilliseconds.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        return RecommendedTrack(id: id.stringValue, title: title,
            artist: artists.compactMap { $0["name"] as? String }.joined(separator: ", "),
            album: album["name"] as? String, coverURL: album["picUrl"] as? String,
            source: "netease", reason: "网易云手机直连", durationSeconds: duration)
    }

    // Return only actual provided lyric text; no song-name completion or generated lyrics.
    // Authentication remains inside this client and is never included in cloud analysis.
    func lyrics(for trackID: String) async throws -> String? {
        guard !trackID.isEmpty, trackID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw NetEaseDirectError.invalidResponse
        }
        let reply = try await request(path: "/api/song/lyric", values: ["id": trackID, "lv": -1, "kv": -1, "tv": -1], crypto: .weapi)
        guard reply.body["nolyric"] as? Bool != true,
              let lrc = reply.body["lrc"] as? [String: Any], let raw = lrc["lyric"] as? String else { return nil }
        let clean = raw.components(separatedBy: .newlines).compactMap { line -> String? in
            let stripped = line.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }.joined(separator: "\n")
        guard !clean.isEmpty, clean != "纯音乐，请欣赏" else { return nil }
        return String(clean.prefix(3_000))
    }

    func playbackURL(for trackID: String) async throws -> URL {
        guard !trackID.isEmpty, trackID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw NetEaseDirectError.invalidResponse
        }
        let response = try await request(path: "/api/song/enhance/player/url",
            values: ["ids": "[\(trackID)]", "br": 320000])
        for entry in response.body["data"] as? [[String: Any]] ?? [] {
            guard let value = entry["url"] as? String, let url = URL(string: value),
                  let host = url.host?.lowercased(),
                  host == "music.126.net" || host.hasSuffix(".music.126.net"),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        throw NetEaseDirectError.noPlayableURL
    }

    func sendCode(phone: String, country: String) async throws {
        _ = try await request(path: "/api/sms/captcha/sent", values: [
            "cellphone": phone, "ctcode": country, "secrete": "music_middleuser_pclogin"
        ], crypto: .weapi, credentials: [:])
    }

    func login(phone: String, country: String, code: String) async throws -> [String: String] {
        let reply = try await request(path: "/api/w/login/cellphone", values: [
            "type": "1", "https": "true", "phone": phone, "countrycode": country,
            "captcha": code, "remember": "true", "secureCaptcha": ""
        ], crypto: .weapi, credentials: [:])
        guard reply.cookies["MUSIC_U"]?.isEmpty == false else { throw NetEaseDirectError.missingSession }
        return reply.cookies
    }

    func profile(credentials: [String: String]? = nil) async throws -> MusicProfile {
        let response = try await request(path: "/api/w/nuser/account/get", values: [:],
            crypto: .weapi, credentials: credentials)
        guard let profile = response.body["profile"] as? [String: Any],
              let id = profile["userId"] as? NSNumber else { throw NetEaseDirectError.loginRequired }
        return MusicProfile(id: id.stringValue, nickname: profile["nickname"] as? String ?? "网易云用户")
    }

    func listeningHistory(userID: String) async throws -> [MusicHistoryRow] {
        var rows: [String: MusicHistoryRow] = [:]
        // Preserve the old snapshot on any failed endpoint, rather than importing a partial profile.
        for scope in [0, 1] {
            let response = try await request(path: "/api/v1/play/record", values: ["uid": userID, "type": scope], crypto: .weapi)
            for record in response.body[scope == 0 ? "allData" : "weekData"] as? [[String: Any]] ?? [] {
                guard let song = record["song"] as? [String: Any], let track = Self.track(song) else { continue }
                let old = rows[track.id]
                rows[track.id] = MusicHistoryRow(id: track.id, title: track.title, artist: track.artist,
                    playCount: max(old?.playCount ?? 0, (record["playCount"] as? Int) ?? 0),
                    liked: old?.liked ?? false, recent: scope == 1 || old?.recent == true)
            }
        }
        let likes = try await request(path: "/api/song/like/get", values: ["uid": userID])
        for id in likes.body["ids"] as? [NSNumber] ?? [] {
            let key = id.stringValue
            let previous = rows[key]
            rows[key] = MusicHistoryRow(id: key, title: previous?.title ?? "", artist: previous?.artist ?? "",
                playCount: previous?.playCount ?? 0, liked: true, recent: previous?.recent ?? false)
        }
        return rows.values.sorted { $0.id < $1.id }
    }

    private func request(path: String, values: [String: Any], crypto: Crypto = .eapi,
                         credentials override: [String: String]? = nil) async throws -> Reply {
        let credentials = override ?? MusicSessionVault.load()
        var values = values
        values["e_r"] = false
        var header: [String: String] = ["os": "pc", "appver": "3.1.17.204416", "__csrf": credentials["__csrf"] ?? "",
            "requestId": "\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"]
        header.merge(credentials) { _, new in new }
        let host: String, route: String, encoded: String
        switch crypto {
        case .eapi:
            values["header"] = header
            let json = try Self.json(values)
            let digest = Insecure.MD5.hash(data: Data("nobody\(path)use\(json)md5forencrypt".utf8)).map { String(format: "%02x", $0) }.joined()
            let envelope = "\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)"
            encoded = "params=" + (try NetEaseCrypto.aes(Data(envelope.utf8), key: "e82ckenh8dichen8", cbc: false)).hex
            host = "https://interfacepc.music.163.com"
            route = "/eapi/" + path.dropFirst(5)
        case .weapi:
            values["csrf_token"] = credentials["__csrf"] ?? ""
            encoded = try NetEaseCrypto.weapi(json: Self.json(values))
            host = "https://music.163.com"
            route = "/weapi/" + path.dropFirst(5)
        }
        var request = URLRequest(url: URL(string: host + route)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(header.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.httpBody = Data(encoded.utf8)
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              body.count < 8_000_000,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NetEaseDirectError.invalidResponse
        }
        let code = object["code"] as? Int ?? -1
        guard code == 200 else {
            if [301, 401].contains(code) { throw NetEaseDirectError.loginRequired }
            if [415, 460, 8821, 903].contains(code) { throw NetEaseDirectError.verificationRequired }
            throw NetEaseDirectError.upstream(code)
        }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let key = field.key as? String, let value = field.value as? String { result[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: request.url!)
        return Reply(body: object, cookies: MusicSessionVault.filtered(cookies))
    }

    private static func json(_ object: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
    }
}

// WeAPI uses raw RSA (no PKCS#1 padding); AES uses the protocol's PKCS#7 padding.
// Protocol constants are public; they are not user credentials.
enum NetEaseCrypto {
    static func aes(_ input: Data, key: String, cbc: Bool) throws -> Data {
        let key = Data(key.utf8), iv = Data("0102030405060708".utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var count = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | (cbc ? 0 : kCCOptionECBMode)),
                            keyBytes.baseAddress, kCCKeySizeAES128, cbc ? ivBytes.baseAddress : nil,
                            inputBytes.baseAddress, input.count, outputBytes.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw NetEaseDirectError.cryptoUnavailable }
        return output.prefix(count)
    }

    static func weapi(json: String, secret: String? = nil) throws -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let key = secret ?? String((0..<16).map { _ in alphabet.randomElement()! })
        guard key.utf8.count == 16 else { throw NetEaseDirectError.cryptoUnavailable }
        let first = try aes(Data(json.utf8), key: "0CoJUm6Qyw8W8jud", cbc: true).base64EncodedString()
        let params = try aes(Data(first.utf8), key: key, cbc: true).base64EncodedString()
        let der = Data(base64Encoded: "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB")!
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 1024]
        guard let rsa = SecKeyCreateWithData(Data(der.dropFirst(22)) as CFData, attributes as CFDictionary, nil) else {
            throw NetEaseDirectError.cryptoUnavailable
        }
        var block = Data(repeating: 0, count: 112)
        block.append(Data(String(key.reversed()).utf8))
        guard let encrypted = SecKeyCreateEncryptedData(rsa, .rsaEncryptionRaw, block as CFData, nil) as Data? else {
            throw NetEaseDirectError.cryptoUnavailable
        }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "params=\(params.addingPercentEncoding(withAllowedCharacters: safe)!)&encSecKey=\(encrypted.hex)"
    }
}

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

enum NetEaseDirectError: LocalizedError {
    case invalidResponse, noPlayableURL, cryptoUnavailable, missingSession, loginRequired, verificationRequired
    case upstream(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "网易云返回了无法识别的数据，请稍后重试。"
        case .noPlayableURL: return "这首歌当前没有可播放链接，可能受账号或版权限制。"
        case .cryptoUnavailable: return "无法构造网易云请求。"
        case .missingSession: return "网易云未返回登录凭据，请使用官方网页登录。"
        case .loginRequired: return "登录已失效或尚未登录。"
        case .verificationRequired: return "网易云要求安全验证，请使用下方官方网页登录，由你完成验证。"
        case .upstream(let code): return "网易云返回状态 \(code)。若验证码登录受限，请使用官方网页登录。"
        }
    }
}
