import Foundation
import ImageIO
import CoreGraphics

// Isolated executable checks: compile with LocalVisualAnalyzer, PhotoProcessing and
// SongAnalysisBudget. No real key, app profile store or paid network service is used.
struct HealthContext: Codable {}
@MainActor final class SongAnalysisSettings {
    static let shared = SongAnalysisSettings()
    var reservations = 0
    var settlements = 0
    var ledger = SongBudgetLedger()
    func apiKey(for purpose: CloudAnalysisPurpose) throws -> String { "test-only" }
    func reserveBudget(for purpose: CloudAnalysisPurpose) throws -> String { reservations += 1; let id = UUID().uuidString; try ledger.reserve(id: id, day: "test-day", purpose: purpose); return id }
    func settleBudget(_ id: String, inputTokens: Int, outputTokens: Int) throws { settlements += 1; if !ledger.settle(id: id, inputTokens: inputTokens, outputTokens: outputTokens) { throw SongAnalysisError.usageMismatch } }
}

private final class VisionFixtureProtocol: URLProtocol {
    static var responseData = Data()
    static var status = 200
    static var headers: [String: String] = [:]
    static var requests = 0
    static var waitUntilCanceled = false
    static var wasCanceled = false
    static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.url == SongAnalysisPolicy.endpoint, "request must use only the fixed Beijing endpoint")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil, "must not forward session cookies")
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        if Self.waitUntilCanceled { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.wasCanceled = true }
}

@main enum CloudVisionChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func envelope(_ object: [String: Any], finish: String = "stop", model: String = CloudVisionPolicy.model) throws -> CloudVisionResponseParser.Envelope {
        let content = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let data = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "choices": [["finish_reason": finish, "message": ["content": content]]],
            "usage": ["prompt_tokens": 1500, "completion_tokens": 200]
        ])
        return try CloudVisionResponseParser.envelope(data)
    }
    static func main() async throws {
        let diagnosticDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("linting-vision-diagnostics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: diagnosticDirectory) }
        let diagnosticsURL = diagnosticDirectory.appendingPathComponent("diagnostics.json")
        let diagnostics = CloudVisionDiagnostics(fileURL: diagnosticsURL)
        let good: [String: Any] = ["scene": "书桌", "mode": "focus", "description": "可见书本、电脑和明亮的桌面。",
            "signals": ["setting": "indoor", "activity": "reading", "lighting": "bright"], "confidence": 0.8,
            "intent_hypotheses": [["intent": "focus", "confidence": 0.65, "evidence": "书本与电脑提示可能正在阅读。", "source": "visual_hypothesis"]],
            "temporal_change": "首张场景，尚无连续变化证据。"]
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = try CloudVisionResponseParser.analysis(envelope(good), imageHash: "test-hash", at: date)
        require(valid.scene == "书桌" && valid.confidence == 0.8 && valid.analyzedAt == date, "scene evidence and timestamp retained")
        require(valid.provider == "aliyun_beijing" && valid.model == CloudVisionPolicy.model, "provenance retained")
        let restored = try JSONDecoder().decode(CloudSceneAnalysis.self, from: JSONEncoder().encode(valid))
        require(restored == valid, "full evidence round-trips for database persistence")
        for (field, bad) in [("mode", "delete" as Any), ("scene", ""), ("confidence", 2.0), ("confidence", true),
                             ("signals", ["setting": "hospital", "activity": "sad", "lighting": "bright"]),
                             ("description", "line1\nline2"), ("scene", String(repeating: "x", count: 41))] {
            var object = good; object[field] = bad
            require((try? CloudVisionResponseParser.analysis(envelope(object), imageHash: "x")) == nil, "reject invalid \(field)")
        }
        var extra = good; extra["inferred_health"] = "ignored"
        require((try? CloudVisionResponseParser.analysis(envelope(extra), imageHash: "x")) == nil, "reject unexpected fields")
        require((try? CloudVisionResponseParser.analysis(envelope(good, finish: "length"), imageHash: "x")) == nil, "reject truncated output")
        require((try? CloudVisionResponseParser.analysis(envelope(good, model: "different-model"), imageHash: "x")) == nil, "reject unexpected model")
        require((try? CloudVisionResponseParser.envelope(Data(repeating: 32, count: 64_001))) == nil, "response size bounded")

        let context = CGContext(data: nil, width: 2200, height: 1100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2200, height: 1100))
        let original = NSMutableData()
        let destination = CGImageDestinationCreateWithData(original, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLongitude: 121.5],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private metadata"]
        ] as CFDictionary)
        require(CGImageDestinationFinalize(destination), "fixture encoding works")
        let cleaned = PhotoProcessing.jpegForAnalysis(from: original as Data)!
        require(cleaned.count <= CloudVisionPolicy.maximumImageBytes, "upload bytes bounded")
        let source = CGImageSourceCreateWithData(cleaned as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        require(properties[kCGImagePropertyGPSDictionary] == nil && (properties[kCGImagePropertyExifDictionary] as? NSDictionary)?[kCGImagePropertyExifUserComment] == nil, "photo private metadata removed")
        require((properties[kCGImagePropertyPixelWidth] as! Int) <= 1024 && (properties[kCGImagePropertyPixelHeight] as! Int) <= 1024, "image resized before upload")
        require(PhotoProcessing.jpegForAnalysis(from: Data("not an image".utf8)) == nil, "bad image not uploaded")
        let body = try CloudVisualAnalyzer.requestBody(cleaned)
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        require(request["enable_thinking"] as? Bool == false && request["max_tokens"] as? Int == CloudVisionPolicy.maximumOutputTokens, "bounded non-thinking request")
        let messages = request["messages"] as! [[String: Any]]
        require(messages.count == 1, "only current photo and fixed prompt sent")
        let requestParts = messages[0]["content"] as! [[String: Any]]
        let prompt = requestParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let templateLine = prompt.split(separator: "\n").first { $0.hasPrefix("{\"scene\":") }!
        let template = try JSONSerialization.jsonObject(with: Data(templateLine.utf8)) as! [String: Any]
        let templateResult = try CloudVisionResponseParser.analysis(envelope(template), imageHash: "template")
        require(templateResult.intentHypotheses?.first?.intent == .unknown && templateResult.intentIssues == [],
                "literal JSON example in the actual serialized request matches Codable contract exactly")
        let encodedHypothesis = try JSONSerialization.jsonObject(with: JSONEncoder().encode(templateResult.intentHypotheses![0])) as! [String: Any]
        require(Set(encodedHypothesis.keys) == Set(["intent", "confidence", "evidence", "source"]),
                "wire hypothesis field names match the shared Codable model")
        do { _ = try await CloudVisualAnalyzer.analyze(Data("invalid".utf8), diagnostics: diagnostics); fatalError("invalid image accepted") }
        catch is CloudVisionError {}
        let reservations = await MainActor.run { SongAnalysisSettings.shared.reservations }
        require(reservations == 0, "invalid image must fail before any budget reservation")

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VisionFixtureProtocol.self]
        VisionFixtureProtocol.responseData = Data("valid response".utf8)
        let received = try await CloudVisualAnalyzer.submit(body, key: "fake-test-key", configuration: config)
        require(received == VisionFixtureProtocol.responseData, "bounded transport reads complete payload")
        VisionFixtureProtocol.status = 302
        VisionFixtureProtocol.headers = ["Location": "https://unexpected.invalid/redirect"]
        do { _ = try await CloudVisualAnalyzer.submit(body, key: "fake-test-key", configuration: config); fatalError("redirect accepted") }
        catch CloudVisionError.http(302) {}
        require(VisionFixtureProtocol.requests == 2, "redirect must never cause a second credentialed request")
        VisionFixtureProtocol.status = 200; VisionFixtureProtocol.headers = [:]
        VisionFixtureProtocol.responseData = Data(repeating: 120, count: 64_001)
        do { _ = try await CloudVisualAnalyzer.submit(body, key: "fake-test-key", configuration: config); fatalError("oversize accepted") }
        catch CloudVisionError.validation(.responseSize) {}
        VisionFixtureProtocol.waitUntilCanceled = true
        let canceled = Task { try await CloudVisualAnalyzer.submit(body, key: "fake-test-key", configuration: config) }
        try await Task.sleep(for: .milliseconds(80))
        canceled.cancel()
        do { _ = try await canceled.value; fatalError("cancellation ignored") } catch {}
        require(VisionFixtureProtocol.wasCanceled, "canceled transport terminates request")
        VisionFixtureProtocol.waitUntilCanceled = false
        VisionFixtureProtocol.headers = ["x-request-id": "test-request-29"]
        let requestMemory = VisualContextMemory(directory: diagnosticDirectory.appendingPathComponent("photo-memory"))
        func rawResponse(_ content: Any, finish: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["model": CloudVisionPolicy.model,
                "choices": [["finish_reason": finish, "message": ["content": content]]],
                "usage": ["prompt_tokens": 1500, "completion_tokens": 200]])
        }
        func responseText(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func expectFailure(_ reason: CloudVisionFailure) async throws {
            let before = VisionFixtureProtocol.requests
            do {
                _ = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
                fatalError("expected failure \(reason.rawValue)")
            } catch CloudVisionError.validation(let actual) { require(actual == reason, "failure diagnosed precisely as \(reason.rawValue)") }
            require(VisionFixtureProtocol.requests == before + 1, "validation failure never triggers another paid request")
            let event = await diagnostics.latest()
            require(event?.outcome == reason.rawValue && event?.budget == "settled_known", "invalid scene still settles known usage and records safe diagnosis")
        }
        VisionFixtureProtocol.responseData = try rawResponse(responseText(good))
        let complete = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
        require(complete.scene == "书桌", "normal first-photo path succeeds with strict contract")
        let successDiagnostic = await diagnostics.latest()
        require(successDiagnostic?.outcome == "success" && successDiagnostic?.requestID == "test-request-29", "successful request diagnostic includes safe vendor request identifier")
        VisionFixtureProtocol.responseData = try rawResponse("{\"scene\":", finish: "length")
        try await expectFailure(.truncated)
        VisionFixtureProtocol.responseData = try rawResponse(NSNull(), finish: "content_filter")
        try await expectFailure(.blocked)
        VisionFixtureProtocol.responseData = try rawResponse(["unsupported": "array-content"])
        try await expectFailure(.envelope)
        let afterRejections = try await requestMemory.snapshot()
        require(afterRejections.photoCount == 1 && afterRejections.summaryCount == 1, "rejected scene output never enters scene memory")
        var absentReport = good
        absentReport["intent_hypotheses"] = [["intent": "focus", "confidence": 0.9, "evidence": "用户陈述但实际未提供", "source": "user_report"]]
        VisionFixtureProtocol.responseData = try rawResponse(responseText(absentReport))
        let withoutIntent = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
        require(withoutIntent.scene == complete.scene && withoutIntent.intentHypotheses == [] && withoutIntent.preferredMode == nil,
                "valid scene survives an unsupported intent without inventing a replacement")
        require(withoutIntent.sceneResponse.intentHypotheses == [] && withoutIntent.intentIssues == [.missingUserReport] && withoutIntent.intentNotice != nil,
                "new empty intent state and visible reason replace previous successful focus result")
        let droppedDiagnostic = await diagnostics.latest()
        require(droppedDiagnostic?.outcome == "success_with_intent_limits" && droppedDiagnostic?.discardedIntentCount == 1
            && droppedDiagnostic?.intentIssueCodes == ["V116"] && droppedDiagnostic?.budget == "settled_known",
                "discarding an intent still completes and settles the single request with a safe issue code")
        var overconfident = good
        overconfident["intent_hypotheses"] = [["intent": "focus", "confidence": 0.8, "evidence": "书桌线索", "source": "visual_hypothesis"]]
        VisionFixtureProtocol.responseData = try rawResponse(responseText(overconfident))
        let limited = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
        require(limited.intentHypotheses?.first?.confidence == 0.75
            && limited.intentLimits == [CloudIntentLimit(intent: .focus, modelConfidence: 0.8, usedConfidence: 0.75)]
            && limited.intentNotice != nil, "visual intent is conservatively limited with raw and used strengths retained")
        let limitedDiagnostic = await diagnostics.latest()
        require(limitedDiagnostic?.limitedIntentCount == 1 && limitedDiagnostic?.discardedIntentCount == 0,
                "limiting is visible separately from discarding")
        overconfident["intent_hypotheses"] = [["intent": "unknown", "confidence": 0.5, "evidence": "无法判断", "source": "visual_hypothesis"]]
        VisionFixtureProtocol.responseData = try rawResponse(responseText(overconfident))
        let limitedUnknown = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
        require(limitedUnknown.intentHypotheses?.first?.confidence == 0.3 && limitedUnknown.preferredMode == nil,
                "unknown is conservatively limited and never forces a listening mode")
        let limitRoundTrip = try JSONDecoder().decode(CloudSceneAnalysis.self, from: JSONEncoder().encode(limited))
        require(limitRoundTrip == limited, "intent participation metadata survives persistence")
        overconfident["intent_hypotheses"] = [["intent": "focus", "confidence": 1.01, "evidence": "书桌线索", "source": "visual_hypothesis"]]
        VisionFixtureProtocol.responseData = try rawResponse(responseText(overconfident))
        let invalidConfidence = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
        require(invalidConfidence.scene == "书桌" && invalidConfidence.intentHypotheses == [] && invalidConfidence.intentIssues == [.confidence],
                "invalid intent confidence is discarded, never clamped into acceptable evidence")
        let goodIntent: [String: Any] = ["intent": "focus", "confidence": 0.65, "evidence": "可见书本", "source": "visual_hypothesis"]
        var extraIntent = goodIntent; extraIntent["private_unknown_key"] = "private ignored value"
        let layeredFixtures: [(Any, Int, CloudVisionFailure?)] = [
            ([], 0, nil),
            (NSNull(), 0, .intentFields),
            ("wrong-container", 0, .intentFields),
            (["wrong-wrapper": [goodIntent]], 0, .intentFields),
            (goodIntent, 1, nil),
            ([extraIntent], 1, nil),
            ([["intent": "focus", "confidence": 0.6, "evidence": "missing source"]], 0, .intentFields),
            ([goodIntent, "non-object"], 1, .intentFields),
            ([["intent": "focus", "confidence": "0.6", "evidence": "书本", "source": "visual_hypothesis"]], 0, .fieldType),
            ([["intent": "focus", "confidence": true, "evidence": "书本", "source": "visual_hypothesis"]], 0, .fieldType),
            ([["intent": "focus", "confidence": 0.6, "evidence": "书本", "source": "unrecognized"]], 0, .invalidEnum),
            ([goodIntent, goodIntent], 1, .duplicateIntent),
            ([goodIntent, goodIntent, goodIntent, goodIntent], 1, .duplicateIntent)
        ]
        for (rawIntents, acceptedCount, issue) in layeredFixtures {
            var output = good; output["intent_hypotheses"] = rawIntents
            VisionFixtureProtocol.responseData = try rawResponse(responseText(output))
            let beforeRequests = VisionFixtureProtocol.requests
            let result = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config)
            require(result.scene == "书桌" && result.intentHypotheses?.count == acceptedCount,
                    "valid scene and supported intents survive independent intent collection parsing")
            require(issue == nil ? result.intentIssues == [] : result.intentIssues?.contains(issue!) == true,
                    "discard reason is specific while successful extras require no warning")
            require(acceptedCount > 0 || result.intentNotice != nil, "empty accepted intent state has a visible explanation")
            let event = await diagnostics.latest()
            require(event?.phase == "complete" && event?.budget == "settled_known" && event?.responseStructure != nil,
                    "layered result completes one paid workflow with shape-only diagnostic")
            require(VisionFixtureProtocol.requests == beforeRequests + 1, "normalizing or discarding intent never performs a retry")
        }
        var omittedIntent = good; omittedIntent.removeValue(forKey: "intent_hypotheses")
        let omittedResult = try CloudVisionResponseParser.analysis(envelope(omittedIntent), imageHash: "missing")
        require(omittedResult.intentHypotheses == [] && omittedResult.intentIssues == [.intentFields],
                "missing intent collection cannot invalidate complete scene fields")
        var singleObject = good; singleObject["intent_hypotheses"] = extraIntent
        let normalized = try CloudVisionResponseParser.analysis(envelope(singleObject), imageHash: "single")
        require(normalized.normalizedSingleIntent == true && normalized.intentHypotheses?.first?.intent == .focus
            && normalized.intentIssues == [], "single complete object normalizes losslessly with the same evidence checks")
        var longCollection = good
        let validIntents = ["focus", "unwind", "energize", "accompany"].map { intent -> [String: Any] in
            var item = goodIntent; item["intent"] = intent; return item
        }
        longCollection["intent_hypotheses"] = ["invalid first item" as Any] + validIntents
        let bounded = try CloudVisionResponseParser.analysis(envelope(longCollection), imageHash: "bounded")
        require(bounded.intentHypotheses?.map(\.intent) == [.focus, .unwind, .energize]
            && bounded.additionalIntentCount == 1 && bounded.intentNotice?.contains("最多参考 3 项") == true,
                "long collections retain the first three valid hypotheses, skipping invalid items and explicitly limiting extras")
        let privateShape = CloudVisionStructure.summarize(try responseText(["scene": "private-scene", "private-key": "private-body",
            "intent_hypotheses": [extraIntent, ["confidence": true], NSNull()]]))!
        require(privateShape.unknownRootFieldCount == 1 && privateShape.intentCount == 3
            && privateShape.intentItems[0].unknownFieldCount == 1 && privateShape.intentItems[1].fields["confidence"] == "boolean",
                "structure summary distinguishes extras, types and item count without recording values")
        let shapeText = String(decoding: try JSONEncoder().encode(privateShape), as: UTF8.self)
        require(!shapeText.contains("private-") && !shapeText.contains("private_unknown_key") && !shapeText.contains("可见书本"),
                "unknown keys and all model prose stay out of diagnostics")
        VisionFixtureProtocol.status = 401
        do { _ = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config); fatalError("401 accepted") }
        catch CloudVisionError.http(401) {}
        let unauthorized = await diagnostics.latest()
        require(unauthorized?.outcome == "HTTP401" && unauthorized?.budget == "reserved_unknown", "HTTP auth failure remains distinct and conservatively reserved")
        VisionFixtureProtocol.status = 200; VisionFixtureProtocol.failure = URLError(.timedOut)
        do { _ = try await CloudVisualAnalyzer.analyze(cleaned, memory: requestMemory, diagnostics: diagnostics, configuration: config); fatalError("timeout accepted") }
        catch CloudVisionError.timeout {}
        let timeoutEvent = await diagnostics.latest()
        require(timeoutEvent?.outcome == "V004", "timeout is diagnosed separately from model content")
        VisionFixtureProtocol.failure = nil
        let diagnosticData = try Data(contentsOf: diagnosticsURL)
        let diagnosticText = String(decoding: diagnosticData, as: UTF8.self)
        require(!diagnosticText.contains("书桌") && !diagnosticText.contains("用户陈述") && !diagnosticText.contains("test-only") && !diagnosticText.contains("base64"), "diagnostics contain no user/model prose, key or image bytes")
        let restoredDiagnostics = CloudVisionDiagnostics(fileURL: diagnosticsURL)
        let restoredEvent = await restoredDiagnostics.latest()
        require(restoredEvent?.outcome == "V004", "safe diagnostic survives relaunch")
        // Private, disposable cache fixtures verify chronology, TTL, count, clear,
        // summaries-only mode and in-flight invalidation without uploading images.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linting-visual-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = VisualContextMemory(directory: directory)
        let now = Date()
        func frame(_ index: Int, captured: Date?, selected: Date, label: String? = nil) -> VisualContextFrame {
            // An opaque unique fixture tag distinguishes retained photo identities.
            let bytes = cleaned + Data([UInt8(index)])
            return VisualContextFrame(timing: SceneImageTime(imageID: UUID().uuidString, capturedAt: captured,
                selectedAt: selected, captureTimeLabel: label, isCurrent: true), jpeg: bytes, imageHash: VisualContextMemory.hash(bytes))
        }
        for index in 0..<6 {
            let selected = now.addingTimeInterval(Double(index - 6) * 3600)
            let item = frame(index, captured: selected.addingTimeInterval(-60), selected: selected)
            let batch = try await memory.batch(current: item, policy: .recent24h, at: now)
            try await memory.record(current: item, analysis: valid, batch: batch)
        }
        let snapshot = try await memory.snapshot(at: now)
        require(snapshot.photoCount == 5 && snapshot.summaryCount == 5, "24h memory retains at most five photos and summaries")
        let imageFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }
        require(imageFiles.count == 5, "discarded images are physically removed")
        let previousCapture = now.addingTimeInterval(-20 * 3600)
        let olderCurrent = frame(20, captured: previousCapture, selected: now)
        let chronological = try await memory.batch(current: olderCurrent, policy: .recent24h, at: now)
        require(chronological.frames.count == 5 && chronological.frames.first?.timing.isCurrent == true,
                "current selection is ordered by known capture time and not falsely assumed newest")
        require(chronological.frames.map(\.timing.orderingDate) == chronological.frames.map(\.timing.orderingDate).sorted(), "known times ordered chronologically")
        var temporalOutput = good
        temporalOutput["temporal_change"] = "早先是工作环境，后来出现休息场景；不能确定其心理状态。"
        temporalOutput["intent_hypotheses"] = [["intent": "unwind", "confidence": 0.6, "evidence": "连续活动变化提示可能想缓一缓。", "source": "history_hypothesis"]]
        let temporalResult = try CloudVisionResponseParser.analysis(envelope(temporalOutput), imageHash: olderCurrent.imageHash,
            batch: chronological, current: olderCurrent)
        require(temporalResult.imageCount == 5 && temporalResult.capturedAt == previousCapture && temporalResult.preferredMode == "relax", "temporal response retains actual image count, times and weak intent")
        let noHistory = try CloudVisionResponseParser.analysis(envelope(temporalOutput), imageHash: "x")
        require(noHistory.scene == "书桌" && noHistory.intentHypotheses == [] && noHistory.intentIssues == [.missingHistory],
                "unsupported history inference is discarded while retaining valid scene facts")
        var reported = good
        reported["intent_hypotheses"] = [["intent": "focus", "confidence": 0.95, "evidence": "用户说接下来要阅读。", "source": "user_report"]]
        let noReport = try CloudVisionResponseParser.analysis(envelope(reported), imageHash: "x")
        require(noReport.intentHypotheses == [] && noReport.userReport == nil, "model cannot invent a user report")
        let selfReport = SceneUserReport(note: "接下来要阅读", mood: "有些累")
        let reportResult = try CloudVisionResponseParser.analysis(envelope(reported), imageHash: "x", userReport: selfReport)
        require(reportResult.userReport == selfReport && reportResult.intentHypotheses?.first?.confidence == 0.95,
                "subjective state retains exact user-report provenance and separate participation limit")
        var mixed = good
        mixed["intent_hypotheses"] = [
            ["intent": "focus", "confidence": 0.6, "evidence": "可见书本", "source": "visual_hypothesis"],
            ["intent": "unwind", "confidence": 0.9, "evidence": "用户并未说过的描述", "source": "user_report"]]
        let mixedResult = try CloudVisionResponseParser.analysis(envelope(mixed), imageHash: "x")
        require(mixedResult.intentHypotheses?.count == 1 && mixedResult.preferredMode == "focus"
            && mixedResult.intentIssues == [.missingUserReport], "one unsupported intent does not discard another supported hypothesis")
        var unknown = good
        unknown["intent_hypotheses"] = [["intent": "unknown", "confidence": 0.2, "evidence": "缺少明确活动和用户说明。", "source": "visual_hypothesis"]]
        let unknownResult = try CloudVisionResponseParser.analysis(envelope(unknown), imageHash: "x")
        require(unknownResult.preferredMode == nil, "unknown intent does not force a listening direction")
        unknown["intent_hypotheses"] = [["intent": "depression", "confidence": 0.9, "evidence": "unsupported", "source": "visual_hypothesis"]]
        let unsupportedIntent = try CloudVisionResponseParser.analysis(envelope(unknown), imageHash: "x")
        require(unsupportedIntent.intentHypotheses == [] && unsupportedIntent.intentIssues == [.invalidEnum],
                "sensitive diagnosis never becomes a listening intent or contaminates valid scene facts")
        let timedBody = try CloudVisualAnalyzer.requestBody(chronological, userReport: selfReport)
        let timedText = String(decoding: timedBody, as: UTF8.self)
        require(timedText.contains("time_zone") && timedText.contains("selected_local_time") && timedText.contains("capturedAt"), "request carries explicit UTC times and timezone-labelled local displays")
        try await memory.applyPolicy(.summariesOnly)
        let summaries = try await memory.snapshot(policy: .summariesOnly, at: now)
        require(summaries.photoCount == 0 && summaries.summaryCount == 5, "summary-only immediately removes image retention")
        let afterRemoval = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }
        require(afterRemoval.isEmpty, "summary-only physically deletes prior JPEGs")
        let unknownTime = frame(21, captured: nil, selected: now, label: "2026:09:28 08:00:00（时区未知）")
        let summaryBatch = try await memory.batch(current: unknownTime, policy: .summariesOnly, at: now)
        require(summaryBatch.frames.count == 1 && summaryBatch.summaries.count == 5, "summary-only request contains one image plus bounded prior summaries")
        require(summaryBatch.frames[0].timing.capturedAt == nil && summaryBatch.frames[0].timing.captureTimeLabel != nil, "missing capture timezone never becomes an invented instant")
        try await memory.clear()
        do { try await memory.record(current: unknownTime, analysis: valid, batch: summaryBatch); fatalError("cleared memory resurrected") }
        catch VisualMemoryError.contextCleared {}
        let empty = try await memory.snapshot(at: now)
        require(empty.photoCount == 0 && empty.summaryCount == 0, "clear removes all contextual memory")
        let expiring = frame(22, captured: nil, selected: now.addingTimeInterval(-23 * 3600))
        let expirationBatch = try await memory.batch(current: expiring, policy: .recent24h, at: now)
        try await memory.record(current: expiring, analysis: valid, batch: expirationBatch)
        let expired = try await memory.snapshot(at: now.addingTimeInterval(2 * 3600))
        require(expired.photoCount == 0 && expired.summaryCount == 0, "24h expiry excludes and removes stale photos before any new upload")
        print("Cloud vision checks passed: strict schema and intent provenance, metadata removal, chronology and expiry, photo/summaries retention, clear race, bounded transport, and cancellation; no paid requests.")
    }
}
