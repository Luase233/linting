import AVFoundation
import Foundation

private final class AudioFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var fixture = Data()
    static var sentRangeHeader = false
    static var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.sentRangeHeader = request.value(forHTTPHeaderField: "Range") != nil
        let path = request.url!.path
        if path.contains("cancel") { return }
        var headers = ["Content-Type": "audio/wav", "Content-Length": String(Self.fixture.count)]
        var status = 200
        if path.contains("oversize") { headers["Content-Length"] = String(AudioTempoAnalyzer.maximumDownloadBytes + 1) }
        if path.contains("oversize-unknown") { headers.removeValue(forKey: "Content-Length") }
        if path.contains("partial") { status = 206; headers["Content-Range"] = "bytes 0-99/9999" }
        if path.contains("short-body") { headers["Content-Length"] = String(Self.fixture.count + 10) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path.contains("oversize-unknown") {
            client?.urlProtocol(self, didLoad: Data(repeating: 0, count: AudioTempoAnalyzer.maximumDownloadBytes + 1))
        } else if !path.contains("oversize") && !path.contains("partial") { client?.urlProtocol(self, didLoad: Self.fixture) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped = true }
}

@main
enum AudioTempoPipelineChecks {
    static func main() async throws {
        let sampleRate = 22_050.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linting-audio-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, seconds: Double, compressed: Bool = false,
                   tempo: (Double) -> Double? = { _ in 120 }) throws -> URL {
            let url = directory.appendingPathComponent(name + (compressed ? ".m4a" : ".wav"))
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            if compressed {
                settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 64_000]
            }
            let output = try AVAudioFile(forWriting: url, settings: settings)
            let count = Int(seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
            var written = 0
            while written < count {
                let amount = min(8_192, count - written)
                buffer.frameLength = AVAudioFrameCount(amount)
                for index in 0..<amount {
                    let time = Double(written + index) / sampleRate
                    var value: Float = 0
                    if let bpm = tempo(time) {
                        let phase = time.truncatingRemainder(dividingBy: 60 / bpm)
                        value = Float(phase < 0.04 ? exp(-phase * 90) * sin(2 * .pi * 900 * phase) : 0)
                    }
                    buffer.floatChannelData![0][index] = value
                    buffer.floatChannelData![1][index] = -value
                }
                try output.write(from: buffer)
                written += amount
            }
            return url
        }
        let long = try write("240-seconds-120", seconds: 240)
        let result = try AudioTempoAnalyzer.analyzeFile(long, expectedDuration: 240)
        precondition(abs((result.bpm ?? 0) - 120) < 2, "Stereo WAV must recover 120 BPM")
        precondition(result.segments.count == 3 && abs(result.sampledSeconds - 72) < 0.1,
            "Exactly three bounded windows, not full PCM")
        precondition(abs(result.coverageFraction - 0.3) < 0.001 && result.sampledSpanFraction > 0.75,
            "Sampled seconds and temporal span are different truthful measures")
        precondition(result.segments[0].startSeconds == 24 && result.segments[1].startSeconds == 108
            && result.segments[2].startSeconds == 192, "Must actually seek to distributed positions")
        let intro = try AudioTempoAnalyzer.analyzeFile(write("60-second-silent-intro", seconds: 240,
            tempo: { $0 < 60 ? nil : 120 }), expectedDuration: 240)
        precondition(intro.segments[0].bpm == nil && intro.segments[1].bpm != nil && intro.segments[2].bpm != nil,
            "Middle/end measurements cannot accidentally decode the beginning again")
        precondition(abs((intro.bpm ?? 0) - 120) < 2 && intro.confidence < result.confidence,
            "A silent intro should not hide consistent later rhythm, and lowers confidence")
        let changing = try AudioTempoAnalyzer.analyzeFile(write("changing-tempo", seconds: 240,
            tempo: { $0 < 80 ? 100 : $0 < 160 ? 130 : 170 }), expectedDuration: 240)
        precondition(changing.bpm == nil && changing.status == "inconsistent",
            "Different section tempos must not be averaged into an invented whole-song BPM")
        let compressed = try AudioTempoAnalyzer.analyzeFile(write("compressed-180", seconds: 180, compressed: true), expectedDuration: 180)
        precondition(abs((compressed.bpm ?? 0) - 120) < 2 && compressed.segments.last!.startSeconds > 130,
            "AAC/M4A random access must measure later content")
        let previewFile = try write("preview", seconds: 30)
        let preview = try AudioTempoAnalyzer.analyzeFile(previewFile, expectedDuration: 240)
        precondition(preview.scope == "partial_resource" && preview.status == "partial_coverage",
            "Complete download of a preview is not complete recording coverage")
        precondition(preview.confidence <= 0.45 && preview.coverageFraction <= 0.126, "Preview coverage and confidence")
        do { _ = try AudioTempoAnalyzer.analyzeFile(write("too-short", seconds: 5)); fatalError("Short file should fail") }
        catch AudioTempoError.insufficientAudio { }
        let silence = try AudioTempoAnalyzer.analyzeFile(write("silence", seconds: 90, tempo: { _ in nil }))
        precondition(silence.bpm == nil && silence.segments.count == 3, "Preserve silent segment evidence without invented BPM")
        let corrupt = directory.appendingPathComponent("corrupt.mp3")
        try Data("not audio".utf8).write(to: corrupt)
        do { _ = try AudioTempoAnalyzer.analyzeFile(corrupt); fatalError("Corrupt audio should fail") }
        catch AudioTempoError.unsupportedAudio { }

        AudioFixtureProtocol.fixture = try Data(contentsOf: previewFile)
        func configuration() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral
            value.protocolClasses = [AudioFixtureProtocol.self]
            return value
        }
        let downloaded = try await AudioTempoAnalyzer.analyze(url: URL(string: "https://unit.music.126.net/complete.wav")!,
            expectedDuration: 30, configuration: configuration())
        precondition(downloaded.bpm != nil && !AudioFixtureProtocol.sentRangeHeader, "Fetch complete bounded resource, never fake byte-time ranges")
        for path in ["oversize", "oversize-unknown", "partial", "short-body"] {
            do {
                _ = try await AudioTempoAnalyzer.analyze(url: URL(string: "https://unit.music.126.net/\(path).wav")!, configuration: configuration())
                fatalError("Invalid transfer accepted: \(path)")
            } catch AudioTempoError.downloadLimit { precondition(path.hasPrefix("oversize")) }
            catch AudioTempoError.incompleteResource { precondition(path != "oversize") }
        }
        AudioFixtureProtocol.stopped = false
        let cancellation = Task {
            try await AudioTempoAnalyzer.analyze(url: URL(string: "https://unit.music.126.net/cancel.wav")!, configuration: configuration())
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        cancellation.cancel()
        do { _ = try await cancellation.value; fatalError("Canceled download completed") }
        catch is CancellationError { }
        precondition(AudioFixtureProtocol.stopped, "Cancel must stop the transport")
        print("Audio pipeline checks passed: distributed real WAV/AAC seeks, silent intro, changing tempo, preview scope, bounded HTTP/partial rejection and cancellation.")
    }
}
