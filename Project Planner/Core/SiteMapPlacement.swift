import Foundation
import CoreLocation

/// Where a job sits on the site map (owner 24 Nov; same order and wording as web `lib/maps/siteMapPlacement.ts`, PR
/// #440). Display only — nothing here writes to Firestore:
/// 1. the job's saved map pin (`latitude` / `longitude`) always wins;
/// 2. else an address stored as "lat, lng" text (how a pin-only job's address reads);
/// 3. else the job's UK postcode, looked up on postcodes.io (only the postcode is sent, never a name or the rest of
///    the address), falling back to Apple geocoding of the postcode alone when postcodes.io cannot be reached.
/// A job with no postcode, or a postcode nobody knows, is not placed: it is listed under "Jobs without an address",
/// where an admin or the job's manager sets the pin by hand.
nonisolated enum SiteMapPlacement: Equatable {
    case stored(CLLocationCoordinate2D)
    case addressCoordinates(CLLocationCoordinate2D)
    case postcode(CLLocationCoordinate2D, postcode: String)
    case postcodeNotFound(postcode: String)
    /// The lookup could not be reached: not placed for now, never remembered as unknown.
    case lookupFailed(postcode: String)
    case noPostcode
    case noAddress

    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .stored(let point), .addressCoordinates(let point), .postcode(let point, _): return point
        default: return nil
        }
    }

    var isUnplaced: Bool { coordinate == nil }

    /// The reason shown beside a job that could not be placed (web `siteMapUnplacedReason`).
    var unplacedReason: String {
        switch self {
        case .noAddress: return "No address"
        case .noPostcode: return "No postcode in the address"
        case .postcodeNotFound(let postcode): return "Postcode \(postcode) not found"
        case .lookupFailed: return SiteMapPlacementRules.lookupFailedText
        default: return ""
        }
    }

    static func == (lhs: SiteMapPlacement, rhs: SiteMapPlacement) -> Bool {
        func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            a.latitude == b.latitude && a.longitude == b.longitude
        }
        switch (lhs, rhs) {
        case let (.stored(a), .stored(b)), let (.addressCoordinates(a), .addressCoordinates(b)): return same(a, b)
        case let (.postcode(a, pa), .postcode(b, pb)): return same(a, b) && pa == pb
        case let (.postcodeNotFound(a), .postcodeNotFound(b)), let (.lookupFailed(a), .lookupFailed(b)): return a == b
        case (.noPostcode, .noPostcode), (.noAddress, .noAddress): return true
        default: return false
        }
    }
}

/// The answer of a postcode lookup: a point, unknown (the lookup answered "no such postcode"), or not reached.
nonisolated enum PostcodeLookupAnswer: Equatable {
    case found(latitude: Double, longitude: Double)
    case notFound
    case failed
}

nonisolated enum SiteMapPlacementRules {
    static let lookupFailedText = "Couldn’t reach the postcode lookup — retry"

    static func validCoordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180, !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// "51.51278, -0.13805" (latitude first; both with a decimal point, as web `coordinatesFromAddressText`) → a point.
    static func coordinatesFromText(_ text: String?) -> CLLocationCoordinate2D? {
        var value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("("), value.hasSuffix(")") { value = String(value.dropFirst().dropLast()) }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].contains("."), parts[1].contains("."),
              let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
        return validCoordinate(latitude, longitude)
    }

    /// The job's UK postcode in its stored form ("SW1X 9HR"): the postcode field first (any case or spacing, an x
    /// look-alike read as x), else the first UK postcode in the address lines.
    static func postcode(field: String, addressTexts: [String]) -> String? {
        let compact = field.filter { !$0.isWhitespace }
        if !compact.isEmpty, UKPostcodeText.isUK(compact) { return UKPostcodeText.formatUK(compact) }
        if !compact.isEmpty, let inField = UKPostcodeText.firstPostcode(in: compact) { return inField }
        for text in addressTexts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let found = UKPostcodeText.firstPostcode(in: trimmed) { return found }
        }
        return nil
    }

    /// Where one job goes. `lookups` holds the answers so far; a postcode not in it is still being looked up (nil).
    static func placement(
        latitude: Double?,
        longitude: Double?,
        addressLine1: String,
        postcodeField: String,
        formattedAddress: String,
        lookups: [String: PostcodeLookupAnswer]
    ) -> SiteMapPlacement? {
        if let stored = validCoordinate(latitude, longitude) { return .stored(stored) }
        for text in [addressLine1, formattedAddress] {
            if let typed = coordinatesFromText(text) { return .addressCoordinates(typed) }
        }
        if let postcode = postcode(field: postcodeField, addressTexts: [formattedAddress]) {
            switch lookups[postcode] {
            case .found(let latitude, let longitude)?:
                return .postcode(CLLocationCoordinate2D(latitude: latitude, longitude: longitude), postcode: postcode)
            case .notFound?: return .postcodeNotFound(postcode: postcode)
            case .failed?: return .lookupFailed(postcode: postcode)
            case nil: return nil
            }
        }
        let hasAddress = !formattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAddress ? .noPostcode : .noAddress
    }

    /// Whether a job is on the map on the day shown: Active and Upcoming always, Completed only with the toggle or when
    /// someone is booked on it that day, inactive never (web `siteMapJobShown`). `tab` is the rulebook's
    /// `worksTab(jobWorkStatus(...))`; nil (no answer) shows the job.
    static func jobShown(isLive: Bool, tab: String?, includeCompleted: Bool, bookedThatDay: Bool) -> Bool {
        if !isLive { return false }
        if bookedThatDay { return true }
        return tab == "completed" ? includeCompleted : true
    }

    /// The Home card line for jobs not on the map, or nil when every job is placed (web `siteMapUnplacedText`).
    static func unplacedText(count: Int, lookupFailedCount: Int) -> String? {
        let unplaced = max(0, count)
        let failed = max(0, lookupFailedCount)
        var parts: [String] = []
        if unplaced > 0 {
            parts.append(unplaced == 1 ? "1 job could not be placed on the map." : "\(unplaced) jobs could not be placed on the map.")
        }
        if failed > 0 {
            parts.append(failed == 1
                ? "1 job is waiting for the postcode lookup — retry."
                : "\(failed) jobs are waiting for the postcode lookup — retry.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Reads a postcodes.io bulk answer: each queried postcode ("SW1X 9HR") to its point, or `.notFound`.
    static func parsePostcodesIoBulk(_ data: Data) -> [String: PostcodeLookupAnswer]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["result"] as? [[String: Any]] else { return nil }
        var out: [String: PostcodeLookupAnswer] = [:]
        for row in rows {
            guard let query = row["query"] as? String else { continue }
            let key = UKPostcodeText.formatUK(query)
            if let result = row["result"] as? [String: Any],
               let latitude = (result["latitude"] as? NSNumber)?.doubleValue,
               let longitude = (result["longitude"] as? NSNumber)?.doubleValue,
               latitude.isFinite, longitude.isFinite {
                out[key] = .found(latitude: latitude, longitude: longitude)
            } else {
                out[key] = .notFound
            }
        }
        return out
    }
}

/// Postcode lookups for the site map: postcodes.io bulk (100 at a time, no key), found points remembered on this phone,
/// unknown ones only for this session (so a fixed postcode is retried). When postcodes.io cannot be reached, Apple
/// geocoding of the postcode alone is tried; if that fails too the postcode reads `.failed` and is asked again later.
actor PostcodeLookupService {
    static let shared = PostcodeLookupService()

    static let bulkURL = URL(string: "https://api.postcodes.io/postcodes")!
    static let bulkLimit = 100
    private static let defaultsKey = "pp.siteMap.postcodes.v1"

    private var found: [String: PostcodeLookupAnswer] = [:]
    private var misses: Set<String> = []

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            for (key, value) in stored {
                let parts = value.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { found[key] = .found(latitude: parts[0], longitude: parts[1]) }
            }
        }
    }

    /// The answers already known on this phone (found and this session's unknown postcodes).
    func cached() -> [String: PostcodeLookupAnswer] {
        var out = found
        for key in misses where out[key] == nil { out[key] = .notFound }
        return out
    }

    /// Looks up every postcode not known yet. Returns an answer for each one asked.
    func lookup(_ postcodes: [String]) async -> [String: PostcodeLookupAnswer] {
        let known = cached()
        let wanted = Array(Set(postcodes.map(UKPostcodeText.formatUK))).filter { !$0.isEmpty && known[$0] == nil }.sorted()
        var answers: [String: PostcodeLookupAnswer] = [:]
        var index = 0
        while index < wanted.count {
            let batch = Array(wanted[index..<min(index + Self.bulkLimit, wanted.count)])
            index += Self.bulkLimit
            if let bulk = await postcodesIo(batch) {
                for postcode in batch { answers[postcode] = bulk[postcode] ?? .notFound }
            } else {
                for postcode in batch { answers[postcode] = await appleGeocode(postcode) }
            }
        }
        remember(answers)
        return answers
    }

    private func postcodesIo(_ batch: [String]) async -> [String: PostcodeLookupAnswer]? {
        var request = URLRequest(url: Self.bulkURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        guard let body = try? JSONSerialization.data(withJSONObject: ["postcodes": batch]) else { return nil }
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return SiteMapPlacementRules.parsePostcodesIoBulk(data)
        } catch {
            return nil
        }
    }

    /// Apple geocoding of the postcode alone (never the rest of the address).
    private func appleGeocode(_ postcode: String) async -> PostcodeLookupAnswer {
        do {
            let placemarks = try await CLGeocoder().geocodeAddressString("\(postcode), United Kingdom")
            if let point = placemarks.first?.location?.coordinate {
                return .found(latitude: point.latitude, longitude: point.longitude)
            }
            return .notFound
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return .notFound
        } catch {
            return .failed
        }
    }

    private func remember(_ answers: [String: PostcodeLookupAnswer]) {
        var stored = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        for (key, answer) in answers {
            switch answer {
            case .found(let latitude, let longitude):
                found[key] = answer
                stored[key] = "\(latitude),\(longitude)"
            case .notFound:
                misses.insert(key)
            case .failed:
                break
            }
        }
        UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
    }
}
