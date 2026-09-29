import Foundation
import ImageIO
import UIKit

/// Shared by SwiftUI covers and the system Now Playing card.
/// Images are downsampled before caching; missing search metadata is repaired from song details.
actor MusicArtworkStore {
    static let shared = MusicArtworkStore()
    private let images = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private var resolvedURLs: [String: URL] = [:]
    private let client = NetEaseDirectClient()

    init() {
        images.countLimit = 80
        images.totalCostLimit = 30 * 1024 * 1024
    }

    func image(trackID: String?, urlString: String?) async -> UIImage? {
        let validID = trackID.flatMap { value in
            !value.isEmpty && value.count <= 24 && value.allSatisfy({ $0.isASCII && $0.isNumber }) ? value : nil
        }
        let key = validID.map { "netease:" + $0 } ?? (urlString ?? "")
        guard !key.isEmpty else { return nil }
        if let image = images.object(forKey: key as NSString) { return image }
        if let work = inFlight[key] { return await work.value }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { return nil }
        // A long list cannot create unbounded network/decoder work.
        while inFlight.count >= 4 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 75_000_000)
            if let image = images.object(forKey: key as NSString) { return image }
            if let work = inFlight[key] { return await work.value }
        }
        if Task.isCancelled { return nil }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { return nil }
        let cachedURL = validID.flatMap { resolvedURLs[$0] }
        let suppliedURL = Self.normalizedURL(urlString)
        let work = Task { [weak self] () -> UIImage? in
            guard let self else { return nil }
            var attempts = [URL]()
            if let suppliedURL { attempts.append(suppliedURL) }
            if let cachedURL, !attempts.contains(cachedURL) { attempts.append(cachedURL) }
            for url in attempts {
                if let image = await Self.fetch(url) { return image }
            }
            // A liked/history row may only contain an ID/title. Ask the provider for the actual album.
            if let validID, let track = try? await self.client.songDetails(ids: [validID]).first,
               let url = Self.normalizedURL(track.coverURL), !attempts.contains(url) {
                await self.rememberURL(url, for: validID)
                return await Self.fetch(url)
            }
            return nil
        }
        inFlight[key] = work
        let result = await work.value
        inFlight.removeValue(forKey: key)
        if let result {
            images.setObject(result, forKey: key as NSString, cost: Int(result.size.width * result.size.height * 4))
            failedAt.removeValue(forKey: key)
        } else {
            failedAt[key] = Date()
            failedAt = failedAt.filter { Date().timeIntervalSince($0.value) < 60 }
        }
        return result
    }

    private func rememberURL(_ url: URL, for id: String) {
        resolvedURLs[id] = url
        if resolvedURLs.count > 300 { resolvedURLs = [id: url] }
    }

    static func normalizedURL(_ value: String?) -> URL? {
        guard let value, var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), host == "music.126.net" || host.hasSuffix(".music.126.net"),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        parts.scheme = "https"
        var query = (parts.queryItems ?? []).filter { $0.name != "param" }
        query.append(URLQueryItem(name: "param", value: "600y600"))
        parts.queryItems = query
        return parts.url
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        return URLSession(configuration: configuration, delegate: ArtworkRedirectGuard(), delegateQueue: nil)
    }()

    private static func fetch(_ url: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: url)
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= 4_000_000 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4_000_000 { return nil }
                data.append(byte)
            }
            let imageData = data
            return await Task.detached(priority: .utility) { decode(imageData) }.value
        } catch { return nil }
    }

    static func decode(_ data: Data) -> UIImage? {
        guard !data.isEmpty, data.count <= 4_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

private final class ArtworkRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let host = request.url?.host?.lowercased(), request.url?.scheme == "https",
              host == "music.126.net" || host.hasSuffix(".music.126.net") else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
