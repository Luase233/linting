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
    private struct Seed { let style: String; let query: String; var limit: Int = 6 }
    private struct Candidate { let track: RecommendedTrack; let style: String; let position: Int; var channels: [String] = [] }
    static let policyVersion = "iPhone adaptive v5 · bounded interest recall"
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
    private var candidateContextKey = ""
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
        let updates = s.model.continuation.updates + s.model.fit.updates + s.model.affinity.updates + s.model.replay.updates
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
        if ["liked", "unliked", "disliked"].contains(kind) {
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
        let music = TrackProfileStore.shared.features(for: track, seedTags: [])
        let features = AdaptivePreferenceModel.features(context: context, music: music, trackID: track.id,
            artist: track.artist, sourceTag: tag, known: history.contains { $0.id == track.id }
                || (state.tracks[track.id]?.starts ?? 0) > 0 || (learning.state.trackStarts[track.id] ?? 0) > 0)
        let id = UUID().uuidString
        let predictions = learning.state.model.predictions(features)
        let factors = RecommendationScoreDefinition.modelContributions(predictions)
        let choices = [AdaptiveCandidateSnapshot(trackID: track.id, sourceTag: tag, features: features,
            score: factors.values.reduce(0, +), predictions: predictions, probability: nil,
            scoreFactors: factors, predictionUpdates: learning.state.model.updateCounts, title: track.title, artist: track.artist,
            recallChannels: [tag], effectiveEvidence: learning.state.effectiveEvidence(trackID: track.id),
            eligibleForExploration: false, modelVersion: AdaptivePreferenceModel.targetVersion, selectionRole: "manual",
            labelVersion: AdaptivePreferenceModel.targetVersion, calibrationStatus: "uncalibrated")]
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

    /// A bounded multi-channel catalog. Imported IDs survive missing metadata; details are
    /// filled in rotating batches and persisted locally, without creating listening evidence.
    func prepareCandidates(history: [MusicHistoryRow], selection: ModeSelection = .auto,
                           listeningContext: RecommendationListeningContext = .empty, force: Bool = false) async {
        let now = Date()
        let intent = Self.recallIntent(selection: selection, context: listeningContext, now: now)
        let key = selection.rawValue + ":" + (intent ?? "") + ":" + String(history.count)
        if let candidateFetch, let id = candidateFetchID {
            let fetched = await candidateFetch.value
            completeCandidateFetch(fetched, id: id)
            if key == candidateContextKey { return }
        }
        guard force || key != candidateContextKey || cachedCandidates.count < 16
            || now.timeIntervalSince(candidatesUpdatedAt) > 300 else { return }
        candidateContextKey = key
        let rotation = fetchRotation
        fetchRotation += 1
        var artistWeights: [String: Int] = [:]
        for row in history where !row.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            artistWeights[row.artist, default: 0] += max(0, row.playCount) + (isLiked(trackID: row.id, imported: row.liked) ? 8 : 0)
        }
        for (id, saved) in state.savedTracks where !saved.artist.isEmpty {
            artistWeights[saved.artist, default: 0] += min(8, state.tracks[id]?.starts ?? 0) + ((state.tracks[id]?.likes ?? 0) > 0 ? 8 : 0)
        }
        let artists = artistWeights.filter { $0.value > 0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map(\.key)
        let artistWindow = Array(artists.prefix(12))
        var searches: [Seed] = []
        for index in 0..<min(3, artistWindow.count) {
            searches.append(Seed(style: "常听艺人", query: artistWindow[(rotation * 3 + index) % artistWindow.count]))
        }
        // Intent only opens one additional lane, anchored in an existing artist when possible.
        // A place or health measurement never becomes a genre query.
        if let intent {
            let anchor = artistWindow.isEmpty ? "" : artistWindow[rotation % artistWindow.count] + " "
            searches.append(Seed(style: "明确意图", query: anchor + intent))
        }
        let recentIDs = learning.state.episodes.suffix(8).reversed()
            .filter { $0.renderedSeconds >= 15 }.map(\.trackID)
        if let neighbor = recentIDs.compactMap({ state.savedTracks[$0] }).first, !neighbor.artist.isEmpty {
            searches.append(Seed(style: "会话邻近", query: neighbor.artist, limit: 6))
        }
        let genericCount = artists.isEmpty && history.isEmpty ? 4 : 2
        for index in 0..<genericCount {
            let seed = Self.seeds[(rotation * 3 + index * 5) % Self.seeds.count]
            searches.append(Seed(style: "通用发现", query: seed.query, limit: artists.isEmpty && history.isEmpty ? 8 : 4))
        }
        let eligible = history.filter {
            Self.validCatalogID($0.id) && (isLiked(trackID: $0.id, imported: $0.liked) || $0.playCount > 0)
                && (state.tracks[$0.id]?.dislikes ?? 0) == 0
        }.sorted {
            let lhs = ($0.liked ? 100 : 0) + min(99, $0.playCount)
            let rhs = ($1.liked ? 100 : 0) + min(99, $1.playCount)
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        var familiar: [Candidate] = []
        var missingIDs: [String] = []
        for index in 0..<min(24, eligible.count) {
            let row = eligible[(rotation * 24 + index) % eligible.count]
            let track = state.savedTracks[row.id]?.asCandidate() ?? RecommendedTrack(id: row.id, title: row.title,
                artist: row.artist, album: nil, coverURL: nil, source: "netease", reason: nil)
            if track.title.isEmpty || track.artist.isEmpty { missingIDs.append(row.id) }
            else { familiar.append(Candidate(track: track, style: row.liked ? "喜欢歌曲" : "熟悉歌曲", position: index)) }
        }
        for id in recentIDs.prefix(4) {
            if let saved = state.savedTracks[id] { familiar.append(Candidate(track: saved.asCandidate(), style: "会话邻近", position: 0)) }
        }
        for id in state.tracks.filter({ $0.value.likes > 0 }).keys.sorted().prefix(12) {
            if let saved = state.savedTracks[id] { familiar.append(Candidate(track: saved.asCandidate(), style: "喜欢歌曲", position: 0)) }
        }
        let searchBatch = searches
        let localBatch = familiar
        let detailsBatch = missingIDs
        let likedIDs = Set(eligible.filter(\.liked).map(\.id))
        let task = Task.detached(priority: .utility) { await withTaskGroup(of: [Candidate].self, returning: [Candidate].self) { group in
            for seed in searchBatch {
                group.addTask {
                    let rows = (try? await NetEaseDirectClient().search(seed.query, limit: seed.limit,
                        offset: ((rotation / 3) % 3) * seed.limit)) ?? []
                    return rows.enumerated().map { Candidate(track: $0.element, style: seed.style, position: $0.offset) }
                }
            }
            if !detailsBatch.isEmpty {
                group.addTask {
                    let rows = (try? await NetEaseDirectClient().songDetails(ids: detailsBatch)) ?? []
                    return rows.enumerated().map { Candidate(track: $0.element,
                        style: likedIDs.contains($0.element.id) ? "喜欢歌曲" : "熟悉歌曲", position: $0.offset) }
                }
            }
            var result = localBatch
            for await batch in group { result += batch }
            return result
        } }
        let id = UUID()
        candidateFetchID = id
        candidateFetch = task
        let fetched = await task.value
        completeCandidateFetch(fetched, id: id)
    }

    private static func validCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 24 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func recallIntent(selection: ModeSelection, context: RecommendationListeningContext, now: Date) -> String? {
        switch selection {
        case .focus: return "instrumental"
        case .relax: return "acoustic"
        case .move: return "rhythm"
        case .auto:
            // Visual guesses only diversify recall; they never replace the interest channels.
            guard context.visualQuality(at: now) > 0 else { return nil }
            switch context.visualIntent {
            case .focus, .accompany: return "instrumental"
            case .unwind: return "acoustic"
            case .energize: return "rhythm"
            default: return nil
            }
        }
    }

    private static func channelPriority(_ source: String) -> Int {
        ["喜欢歌曲", "熟悉歌曲", "会话邻近", "常听艺人", "明确意图", "通用发现"].firstIndex(of: source) ?? 6
    }

    private func completeCandidateFetch(_ fetched: [Candidate], id: UUID) {
        guard candidateFetchID == id else { return }
        candidateFetch = nil
        candidateFetchID = nil
        var byID: [String: Candidate] = [:]
        // The priority is about recall provenance only, never an asserted musical genre.
        for row in (fetched + cachedCandidates).sorted(by: {
            let lhs = Self.channelPriority($0.style), rhs = Self.channelPriority($1.style)
            if lhs != rhs { return lhs < rhs }
            return $0.position == $1.position ? $0.track.id < $1.track.id : $0.position < $1.position
        }) where !row.track.title.isEmpty {
            var candidate = byID[row.track.id] ?? row
            candidate.channels = Array(Set(candidate.channels + row.channels + [row.style])).sorted()
            byID[row.track.id] = candidate
        }
        let freshIDs = Set(fetched.map { $0.track.id })
        var counts: [String: Int] = [:]
        let limits = ["喜欢歌曲": 24, "熟悉歌曲": 12, "会话邻近": 8, "常听艺人": 20, "明确意图": 8, "通用发现": 8]
        cachedCandidates = Array(byID.values.sorted {
            let lhs = Self.channelPriority($0.style), rhs = Self.channelPriority($1.style)
            if lhs != rhs { return lhs < rhs }
            if freshIDs.contains($0.track.id) != freshIDs.contains($1.track.id) { return freshIDs.contains($0.track.id) }
            return $0.position == $1.position ? $0.track.id < $1.track.id : $0.position < $1.position
        }.filter { row in
            guard counts[row.style, default: 0] < limits[row.style, default: 4] else { return false }
            counts[row.style, default: 0] += 1
            return true
        }.prefix(80))
        if !fetched.isEmpty {
            candidatesUpdatedAt = Date()
            for row in fetched { remember(row.track) }
            try? save() // Metadata cache only; does not create preference or playback evidence.
        }
    }

    func previewDecision(selection: ModeSelection, discovery: Int, scene: SceneResponse?,
                         health: HealthContext?, history: [MusicHistoryRow], excludeIDs: [String],
                         sceneObservedAt: Date? = nil, listeningContext: RecommendationListeningContext = .empty) async throws -> DecisionResponse {
        try await prepare()
        await prepareCandidates(history: history, selection: selection, listeningContext: listeningContext)
        try Task.checkCancellation()
        return try rankCandidates(selection: selection, discovery: discovery, scene: scene, health: health,
            history: history, excludeIDs: excludeIDs, sceneObservedAt: sceneObservedAt, register: false, listeningContext: listeningContext)
    }

    func nextDecision(selection: ModeSelection, discovery: Int, scene: SceneResponse?,
                      health: HealthContext?, history: [MusicHistoryRow], excludeIDs: [String],
                      sceneObservedAt: Date? = nil, listeningContext: RecommendationListeningContext = .empty,
                      parentDecisionID: String? = nil) async throws -> DecisionResponse {
        try await prepare()
        let excluded = Set(excludeIDs)
        if !cachedCandidates.contains(where: { !excluded.contains($0.track.id) && (state.tracks[$0.track.id]?.dislikes ?? 0) == 0 }) {
            await prepareCandidates(history: history, selection: selection, listeningContext: listeningContext, force: true)
        }
        try Task.checkCancellation()
        return try rankCandidates(selection: selection, discovery: discovery, scene: scene, health: health,
            history: history, excludeIDs: excludeIDs, sceneObservedAt: sceneObservedAt, register: true, listeningContext: listeningContext, parentDecisionID: parentDecisionID)
    }

    private func rankCandidates(selection: ModeSelection, discovery: Int, scene: SceneResponse?,
                                health: HealthContext?, history: [MusicHistoryRow], excludeIDs: [String],
                                sceneObservedAt: Date?, register: Bool, listeningContext: RecommendationListeningContext,
                                parentDecisionID: String? = nil) throws -> DecisionResponse {
        let now = Date()
        let context = contextFeatures(selection: selection, health: health, scene: scene,
            sceneObservedAt: sceneObservedAt, now: now, listeningContext: listeningContext)
        var seen = Set(excludeIDs)
        // Stable tie order is part of the logged policy. Network completion order is irrelevant.
        let unique = cachedCandidates.sorted { $0.track.id < $1.track.id }.filter {
            seen.insert($0.track.id).inserted && (state.tracks[$0.track.id]?.dislikes ?? 0) == 0
        }
        guard !unique.isEmpty else { throw RecommendationError.noCandidates }
        var imported: [String: MusicHistoryRow] = [:]
        var artistCounts: [String: Int] = [:]
        for row in history {
            if imported[row.id] == nil || row.liked { imported[row.id] = row }
            guard !row.artist.isEmpty else { continue }
            artistCounts[row.artist.lowercased(), default: 0] += max(0, row.playCount) + (row.liked ? 3 : 0)
        }
        let recentArtists = learning.state.episodes.suffix(3).reversed().compactMap {
            state.savedTracks[$0.trackID]?.artist.lowercased()
        }
        // A contextual rejection blocks exploration during this session, until corrected.
        // It does not globally blacklist the song or suppress a future explicit selection.
        let sessionStart = learning.state.episodes.last.map { now.timeIntervalSince($0.endedAt) < 1800 ? now.addingTimeInterval(-1800) : now } ?? now.addingTimeInterval(-1800)
        var sessionFit: [String: String] = [:]
        for event in learning.state.journal where event.at >= sessionStart && ["suitable", "unsuitable"].contains(event.kind) {
            sessionFit[event.trackID] = event.kind
        }
        let discoveryValue = min(1, max(0, Double(discovery) / 2))
        var snapshots: [AdaptiveCandidateSnapshot] = []
        var allTracks: [String: RecommendedTrack] = [:]
        var musicByID: [String: [String: Double]] = [:]
        var knownByID: [String: Bool] = [:]
        var relatedByID: [String: Bool] = [:]
        let model = learning.state.model
        for candidate in unique {
            let track = candidate.track
            let stats = state.tracks[track.id] ?? LocalTrackStats()
            let known = imported[track.id] != nil || stats.starts > 0 || (learning.state.trackStarts[track.id] ?? 0) > 0
            let music = TrackProfileStore.shared.features(for: track, seedTags: [])
            let features = AdaptivePreferenceModel.features(context: context, music: music, trackID: track.id,
                artist: track.artist, sourceTag: candidate.style, known: known)
            let favorite = isLiked(trackID: track.id, imported: imported[track.id]?.liked == true)
            let predictions = model.predictions(features)
            var factors = RecommendationScoreDefinition.modelContributions(predictions)
            // Exploration is exclusively a probability budget below, never a novelty score bonus.
            factors["favorite"] = favorite ? 0.75 : 0
            factors["artist"] = min(2, log1p(Double(artistCounts[track.artist.lowercased()] ?? 0))) * 0.25
            factors["recency"] = 0
            if let last = learning.state.trackLastStarted[track.id] ?? stats.lastStarted {
                factors["recency"] = -exp(-max(0, now.timeIntervalSince(last)) / 3600) * (favorite ? 0.25 : 0.85)
            }
            factors["variety"] = 0
            if !track.artist.isEmpty {
                for (index, artist) in recentArtists.enumerated() where artist == track.artist.lowercased() {
                    factors["variety", default: 0] -= [0.18, 0.09, 0.04][index]
                }
            }
            factors["intent"] = intentPrior(selection, music: music)
            factors["visual_intent"] = listeningContext.visualPrior(selection: selection, music: music, known: known, at: now)
            factors["self_reported_mood"] = listeningContext.moodPrior(music: music, at: now)
            let channels = candidate.channels.isEmpty ? [candidate.style] : candidate.channels
            snapshots.append(AdaptiveCandidateSnapshot(trackID: track.id, sourceTag: candidate.style,
                features: features, score: factors.values.reduce(0, +), predictions: predictions, probability: nil,
                scoreFactors: factors, predictionUpdates: model.updateCounts, title: track.title, artist: track.artist,
                recallChannels: channels, effectiveEvidence: learning.state.effectiveEvidence(trackID: track.id),
                modelVersion: AdaptivePreferenceModel.targetVersion, labelVersion: AdaptivePreferenceModel.targetVersion,
                calibrationStatus: "uncalibrated"))
            allTracks[track.id] = track
            musicByID[track.id] = music
            knownByID[track.id] = known
            relatedByID[track.id] = known || channels.contains(where: { ["常听艺人", "会话邻近", "喜欢歌曲", "熟悉歌曲"].contains($0) })
                || artistCounts[track.artist.lowercased(), default: 0] > 0
        }
        func distribution(_ scores: [Double]) -> RecommendationExplorationPolicy.Result {
            RecommendationExplorationPolicy.distribution(candidates: snapshots.enumerated().map { index, row in
                let evidence = row.effectiveEvidence ?? [:]
                return RecommendationExplorationPolicy.Candidate(score: scores[index],
                    evidenceCount: ["continuation", "fit", "affinity"].reduce(0) { $0 + (evidence[$1] ?? 0) },
                    interestRelated: relatedByID[row.trackID] == true && sessionFit[row.trackID] != "unsuitable")
            }, discovery: discoveryValue, recentSkipRun: learning.state.recentSkipRun)
        }
        let policy = distribution(snapshots.map(\.score))
        snapshots = snapshots.enumerated().map { index, row in
            var result = AdaptiveCandidateSnapshot(trackID: row.trackID, sourceTag: row.sourceTag, features: row.features,
                score: row.score, predictions: row.predictions, probability: policy.probabilities[index],
                scoreFactors: row.scoreFactors, predictionUpdates: row.predictionUpdates, title: row.title, artist: row.artist,
                recallChannels: row.recallChannels, effectiveEvidence: row.effectiveEvidence,
                eligibleForExploration: policy.explorationEligible[index], modelVersion: row.modelVersion)
            result.selectionRole = policy.mainProbabilities[index] > 0 ? "main" : policy.explorationProbabilities[index] > 0 ? "explore" : "excluded"
            result.mainProbability = policy.mainProbabilities[index]
            result.explorationProbability = policy.explorationProbabilities[index]
            result.labelVersion = row.labelVersion
            result.calibrationStatus = row.calibrationStatus
            return result
        }
        func ranks(_ scores: [Double]) -> [Int] {
            var result = Array(repeating: 0, count: scores.count)
            for (rank, index) in scores.indices.sorted(by: { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }).enumerated() {
                result[index] = rank + 1
            }
            return result
        }
        let fullRanks = ranks(snapshots.map(\.score))
        let sharedPlace = listeningContext.usesSharedPlaceEvidence(at: now, includeVisualIntent: selection == .auto,
            includeSceneEvidence: context["scene_quality", default: 0] > 0)
        let influences = ["visual", "place", "health"].map { source -> ContextInfluenceSnapshot in
            func belongs(_ key: String) -> Bool {
                switch source {
                case "visual": return key.hasPrefix("visual_intent") || key.hasPrefix("scene_")
                case "place": return key.hasPrefix("place.")
                default: return key.hasPrefix("health.")
                }
            }
            let removed = context.filter { belongs($0.key) }
            let without = context.filter { !belongs($0.key) }
            let scores = snapshots.map { row -> Double in
                guard let track = allTracks[row.trackID] else { return row.score }
                // Rebuild features: removing only visible prefixes would leave hashed fit context behind.
                let features = AdaptivePreferenceModel.features(context: without, music: musicByID[row.trackID] ?? [:],
                    trackID: row.trackID, artist: track.artist, sourceTag: row.sourceTag, known: knownByID[row.trackID] == true)
                return row.score - model.score(row.features) + model.score(features)
                    - (source == "visual" ? row.scoreFactors?["visual_intent"] ?? 0 : 0)
            }
            let ablatedRanks = ranks(scores)
            let ablated = distribution(scores)
            let observed = removed.filter { !$0.key.contains("missing") && !$0.key.contains("confirmed") && $0.value != 0 }
            var missing = removed.filter { $0.key.contains("missing") && $0.value > 0 }.map(\.key).sorted()
            if observed.isEmpty { missing.append(source == "place" && sharedPlace ? "与图片共享地点来源，未重复计入" : "缺失、失效或无可用特征") }
            if source == "visual" && sharedPlace { missing.append("包含共同地点线索，不能解读为图片独立收益") }
            let coverage = source == "health" ? (context["health.health_coverage"] ?? 0)
                : min(1, max(0, observed.values.map(abs).max() ?? 0))
            return ContextInfluenceSnapshot(source: source, coverage: coverage, missing: missing,
                candidateEffects: snapshots.enumerated().map { index, row in
                    ContextCandidateEffect(trackID: row.trackID, scoreDelta: row.score - scores[index],
                        rankDelta: ablatedRanks[index] - fullRanks[index])
                }, totalVariation: zip(policy.probabilities, ablated.probabilities).reduce(0) { $0 + abs($1.0 - $1.1) } / 2,
                rankingChanged: fullRanks != ablatedRanks)
        }
        let picked = snapshots[AdaptivePreferenceModel.sampledIndex(probabilities: policy.probabilities, uniform: selectionUniform)]
        let id = UUID().uuidString
        let snapshot = AdaptiveDecisionSnapshot(id: id, at: now, chosenTrackID: picked.trackID, candidates: snapshots,
            selection: "bounded_top3_interest_exploration", policyVersion: Self.policyVersion, context: context,
            parentDecisionID: parentDecisionID, samplingTemperature: 0.25, uniformExploration: 0,
            explorationBudget: policy.explorationBudget, contextInfluences: influences)
        if register {
            try learning.transaction { $0.decisions.append(snapshot); $0.decisionCount += 1 }
            selectionUniform = Double.random(in: 0..<1)
            cachedCandidates.removeAll { $0.track.id == picked.trackID }
        }
        let ordered = [picked] + snapshots.filter { $0.trackID != picked.trackID }.sorted {
            $0.score == $1.score ? $0.trackID < $1.trackID : $0.score > $1.score
        }
        let shown = Array(ordered.prefix(6))
        let items = shown.compactMap { row -> RecommendedTrack? in
            guard let track = allTracks[row.trackID] else { return nil }
            return RecommendedTrack(id: track.id, title: track.title, artist: track.artist, album: track.album,
                coverURL: track.coverURL, source: track.source,
                reason: "\(row.sourceTag)召回 · \(TrackProfileStore.shared.evidenceSummary(for: track.id))", durationSeconds: track.durationSeconds)
        }
        guard let first = items.first else { throw RecommendationError.noCandidates }
        if register {
            currentStyles = Dictionary(uniqueKeysWithValues: shown.map { ($0.trackID, $0.sourceTag) })
            for row in shown { if let track = allTracks[row.trackID] { remember(track) } }
            state.decisions += 1
            try save()
        }
        let changed = influences.filter(\.rankingChanged).map { ["visual": "图片", "place": "地点", "health": "健康"][$0.source] ?? $0.source }
        let explanation = (changed.isEmpty ? "本轮情境未改变候选排序" : "本轮\(changed.joined(separator: "、"))改变了候选排序")
            + "；这是决策敏感度，不等于体验改善。优先从候选前列选择，探索受质量门槛和独立预算限制。"
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
            let quality = listeningContext.sceneQuality(confidence: scene?.confidence ?? 0, observedAt: observed, at: now)
            if quality > 0 {
                context["scene_category." + category.rawValue] = quality
                context["scene_quality"] = quality
            }
        }
        for (key, value) in listeningContext.vector(at: now, includeVisualIntent: selection == .auto, includeSceneEvidence: context["scene_quality", default: 0] > 0) { context[key] = value }
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
