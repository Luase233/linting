import Foundation

@main
enum PlaybackEvidenceChecks {
    static func main() throws {
        var value = PlaybackTracker(decisionID: "decision", trackID: "song", startReason: "automatic", duration: 240)
        value.resetPosition(0, monotonic: 0, isPlaying: true)
        value.sample(position: 8, monotonic: 8, isPlaying: true)
        value.resetPosition(100, monotonic: 8, isPlaying: true)
        value.sample(position: 120, monotonic: 28, isPlaying: true)
        assert(abs(value.renderedSeconds - 28) < 0.001)
        assert(abs(value.uniqueCoveredSeconds - 28) < 0.001)
        value.resetPosition(100, monotonic: 28, isPlaying: true)
        value.sample(position: 120, monotonic: 48, isPlaying: true)
        assert(abs(value.renderedSeconds - 48) < 0.001)
        assert(abs(value.uniqueCoveredSeconds - 28) < 0.001, "Repeated section is not new coverage")
        value.sample(position: 120, monotonic: 48, isPlaying: false)
        value.sample(position: 120, monotonic: 148, isPlaying: false)
        assert(abs(value.renderedSeconds - 48) < 0.001, "Paused time must not count")
        value.sample(position: 120, monotonic: 149, isPlaying: true)
        value.sample(position: 121, monotonic: 150, isPlaying: true)
        assert(abs(value.renderedSeconds - 49) < 0.001)
        value.sample(position: 230, monotonic: 151, isPlaying: true)
        assert(abs(value.renderedSeconds - 49) < 0.001, "Unobserved seek jump must not count")
        value.sample(position: .nan, monotonic: 152, isPlaying: true)
        let evidence = value.evidence(reason: "playback_error")
        let roundtrip = try JSONDecoder().decode(PlaybackEvidence.self, from: JSONEncoder().encode(evidence))
        assert(roundtrip.endReason == "playback_error" && roundtrip.lastPosition == 230)
        print("Playback evidence checks passed: seek, replay coverage, pause, jump, serialization.")
    }
}
