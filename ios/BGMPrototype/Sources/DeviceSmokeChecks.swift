#if DEBUG
import Foundation
import MediaPlayer
import UIKit

/// Runs only for an explicitly requested developer launch, never a normal app launch.
@MainActor
enum DeviceSmokeChecks {
    private static var hasRun = false
    static func run(_ model: BGMViewModel) async {
        guard !hasRun, ProcessInfo.processInfo.environment["LINTING_DEVICE_CHECK"] == "1" else { return }
        hasRun = true
        var report: [String: String] = ["started_at": ISO8601DateFormatter().string(from: Date()), "status": "running"]
        func save() {
            do {
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: folder.appendingPathComponent("device-smoke-v2.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { print("Linting device check: unable to persist report") }
        }
        save()
        if ProcessInfo.processInfo.environment["LINTING_LOCATION_CHECK"] == "1" {
            let location = model.locationContext
            location.refreshIfAuthorized()
            for _ in 0..<220 {
                if !location.requesting { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            report["location_status"] = location.status
            report["location_precise_permission"] = String(location.preciseAuthorization)
            report["location_accuracy_m"] = location.horizontalAccuracy.map { String(Int($0)) } ?? "unavailable"
            report["location_mainland_map_correction"] = String(location.mainlandMapCorrection)
            report["location_observed_at"] = location.observedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unavailable"
            save()
        }
        let client = NetEaseDirectClient()
        var testTrack: RecommendedTrack?
        do {
            let start = ProcessInfo.processInfo.systemUptime
            let tracks = try await client.search("周杰伦 晴天", limit: 5)
            report["search_count"] = String(tracks.count)
            report["search_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
            testTrack = tracks.first
            report["search"] = tracks.isEmpty ? "empty" : "passed"
        } catch { report["search"] = error.localizedDescription }
        save()
        do {
            let profile = try await client.profile()
            let page = try await client.playlists(userID: profile.id)
            report["playlist_count"] = String(page.items.count)
            report["playlists"] = "passed"
            if let first = page.items.first {
                let ids = try await client.playlistTrackIDs(first.id)
                let songs = ids.isEmpty ? [] : try await client.songDetails(ids: Array(ids.prefix(5)))
                report["playlist_track_ids"] = String(ids.count)
                report["playlist_song_details"] = String(songs.count)
                if testTrack == nil { testTrack = songs.first }
            }
        } catch { report["playlists"] = error.localizedDescription }
        save()
        if let track = testTrack {
            let start = ProcessInfo.processInfo.systemUptime
            await model.playRequested(track, source: "diagnostic")
            let firstPlaying = await waitForPlayback(model, excluding: nil)
            report["first_playing"] = String(firstPlaying)
            report["first_play_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
            report["first_track_id"] = model.currentTrack?.id ?? "none"
            save()
            if firstPlaying {
                if ProcessInfo.processInfo.environment["LINTING_BPM_CHECK"] == "1" {
                    let samplingStart = Date()
                    for _ in 0..<650 {
                        let tempo = TrackProfileStore.shared.tempoSummary(for: track.id)
                        if ["complete", "partial_coverage", "resource_only", "inconsistent", "low_confidence", "download_limited", "incomplete_resource", "unsupported_audio", "unavailable"].contains(tempo.status),
                           tempo.algorithmVersion == TempoEstimator.version { break }
                        if !model.isPlaying || model.currentTrack?.id != track.id { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let tempo = TrackProfileStore.shared.tempoSummary(for: track.id)
                    report["bpm_wait_ms"] = String(Int(Date().timeIntervalSince(samplingStart) * 1000))
                    report["bpm_status"] = tempo.status
                    report["bpm_algorithm"] = tempo.algorithmVersion ?? "unavailable"
                    report["bpm_value"] = tempo.bpm.map { String($0) } ?? "unknown"
                    report["bpm_sampling"] = tempo.samplingSummary
                    report["bpm_segment_count"] = String(tempo.segments.count)
                    save()
                }
                let cover = await MusicArtworkStore.shared.image(trackID: track.id, urlString: nil)
                report["cover_resolved_from_id"] = String(cover != nil)
                if let cover { report["cover_pixels"] = "\(Int(cover.size.width))x\(Int(cover.size.height))" }
                try? await Task.sleep(nanoseconds: 250_000_000)
                report["system_artwork_present"] = String(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
                save()
                // Let the normal app prepare candidates/URLs. The scripted skip is a system action,
                // so it does not train a voluntary dislike.
                for _ in 0..<200 {
                    if model.preparedTrackCount >= 3 { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                report["prepared_urls_before_skip"] = String(model.preparedTrackCount)
                let previous = model.currentTrack?.id
                let switchStart = ProcessInfo.processInfo.systemUptime
                await model.next(source: "system")
                let secondPlaying = await waitForPlayback(model, excluding: previous)
                report["second_playing"] = String(secondPlaying)
                report["skip_to_playing_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - switchStart) * 1000))
                report["second_track_id"] = model.currentTrack?.id ?? "none"
                save()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            model.pause(source: "system")
        } else { report["playback"] = "No playable search or playlist candidate" }
        do { try await ListeningDatabase.shared.flush(); report["database_flush"] = "passed" }
        catch { report["database_flush"] = error.localizedDescription }
        report["status"] = "completed"
        report["completed_at"] = ISO8601DateFormatter().string(from: Date())
        save()
        print("Linting device checks completed; see device-smoke-v2.json")
    }

    private static func waitForPlayback(_ model: BGMViewModel, excluding oldID: String?) async -> Bool {
        for _ in 0..<250 {
            if model.isPlaying, model.currentTrack?.id != oldID { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
#endif
