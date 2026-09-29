import Foundation

private struct LocalTrackStats: Codable {
    var starts = 0
    var likes = 0
    var dislikes = 0
    var unsuitable = 0
    var completions = 0
    var lastStarted: Date?
    var preferenceOverride: String?
}

private struct LocalPreferenceState: Codable {
    var decisions = 0
    var tracks: [String: LocalTrackStats] = [:]
    var recentStyles: [String] = []
    var savedTracks: [String: LocalSavedTrack] = [:]

    enum CodingKeys: String, CodingKey { case decisions, tracks, recentStyles, savedTracks }
    init() {}
    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try data.decodeIfPresent(Int.self, forKey: .decisions) ?? 0
        tracks = try data.decodeIfPresent([String: LocalTrackStats].self, forKey: .tracks) ?? [:]
        recentStyles = try data.decodeIfPresent([String].self, forKey: .recentStyles) ?? []
        savedTracks = try data.decodeIfPresent([String: LocalSavedTrack].self, forKey: .savedTracks) ?? [:]
    }
}

private struct LocalSavedTrack: Codable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let coverURL: String?
    let source: String
    var durationSeconds: Double?

    init(_ track: RecommendedTrack) {
        id = track.id; title = track.title; artist = track.artist
        album = track.album; coverURL = track.coverURL; source = track.source
        durationSeconds = track.durationSeconds
    }

    func asCandidate() -> RecommendedTrack {
        RecommendedTrack(id: id, title: title, artist: artist, album: album,
            coverURL: coverURL, source: source, reason: nil, durationSeconds: durationSeconds)
    }
}

@MainActor
final class LocalRecommendationEngine {
    private struct Seed { let style: String; let query: String }
    private struct Candidate { let track: RecommendedTrack; let style: String; let position: Int }
    static let policyVersion = "iPhone adaptive v4 · signed utility"
    // One shared catalog. Intent, health, and scene affect scores; they never close off a genre pool.
    private static let seeds: [Seed] = [
        Seed(style: "氛围", query: "ambient instrumental"), Seed(style: "独立流行", query: "indie pop"),
        Seed(style: "爵士", query: "instrumental jazz"), Seed(style: "民谣", query: "indie folk"),
        Seed(style: "电子", query: "downtempo electronic"), Seed(style: "放克", query: "funk groove"),
        Seed(style: "钢琴", query: "modern piano"), Seed(style: "城市流行", query: "city pop"),
        Seed(style: "古典", query: "modern classical"), Seed(style: "灵魂乐", query: "soul music"),
        Seed(style: "后摇", query: "post rock instrumental"), Seed(style: "巴萨诺瓦", query: "bossa nova"),
        Seed(style: "世界音乐", query: "world music"), Seed(style: "合成器流行", query: "synth pop"),
        Seed(style: "独立摇滚", query: "indie rock"), Seed(style: "木吉他", query: "acoustic guitar")
    ]

    private var state: LocalPreferenceState
    private var currentStyles: [String: String] = [:]
    private let fileURL: URL
    private let learning: AdaptiveDecisionStore
    private var persistenceNotice: String?
    private let persistenceQueue = DispatchQueue(label: "linting.preference-persistence", qos: .utility)
    private var cachedCandidates: [Candidate] = []
    private var candidatesUpdatedAt = Date.distantPast
    private var candidateFetch: Task<[Candidate], Never>?
    private var candidateFetchID: UUID?
    private var fetchRotation = 0
    // One independent draw for the next decision. Preview may resolve URLs, but must never
    // start content analysis or mutate model features based on the preselected song.
    private var selectionUniform = Double.random(in: 0..<1)

    var cachedCandidateCount: Int { cachedCandidates.count }

    func decisionSnapshot(id: String?) -> AdaptiveDecisionSnapshot? {
        guard let id else { return nil }
        return learning.state.decisions.last { $0.id == id }
    }

    init(localStateURL: URL? = nil, learningStore: AdaptiveDecisionStore? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = localStateURL ?? folder.appendingPathComponent("local-recommendation.json")
        state = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(LocalPreferenceState.self, from: $0) }
            ?? LocalPreferenceState()
        learning = learningStore ?? AdaptiveDecisionStore()
    }

    func prepare() async throws { try await learning.prepare() }

    var learningSummary: String {
        let s = learning.state
        let updates = s.model.acceptance.updates + s.model.rejection.updates + s.model.affinity.updates + s.model.replay.updates
        return "已记录 \(s.episodeCount) 次播放、\(s.explicitFeedbackCount) 次明确反馈；\(updates) 次模型更新。健康×歌曲、时间与场景共同学习当下适配；自动播完不当作喜欢。" + (persistenceNotice.map { " \($0)" } ?? "")
    }

    func remember(_ track: RecommendedTrack) {
        state.savedTracks[track.id] = LocalSavedTrack(track)
        if state.savedTracks.count > 1200 {
            let disposable = state.savedTracks.keys.filter {
                $0 != track.id && (state.tracks[$0]?.likes ?? 0) == 0
            }.sorted().prefix(state.savedTracks.count - 1200)
            for id in disposable { state.savedTracks.removeValue(forKey: id) }
        }
    }

    func isLiked(trackID: String, imported: Bool) -> Bool {
        guard let stats = state.tracks[trackID] else { return imported }
        if let override = stats.preferenceOverride { return override == "liked" }
        return stats.likes > 0 || (imported && stats.dislikes == 0)
    }

    // Compatibility for start events and previously imported preference operations.
    func record(_ event: EventPayload) throws {
        var row = state.tracks[event.trackID] ?? LocalTrackStats()
        switch event.event {
        case "started": row.starts += 1; row.lastStarted = Date()
        case "liked": row.likes = 1; row.dislikes = 0; row.preferenceOverride = "liked"
        case "unliked": row.likes = 0; row.preferenceOverride = "unliked"
        case "disliked": row.dislikes = 1; row.likes = 0; row.preferenceOverride = "disliked"
        case "completed": row.completions += 1
        default: break
        }
        state.tracks[event.trackID] = row
        if event.event == "started", let style = currentStyles[event.trackID] {
            state.recentStyles.insert(style, at: 0)
            state.recentStyles = Array(state.recentStyles.prefix(3))
        }
        try save()
    }

    func recordEpisode(_ evidence: PlaybackEvidence) throws { try learning.recordEpisode(evidence) }

    func recordFeedback(trackID: String, decisionID: String?, episodeID: String, kind: String) throws {
        try learning.recordFeedback(trackID: trackID, decisionID: decisionID, episodeID: episodeID, kind: kind)
        // The legacy catalog remains readable and keeps explicit track-level likes; unsuitable is contextual only.
        if kind != "unsuitable" {
            var row = state.tracks[trackID] ?? LocalTrackStats()
            if kind == "liked" { row.likes = 1; row.dislikes = 0 }
            if kind == "unliked" { row.likes = 0 }
            if kind == "disliked" { row.dislikes = 1; row.likes = 0 }
            row.preferenceOverride = kind
            state.tracks[trackID] = row
            try save()
        }
    }

    func recordAction(_ action: PlaybackAction, trackID: String, decisionID: String?, episodeID: String) throws {
        try learning.recordAction(action, trackID: trackID, decisionID: decisionID, episodeID: episodeID)
    }

    /// A manual choice has a fresh context and unknown propensity, even when selected from an old list.
    func registerManualSelection(track: RecommendedTrack, from decisionID: String?,
        selection: ModeSelection = .auto, discovery: Int = 1, scene: SceneResponse? = nil,
        health: HealthContext? = nil, history: [MusicHistoryRow] = [], sceneObservedAt: Date? = nil,
        reason: String = "manual_selection", listeningContext: RecommendationListeningContext = .empty) -> String? {
        let now = Date()
        let tag = decisionID.flatMap { id in learning.state.decisions.last { $0.id == id }?.candidate(track.id)?.sourceTag }
            ?? Self.manualSourceTag(reason)
        let context = contextFeatures(selection: selection, health: health, scene: scene,
            sceneObservedAt: sceneObservedAt, now: now, listeningContext: listeningContext)
        let music = TrackProfileStore.shared.features(for: track, seedTags: [tag])
        let features = AdaptivePreferenceModel.features(context: context, music: music, trackID: track.id,
            artist: track.artist, sourceTag: tag, known: history.contains { $0.id == track.id }
                || (state.tracks[track.id]?.starts ?? 0) > 0 || (learning.state.trackStarts[track.id] ?? 0) > 0)
        let id = UUID().uuidString
        let predictions = learning.state.model.predictions(features)
        let factors = RecommendationScoreDefinition.modelContributions(predictions)
        let choices = [AdaptiveCandidateSnapshot(trackID: track.id, sourceTag: tag, features: features,
            score: factors.values.reduce(0, +), predictions: predictions, probability: nil,
            scoreFactors: factors, predictionUpdates: learning.state.model.updateCounts)]
        let snapshot = AdaptiveDecisionSnapshot(id: id, at: now, chosenTrackID: track.id, candidates: choices,
            selection: reason, policyVersion: Self.policyVersion, context: context, parentDecisionID: decisionID)
        do {
            try learning.transaction {
                $0.decisions.append(snapshot); $0.decisionCount += 1
            }
            remember(track)
            return id
        } catch { persistenceNotice = "手动选择日志暂未保存。"; return nil }
    }

    /// Network retrieval is bounded and coalesced; it does not log a choice or train the model.
    func prepareCandidates(history: [MusicHistoryRow], force: Bool = false) async {
        if let candidateFetch, let id = candidateFetchID {
            let fetched = await candidateFetch.value
            completeCandidateFetch(fetched, id: id)
            return
        }
        guard force || cachedCandidates.count < 16 || Date().timeIntervalSince(candidatesUpdatedAt) > 300 else { return }
        let rotation = fetchRotation
        fetchRotation += 1
        let selected = (0..<5).map { Self.seeds[(rotation * 5 + $0 * 3) % Self.seeds.count] }
        var artistNames = Set<String>()
        for row in history where (row.liked || row.playCount >= 3) && !row.artist.isEmpty {
            artistNames.insert(row.artist)
        }
        let favoriteArtists = artistNames.sorted()
        var searches = selected
        if !favoriteArtists.isEmpty {
            searches.append(Seed(style: "常听艺人", query: favoriteArtists[rotation % favoriteArtists.count]))
        }
        let searchBatch = searches
        let task = Task.detached(priority: .utility) { await withTaskGroup(of: [Candidate].self, returning: [Candidate].self) { group in
            for seed in searchBatch {
                group.addTask {
                    let rows = (try? await NetEaseDirectClient().search(seed.query, limit: 8, offset: ((rotation / 3) % 4) * 8)) ?? []
                    return rows.enumerated().map { Candidate(track: $0.element, style: seed.style, position: $0.offset) }
                }
            }
            var result: [Candidate] = []
            for await batch in group { result += batch }
            return result
        } }
        let id = UUID()
        candidateFetchID = id
        candidateFetch = task
        let fetched = await task.value
        completeCandidateFetch(fetched, id: id)
    }

    private func completeCandidateFetch(_ fetched: [Candidate], id: UUID) {
        guard candidateFetchID == id else { return }
        candidateFetch = nil
        candidateFetchID = nil
        // Fresh results lead; older useful candidates survive an unavailable search endpoint.
        var seen = Set<String>()
        cachedCandidates = Array((fetched.sorted { $0.track.id == $1.track.id ? $0.style < $1.style : $0.track.id < $1.track.id }
            + cachedCandidates).filter { seen.insert($0.track.id).inserted }.prefix(80))
        if !fetched.isEmpty { candidatesUpdatedAt = Date() }
    }

    func previewDecision(selection: ModeSelection, discovery: Int, scene: SceneResponse?,
                         health: HealthContext?, history: [MusicHistoryRow], excludeIDs: [String],
                         sceneObservedAt: Date? = nil, listeningContext: RecommendationListeningContext = .empty) async throws -> DecisionResponse {
        try await prepare()
        await prepareCandidates(history: history)
        try Task.checkCancellation()
        return try rankCandidates(selection: selection, discovery: discovery, scene: scene, health: health,
            history: history, excludeIDs: excludeIDs, sceneObservedAt: sceneObservedAt, register: false, listeningContext: listeningContext)
    }

    func nextDecision(selection: ModeSelection, discovery: Int, scene: SceneResponse?,
                      health: HealthContext?, history: [MusicHistoryRow], excludeIDs: [String],
                      sceneObservedAt: Date? = nil, listeningContext: RecommendationListeningContext = .empty) async throws -> DecisionResponse {
        try await prepare()
        let excluded = Set(excludeIDs)
        if !cachedCandidates.contains(where: { !excluded.contains($0.track.id) && (state.tracks[$0.track.id]?.dislikes ?? 0) == 0 }) {
            await prepareCandidates(history: history, force: true)
        }
        try Task.checkCancellation()
        return try rankCandidates(selection: selection, discovery: discovery, scene: scene, health: health,
            history: history, excludeIDs: excludeIDs, sceneObservedAt: sceneObservedAt, register: true, listeningContext: listeningContext)
    }

    private func rankCandidates(selection: ModeSelection, discovery: Int, scene: SceneResponse?,
                                health: HealthContext?, history: [MusicHistoryRow], excludeIDs: [String],
                                sceneObservedAt: Date?, register: Bool, listeningContext: RecommendationListeningContext) throws -> DecisionResponse {
        let now = Date()
        let rotation = state.decisions
        let context = contextFeatures(selection: selection, health: health, scene: scene,
            sceneObservedAt: sceneObservedAt, now: now, listeningContext: listeningContext)
        var candidates = cachedCandidates
        let favoriteRows = history.filter { isLiked(trackID: $0.id, imported: $0.liked) && !$0.title.isEmpty && $0.id.allSatisfy(\.isNumber) }
        if !favoriteRows.isEmpty {
            for i in 0..<min(4, favoriteRows.count) {
                let row = favoriteRows[(rotation + i) % favoriteRows.count]
                candidates.append(Candidate(track: RecommendedTrack(id: row.id, title: row.title, artist: row.artist,
                    album: nil, coverURL: nil, source: "netease", reason: nil), style: "喜欢歌曲", position: 0))
            }
        }
        let likedIDs = state.tracks.filter { $0.value.likes > 0 }.keys.sorted()
        if !likedIDs.isEmpty {
            for i in 0..<min(3, likedIDs.count) {
                if let track = state.savedTracks[likedIDs[(rotation + i) % likedIDs.count]]?.asCandidate() {
                    candidates.append(Candidate(track: track, style: "喜欢歌曲", position: 0))
                }
            }
        }
        // Task-group completion order must not change deduplication or logged candidate probabilities.
        candidates.sort { $0.track.id == $1.track.id ? $0.style < $1.style : $0.track.id < $1.track.id }
        var seen = Set(excludeIDs)
        let unique = candidates.filter { seen.insert($0.track.id).inserted && (state.tracks[$0.track.id]?.dislikes ?? 0) == 0 }
        guard !unique.isEmpty else { throw RecommendationError.noCandidates }
        var imported: [String: MusicHistoryRow] = [:]
        var artistCounts: [String: Int] = [:]
        for row in history {
            if imported[row.id] == nil || row.liked { imported[row.id] = row }
            artistCounts[row.artist.lowercased(), default: 0] += max(1, row.playCount)
        }
        let discoveryValue = min(1, max(0, Double(discovery) / 2))
        var snapshots: [AdaptiveCandidateSnapshot] = []
        var allTracks: [String: RecommendedTrack] = [:]
        let model = learning.state.model
        for candidate in unique {
            let track = candidate.track
            let stats = state.tracks[track.id] ?? LocalTrackStats()
            let known = imported[track.id] != nil || stats.starts > 0 || (learning.state.trackStarts[track.id] ?? 0) > 0
            let music = TrackProfileStore.shared.features(for: track, seedTags: [candidate.style])
            let features = AdaptivePreferenceModel.features(context: context, music: music, trackID: track.id,
                artist: track.artist, sourceTag: candidate.style, known: known)
            let favorite = isLiked(trackID: track.id, imported: imported[track.id]?.liked == true)
            let predictions = model.predictions(features)
            var factors = RecommendationScoreDefinition.modelContributions(predictions)
            factors["discovery"] = known ? 0.15 - discoveryValue * 0.25 : 0.15 + discoveryValue * 0.5
            factors["favorite"] = favorite ? 0.75 : 0
            factors["artist"] = min(2, log1p(Double(artistCounts[track.artist.lowercased()] ?? 0))) * (0.25 - discoveryValue * 0.12)
            factors["recency"] = 0
            if let last = learning.state.trackLastStarted[track.id] ?? stats.lastStarted {
                factors["recency"] = -exp(-max(0, now.timeIntervalSince(last)) / 3600) * (favorite ? 0.25 : 0.85)
            }
            let recentStyles = learning.state.recentSourceTags.isEmpty ? state.recentStyles : learning.state.recentSourceTags
            factors["variety"] = 0
            for (index, style) in recentStyles.prefix(3).enumerated() where style == candidate.style {
                factors["variety", default: 0] -= [0.4, 0.2, 0.08][index]
            }
            // Explicit intent is a soft prior. No health measurement becomes a mandatory mood or genre.
            factors["intent"] = intentPrior(selection, music: music)
            factors["visual_intent"] = listeningContext.visualPrior(selection: selection, music: music, known: known, at: now)
            factors["self_reported_mood"] = listeningContext.moodPrior(music: music, at: now)
            let score = factors.values.reduce(0, +)
            snapshots.append(AdaptiveCandidateSnapshot(trackID: track.id, sourceTag: candidate.style,
                features: features, score: score, predictions: predictions, probability: nil, scoreFactors: factors,
                predictionUpdates: model.updateCounts))
            allTracks[track.id] = track
        }
        let probabilities = AdaptivePreferenceModel.softmax(snapshots.map(\.score))
        snapshots = snapshots.enumerated().map { index, row in
            AdaptiveCandidateSnapshot(trackID: row.trackID, sourceTag: row.sourceTag, features: row.features,
                score: row.score, predictions: row.predictions, probability: probabilities[index], scoreFactors: row.scoreFactors,
                predictionUpdates: row.predictionUpdates)
        }
        // The same unexposed draw keeps the prepared choice warm. Current-song evidence and
        // user feedback can rerank independently; preview itself performs no feature updates.
        let picked = snapshots[AdaptivePreferenceModel.sampledIndex(probabilities: probabilities, uniform: selectionUniform)]
        let id = UUID().uuidString
        let snapshot = AdaptiveDecisionSnapshot(id: id, at: now, chosenTrackID: picked.trackID, candidates: snapshots,
            selection: "softmax_with_exploration", policyVersion: Self.policyVersion, context: context,
            samplingTemperature: RecommendationScoreDefinition.temperature,
            uniformExploration: RecommendationScoreDefinition.exploration)
        if register {
            try learning.transaction { $0.decisions.append(snapshot); $0.decisionCount += 1 }
            selectionUniform = Double.random(in: 0..<1)
            cachedCandidates.removeAll { $0.track.id == picked.trackID }
        }
        let ordered = [picked] + snapshots.filter { $0.trackID != picked.trackID }.sorted { $0.score > $1.score }
        var shown: [AdaptiveCandidateSnapshot] = []
        var styles: [String: Int] = [:]
        for row in ordered where shown.count < 6 {
            if styles[row.sourceTag, default: 0] >= 2 { continue }
            shown.append(row); styles[row.sourceTag, default: 0] += 1
        }
        let bucket = Self.timeBucket(Calendar.current.component(.hour, from: now))
        let items = shown.compactMap { row -> RecommendedTrack? in
            guard let track = allTracks[row.trackID] else { return nil }
            let evidence = TrackProfileStore.shared.evidenceSummary(for: track.id)
            return RecommendedTrack(id: track.id, title: track.title, artist: track.artist, album: track.album,
                coverURL: track.coverURL, source: track.source,
                reason: "\(row.sourceTag)召回 · \(bucket) · \(evidence)", durationSeconds: track.durationSeconds)
        }
        guard let first = items.first else { throw RecommendationError.noCandidates }
        if register {
            currentStyles = Dictionary(uniqueKeysWithValues: shown.map { ($0.trackID, $0.sourceTag) })
            for row in shown { if let track = allTracks[row.trackID] { remember(track) } }
            state.decisions += 1
            try save()
        }
        let topWithHealth = snapshots.max { $0.score < $1.score }?.trackID
        let withoutHealth = snapshots.map { row -> (String, Double) in
            let stripped = row.features.filter { !$0.key.hasPrefix("context.health.") && !$0.key.hasPrefix("cross.health.") }
            return (row.trackID, row.score - model.score(row.features) + model.score(stripped))
        }.max { $0.1 < $1.1 }?.0
        let learnedHealth = [model.acceptance, model.rejection, model.affinity, model.replay].contains { head in
            head.weights.contains { $0.key.hasPrefix("cross.health.") && abs($0.value) > 0.000001 }
        }
        let healthEffect = health == nil ? "健康数据暂缺" : !learnedHealth
            ? "健康关联尚在积累；本轮先以已有口味和歌曲线索为起点"
            : topWithHealth != withoutHealth ? "本轮健康关联改变了候选首选顺序" : "已使用个人健康关联，本轮未改变候选首选顺序"
        let explanation = "时间始终参与；\(healthEffect)。\(health?.explanation ?? "") 候选与播放地址提前准备，切歌前按最新反馈重排。"
        return DecisionResponse(track: first, items: items, strategyVersion: Self.policyVersion, recommendationID: id,
            provider: "netease", modeUsed: selection.rawValue, modeSource: "adaptive_local",
            modeExplanation: explanation, contextUsed: DecisionContext(scene: scene?.scene))
    }

    private func contextFeatures(selection: ModeSelection, health: HealthContext?, scene: SceneResponse?,
                                 sceneObservedAt: Date?, now: Date, listeningContext: RecommendationListeningContext) -> [String: Double] {
        let calendar = Calendar.current
        let hours = Double(calendar.component(.hour, from: now)) + Double(calendar.component(.minute, from: now)) / 60
        var context: [String: Double] = ["time_sin": sin(hours * .pi / 12), "time_cos": cos(hours * .pi / 12),
            "weekend": calendar.isDateInWeekend(now) ? 1 : 0, "intent." + selection.rawValue: 1,
            "skip_run": min(1, Double(learning.state.recentSkipRun) / 5)]
        for (key, value) in health?.vector(at: now) ?? ["health_missing": 1] { context["health." + key] = value }
        if !learning.state.recentCoverage.isEmpty {
            context["recent_coverage"] = learning.state.recentCoverage.reduce(0, +) / Double(learning.state.recentCoverage.count)
        }
        let episodes = Array(learning.state.episodes.suffix(5))
        if !episodes.isEmpty {
            let actions = episodes.flatMap(\.actions)
            let seeks = actions.filter { $0.kind == "seek" }
            let backward = seeks.filter { ($0.targetPosition ?? 0) < ($0.position ?? 0) }
            context["recent_backward_seeks"] = min(1, Double(backward.count) / 5)
            context["recent_forward_seeks"] = min(1, Double(seeks.count - backward.count) / 5)
            context["recent_pauses"] = min(1, Double(actions.filter { $0.kind == "pause" && $0.source == "app" }.count) / 5)
            context["recent_manual_fraction"] = Double(episodes.filter { $0.startReason.hasPrefix("manual") }.count) / Double(episodes.count)
            let rendered = episodes.reduce(0) { $0 + $1.renderedSeconds }
            let coverage = episodes.reduce(0) { $0 + $1.uniqueCoveredSeconds }
            context["recent_repeated_fraction"] = rendered > 0 ? min(1, max(0, (rendered - coverage) / rendered)) : 0
            if let previous = episodes.last {
                context["last_play_duration"] = min(1, previous.renderedSeconds / 600)
                context["session_gap"] = min(1, max(0, now.timeIntervalSince(previous.endedAt)) / 3600)
            }
        }
        if let category = scene?.sceneCategory, category != .unknown, let observed = sceneObservedAt {
            let quality = max(0, 1 - max(0, now.timeIntervalSince(observed)) / (24 * 3600)) * min(1, max(0, scene?.confidence ?? 0))
            if quality > 0 {
                context["scene_category." + category.rawValue] = quality
                context["scene_quality"] = quality
            }
        }
        for (key, value) in listeningContext.vector(at: now, includeVisualIntent: selection == .auto) { context[key] = value }
        return context
    }

    private func intentPrior(_ selection: ModeSelection, music: [String: Double]) -> Double {
        switch selection {
        case .focus: return -(music["attention_demand"].map { $0 - 0.5 } ?? 0) * 0.4
        case .relax: return -(music["energy"].map { $0 - 0.5 } ?? 0) * 0.4
        case .move: return (music["rhythmic_strength"].map { $0 - 0.5 } ?? 0) * 0.4
        case .auto: return 0
        }
    }

    private static func manualSourceTag(_ reason: String) -> String {
        switch reason {
        case "manual_search": return "搜索点播"
        case "manual_playlist": return "歌单点播"
        case "manual_candidate": return "候选点播"
        case "manual_replay": return "主动重播"
        case "manual_previous": return "返回上一首"
        case "diagnostic": return "设备测试"
        default: return "手动选择"
        }
    }

    private func save() throws {
        // Encode/write immutable snapshots on one serial queue; button handlers only update memory.
        let snapshot = state
        let destination = fileURL
        persistenceQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                #if os(iOS)
                try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: destination, options: .atomic)
                #endif
            } catch {
                Task { @MainActor [weak self] in self?.persistenceNotice = "本机偏好暂未落盘，请检查可用空间。" }
            }
        }
    }

    private static func timeBucket(_ hour: Int) -> String {
        if hour >= 5 && hour < 11 { return "早晨" }
        if hour >= 11 && hour < 14 { return "午间" }
        if hour >= 14 && hour < 19 { return "下午" }
        if hour >= 19 && hour < 23 { return "晚间" }
        return "深夜"
    }

    private enum RecommendationError: LocalizedError {
        case noCandidates
        var errorDescription: String? { "网易云没有返回可用候选，请检查网络后重试。" }
    }
}
