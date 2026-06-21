//
//  BankHolidayService.swift
//  Project Planner
//
//  Fetches public holidays from Nager.Date, caches per region/year for offline use.
//

import Combine
import Foundation

struct BankHolidayDay: Hashable, Codable, Sendable, Identifiable {
    /// Stable `yyyy-MM-dd` key used for calendar lookups (stored explicitly for cache round-trips).
    let dayKey: String
    let date: Date
    let name: String

    var id: String { dayKey }

    init(dayKey: String, date: Date, name: String) {
        self.dayKey = dayKey
        self.date = date
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        name = try c.decode(String.self, forKey: .name)
        if let storedKey = try c.decodeIfPresent(String.self, forKey: .dayKey), !storedKey.isEmpty {
            dayKey = storedKey
        } else {
            dayKey = Self.dayKey(for: date)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, date, name
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dayKey, forKey: .dayKey)
        try c.encode(date, forKey: .date)
        try c.encode(name, forKey: .name)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let y = calendar.component(.year, from: day)
        let m = calendar.component(.month, from: day)
        let d = calendar.component(.day, from: day)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

@MainActor
final class BankHolidayService: ObservableObject {
    static let shared = BankHolidayService()

    @Published private(set) var holidaysByDayKey: [String: BankHolidayDay] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastErrorMessage: String?

    private var activeRegionId: String?
    private let calendar = Calendar.current
    private let cacheSchemaVersion = 4
    private let cacheFileName = "bank-holiday-cache-v4.json"
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    private struct CacheFile: Codable {
        var regionId: String
        var schemaVersion: Int
        var years: [String: [BankHolidayDay]]
        var updatedAt: Date

        init(regionId: String, schemaVersion: Int, years: [String: [BankHolidayDay]], updatedAt: Date) {
            self.regionId = regionId
            self.schemaVersion = schemaVersion
            self.years = years
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            regionId = try c.decode(String.self, forKey: .regionId)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            years = try c.decode([String: [BankHolidayDay]].self, forKey: .years)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        }
    }

    private struct NagerHolidayDTO: Decodable {
        let date: String
        let localName: String
        let name: String
        let countryCode: String
        let global: Bool
        let counties: [String]?
    }

    private init() {}

    func holidays(for region: BankHolidayRegion, referenceDate: Date = Date()) async -> [BankHolidayDay] {
        await ensureLoaded(region: region, referenceDate: referenceDate)
        return holidaysByDayKey.values.sorted { $0.date < $1.date }
    }

    func holiday(on day: Date) -> BankHolidayDay? {
        holidaysByDayKey[BankHolidayDay.dayKey(for: calendar.startOfDay(for: day), calendar: calendar)]
    }

    func invalidateCache(for regionId: String) {
        let url = cacheFileURL(regionId: regionId)
        try? FileManager.default.removeItem(at: url)
        if activeRegionId == regionId {
            activeRegionId = nil
            holidaysByDayKey = [:]
        }
    }

    func ensureLoaded(
        region: BankHolidayRegion,
        referenceDate: Date = Date(),
        forceRefresh: Bool = false
    ) async {
        let years = Self.prefetchYears(for: referenceDate, calendar: calendar)

        if forceRefresh {
            invalidateCache(for: region.id)
        }

        let cacheValid = !forceRefresh
            && activeRegionId == region.id
            && years.allSatisfy({ yearHasUsableCachedHolidays(regionId: region.id, year: $0) })

        if cacheValid {
            loadMergedCache(regionId: region.id, years: years)
            return
        }

        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        var cache = readCache(regionId: region.id)
            ?? CacheFile(regionId: region.id, schemaVersion: cacheSchemaVersion, years: [:], updatedAt: Date())

        if cache.schemaVersion < cacheSchemaVersion {
            cache = CacheFile(regionId: region.id, schemaVersion: cacheSchemaVersion, years: [:], updatedAt: Date())
        }

        for year in years {
            let yearKey = String(year)
            let existing = cache.years[yearKey] ?? []
            let needsFetch = forceRefresh || existing.isEmpty
            guard needsFetch else { continue }
            do {
                let fetched = try await fetchYear(region: region, year: year)
                cache.years[yearKey] = fetched
            } catch {
                lastErrorMessage = error.localizedDescription
                print("🔥🔥🔥 DEBUG: Bank holiday fetch failed for \(region.id) \(year): \(error.localizedDescription)")
            }
        }

        cache.schemaVersion = cacheSchemaVersion
        cache.updatedAt = Date()
        writeCache(cache)
        activeRegionId = region.id
        loadMergedCache(regionId: region.id, years: years)

        if holidaysByDayKey.isEmpty, lastErrorMessage == nil {
            lastErrorMessage = "No bank holidays could be loaded for \(region.title). Check your connection and try again."
        }
    }

    /// Prior year plus current and two years ahead (leave years often span calendar years).
    static func prefetchYears(for referenceDate: Date, calendar: Calendar = .current) -> [Int] {
        let year = calendar.component(.year, from: referenceDate)
        return [year - 1, year, year + 1, year + 2]
    }

    private func yearHasUsableCachedHolidays(regionId: String, year: Int) -> Bool {
        guard let cache = readCache(regionId: regionId) else { return false }
        guard cache.schemaVersion >= cacheSchemaVersion else { return false }
        guard let yearHolidays = cache.years[String(year)] else { return false }
        return !yearHolidays.isEmpty
    }

    private func loadMergedCache(regionId: String, years: [Int]) {
        guard let cache = readCache(regionId: regionId),
              cache.schemaVersion >= cacheSchemaVersion else {
            holidaysByDayKey = [:]
            return
        }
        var merged: [String: BankHolidayDay] = [:]
        for year in years {
            for day in cache.years[String(year)] ?? [] {
                merged[day.dayKey] = day
            }
        }
        holidaysByDayKey = merged
        objectWillChange.send()
    }

    private func fetchYear(region: BankHolidayRegion, year: Int) async throws -> [BankHolidayDay] {
        guard let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(year)/\(region.countryCode)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode([NagerHolidayDTO].self, from: data)

        return decoded.compactMap { dto -> BankHolidayDay? in
            guard matchesRegion(dto, region: region) else { return nil }
            guard let sod = Self.parseHolidayDateString(dto.date, calendar: calendar) else { return nil }
            let key = BankHolidayDay.dayKey(for: sod, calendar: calendar)
            let label = dto.localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? dto.name : dto.localName
            return BankHolidayDay(dayKey: key, date: sod, name: label)
        }
        .sorted { $0.date < $1.date }
    }

    /// Parses `"yyyy-MM-dd"` as a local calendar day (avoids UTC day-shift bugs).
    private static func parseHolidayDateString(_ string: String, calendar: Calendar) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d)).map { calendar.startOfDay(for: $0) }
    }

    private func matchesRegion(_ dto: NagerHolidayDTO, region: BankHolidayRegion) -> Bool {
        guard dto.countryCode.uppercased() == region.countryCode.uppercased() else { return false }
        guard let countyCodes = region.countyCodes, !countyCodes.isEmpty else { return true }
        if dto.global { return true }
        guard let counties = dto.counties, !counties.isEmpty else { return false }
        return !Set(countyCodes).isDisjoint(with: Set(counties))
    }

    private var cacheDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("BankHolidayCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func cacheFileURL(regionId: String) -> URL {
        let safe = regionId.replacingOccurrences(of: "/", with: "_")
        return cacheDirectoryURL.appendingPathComponent("\(safe)-\(cacheFileName)")
    }

    private func readCache(regionId: String) -> CacheFile? {
        let url = cacheFileURL(regionId: regionId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private func writeCache(_ cache: CacheFile) {
        let url = cacheFileURL(regionId: cache.regionId)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
