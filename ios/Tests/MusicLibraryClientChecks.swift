import Foundation

// Compile this standalone fixture with NetEaseDirectClient.swift, Models.swift and
// HealthFeatures.swift. These account stubs deliberately cannot read Keychain or cookies.
struct MusicProfile { let id: String; let nickname: String }
struct MusicHistoryRow {
    let id: String; let title: String; let artist: String
    let playCount: Int; let liked: Bool; let recent: Bool
}
struct MusicPlaylist {
    let id: String; let name: String; let coverURL: String?
    let trackCount: Int; let creator: String; let updatedAt: Date?
}
enum MusicSessionVault {
    static func load() -> [String: String] { [:] }
    static func filtered(_ cookies: [HTTPCookie]) -> [String: String] { [:] }
}

@main
enum MusicLibraryClientChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func main() async throws {
        let modern: [String: Any] = ["id": 123_456_789, "name": "Fixture A", "dt": 245_500,
            "ar": [["name": "First"], ["name": "Second"]], "al": ["name": "Album", "picUrl": "https://example.com/a.jpg"]]
        let legacy: [String: Any] = ["id": 987_654, "name": "Fixture B", "duration": 180_000,
            "artists": [["name": "Legacy"]], "album": ["name": "Old Album"]]
        let parsed = NetEaseDirectClient.track(modern)!
        require(parsed.id == "123456789" && parsed.artist == "First, Second", "Modern track metadata")
        require(parsed.durationSeconds == 245.5 && parsed.source == "netease", "Milliseconds and provider")
        let old = NetEaseDirectClient.track(legacy)!
        require(old.artist == "Legacy" && old.album == "Old Album" && old.durationSeconds == 180,
            "Legacy metadata aliases")
        require(NetEaseDirectClient.track(["name": "missing ID"]) == nil, "Missing ID is not a playable song")
        require(NetEaseDirectClient.track(["id": 1]) == nil, "Missing title is not a usable row")
        require(NetEaseDirectClient.track(["id": 1, "name": "Unknown duration", "dt": -1])?.durationSeconds == nil,
            "Invalid duration must remain unknown")
        require(NetEaseDirectClient.track(["id": 1, "name": "Unknown duration", "dt": Double.nan])?.durationSeconds == nil,
            "Nonfinite duration must remain unknown")
        let client = NetEaseDirectClient()
        for invalid in ["", "one", "123/456", "１２３", String(repeating: "9", count: 25)] {
            do { _ = try await client.playlistTrackIDs(invalid); fatalError("Invalid playlist ID escaped validation") }
            catch NetEaseDirectError.invalidResponse { }
            do { _ = try await client.songDetails(ids: [invalid]); fatalError("Invalid track ID escaped validation") }
            catch NetEaseDirectError.invalidResponse { }
        }
        do { _ = try await client.songDetails(ids: []); fatalError("Empty detail request") }
        catch NetEaseDirectError.invalidResponse { }
        do { _ = try await client.songDetails(ids: (0...100).map(String.init)); fatalError("Oversized detail request") }
        catch NetEaseDirectError.invalidResponse { }
        do { _ = try await client.playlists(userID: "1", offset: -1); fatalError("Negative offset") }
        catch NetEaseDirectError.invalidResponse { }
        print("Music library fixture checks passed: metadata variants, missing/invalid fields, duration scale, IDs and request bounds.")

        // Optional public-only endpoint smoke check. No user credentials are accessed.
        if CommandLine.arguments.contains("--live-public") {
            let songs = try await client.search("莫扎特", limit: 3)
            require(!songs.isEmpty && songs.count <= 3, "Public search should return a bounded nonempty page")
            let ids = songs.map(\.id)
            let details = try await client.songDetails(ids: ids)
            require(details.map(\.id) == ids, "Song details must preserve requested search order")
            print("Live public search + song details passed (\(songs.count) songs; no account credentials).")
            // Public NetEase chart playlist; this does not access any user's library.
            let playlistIDs = try await client.playlistTrackIDs("19723756")
            require(!playlistIDs.isEmpty && Set(playlistIDs).count == playlistIDs.count,
                "Public playlist must return unique, nonempty recording IDs")
            let prefix = Array(playlistIDs.prefix(3))
            let playlistDetails = try await client.songDetails(ids: prefix)
            require(playlistDetails.map(\.id) == prefix, "Public playlist detail order")
            print("Live public playlist-ID + song-detail pagination source passed (\(playlistIDs.count) IDs; first 3 decoded).")
        }
    }
}
