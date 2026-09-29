import CoreLocation
import Foundation

// Compile with the unmodified UserPlace/PlaceMatcher prefix of LocationContextManager.swift
// (before @MainActor). The manager's authorization API is iOS-only; this pure fixture
// runs on macOS and never opens a database or requests location.

@main
enum PlaceContextChecks {
    static func main() {
        let now = Date()
        let gps = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let mapped = MapCoordinateAdapter.display(gps, mainland: true)
        let restored = MapCoordinateAdapter.geographic(mapped, mainland: true)
        precondition(abs(restored.latitude - gps.latitude) < 1e-7 && abs(restored.longitude - gps.longitude) < 1e-7,
                     "Map pick must roundtrip into geographic coordinates without double shifting")
        precondition(abs(mapped.longitude - 121.47822305927693) < 1e-6, "Independent GCJ-02 reference vector")
        let disabled = MapCoordinateAdapter.display(gps, mainland: false)
        precondition(disabled.latitude == gps.latitude && disabled.longitude == gps.longitude)
        let abroad = CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4)
        precondition(MapCoordinateAdapter.display(abroad, mainland: true).longitude == abroad.longitude)
        let home = UserPlace(id: "home", name: "Private address must stay local", kind: .home,
            latitude: 31.2304, longitude: 121.4737, radius: 300)
        let school = UserPlace(id: "school", name: "Private school name", kind: .school,
            latitude: 31.25, longitude: 121.50, radius: 300)
        func point(latitude: Double = 31.2304, longitude: Double = 121.4737,
                   accuracy: Double = 30, secondsAgo: Double = 0) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-secondsAgo))
        }
        let match = PlaceMatcher.match(point(), places: [home, school], previous: nil, now: now)
        precondition(match?.category == "home" && match?.label == "在家", "Home recognition")
        precondition(match?.label.contains(home.name) == false, "User's private place name must not become cloud label")
        let schoolMatch = PlaceMatcher.match(point(latitude: school.latitude, longitude: school.longitude), places: [home, school], previous: nil, now: now)
        precondition(schoolMatch?.category == "school" && schoolMatch?.label == "在学校", "School recognition")
        precondition(PlaceMatcher.match(point(accuracy: 500), places: [home], previous: nil, now: now) == nil,
            "Imprecise location must not infer a place")
        precondition(PlaceMatcher.match(point(accuracy: -1), places: [home], previous: nil, now: now) == nil,
            "Invalid accuracy")
        precondition(PlaceMatcher.match(point(secondsAgo: 901), places: [home], previous: nil, now: now) == nil,
            "Expired location must not infer current place")
        let outside = point(latitude: 31.4, longitude: 121.7)
        precondition(PlaceMatcher.match(outside, places: [home, school], previous: nil, now: now)?.category == "unknown",
            "Outside known places is not automatically transit")
        let traveled = PlaceMatcher.match(outside, places: [home], previous: point(secondsAgo: 60), now: now)
        precondition(traveled?.category == "transit", "Observed displacement beyond accuracy can indicate transit")
        let invalidPrevious = PlaceMatcher.match(outside, places: [], previous: point(accuracy: -1, secondsAgo: 60), now: now)
        precondition(invalidPrevious?.category == "unknown", "Invalid old location must not establish motion")
        let imprecisePrevious = PlaceMatcher.match(outside, places: [], previous: point(accuracy: 1_000, secondsAgo: 60), now: now)
        precondition(imprecisePrevious?.category == "unknown", "Imprecise old location must not establish motion")
        let jitter = PlaceMatcher.match(point(latitude: 31.231), places: [], previous: point(secondsAgo: 60), now: now)
        precondition(jitter?.category == "unknown", "GPS jitter must not become transit")
        precondition(!LocationFixQuality.accepts(point(secondsAgo: 30), startedAt: now, now: now), "Discard cached observations")
        precondition(!LocationFixQuality.accepts(point(accuracy: -1), startedAt: now, now: now), "Reject invalid fixes")
        precondition(LocationFixQuality.accepts(point(accuracy: 8), startedAt: now, now: now))
        precondition(LocationFixQuality.isBetter(point(accuracy: 8), than: point(accuracy: 150)), "Wait for a better fix")
        precondition(!LocationFixQuality.isBetter(point(accuracy: 150), than: point(accuracy: 8)), "Do not regress to last coarse fix")
        let old = try! JSONDecoder().decode(UserPlace.self, from: Data(#"{"id":"old","name":"old","kind":"home","latitude":31.2,"longitude":121.4,"radius":300}"#.utf8))
        precondition(old.coordinateSystem == nil, "Legacy pins must remain distinguishable")
        print("Place matcher checks passed: home/school categories, private-label isolation, stale/imprecise rejection, transit evidence and jitter.")
    }
}
