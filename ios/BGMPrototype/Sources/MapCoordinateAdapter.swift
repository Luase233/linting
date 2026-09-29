import CoreLocation
import Foundation

/// Explicit Amap display adapter. Stored new places and CLLocation matching always use WGS-84.
/// Never run this twice, or infer the map provider from the phone's language/locale.
/// Formula adapted from googollee/eviltransform; BSD license in ThirdPartyNotices.txt.
enum MapCoordinateAdapter {
    static func display(_ point: CLLocationCoordinate2D, mainland: Bool) -> CLLocationCoordinate2D {
        guard mainland, supported(point) else { return point }
        let offset = delta(point)
        return .init(latitude: point.latitude + offset.latitude, longitude: point.longitude + offset.longitude)
    }

    static func geographic(_ point: CLLocationCoordinate2D, mainland: Bool) -> CLLocationCoordinate2D {
        guard mainland, supported(point) else { return point }
        var result = point
        for _ in 0..<30 {
            let offset = delta(result)
            let next = CLLocationCoordinate2D(latitude: point.latitude - offset.latitude, longitude: point.longitude - offset.longitude)
            let error = max(abs(next.latitude - result.latitude), abs(next.longitude - result.longitude))
            result = next
            if error < 1e-8 { break }
        }
        return result
    }

    private static func supported(_ point: CLLocationCoordinate2D) -> Bool {
        // Numerical bounds of this transform, not a country/provider detector.
        // The explicit switch is for mainland Amap only; turn it off with other base maps.
        CLLocationCoordinate2DIsValid(point) && (72.004...137.8347).contains(point.longitude) &&
            (0.8293...55.8271).contains(point.latitude)
    }

    private static func delta(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let x = point.longitude - 105, y = point.latitude - 35
        let xy = x * y, root = sqrt(abs(x)), xp = x * Double.pi, yp = y * Double.pi
        let common = 20 * sin(6 * xp) + 20 * sin(2 * xp)
        var lat = common + 20 * sin(yp) + 40 * sin(yp / 3) + 160 * sin(yp / 12) + 320 * sin(yp / 30)
        var lon = common + 20 * sin(xp) + 40 * sin(xp / 3) + 150 * sin(xp / 12) + 300 * sin(xp / 30)
        lat = lat * 2 / 3 - 100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * xy + 0.2 * root
        lon = lon * 2 / 3 + 300 + x + 2 * y + 0.1 * x * x + 0.1 * xy + 0.1 * root
        let eccentricity = 0.00669342162296594323, earthRadius = 6_378_137.0
        let radians = point.latitude * Double.pi / 180
        let magic = 1 - eccentricity * pow(sin(radians), 2)
        let squareRoot = sqrt(magic)
        return .init(latitude: lat * 180 / (earthRadius * (1 - eccentricity) / (magic * squareRoot) * Double.pi),
                     longitude: lon * 180 / (earthRadius / squareRoot * cos(radians) * Double.pi))
    }
}
