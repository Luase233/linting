import CoreLocation
import Foundation
import SwiftUI

struct UserPlace: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var kind: Kind
    var latitude: Double
    var longitude: Double
    var radius: Double
    /// New entries use WGS-84. Missing means an untouched pin from the old map editor.
    var coordinateSystem: String? = nil
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case home, school, work, other
        var id: String { rawValue }
        var title: String {
            switch self { case .home: return "家"; case .school: return "学校"; case .work: return "工作地点"; case .other: return "其他地点" }
        }
    }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct PlaceMatch {
    let label: String
    let category: String
    let confidence: Double
}

enum PlaceMatcher {
    static func match(_ location: CLLocation, places: [UserPlace], previous: CLLocation?, now: Date = Date()) -> PlaceMatch? {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 250,
              abs(now.timeIntervalSince(location.timestamp)) <= 900 else { return nil }
        let ranked = places.map { place in
            (place, location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)))
        }.sorted { $0.1 < $1.1 }
        if let (place, _) = ranked.first(where: { $0.1 + location.horizontalAccuracy <= $0.0.radius }) {
            let confidence = max(0.4, min(1, 1 - location.horizontalAccuracy / max(100, place.radius)))
            return PlaceMatch(label: place.kind == .other ? "在自定义地点" : "在" + place.kind.title,
                              category: place.kind.rawValue, confidence: confidence)
        }
        // Outside a saved circle is not evidence of travel. Require observed motion.
        if location.speed >= 1.2, location.speedAccuracy >= 0, location.speedAccuracy <= 2 {
            return PlaceMatch(label: "在移动中", category: "transit", confidence: 0.7)
        }
        if let previous, previous.horizontalAccuracy >= 0, previous.horizontalAccuracy <= 250 {
            let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
            let uncertainty = max(0, previous.horizontalAccuracy) + location.horizontalAccuracy
            if (30...900).contains(seconds), location.distance(from: previous) - uncertainty > 200 {
                return PlaceMatch(label: "近期位置发生移动", category: "transit", confidence: 0.5)
            }
        }
        return PlaceMatch(label: "未匹配已添加地点", category: "unknown", confidence: 0)
    }
}

/// Only fresh observations from the current short acquisition session can move the map.
enum LocationFixQuality {
    static func accepts(_ location: CLLocation, startedAt: Date, now: Date = Date()) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate) && location.horizontalAccuracy.isFinite &&
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 1_000 &&
        location.timestamp >= startedAt.addingTimeInterval(-2) &&
        (-2...15).contains(now.timeIntervalSince(location.timestamp))
    }
    static func isBetter(_ candidate: CLLocation, than best: CLLocation?) -> Bool {
        guard let best else { return true }
        return candidate.horizontalAccuracy < best.horizontalAccuracy ||
            (candidate.horizontalAccuracy == best.horizontalAccuracy && candidate.timestamp > best.timestamp)
    }
}

@MainActor
final class LocationContextManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "linting.location.enabled")
            if !enabled {
                cancelUpdate(); pendingAuthorization = false
                semanticLabel = nil; semanticCategory = nil; observedAt = nil; semanticConfidence = 0
                currentLocation = nil; previousLocation = nil; lastCoordinate = nil; horizontalAccuracy = nil
                status = "位置辅助已关闭"
                NotificationCenter.default.post(name: .init("LintingLocationContextChanged"), object: self)
            }
        }
    }
    @Published private(set) var places: [UserPlace] = []
    @Published private(set) var hasLoadedPlaces = false
    private var restoringPlaces = false
    @Published private(set) var semanticLabel: String?
    @Published private(set) var semanticCategory: String?
    @Published private(set) var semanticConfidence: Double = 0
    @Published private(set) var observedAt: Date?
    @Published private(set) var status = "按需读取位置，用你添加的地点判断在家、学校或路上。"
    @Published private(set) var requesting = false
    @Published private(set) var lastCoordinate: CLLocationCoordinate2D?
    @Published private(set) var horizontalAccuracy: Double?
    @Published private(set) var preciseAuthorization = false
    @Published private(set) var fixRevision = 0
    @Published var mainlandMapCorrection: Bool {
        didSet { UserDefaults.standard.set(mainlandMapCorrection, forKey: "linting.map.mainlandCorrection"); classify() }
    }
    private let manager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var previousLocation: CLLocation?
    private var timeoutTask: Task<Void, Never>?
    private var pendingAuthorization = false
    private var acquisitionStartedAt: Date?
    private var bestFix: CLLocation?
    private var sampleCount = 0

    override init() {
        enabled = UserDefaults.standard.bool(forKey: "linting.location.enabled")
        // This installation's Amap base map was confirmed by the user. The switch remains explicit
        // because MapKit does not expose a supported API to identify its regional map provider.
        mainlandMapCorrection = UserDefaults.standard.object(forKey: "linting.map.mainlandCorrection") as? Bool ?? true
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        Task { await restore() }
    }

    var freshCategory: String? {
        guard enabled, let observedAt, Date().timeIntervalSince(observedAt) < 900 else { return nil }
        return semanticCategory
    }

    func restore() async {
        guard !restoringPlaces, !hasLoadedPlaces else { return }
        restoringPlaces = true
        defer { restoringPlaces = false }
        do {
            let stored = try await ListeningDatabase.shared.document(collection: "private_places", id: "user", as: [UserPlace].self) ?? []
            places = stored.filter { CLLocationCoordinate2DIsValid($0.coordinate) && (100...3000).contains($0.radius) }
            hasLoadedPlaces = true
            classify()
        } catch { status = "地点暂未读取：\(error.localizedDescription)" }
    }

    func requestUpdate() {
        enabled = true
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingAuthorization = true
            status = "请允许使用 App 时定位。"
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !requesting else { return }
            preciseAuthorization = manager.accuracyAuthorization == .fullAccuracy
            acquisitionStartedAt = Date(); bestFix = nil; sampleCount = 0
            requesting = true; status = "正在提高定位精度…"
            manager.startUpdatingLocation()
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.requesting else { return }
                self.finishAcquisition(reason: "timeout")
            }
        case .denied, .restricted: status = "定位未允许，可到系统设置开启；仍可正常听歌。"
        @unknown default: status = "当前系统定位状态不可用。"
        }
    }

    func cancelUpdate() {
        let wasRequesting = requesting
        timeoutTask?.cancel(); timeoutTask = nil
        manager.stopUpdatingLocation(); requesting = false; acquisitionStartedAt = nil; bestFix = nil
        if wasRequesting { status = "本次定位已停止，可重新更新位置。" }
    }

    func mapCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        MapCoordinateAdapter.display(coordinate, mainland: mainlandMapCorrection)
    }
    func geographicCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        MapCoordinateAdapter.geographic(coordinate, mainland: mainlandMapCorrection)
    }
    func mapCoordinate(for place: UserPlace) -> CLLocationCoordinate2D {
        place.coordinateSystem == "wgs84" ? mapCoordinate(place.coordinate) : place.coordinate
    }

    private func finishAcquisition(reason: String) {
        let fix = bestFix
        let count = sampleCount
        let duration = acquisitionStartedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        cancelUpdate()
        if let fix, fix.horizontalAccuracy <= 250 {
            previousLocation = currentLocation; currentLocation = fix
            lastCoordinate = fix.coordinate; horizontalAccuracy = fix.horizontalAccuracy
            classify()
        } else { status = "未取得足够准确的新位置，请到窗边或室外重试。" }
        fixRevision += 1
        ListeningDatabase.shared.recordMetric("location_acquisition", milliseconds: duration,
            detail: "reason=\(reason);samples=\(count);accuracy_m=\(Int(fix?.horizontalAccuracy ?? -1));precise=\(preciseAuthorization);map_correction=\(mainlandMapCorrection)")
    }

    /// Photo analysis may refresh an existing authorization, but never opens a permission prompt.
    func refreshIfAuthorized() {
        guard enabled, [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus),
              observedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        requestUpdate()
    }

    @discardableResult func savePlace(_ place: UserPlace) -> Bool {
        guard hasLoadedPlaces else { status = "请等待已有地点读取完成。"; return false }
        guard !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              place.name.count <= 40, CLLocationCoordinate2DIsValid(place.coordinate), (100...3000).contains(place.radius) else {
            status = "请填写地点名称并选择有效范围。"; return false
        }
        if let index = places.firstIndex(where: { $0.id == place.id }) { places[index] = place }
        else if places.count < 30 { places.append(place) }
        else { status = "最多保留 30 个地点。"; return false }
        persist(); classify()
        return true
    }

    func removePlace(_ id: String) { guard hasLoadedPlaces else { return }; places.removeAll { $0.id == id }; persist(); classify() }
    private func persist() { ListeningDatabase.shared.saveDocument(collection: "private_places", id: "user", value: places) }

    private func classify() {
        guard enabled, let location = currentLocation else { return }
        observedAt = location.timestamp
        let geographicPlaces = places.map { place -> UserPlace in
            guard place.coordinateSystem != "wgs84" else { return place }
            var corrected = place
            let coordinate = geographicCoordinate(place.coordinate)
            corrected.latitude = coordinate.latitude; corrected.longitude = coordinate.longitude
            return corrected
        }
        if let match = PlaceMatcher.match(location, places: geographicPlaces, previous: previousLocation) {
            semanticLabel = match.label; semanticCategory = match.category; semanticConfidence = match.confidence
            status = match.label + " · 估计误差 ±\(Int(ceil(location.horizontalAccuracy))) 米 · " + location.timestamp.formatted(date: .omitted, time: .shortened)
        } else {
            semanticLabel = nil; semanticCategory = nil; semanticConfidence = 0
            status = "定位误差较大或已过期，暂不推断地点。"
        }
        NotificationCenter.default.post(name: .init("LintingLocationContextChanged"), object: self)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.preciseAuthorization = self.manager.accuracyAuthorization == .fullAccuracy
            if self.pendingAuthorization, self.manager.authorizationStatus != .notDetermined {
                self.pendingAuthorization = false
                self.requestUpdate()
            }
            if [.denied, .restricted].contains(self.manager.authorizationStatus) {
                self.semanticLabel = nil; self.semanticCategory = nil; self.observedAt = nil; self.semanticConfidence = 0
                self.cancelUpdate(); self.lastCoordinate = nil; self.horizontalAccuracy = nil
                self.currentLocation = nil; self.previousLocation = nil
                self.status = "定位未允许，地点线索未启用。"
                NotificationCenter.default.post(name: .init("LintingLocationContextChanged"), object: self)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.enabled, self.requesting, let started = self.acquisitionStartedAt else { return }
            for location in locations where LocationFixQuality.accepts(location, startedAt: started) {
                self.sampleCount += 1
                if LocationFixQuality.isBetter(location, than: self.bestFix) { self.bestFix = location }
            }
            if let best = self.bestFix {
                if best.horizontalAccuracy <= 25 { self.finishAcquisition(reason: "accurate") }
                else { self.status = "正在提高定位精度…目前估计误差 ±\(Int(ceil(best.horizontalAccuracy))) 米" }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.requesting else { return }
            // A temporary lack of GPS is recoverable during the bounded session.
            if (error as? CLError)?.code == .locationUnknown { return }
            self.finishAcquisition(reason: "error")
        }
    }
}
