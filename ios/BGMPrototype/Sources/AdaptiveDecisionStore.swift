import Foundation

struct AdaptiveCandidateSnapshot: Codable {
    let trackID: String
    let sourceTag: String
    let features: [String: Double]
    let score: Double
    let predictions: [String: Double]
    let probability: Double?
    var scoreFactors: [String: Double]? = nil
    var predictionUpdates: [String: Int]? = nil
}

struct AdaptiveDecisionSnapshot: Codable {
    let id: String
    let at: Date
    let chosenTrackID: String
    let candidates: [AdaptiveCandidateSnapshot]
    let selection: String
    let policyVersion: String
    let context: [String: Double]
    var parentDecisionID: String? = nil
    var samplingTemperature: Double? = nil
    var uniformExploration: Double? = nil

    func candidate(_ id: String) -> AdaptiveCandidateSnapshot? { candidates.first { $0.trackID == id } }
}

struct AdaptiveJournalEvent: Codable {
    let at: Date
    let episodeID: String
    let trackID: String
    let decisionID: String?
    let kind: String
    let action: PlaybackAction?
}

struct AdaptiveLearningState: Codable {
    var version = 1
    var model = AdaptivePreferenceModel()
    var decisions: [AdaptiveDecisionSnapshot] = []
    var episodes: [PlaybackEvidence] = []
    var journal: [AdaptiveJournalEvent] = []
    var processedEpisodes: [String] = []
    var feedbackState: [String: String] = [:]
    var trainedHeads: [String: [String]] = [:]
    var decisionCount = 0
    var episodeCount = 0
    var explicitFeedbackCount = 0
    var learnedEpisodes = 0
    var recentSkipRun = 0
    var recentCoverage: [Double] = []
    var startedEpisodes: [String] = []
    var trackStarts: [String: Int] = [:]
    var trackLastStarted: [String: Date] = [:]
    var recentSourceTags: [String] = []

    mutating func trim() {
        decisions = Array(decisions.suffix(32))
        episodes = Array(episodes.suffix(320))
        journal = Array(journal.suffix(1200))
        processedEpisodes = Array(processedEpisodes.suffix(2000))
        recentCoverage = Array(recentCoverage.suffix(5))
        startedEpisodes = Array(startedEpisodes.suffix(2000))
        recentSourceTags = Array(recentSourceTags.prefix(3))
        let retained = Set(processedEpisodes).union(episodes.map(\.id)).union(journal.suffix(300).map(\.episodeID))
        feedbackState = feedbackState.filter { retained.contains($0.key.components(separatedBy: "|").first ?? "") }
        trainedHeads = trainedHeads.filter { retained.contains($0.key) }
    }
}

@MainActor
final class AdaptiveDecisionStore {
    private(set) var state = AdaptiveLearningState()
    let fileURL: URL
    private let database: ListeningDatabase
    private let synchronous: Bool
    private var preparation: Task<AdaptiveLearningState, Error>?
    private(set) var isReady = false
    private var loadFailure: Error?

    init(fileURL: URL? = nil, synchronous: Bool? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("adaptive-decisions-v1.json")
        self.synchronous = synchronous ?? (fileURL != nil)
        database = fileURL.map { ListeningDatabase(fileURL: $0.deletingPathExtension().appendingPathExtension("sqlite")) } ?? .shared
        if self.synchronous {
            do { state = try database.loadLearningSynchronously(legacyURL: self.fileURL); isReady = true }
            catch { loadFailure = error }
        }
    }

    func prepare() async throws {
        if isReady { return }
        if let loadFailure { throw loadFailure }
        if preparation == nil {
            let database = database, legacyURL = fileURL
            preparation = Task { try await database.loadLearning(legacyURL: legacyURL) }
        }
        do {
            let loaded = try await preparation!.value
            if !isReady { state = loaded; isReady = true }
        } catch { loadFailure = error; throw error }
    }

    func transaction(_ update: (inout AdaptiveLearningState) -> Void) throws {
        guard isReady else { throw loadFailure ?? DatabaseError.message("正在迁移本机学习记录，请稍候。") }
        var next = state
        update(&next)
        next.trim()
        if synchronous { try database.saveLearningSynchronously(next) }
        else { database.saveLearning(next) }
        state = next
    }

    func snapshot(decisionID: String?, trackID: String) -> AdaptiveCandidateSnapshot? {
        guard let id = decisionID, let decision = state.decisions.last(where: { $0.id == id }) else { return nil }
        return decision.candidate(trackID)
    }

    func recordEpisode(_ evidence: PlaybackEvidence) throws {
        guard !state.processedEpisodes.contains(evidence.id) else { return }
        let snapshot = self.snapshot(decisionID: evidence.decisionID, trackID: evidence.trackID)
        try transaction { next in
            next.processedEpisodes.append(evidence.id)
            next.episodes.append(evidence)
            next.episodeCount += 1
            let targets = AdaptiveEpisodeTargets.from(evidence, recentSkipRun: next.recentSkipRun)
            let trained = Set(next.trainedHeads[evidence.id] ?? [])
            var added: [String] = []
            if let snapshot, targets.confidence > 0 {
                if let target = targets.acceptance, !trained.contains("acceptance") {
                    next.model.acceptance.update(features: snapshot.features, target: target, confidence: targets.confidence(for: "acceptance"))
                    added.append("acceptance")
                }
                if let target = targets.rejection, !trained.contains("rejection") {
                    next.model.rejection.updateContextually(features: snapshot.features,
                        target: target, confidence: targets.confidence(for: "rejection"))
                    added.append("rejection")
                }
                if let target = targets.replay, !trained.contains("replay") {
                    next.model.replay.update(features: snapshot.features, target: target, confidence: targets.confidence(for: "replay"))
                    added.append("replay")
                }
                if !added.isEmpty { next.learnedEpisodes += 1 }
            }
            next.trainedHeads[evidence.id] = Array(trained.union(added))
            if targets.skipStrength > 0.1 { next.recentSkipRun += 1 }
            else if evidence.renderedSeconds > 45 { next.recentSkipRun = 0 }
            if let duration = evidence.duration, duration > 0, evidence.renderedSeconds > 0 {
                next.recentCoverage.append(min(1, evidence.uniqueCoveredSeconds / duration))
            }
        }
    }

    func recordFeedback(trackID: String, decisionID: String?, episodeID: String, kind: String) throws {
        guard ["liked", "unliked", "disliked", "unsuitable"].contains(kind) else { return }
        let channel = kind == "unsuitable" ? "context" : "preference"
        let key = episodeID + "|" + channel
        guard state.feedbackState[key] != kind else { return }
        let snapshot = self.snapshot(decisionID: decisionID, trackID: trackID)
        try transaction { next in
            next.feedbackState[key] = kind
            next.explicitFeedbackCount += 1
            next.journal.append(AdaptiveJournalEvent(at: Date(), episodeID: episodeID, trackID: trackID,
                decisionID: decisionID, kind: kind, action: nil))
            guard let snapshot else { return }
            var trained = Set(next.trainedHeads[episodeID] ?? [])
            if kind == "liked" || kind == "unliked" || kind == "disliked" {
                next.model.affinity.update(features: snapshot.features,
                    target: kind == "liked" ? 1 : (kind == "unliked" ? 0.5 : 0), confidence: kind == "unliked" ? 0.5 : 1)
                trained.insert("affinity")
            }
            if kind == "unsuitable" || kind == "disliked" {
                if kind == "unsuitable" {
                    next.model.rejection.updateContextually(features: snapshot.features, target: 1, confidence: 1)
                } else { next.model.rejection.update(features: snapshot.features, target: 1, confidence: 1) }
                next.model.acceptance.updateContextually(features: snapshot.features, target: 0, confidence: 0.8)
                trained.formUnion(["rejection", "acceptance"])
            }
            next.trainedHeads[episodeID] = Array(trained)
        }
    }

    func recordAction(_ action: PlaybackAction, trackID: String, decisionID: String?, episodeID: String) throws {
        guard !state.journal.contains(where: { $0.action?.id == action.id }) else { return }
        let snapshot = self.snapshot(decisionID: decisionID, trackID: trackID)
        try transaction { next in
            next.journal.append(AdaptiveJournalEvent(at: action.at, episodeID: episodeID, trackID: trackID,
                decisionID: decisionID, kind: action.kind, action: action))
            if action.kind == "started", !next.startedEpisodes.contains(episodeID) {
                next.startedEpisodes.append(episodeID)
                next.trackStarts[trackID, default: 0] += 1
                next.trackLastStarted[trackID] = action.at
                if let source = snapshot?.sourceTag { next.recentSourceTags.insert(source, at: 0) }
            }
            // Replay/previous credit belongs to the newly selected target and its fresh decision,
            // not to the episode being left (which may have begun hours ago).
        }
    }
}
