import AVFoundation
import Foundation

enum AudioTempoError: Error, LocalizedError {
    case invalidURL, invalidResponse, insufficientAudio, unsupportedAudio, noStablePulse, downloadLimit, incompleteResource
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "音频地址不可分析"
        case .invalidResponse: return "未取得可用音频资源"
        case .insufficientAudio: return "可用音频不足 12 秒"
        case .unsupportedAudio: return "音频格式暂不可解码或定位采样"
        case .noStablePulse: return "多个片段没有足够稳定的节拍，BPM 保持未知"
        case .downloadLimit: return "资源超过 16 MB 分析下载上限，尚未完成跨段采样"
        case .incompleteResource: return "只取得部分音频资源，未把开头片段当作全曲分析"
        }
    }
    var status: String {
        switch self {
        case .noStablePulse: return "low_confidence"
        case .insufficientAudio: return "insufficient_audio"
        case .unsupportedAudio: return "unsupported_audio"
        case .downloadLimit: return "download_limited"
        case .incompleteResource: return "incomplete_resource"
        default: return "unavailable"
        }
    }
}

/// Obtains one bounded, complete compressed resource, then seeks in decoded time.
/// It never treats a byte offset as a time offset (VBR MP3 and indexed containers
/// make that assumption invalid). No credentials, microphone data or audio uploads.
/// Call only after stable real playback; downloading and decoding are cancellable.
enum AudioTempoAnalyzer {
    static let maximumDownloadBytes = 16_000_000
    static let source = "audio_distributed_pcm_onset_consensus"

    static func analyze(url: URL, expectedDuration: Double? = nil,
                        configuration: URLSessionConfiguration = .ephemeral) async throws -> TempoEstimator.RecordingEstimate {
        guard allowed(url) else { throw AudioTempoError.invalidURL }
        let localURL = try await AudioBoundedDownload.fetch(url: url, limit: maximumDownloadBytes, configuration: configuration)
        let worker = Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: localURL) }
            try Task.checkCancellation()
            return try analyzeFile(localURL, expectedDuration: expectedDuration)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// Exact same decoder/seek pipeline used by the app and real WAV/AAC fixtures.
    /// At most three small PCM windows are decoded; full-track PCM is never retained.
    static func analyzeFile(_ url: URL, expectedDuration: Double? = nil) throws -> TempoEstimator.RecordingEstimate {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AudioTempoError.unsupportedAudio }
        let format = file.processingFormat
        guard format.sampleRate.isFinite, (1_000...192_000).contains(format.sampleRate),
              format.channelCount > 0, format.channelCount <= 8, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw AudioTempoError.unsupportedAudio
        }
        let duration = Double(file.length) / format.sampleRate
        let windows = TempoEstimator.sampleWindows(duration: duration)
        guard !windows.isEmpty else { throw AudioTempoError.insufficientAudio }
        var segments: [TempoEstimator.SegmentEstimate] = []
        for window in windows {
            try Task.checkCancellation()
            let target = min(file.length - 1, max(0, AVAudioFramePosition(window.lowerBound * format.sampleRate)))
            file.framePosition = target
            let actualStart = file.framePosition
            guard abs(Double(actualStart - target) / format.sampleRate) < 0.25 else { throw AudioTempoError.unsupportedAudio }
            let maximumFrames = min(Int(file.length - actualStart), Int((window.upperBound - window.lowerBound) * format.sampleRate))
            var envelope = TempoEstimator.Envelope(sampleRate: format.sampleRate)
            var frames = 0
            while frames < maximumFrames {
                try Task.checkCancellation()
                let amount = AVAudioFrameCount(min(8_192, maximumFrames - frames))
                do { try file.read(into: buffer, frameCount: amount) }
                catch { throw AudioTempoError.incompleteResource }
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for index in 0..<Int(buffer.frameLength) {
                    // Preserve transients even when stereo channels are in opposite phase.
                    var value: Float = 0
                    for channel in 0..<Int(format.channelCount) { value += abs(channels[channel][index]) }
                    envelope.append(value / Float(format.channelCount))
                }
                frames += Int(buffer.frameLength)
            }
            // Truncated container metadata must not claim successful access to the end.
            guard frames >= maximumFrames - 2 else { throw AudioTempoError.incompleteResource }
            let estimate = TempoEstimator.estimate(envelope: envelope.values, framesPerSecond: envelope.framesPerSecond)
            let start = Double(actualStart) / format.sampleRate
            segments.append(TempoEstimator.SegmentEstimate(startSeconds: start,
                endSeconds: start + Double(frames) / format.sampleRate,
                bpm: estimate?.bpm, confidence: estimate?.confidence ?? 0, rhythmicStrength: estimate?.rhythmicStrength))
        }
        return TempoEstimator.combine(segments, resourceDuration: duration, expectedDuration: expectedDuration)
    }

    fileprivate static func allowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return host == "music.126.net" || host.hasSuffix(".music.126.net")
    }
}

/// Stream directly to a temporary compressed file. Reject oversized Content-Length
/// before accepting its body, and enforce the same bound if size is unknown/incorrect.
/// No Range is requested: partial 206 responses are refused, not presented as full songs.
private final class AudioBoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let destination: URL
    private var handle: FileHandle?
    private var received = 0
    private var expectedBytes: Int64 = -1
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var responseAccepted = false
    private var terminalError: Error?
    private let stateLock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    private init(limit: Int, url: URL) {
        self.limit = limit
        let suffix = ["mp3", "m4a", "aac", "wav", "flac"].contains(url.pathExtension.lowercased())
            ? url.pathExtension.lowercased() : "mp3"
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("linting-tempo-" + UUID().uuidString).appendingPathExtension(suffix)
    }

    static func fetch(url: URL, limit: Int, configuration: URLSessionConfiguration) async throws -> URL {
        let download = AudioBoundedDownload(limit: limit, url: url)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                download.start(url: url, configuration: configuration, continuation: continuation)
            }
        }, onCancel: { download.cancel() })
    }

    private func start(url: URL, configuration: URLSessionConfiguration, continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.allowsConstrainedNetworkAccess = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        task.priority = URLSessionTask.lowPriority
        stateLock.lock()
        self.task = task
        let wasCancelled = cancelled
        stateLock.unlock()
        task.resume()
        if wasCancelled { task.cancel() }
    }

    private func cancel() {
        stateLock.lock()
        cancelled = true
        let running = task
        stateLock.unlock()
        running?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(AudioTempoAnalyzer.allowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.url.map(AudioTempoAnalyzer.allowed) == true else {
            terminalError = AudioTempoError.invalidResponse; completionHandler(.cancel); return
        }
        guard http.statusCode == 200 else {
            terminalError = http.statusCode == 206 ? AudioTempoError.incompleteResource : AudioTempoError.invalidResponse
            completionHandler(.cancel); return
        }
        expectedBytes = response.expectedContentLength
        guard expectedBytes <= Int64(limit) else {
            terminalError = AudioTempoError.downloadLimit; completionHandler(.cancel); return
        }
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: destination)
            responseAccepted = true
            completionHandler(.allow)
        } catch { terminalError = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseAccepted, terminalError == nil else { return }
        guard data.count <= limit - received else { terminalError = AudioTempoError.downloadLimit; dataTask.cancel(); return }
        do { try handle?.write(contentsOf: data); received += data.count }
        catch { terminalError = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        stateLock.lock()
        let wasCancelled = cancelled
        self.task = nil
        stateLock.unlock()
        let failure: Error?
        if wasCancelled { failure = CancellationError() }
        else if let terminalError { failure = terminalError }
        else if let error { failure = error }
        else if !responseAccepted || received == 0 || (expectedBytes >= 0 && expectedBytes != Int64(received)) {
            failure = AudioTempoError.incompleteResource
        } else { failure = nil }
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: failure)
        } else { continuation?.resume(returning: destination) }
        continuation = nil; self.session = nil; session.invalidateAndCancel()
    }
}
