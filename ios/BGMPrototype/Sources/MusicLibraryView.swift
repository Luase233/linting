import Foundation
import SwiftUI

struct MusicPlaylist: Codable, Identifiable {
    let id: String
    let name: String
    let coverURL: String?
    let trackCount: Int
    let creator: String
    let updatedAt: Date?
}

private struct PlaylistCatalog: Codable {
    let userID: String
    let at: Date
    let playlists: [MusicPlaylist]
    let more: Bool
    var nextOffset: Int? = nil
}

private struct PlaylistSongs: Codable {
    let userID: String
    let playlistID: String
    let at: Date
    let trackIDs: [String]
    let tracks: [RecommendedTrack]
    let fetchedCount: Int
}

@MainActor
final class MusicLibraryModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [RecommendedTrack] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var tracks: [RecommendedTrack] = []
    @Published private(set) var selectedPlaylist: MusicPlaylist?
    @Published private(set) var searching = false
    @Published private(set) var syncing = false
    @Published private(set) var loadingTracks = false
    @Published private(set) var hasMoreSearch = false
    @Published private(set) var hasMorePlaylists = false
    @Published private(set) var hasMoreTracks = false
    @Published private(set) var searchMessage = "输入歌曲或艺人，直接在霖听播放。"
    @Published private(set) var playlistMessage = "同步网易云创建和收藏的歌单。"
    @Published private(set) var trackMessage = ""
    private var accountID: String?
    private var searchGeneration = 0
    private var accountGeneration = 0
    private var playlistGeneration = 0
    private var submittedQuery = ""
    private var searchOffset = 0
    private var playlistOffset = 0
    private var allTrackIDs: [String] = []
    private var fetchedCount = 0
    private let client = NetEaseDirectClient()

    func cancelSearch() {
        searchGeneration += 1
        searching = false
        hasMoreSearch = false
    }

    func search(more: Bool = false) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelSearch(); results = []; return }
        if more && (searching || submittedQuery != text) { return }
        searchGeneration += 1
        let token = searchGeneration
        let offset = more ? searchOffset : 0
        searching = true
        if !more { results = []; hasMoreSearch = false }
        defer { if token == searchGeneration { searching = false } }
        do {
            let page = try await client.search(String(text.prefix(120)), limit: 30, offset: offset)
            guard token == searchGeneration, !Task.isCancelled else { return }
            submittedQuery = text; searchOffset = offset + 30
            results = Self.unique((more ? results : []) + page)
            hasMoreSearch = page.count == 30
            searchMessage = results.isEmpty ? "没有找到歌曲，试试别的关键词。" : "已找到 \(results.count) 首；点播、跳过、喜欢都会继续学习。"
        } catch {
            if token == searchGeneration { searchMessage = "搜索失败：\(error.localizedDescription)" }
        }
    }

    func useAccount(_ userID: String?) async {
        guard userID != accountID else { return }
        accountGeneration += 1; playlistGeneration += 1; cancelSearch()
        results = []; playlists = []; tracks = []; selectedPlaylist = nil
        hasMorePlaylists = false; hasMoreTracks = false; syncing = false; loadingTracks = false
        accountID = userID
        playlistOffset = 0
        playlistMessage = userID == nil ? "请先在「我的」登录网易云。" : "点击同步，读取你的网易云歌单。"
        guard let userID else { return }
        let token = accountGeneration
        do {
            if let cache = try await ListeningDatabase.shared.document(collection: "playlist_catalog", id: userID, as: PlaylistCatalog.self),
               token == accountGeneration, cache.userID == userID {
                playlists = cache.playlists; hasMorePlaylists = cache.more
                playlistOffset = cache.nextOffset ?? cache.playlists.count
                playlistMessage = "本机缓存 · \(cache.at.formatted(date: .abbreviated, time: .shortened))"
            }
        } catch { if token == accountGeneration { playlistMessage = error.localizedDescription } }
    }

    func syncPlaylists(more: Bool = false) async {
        guard let userID = accountID, !syncing else { return }
        syncing = true
        let token = accountGeneration
        defer { if token == accountGeneration { syncing = false } }
        do {
            let page = try await client.playlists(userID: userID, offset: more ? playlistOffset : 0)
            guard token == accountGeneration else { return }
            var seen = Set<String>()
            playlists = ((more ? playlists : []) + page.items).filter { seen.insert($0.id).inserted }
            hasMorePlaylists = page.more
            playlistOffset = page.nextOffset
            let now = Date()
            ListeningDatabase.shared.saveDocument(collection: "playlist_catalog", id: userID,
                value: PlaylistCatalog(userID: userID, at: now, playlists: playlists, more: page.more, nextOffset: page.nextOffset))
            playlistMessage = "已同步 \(playlists.count) 个歌单 · \(now.formatted(date: .omitted, time: .shortened))"
        } catch { if token == accountGeneration { playlistMessage = "同步失败，保留缓存：\(error.localizedDescription)" } }
    }

    func open(_ playlist: MusicPlaylist) async {
        guard let userID = accountID else { return }
        playlistGeneration += 1
        let token = playlistGeneration
        selectedPlaylist = playlist; tracks = []; allTrackIDs = []; fetchedCount = 0
        loadingTracks = true; hasMoreTracks = false; trackMessage = "正在读取歌单…"
        defer { if token == playlistGeneration { loadingTracks = false } }
        if let cache = try? await ListeningDatabase.shared.document(collection: "playlist_songs", id: userID + ":" + playlist.id, as: PlaylistSongs.self),
           token == playlistGeneration, !Task.isCancelled, cache.userID == userID {
            tracks = cache.tracks; allTrackIDs = cache.trackIDs; fetchedCount = cache.fetchedCount
            hasMoreTracks = fetchedCount < allTrackIDs.count
            trackMessage = "已显示本机缓存，正在检查更新…"
        }
        guard token == playlistGeneration, !Task.isCancelled else { return }
        do {
            let ids = try await client.playlistTrackIDs(playlist.id)
            // Account/playlist may change during either await. Do not issue a stale
            // second request with whatever account credentials are current now.
            guard token == playlistGeneration, !Task.isCancelled else { return }
            let first = ids.isEmpty ? [] : try await client.songDetails(ids: Array(ids.prefix(100)))
            guard token == playlistGeneration, !Task.isCancelled else { return }
            allTrackIDs = ids; fetchedCount = min(100, ids.count); tracks = first
            cacheTracks(userID: userID, playlist: playlist)
        } catch { if token == playlistGeneration, !Task.isCancelled { trackMessage = "更新未完成，保留缓存：\(error.localizedDescription)" } }
    }

    func loadMoreTracks() async {
        guard let userID = accountID, let playlist = selectedPlaylist, !loadingTracks, hasMoreTracks else { return }
        loadingTracks = true
        let token = playlistGeneration
        defer { if token == playlistGeneration { loadingTracks = false } }
        do {
            let ids = Array(allTrackIDs.dropFirst(fetchedCount).prefix(100))
            let page = try await client.songDetails(ids: ids)
            guard token == playlistGeneration else { return }
            tracks = Self.unique(tracks + page); fetchedCount += ids.count
            cacheTracks(userID: userID, playlist: playlist)
        } catch { if token == playlistGeneration { trackMessage = error.localizedDescription } }
    }

    private func cacheTracks(userID: String, playlist: MusicPlaylist) {
        hasMoreTracks = fetchedCount < allTrackIDs.count
        trackMessage = "已读取 \(fetchedCount)/\(allTrackIDs.count) 首，\(tracks.count) 首有歌曲资料；播放仍受账号和版权限制。"
        ListeningDatabase.shared.saveDocument(collection: "playlist_songs", id: userID + ":" + playlist.id,
            value: PlaylistSongs(userID: userID, playlistID: playlist.id, at: Date(), trackIDs: allTrackIDs, tracks: tracks, fetchedCount: fetchedCount))
    }
    private static func unique(_ tracks: [RecommendedTrack]) -> [RecommendedTrack] {
        var seen = Set<String>(); return tracks.filter { seen.insert($0.id).inserted }
    }
}

struct MusicLibraryView: View {
    @ObservedObject var player: BGMViewModel
    @ObservedObject var account: MusicAccount
    @StateObject private var library = MusicLibraryModel()
    @State private var tab = 0
    @State private var showingPlaylist = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Picker("曲库入口", selection: $tab) {
                Text("搜索歌曲").tag(0); Text("我的歌单").tag(1)
            }.pickerStyle(.segmented).padding()
            if tab == 0 { searchPage } else { playlistPage }
        }
        .navigationTitle("曲库").navigationBarTitleDisplayMode(.inline)
        .task(id: account.profile?.id) { await library.useAccount(account.profile?.id) }
        .sheet(isPresented: $showingPlaylist) {
            NavigationStack {
                List {
                    Text(library.trackMessage).font(.caption).foregroundStyle(.secondary)
                    ForEach(library.tracks) { track in trackRow(track, source: "manual_playlist") }
                    if library.loadingTracks { ProgressView("读取歌曲…") }
                    else if library.hasMoreTracks { Button("继续读取 100 首") { Task { await library.loadMoreTracks() } } }
                    Button("重新同步此歌单") {
                        if let playlist = library.selectedPlaylist { Task { await library.open(playlist) } }
                    }.disabled(library.loadingTracks)
                }
                .navigationTitle(library.selectedPlaylist?.name ?? "歌单")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingPlaylist = false } } }
            }.preferredColorScheme(.dark)
        }
        .onDisappear { searchTask?.cancel(); library.cancelSearch() }
    }

    private var searchPage: some View {
        VStack {
            HStack {
                TextField("搜索歌曲、艺人", text: $library.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { submitSearch() }
                    .onChange(of: library.query) { _, _ in searchTask?.cancel(); library.cancelSearch() }
                Button("搜索") { submitSearch() }.disabled(library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
            List {
                Text(library.searchMessage).font(.caption).foregroundStyle(.secondary)
                ForEach(library.results) { track in trackRow(track, source: "manual_search") }
                if library.searching { ProgressView("正在搜索…") }
                else if library.hasMoreSearch { Button("更多结果") { searchTask = Task { await library.search(more: true) } } }
            }.listStyle(.plain)
        }
    }

    private var playlistPage: some View {
        List {
            Text(library.playlistMessage).font(.caption).foregroundStyle(.secondary)
            Button { Task { await library.syncPlaylists() } } label: {
                Label(library.syncing ? "同步中…" : "同步我的网易云歌单", systemImage: "arrow.clockwise")
            }.disabled(account.profile == nil || library.syncing)
            ForEach(library.playlists) { playlist in
                Button {
                    showingPlaylist = true
                    Task { await library.open(playlist) }
                } label: {
                    HStack {
                        Image(systemName: "music.note.list").frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(playlist.name).foregroundStyle(.primary)
                            Text("\(playlist.trackCount) 首 · \(playlist.creator)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.padding(.vertical, 5)
                }
            }
            if library.hasMorePlaylists { Button("更多歌单") { Task { await library.syncPlaylists(more: true) } }.disabled(library.syncing) }
        }.listStyle(.plain)
    }

    private func trackRow(_ track: RecommendedTrack, source: String) -> some View {
        Button {
            ListeningHaptics.next()
            Task { await player.playRequested(track, source: source) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).fontWeight(.semibold).foregroundStyle(.primary)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: player.currentTrack?.id == track.id ? "waveform" : "play.fill")
            }.frame(minHeight: 48).contentShape(Rectangle())
        }
        .accessibilityLabel("播放 \(track.title)，\(track.artist)")
    }
    private func submitSearch() {
        searchTask?.cancel()
        searchTask = Task { await library.search() }
    }
}
