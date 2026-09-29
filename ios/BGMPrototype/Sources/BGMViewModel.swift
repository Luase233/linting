import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class BGMViewModel: ObservableObject {
    @Published var modeSelection: ModeSelection = .auto {
        didSet {
            if modeSelection != oldValue {
                recordAction("intent_\(modeSelection.rawValue)", source: "app")
                schedulePreparation()
            }
        }
    }
    @Published var discovery = 1 { didSet { if discovery != oldValue { schedulePreparation() } } }
    @Published private(set) var recommendations: [RecommendedTrack] = []
    @Published private(set) var strategyVersion = ""
    @Published private(set) var currentTrack: RecommendedTrack?
    @Published private(set) var decisionSnapshot: AdaptiveDecisionSnapshot?
    @Published private(set) var preparedTrackCount = 0
    @Published private(set) var modeUsed: ListeningMode?
    @Published private(set) var modeSource = ""
    @Published private(set) var modeExplanation = ""
    @Published private(set) var contextScene: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var renderedSeconds = 0.0
    @Published private(set) var isLiked = false
    @Published private(set) var playbackStateText = ""
    @Published private(set) var learningSummary = "尚未积累本机学习记录"
    @Published private(set) var scene: SceneResponse?
    @Published private(set) var lastSceneAnalysis: CloudSceneAnalysis?
    @Published var userNote = ""
    @Published var selfReportedMood: SelfReportedMood = .unspecified {
        didSet {
            guard selfReportedMood != oldValue, !restoringReportedContext else { return }
            moodObservedAt = Date()
            persistReportedContext()
            schedulePreparation()
        }
    }
    @Published var inferredIntentPolicy: InferredIntentPolicy = .automatic {
        didSet {
            UserDefaults.standard.set(inferredIntentPolicy.rawValue, forKey: "listening.intentPolicy")
            schedulePreparation()
        }
    }
    @Published private(set) var confirmedListeningIntent: ListeningIntent?
    @Published private(set) var sceneMemoryPolicy: SceneMemoryPolicy = .recent24h
    @Published private(set) var sceneMemorySnapshot: VisualMemorySnapshot?
    @Published var message: String?

    let health = HealthKitManager()
    let musicAccount = MusicAccount()
    let locationContext = LocationContextManager()
    private let recommender = LocalRecommendationEngine()
    private let player = AVPlayer()
    private let playbackClient = NetEaseDirectClient()
    private var startupTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var cachedHealth: HealthContext?
    private var healthTask: Task<Void, Never>?
    private var lastHealthRefresh = Date.distantPast
    private var lastPreparationAt = Date.distantPast
    private var recentPlayedIDs: [String] = []
    private struct CachedPlaybackURL { let url: URL; let at: Date }
    private var playbackURLs: [String: CachedPlaybackURL] = [:]
    private struct PendingPlaybackURL { let id: UUID; let task: Task<URL, Error> }
    private var playbackURLTasks: [String: PendingPlaybackURL] = [:]
    private var preparedItem: (trackID: String, url: URL, item: AVPlayerItem)?
    private var decision: DecisionResponse?
    private var failedIDs: [String] = []
    private var consecutiveFailures = 0
    private var currentRecommendationID: String?
    private var sceneCapturedAt: Date?
    private var sceneConfidence = 0.0
    private var moodObservedAt: Date?
    private var restoringReportedContext = false
    private var confirmedIntentAt: Date?
    private var visualPlaceCategory: String?
    private var visualPlaceObservedAt: Date?
    private var pendingRetryDecisionID: String?
    private var analysisTask: Task<CloudSceneAnalysis, Error>?
    private var analysisGeneration = 0
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = 0
    private struct IntentCorrection: Codable {
        let analysisID: String
        let imageHash: String
        let observedAt: Date
        let correctedAt: Date
        let selectedIntent: ListeningIntent?
        let action: String
    }
    private struct ReportedContext: Codable {
        let mood: SelfReportedMood
        let observedAt: Date?
    }
    private var tracker: PlaybackTracker?
    private var isSeeking = false
    private var startRecorded = false
    private var activePlaybackURL: URL?
    private var audioAnalysisRequested = false
    private var handlingFailure = false
    private var lastCheckpointAt = Date.distantPast
    private var generation = 0
    private var wantsPlayback = false
    private var transitionStartedAt: TimeInterval?
    private var transitionMetricDetail = ""
    private var playingLatencyRecorded = false
    private var lastPlayed: (RecommendedTrack, DecisionResponse)?
    private var currentDecision: DecisionResponse?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var systemObservers: [NSObjectProtocol] = []
    private var isDeviceCheck: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LINTING_DEVICE_CHECK"] == "1"
        #else
        return false
        #endif
    }
    private var statusObservation: NSKeyValueObservation?
    private var transportObservation: NSKeyValueObservation?

    init() {
        inferredIntentPolicy = InferredIntentPolicy(rawValue: UserDefaults.standard.string(forKey: "listening.intentPolicy") ?? "") ?? .automatic
        sceneMemoryPolicy = SceneMemoryPolicy(rawValue: UserDefaults.standard.string(forKey: "listening.sceneMemoryPolicy") ?? "") ?? .recent24h
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recommender.prepare()
                // A process termination is unknown observation, never a voluntary dislike.
                if let recovered = PlaybackCheckpoint.recover() {
                    try self.recommender.recordEpisode(recovered)
                    try await ListeningDatabase.shared.flush()
                    PlaybackCheckpoint.clear()
                }
                self.learningSummary = self.recommender.learningSummary
                if let saved = try? await ListeningDatabase.shared.document(collection: "self_reported_context", id: "current", as: ReportedContext.self) {
                    self.restoringReportedContext = true
                    self.selfReportedMood = saved.mood
                    self.moodObservedAt = saved.observedAt
                    self.restoringReportedContext = false
                }
                await self.refreshSceneMemory()
                self.schedulePreparation()
            } catch { self.message = "本机学习记录暂未恢复：\(error.localizedDescription)" }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.samplePlayback()
                if Date().timeIntervalSince(self.lastCheckpointAt) >= 15 { self.checkpoint() }
                if self.isPlaying, Date().timeIntervalSince(self.lastPreparationAt) >= 60 { self.schedulePreparation() }
                if self.player.currentItem?.status == .failed { await self.handlePlaybackFailure() }
            }
        }
        transportObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.transportChanged() }
        }
        observeSystemAudio()
        configureRemoteCommands()
    }

    func play(source: String = "app") async {
        wantsPlayback = true
        if currentTrack != nil, player.currentItem != nil {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                recordAction("resume", source: source)
                player.play()
                transportChanged()
                schedulePreparation()
            } catch { message = "无法恢复音频：\(error.localizedDescription)" }
            return
        }
        consecutiveFailures = 0
        await transition(endingReason: nil, source: source)
    }

    func pause(source: String = "app") {
        wantsPlayback = false
        TrackProfileStore.shared.cancelPendingAudio()
        audioAnalysisRequested = false
        transitionStartedAt = nil
        generation += 1
        if isLoading { message = "已暂停，正在等待的选曲不会自动播放。" }
        isLoading = false
        preparationTask?.cancel()
        preparationGeneration += 1
        preparationTask = nil
        guard currentTrack != nil else { return }
        samplePlayback()
        recordAction("pause", source: source)
        player.pause()
        transportChanged()
        checkpoint()
    }

    func next(source: String = "app") async {
        wantsPlayback = true
        if currentTrack != nil { recordAction("manual_next", source: source) }
        consecutiveFailures = 0
        await transition(endingReason: currentTrack == nil ? nil : "user_next", source: source)
    }

    func play(_ alternative: RecommendedTrack) async {
        guard recommendations.contains(where: { $0.id == alternative.id }) else { return }
        await playRequested(alternative, source: "candidate")
    }

    /// Search, playlist and candidate choices use the same playback evidence and learning path.
    func playRequested(_ track: RecommendedTrack, source: String) async {
        if track.id == currentTrack?.id { await replay(source: source); return }
        let reason = source == "candidate" ? "manual_candidate"
            : (source == "diagnostic" || source.hasPrefix("manual_") ? source : "manual_selection")
        await startManual(track, parent: decision, reason: reason, source: source)
    }

    func replay(source: String = "app") async {
        guard let track = currentTrack, let previousDecision = currentDecision else { return }
        await startManual(track, parent: previousDecision, reason: "manual_replay", source: source)
    }

    func previous(source: String = "app") async {
        guard let (track, oldDecision) = lastPlayed else { await replay(source: source); return }
        await startManual(track, parent: oldDecision, reason: "manual_previous", source: source)
    }

    private func startManual(_ track: RecommendedTrack, parent: DecisionResponse?, reason: String, source: String) async {
        pendingRetryDecisionID = nil
        generation += 1
        let token = generation
        isLoading = true
        wantsPlayback = true
        defer { if token == generation { isLoading = false } }
        let action = reason == "manual_replay" ? "replay" : reason == "manual_previous" ? "manual_previous" : "select_track"
        recordAction(action, source: source == "remote" ? "remote" : source == "diagnostic" ? "system" : "app")
        finishCurrent(reason: reason == "manual_replay" ? "manual_replay" : "user_selected_other")
        playbackStateText = "正在准备点播…"
        transitionStartedAt = ProcessInfo.processInfo.systemUptime
        consecutiveFailures = 0
        await startupTask?.value
        guard token == generation, wantsPlayback else { return }
        let manualID = await manualDecisionID(for: track, from: parent?.recommendationID, reason: reason)
        guard token == generation, wantsPlayback else { return }
        let response = DecisionResponse(track: track, items: [track],
            strategyVersion: LocalRecommendationEngine.policyVersion, recommendationID: manualID ?? UUID().uuidString,
            provider: track.source, modeUsed: modeSelection.rawValue, modeSource: "manual",
            modeExplanation: "由你点播；播放时长、跳过与明确反馈继续进入同一学习算法。",
            contextUsed: DecisionContext(scene: freshScene?.scene))
        self.decision = response
        recommendations = response.items
        if !(await startTrack(track, from: response, decisionID: manualID, startReason: reason,
                              expectedGeneration: token, source: source)) {
            pendingRetryDecisionID = manualID
            await decideAndStart(expectedGeneration: token)
        }
    }

    func seek(to seconds: Double, source: String = "app") async {
        guard let item = player.currentItem, currentTrack != nil, !isLoading, !isSeeking,
              duration > 0, seconds.isFinite else { return }
        let target = max(0, min(seconds, max(0, duration - 0.1)))
        samplePlayback()
        isSeeking = true
        recordAction("seek", source: source, target: target)
        let completed = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
        guard player.currentItem === item else { isSeeking = false; return }
        isSeeking = false
        tracker?.resetPosition(safePosition, monotonic: ProcessInfo.processInfo.systemUptime,
                               isPlaying: player.timeControlStatus == .playing)
        samplePlayback()
        checkpoint()
        if !completed { message = "拖动未完成，保留实际播放位置。" }
    }

    func feedback(_ event: String) {
        guard let track = currentTrack, let tracker, !isLoading else { return }
        let kind = event == "liked" && isLiked ? "unliked" : event
        guard ["liked", "unliked", "disliked", "suitable", "unsuitable"].contains(kind) else { return }
        recordAction(kind, source: "app")
        do {
            try recommender.recordFeedback(trackID: track.id, decisionID: currentRecommendationID,
                                           episodeID: tracker.id, kind: kind)
            learningSummary = recommender.learningSummary
            if kind == "liked" || kind == "unliked" {
                isLiked = kind == "liked"
                message = isLiked ? "已喜欢，将用于学习你的口味与当下偏好。" : "已取消本机喜欢。"
                schedulePreparation()
            } else if kind == "suitable" {
                message = "已记录这首此刻合适；它与长期喜欢分开学习。"
                schedulePreparation()
            } else {
                Task { await transition(endingReason: kind == "disliked" ? "explicit_dislike" : "context_unsuitable", source: "app") }
            }
        } catch { message = "反馈未能保存：\(error.localizedDescription)" }
    }

    func analyzePhoto(jpegData: Data, capturedAt: Date? = nil, captureTimeLabel: String? = nil) async {
        analysisTask?.cancel()
        analysisGeneration += 1
        let token = analysisGeneration
        isAnalyzing = true
        defer { if token == analysisGeneration { isAnalyzing = false; analysisTask = nil } }
        let note = String(userNote.prefix(500))
        let mood = selfReportedMood == .unspecified ? "" : selfReportedMood.rawValue
        let policy = sceneMemoryPolicy
        locationContext.refreshIfAuthorized()
        let locationLabel = locationContext.freshCategory == nil ? nil : locationContext.semanticLabel
        let locationObservedAt = locationLabel == nil ? nil : locationContext.observedAt
        let locationCategory = locationLabel == nil ? nil : locationContext.freshCategory
        let task = Task {
            try await CloudVisualAnalyzer.analyze(jpegData, userNote: note, mood: mood, policy: policy,
                capturedAt: capturedAt, captureTimeLabel: captureTimeLabel,
                locationLabel: locationLabel, locationObservedAt: locationObservedAt)
        }
        analysisTask = task
        do {
            let result = try await task.value
            guard token == analysisGeneration, !Task.isCancelled else { return }
            lastSceneAnalysis = result
            visualPlaceCategory = result.locationLabel == nil ? nil : locationCategory
            visualPlaceObservedAt = result.locationObservedAt
            scene = result.sceneResponse
            sceneCapturedAt = capturedAt ?? result.analyzedAt
            sceneConfidence = result.confidence
            confirmedListeningIntent = nil
            confirmedIntentAt = nil
            if let saved = try? await ListeningDatabase.shared.document(collection: "intent_corrections",
                id: result.analysisID ?? result.imageHash, as: IntentCorrection.self) {
                guard token == analysisGeneration else { return }
                confirmedListeningIntent = saved.selectedIntent
                confirmedIntentAt = saved.correctedAt
            }
            ListeningDatabase.shared.saveScene(result)
            await refreshSceneMemory()
            schedulePreparation()
            message = "已结合照片、拍摄时间和你的描述更新听歌线索；下一首会轻量参考，你也可以纠正。"
        } catch {
            guard token == analysisGeneration, !Task.isCancelled else { return }
            message = "照片分析失败：\(error.localizedDescription)"
        }
    }

    var inferredListeningIntent: ListeningIntentHypothesis? {
        let usable = lastSceneAnalysis?.intentHypotheses?.filter { $0.intent != .unknown && $0.confidence >= 0.35 } ?? []
        let reported = usable.filter { $0.source == .userReport }
        return (reported.isEmpty ? usable : reported).max { $0.confidence < $1.confidence }
    }

    var inferredIntentConfirmed: Bool {
        confirmedListeningIntent != nil && listeningContext.visualQuality(at: Date()) > 0
    }

    var intentConfirmationText: String {
        if modeSelection != .auto { return "当前采用你手动选择的听歌方向，图片意图暂不参与。" }
        if let confirmedListeningIntent {
            return listeningContext.visualQuality(at: Date()) > 0 ? "已按你的选择：" + confirmedListeningIntent.title : "此前确认的意图已过期，可重新选择当前方向。"
        }
        guard let hypothesis = inferredListeningIntent else { return "尚无明确意图；仍按听歌反馈推荐。" }
        guard listeningContext.visualQuality(at: Date()) > 0 else {
            return "图片意图已过期、场景已变或已有你的自述，当前不再沿用旧推断。"
        }
        if inferredIntentPolicy == .confirmOnly { return "待你确认：" + hypothesis.intent.title }
        return "轻量参考：" + hypothesis.intent.title + "，可随时纠正。"
    }

    func confirmInferredIntent() {
        guard let intent = inferredListeningIntent?.intent else { return }
        applyIntentCorrection(intent, action: "confirmed")
    }

    func correctInferredIntent(_ intent: ListeningIntent) {
        applyIntentCorrection(intent, action: "corrected")
    }

    func correctInferredIntent(_ mode: ModeSelection) {
        let intent: ListeningIntent
        switch mode { case .focus: intent = .focus; case .relax: intent = .unwind; case .move: intent = .energize; case .auto: intent = .unknown }
        correctInferredIntent(intent)
    }

    func resetInferredIntent() {
        applyIntentCorrection(nil, action: "reset")
    }

    private func applyIntentCorrection(_ intent: ListeningIntent?, action: String) {
        // A new explicit correction is the latest intent; a later mode change can override it.
        if intent != nil { modeSelection = .auto }
        confirmedListeningIntent = intent
        confirmedIntentAt = intent == nil ? nil : Date()
        if let analysis = lastSceneAnalysis {
            let record = IntentCorrection(analysisID: analysis.analysisID ?? analysis.imageHash,
                imageHash: analysis.imageHash, observedAt: sceneCapturedAt ?? analysis.analyzedAt,
                correctedAt: Date(), selectedIntent: intent, action: action)
            ListeningDatabase.shared.saveDocument(collection: "intent_corrections", id: record.analysisID, value: record)
        }
        recordAction("intent_" + action, source: "app")
        schedulePreparation()
    }

    private func persistReportedContext() {
        ListeningDatabase.shared.saveDocument(collection: "self_reported_context", id: "current",
            value: ReportedContext(mood: selfReportedMood, observedAt: moodObservedAt))
    }

    func refreshLocationContext() { schedulePreparation() }

    func refreshSceneMemory() async {
        do { sceneMemorySnapshot = try await VisualContextMemory.shared.snapshot(policy: sceneMemoryPolicy) }
        catch { message = "照片记忆状态暂不可读：\(error.localizedDescription)" }
    }

    func changeSceneMemoryPolicy(_ policy: SceneMemoryPolicy) async {
        cancelSceneAnalysis()
        do {
            try await VisualContextMemory.shared.applyPolicy(policy)
            sceneMemoryPolicy = policy
            UserDefaults.standard.set(policy.rawValue, forKey: "listening.sceneMemoryPolicy")
            clearCurrentSceneContext()
            await refreshSceneMemory()
            schedulePreparation()
        } catch { message = "照片记忆范围未能修改：\(error.localizedDescription)" }
    }

    func clearSceneMemory() async {
        cancelSceneAnalysis()
        do {
            try await VisualContextMemory.shared.clear()
            ListeningDatabase.shared.deleteDocuments(collection: "intent_corrections")
            ListeningDatabase.shared.deleteDocuments(collection: "scene_analysis")
            clearCurrentSceneContext()
            await refreshSceneMemory()
            schedulePreparation()
            message = "已清除照片记忆和意图纠正；以后从新照片重新判断。"
        } catch { message = "照片记忆暂未清除：\(error.localizedDescription)" }
    }

    private func cancelSceneAnalysis() {
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }

    private func clearCurrentSceneContext() {
        lastSceneAnalysis = nil; scene = nil; sceneCapturedAt = nil; sceneConfidence = 0
        confirmedListeningIntent = nil; confirmedIntentAt = nil
        visualPlaceCategory = nil; visualPlaceObservedAt = nil
    }

    func verifyNetEaseDirect() async { await play() }

    private func manualDecisionID(for track: RecommendedTrack, from oldID: String?, reason: String) async -> String? {
        do { try await recommender.prepare() }
        catch { message = "点播学习记录暂不可用：\(error.localizedDescription)"; return nil }
        refreshHealthInBackground()
        return recommender.registerManualSelection(track: track, from: oldID,
            selection: modeSelection, discovery: discovery, scene: freshScene,
            health: effectiveHealth, history: musicAccount.listeningRows,
            sceneObservedAt: freshScene == nil ? nil : sceneCapturedAt, reason: reason, listeningContext: listeningContext)
    }

    private func transition(endingReason: String?, source: String) async {
        isLoading = true
        transitionStartedAt = ProcessInfo.processInfo.systemUptime
        generation += 1
        let token = generation
        let lease = PlaybackBackgroundLease()
        lease.identifier = UIApplication.shared.beginBackgroundTask(withName: "ChooseNextTrack") { [weak self, lease] in
            Task { @MainActor [weak self] in
                lease.end()
                guard let self, self.generation == token, self.isLoading else { return }
                self.generation += 1
                self.wantsPlayback = false
                self.isLoading = false
                self.message = "系统暂停了后台选曲，请打开 App 继续。"
            }
        }
        defer {
            if token == generation { isLoading = false }
            lease.end()
        }
        pendingRetryDecisionID = endingReason == "playback_error" ? currentRecommendationID : nil
        if let endingReason { finishCurrent(reason: endingReason) }
        if endingReason == "natural_end" { consecutiveFailures = 0 }
        decision = nil; recommendations = []; modeUsed = nil; contextScene = nil
        playbackStateText = "正在切歌…"
        await startupTask?.value
        guard token == generation, wantsPlayback else { return }
        await decideAndStart(expectedGeneration: token)
    }

    private func decideAndStart(expectedGeneration: Int? = nil) async {
        let token = expectedGeneration ?? generation
        while consecutiveFailures < 5, token == generation, wantsPlayback {
            do {
                refreshHealthInBackground()
                let result = try await recommender.nextDecision(selection: modeSelection,
                    discovery: discovery, scene: freshScene, health: effectiveHealth,
                    history: musicAccount.listeningRows, excludeIDs: excludedRecommendationIDs,
                    sceneObservedAt: freshScene == nil ? nil : sceneCapturedAt, listeningContext: listeningContext,
                    parentDecisionID: pendingRetryDecisionID)
                guard token == generation else { return }
                pendingRetryDecisionID = result.recommendationID
                decision = result; recommendations = result.items; strategyVersion = result.strategyVersion
                modeUsed = nil; modeSource = result.modeSource; modeExplanation = result.modeExplanation
                contextScene = result.contextUsed?.scene; learningSummary = recommender.learningSummary
                if await startTrack(result.track, from: result, decisionID: result.recommendationID,
                                    startReason: "automatic", expectedGeneration: token) {
                    pendingRetryDecisionID = nil
                    return
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                message = "手机选曲失败：\(error.localizedDescription)"
                return
            }
        }
        if token == generation { message = "连续 5 次无法播放，已停止自动选曲；请检查音乐来源或网络。" }
    }

    private func startTrack(_ track: RecommendedTrack, from decision: DecisionResponse,
                            decisionID: String?, startReason: String, expectedGeneration: Int? = nil,
                            source: String = "app") async -> Bool {
        let token = expectedGeneration ?? generation
        let evidenceStartReason = isDeviceCheck ? "diagnostic" : startReason
        do {
            let cached = playbackURLs[track.id].map { Date().timeIntervalSince($0.at) < 240 } == true
            let url = try await playbackURL(for: track.id)
            guard token == generation, wantsPlayback else { return false }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = preparedItem.flatMap { $0.trackID == track.id && $0.url == url ? $0.item : nil } ?? AVPlayerItem(url: url)
            preparedItem = nil
            clearItemObservers()
            player.replaceCurrentItem(with: item)
            currentTrack = track; currentDecision = decision; currentRecommendationID = decisionID
            activePlaybackURL = url; audioAnalysisRequested = false
            strategyVersion = decision.strategyVersion
            modeSource = decision.modeSource; modeExplanation = decision.modeExplanation
            contextScene = decision.contextUsed?.scene
            decisionSnapshot = recommender.decisionSnapshot(id: decisionID)
            recentPlayedIDs.removeAll { $0 == track.id }
            recentPlayedIDs.append(track.id)
            recentPlayedIDs = Array(recentPlayedIDs.suffix(3))
            recommender.remember(track)
            elapsed = 0; duration = track.durationSeconds ?? 0; renderedSeconds = 0
            startRecorded = false
            isLiked = recommender.isLiked(trackID: track.id,
                imported: musicAccount.listeningRows.contains { $0.id == track.id && $0.liked })
            tracker = PlaybackTracker(decisionID: decisionID, trackID: track.id,
                                      startReason: evidenceStartReason, duration: track.durationSeconds)
            tracker?.resetPosition(0, monotonic: ProcessInfo.processInfo.systemUptime, isPlaying: false)
            observe(item)
            recordAction("play", source: startReason == "automatic" ? "automatic" : startReason == "diagnostic" ? "system" : "app")
            playingLatencyRecorded = false
            transitionMetricDetail = "source=\(startReason);url_cache=\(cached ? "hit" : "miss");candidates=\(recommender.cachedCandidateCount)"
            player.play()
            if let began = transitionStartedAt {
                ListeningDatabase.shared.recordMetric("transition_to_play_request",
                    milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000, detail: transitionMetricDetail)
            }
            transportChanged()
            message = decision.modeExplanation
            updateNowPlaying(track)
            checkpoint()
            let sourceTag = decisionSnapshot?.candidate(track.id)?.sourceTag ?? "手动选择"
            TrackProfileStore.shared.enqueue(track, seedTags: [sourceTag])
            schedulePreparation()
            return true
        } catch {
            guard token == generation, wantsPlayback, !Task.isCancelled else { return false }
            playbackURLs.removeValue(forKey: track.id)
            rememberFailed(track.id)
            let failure = PlaybackEvidence(id: UUID().uuidString, decisionID: decisionID, trackID: track.id,
                startedAt: Date(), endedAt: Date(), duration: track.durationSeconds, renderedSeconds: 0,
                uniqueCoveredSeconds: 0, lastPosition: 0, startReason: evidenceStartReason,
                endReason: "playback_error", actions: [], contentKind: "unknown")
            try? recommender.recordEpisode(failure)
            message = "“\(track.title)”暂时无法播放，正在重新选曲。"
            return false
        }
    }

    private func finishCurrent(reason: String) {
        samplePlayback()
        if let tracker {
            do {
                try recommender.recordEpisode(tracker.evidence(reason: reason))
                let episodeID = tracker.id
                Task { [weak self] in
                    do {
                        try await ListeningDatabase.shared.flush()
                        // Never clear the checkpoint for a newer song while an earlier write drains.
                        if PlaybackCheckpoint.recover()?.id == episodeID { PlaybackCheckpoint.clear() }
                    } catch { self?.message = "播放记录暂未落盘：\(error.localizedDescription)" }
                }
            } catch { message = "播放记录未能保存：\(error.localizedDescription)" }
        }
        if reason != "manual_replay", let track = currentTrack, let decision = currentDecision { lastPlayed = (track, decision) }
        self.tracker = nil
        activePlaybackURL = nil; audioAnalysisRequested = false
        TrackProfileStore.shared.cancelPendingAudio()
        artworkGeneration += 1
        artworkTask?.cancel(); artworkTask = nil
        player.pause(); clearItemObservers(); player.replaceCurrentItem(with: nil)
        currentTrack = nil; currentRecommendationID = nil; currentDecision = nil; decisionSnapshot = nil
        isPlaying = false; elapsed = 0; duration = 0; renderedSeconds = 0; isSeeking = false
        playbackStateText = ""; learningSummary = recommender.learningSummary
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func handlePlaybackFailure() async {
        guard currentTrack != nil, !isLoading, !handlingFailure else { return }
        handlingFailure = true
        defer { handlingFailure = false }
        if let id = currentTrack?.id { rememberFailed(id) }
        if consecutiveFailures >= 5 {
            finishCurrent(reason: "playback_error")
            message = "连续 5 次无法播放，已停止自动选曲。"
        } else { await transition(endingReason: "playback_error", source: "system") }
    }

    private func rememberFailed(_ id: String) {
        failedIDs.removeAll { $0 == id }; failedIDs.insert(id, at: 0)
        failedIDs = Array(failedIDs.prefix(20)); consecutiveFailures += 1
    }

    private var freshScene: SceneResponse? {
        guard sceneConfidence >= 0.35, let capturedAt = sceneCapturedAt else { return nil }
        return listeningContext.sceneQuality(confidence: sceneConfidence, observedAt: capturedAt, at: Date()) > 0 ? scene : nil
    }

    private var listeningContext: RecommendationListeningContext {
        let hypothesis = inferredListeningIntent.flatMap { $0.confidence >= 0.35 ? $0 : nil }
        let confirmed = confirmedListeningIntent != nil
        let intent = confirmedListeningIntent ?? (inferredIntentPolicy == .automatic ? hypothesis?.intent : nil)
        let inferredAt = hypothesis?.source == .userReport ? lastSceneAnalysis?.analyzedAt : sceneCapturedAt
        return RecommendationListeningContext(visualIntent: intent,
            confidence: confirmed ? 1 : (hypothesis?.confidence ?? 0), confirmed: confirmed,
            observedAt: confirmed ? confirmedIntentAt : inferredAt,
            selfReportedMood: selfReportedMood, moodObservedAt: moodObservedAt,
            placeCategory: locationContext.freshCategory, placeObservedAt: locationContext.observedAt,
            placeConfidence: locationContext.semanticConfidence,
            visualSource: hypothesis?.source,
            visualPlaceCategory: visualPlaceCategory, visualPlaceObservedAt: visualPlaceObservedAt,
            visualIncludesPlaceEvidence: lastSceneAnalysis?.locationLabel != nil,
            contextChangedAt: locationContext.semanticChangedAt)
    }

    private var effectiveHealth: HealthContext? { health.enabled ? cachedHealth : nil }

    private var excludedRecommendationIDs: [String] {
        Array(Set(failedIDs + recentPlayedIDs + (currentTrack.map { [$0.id] } ?? [])))
    }

    /// HealthKit queries are never on the next/play critical path. Existing measurement
    /// timestamps stay intact so freshness weighting still applies to a cached snapshot.
    private func refreshHealthInBackground() {
        guard health.enabled else { cachedHealth = nil; return }
        guard healthTask == nil, Date().timeIntervalSince(lastHealthRefresh) >= 60 else { return }
        healthTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.health.refresh()
            self.cachedHealth = self.health.enabled ? snapshot : nil
            self.lastHealthRefresh = Date()
            self.healthTask = nil
            if self.currentTrack != nil { self.schedulePreparation() }
        }
    }

    /// Preview is read-only: no decision row, start count, playback episode or reward is created.
    private func schedulePreparation() {
        preparationTask?.cancel()
        preparationGeneration += 1
        let token = preparationGeneration
        lastPreparationAt = Date()
        refreshHealthInBackground()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.preparationGeneration { self.preparationTask = nil } }
            do {
                let preview = try await self.recommender.previewDecision(selection: self.modeSelection,
                    discovery: self.discovery, scene: self.freshScene, health: self.effectiveHealth,
                    history: self.musicAccount.listeningRows, excludeIDs: self.excludedRecommendationIDs,
                    sceneObservedAt: self.freshScene == nil ? nil : self.sceneCapturedAt, listeningContext: self.listeningContext)
                guard !Task.isCancelled, token == self.preparationGeneration else { return }
                let tracks = Array(preview.items.prefix(6))
                let retained = Set(tracks.map(\.id) + (self.currentTrack.map { [$0.id] } ?? []))
                self.playbackURLs = self.playbackURLs.filter {
                    retained.contains($0.key) && Date().timeIntervalSince($0.value.at) < 240
                }
                if !self.isLoading {
                    for id in Array(self.playbackURLTasks.keys) where !retained.contains(id) {
                        self.playbackURLTasks.removeValue(forKey: id)?.task.cancel()
                    }
                }
                self.preparedTrackCount = tracks.filter { self.playbackURLs[$0.id] != nil }.count
                await withTaskGroup(of: Void.self) { group in
                    for track in tracks {
                        group.addTask { [weak self] in
                            await self?.prefetchPlayback(track, selected: track.id == preview.track.id, token: token)
                        }
                    }
                }
            } catch {
                // A failed background preview does not interrupt the current song.
                if token == self.preparationGeneration { self.preparedTrackCount = 0 }
            }
        }
    }

    private func prefetchPlayback(_ track: RecommendedTrack, selected: Bool, token: Int) async {
        guard !Task.isCancelled, token == preparationGeneration else { return }
        guard playbackURLs[track.id] != nil || playbackURLTasks[track.id] != nil || playbackURLTasks.count < 6 else { return }
        do {
            let url = try await playbackURL(for: track.id)
            guard !Task.isCancelled, token == preparationGeneration else { return }
            preparedTrackCount = min(6, playbackURLs.keys.filter { $0 != currentTrack?.id }.count)
            guard selected else { return }
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            guard playable, !Task.isCancelled, token == preparationGeneration else { return }
            preparedItem = (track.id, url, AVPlayerItem(asset: asset))
        } catch { /* Unavailable previews are not listening feedback. */ }
    }

    private func playbackURL(for trackID: String) async throws -> URL {
        if let entry = playbackURLs[trackID], Date().timeIntervalSince(entry.at) < 240 { return entry.url }
        if let pending = playbackURLTasks[trackID] { return try await pending.task.value }
        // At most six background resolutions plus two foreground transitions may be in flight.
        if playbackURLTasks.count >= 8, let obsoleteID = playbackURLTasks.keys.first {
            playbackURLTasks.removeValue(forKey: obsoleteID)?.task.cancel()
        }
        let client = playbackClient
        let id = UUID()
        let task = Task { try await client.playbackURL(for: trackID) }
        playbackURLTasks[trackID] = PendingPlaybackURL(id: id, task: task)
        do {
            let url = try await task.value
            if playbackURLTasks[trackID]?.id == id { playbackURLTasks.removeValue(forKey: trackID) }
            try Task.checkCancellation()
            playbackURLs[trackID] = CachedPlaybackURL(url: url, at: Date())
            if playbackURLs.count > 8 {
                for id in playbackURLs.sorted(by: { $0.value.at > $1.value.at }).dropFirst(8).map(\.key) {
                    playbackURLs.removeValue(forKey: id)
                }
            }
            return url
        } catch {
            if playbackURLTasks[trackID]?.id == id { playbackURLTasks.removeValue(forKey: trackID) }
            throw error
        }
    }

    private var safePosition: Double {
        let value = player.currentTime().seconds
        return value.isFinite && value >= 0 ? value : 0
    }

    private func samplePlayback() {
        guard tracker != nil, !isSeeking else { return }
        let actualDuration = player.currentItem?.duration.seconds ?? .nan
        if actualDuration.isFinite, actualDuration > 0 {
            duration = actualDuration
            tracker?.contentKind = PlaybackRenditionClassifier.kind(catalogDuration: currentTrack?.durationSeconds,
                mediaDuration: actualDuration)
        }
        tracker?.sample(position: safePosition, monotonic: ProcessInfo.processInfo.systemUptime,
                        isPlaying: player.timeControlStatus == .playing,
                        duration: actualDuration.isFinite && actualDuration > 0 ? actualDuration : nil)
        elapsed = safePosition; renderedSeconds = tracker?.renderedSeconds ?? 0
        if renderedSeconds > 0, !startRecorded {
            startRecorded = true
            recordAction("started", source: "system")
        }
        isPlaying = player.timeControlStatus == .playing
        if isPlaying, renderedSeconds >= 12, !audioAnalysisRequested,
           let track = currentTrack, let url = activePlaybackURL {
            audioAnalysisRequested = true
            TrackProfileStore.shared.enqueueAudio(track, playbackURL: url)
        }
        if renderedSeconds > 8 { consecutiveFailures = 0 }
        updateNowPlayingElapsed()
    }

    private func transportChanged() {
        samplePlayback()
        let status = player.timeControlStatus
        if status == .playing, !playingLatencyRecorded, let began = transitionStartedAt {
            playingLatencyRecorded = true
            ListeningDatabase.shared.recordMetric("transition_to_player_playing",
                milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000, detail: transitionMetricDetail)
        }
        if status == .waitingToPlayAtSpecifiedRate {
            if playbackStateText != "正在缓冲…" { recordAction("buffering", source: "system") }
            playbackStateText = "正在缓冲…"
        } else { playbackStateText = status == .playing ? "正在播放" : "已暂停" }
        isPlaying = status == .playing
        updateNowPlayingElapsed()
    }

    private func recordAction(_ kind: String, source: String, target: Double? = nil) {
        guard let current = tracker else { return }
        let action = PlaybackAction(kind: kind, at: Date(), position: safePosition, targetPosition: target,
                                    source: isDeviceCheck ? "diagnostic" : source)
        tracker?.append(action)
        do {
            try recommender.recordAction(action, trackID: current.trackID,
                decisionID: current.decisionID, episodeID: current.id)
        } catch { message = "操作记录未能保存：\(error.localizedDescription)" }
        learningSummary = recommender.learningSummary
        checkpoint()
    }

    private func checkpoint() {
        guard let tracker else { return }
        do {
            try PlaybackCheckpoint.save(tracker.evidence(reason: "unknown"))
            lastCheckpointAt = Date()
        } catch { message = "播放恢复点未能保存：\(error.localizedDescription)" }
    }

    private func observe(_ item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                await self.transition(endingReason: "natural_end", source: "automatic")
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                await self.handlePlaybackFailure()
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === observed else { return }
                await self.handlePlaybackFailure()
            }
        }
    }

    private func clearItemObservers() {
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil
    }

    private func observeSystemAudio() {
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(forName: Notification.Name("LintingLocationContextChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLocationContext() }
        })
        systemObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.samplePlayback()
                self.recordAction(raw == AVAudioSession.InterruptionType.began.rawValue ? "interruption" : "interruption_ended", source: "system")
                self.transportChanged()
                // User controls resumption. A phone call must never train a dislike.
            }
        })
        systemObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.samplePlayback(); self.recordAction("route_change", source: "system")
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause(source: "system") }
            }
        })
        systemObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.samplePlayback(); self?.checkpoint() }
        })
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.play(source: "remote") }; return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause(source: "remote") }; return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.next(source: "remote") }; return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.previous(source: "remote") }; return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in await self?.seek(to: event.positionTime, source: "remote") }; return .success
        }
    }

    private func updateNowPlaying(_ track: RecommendedTrack) {
        artworkTask?.cancel()
        artworkGeneration += 1
        let token = artworkGeneration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0
        ]
        if let fallback = UIImage(named: "LinYiIcon") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: fallback.size) { _ in fallback }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingElapsed()
        artworkTask = Task { [weak self] in
            let artwork = await MusicArtworkStore.shared.image(trackID: track.id, urlString: track.coverURL)
            guard !Task.isCancelled, let self, self.artworkGeneration == token, self.currentTrack?.id == track.id,
                  let artwork, var current = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            // Merge only artwork into the current dictionary; transport updates may have changed it.
            current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            self.updateNowPlayingElapsed()
        }
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1 : 0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

@MainActor
private final class PlaybackBackgroundLease {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard identifier != .invalid else { return }
        let active = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(active)
    }
}
