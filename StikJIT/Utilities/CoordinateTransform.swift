import Foundation
import CoreLocation

enum CoordinateTransform {
    private static let pi = Double.pi
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    static func wgs84ToGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = coordinate.latitude
        let lon = coordinate.longitude

        guard outOfChina(lat: lat, lon: lon) else {
            let dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
            let dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
            let radLat = lat / 180.0 * pi
            let sinRadLat = sin(radLat)
            let magic = 1 - ee * sinRadLat * sinRadLat
            let sqrtMagic = sqrt(magic)
            let adjustedLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi)
            let adjustedLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * pi)
            return CLLocationCoordinate2D(
                latitude: lat + adjustedLat,
                longitude: lon + adjustedLon
            )
        }

        return coordinate
    }

    static func wgs84ToGCJ02(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        coordinates.map { wgs84ToGCJ02($0) }
    }

    private static func outOfChina(lat: Double, lon: Double) -> Bool {
        return !(72.004 <= lon && lon <= 137.8347 && 0.8293 <= lat && lat <= 55.8271)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return ret
    }
}
