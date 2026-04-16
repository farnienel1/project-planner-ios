import Foundation
import CoreLocation

actor GeocodingCacheService {
    static let shared = GeocodingCacheService()

    private let geocoder = CLGeocoder()
    private var cache: [String: CLLocationCoordinate2D] = [:]

    private init() {}

    func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let key = normalized(address)
        if let cached = cache[key] { return cached }
        if let persisted = readFromDefaults(for: key) {
            cache[key] = persisted
            return persisted
        }
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            guard let location = placemarks.first?.location?.coordinate else { return nil }
            cache[key] = location
            persist(location, for: key)
            return location
        } catch {
            return nil
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func defaultsKey(for key: String) -> String {
        "geocode_cache_\(key)"
    }

    private func readFromDefaults(for key: String) -> CLLocationCoordinate2D? {
        let raw = UserDefaults.standard.string(forKey: defaultsKey(for: key))
        let parts = raw?.split(separator: ",").map(String.init) ?? []
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func persist(_ coordinate: CLLocationCoordinate2D, for key: String) {
        UserDefaults.standard.set("\(coordinate.latitude),\(coordinate.longitude)", forKey: defaultsKey(for: key))
    }
}
