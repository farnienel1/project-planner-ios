//
//  BankHolidayService.swift
//  Project Planner
//
//  Fetches public holidays from Nager.Date, caches per region/year for offline use.
//

import Combine
import Foundation

struct BankHolidayDay: Hashable, Codable, Sendable, Identifiable {
    var id: String { Self.dayKey(for: date) }
    let date: Date
    let name: String

    static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
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
    private let cacheFileName = "bank-holiday-cache-v1.json"
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    private struct CacheFile: Codable {
        var regionId: String
        var years: [String: [BankHolidayDay]]
        var updatedAt: Date
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
        holidaysByDayKey[BankHolidayDay.dayKey(for: calendar.startOfDay(for: day))]
    }

    func ensureLoaded(region: BankHolidayRegion, referenceDate: Date = Date()) async {
        let years = Self.prefetchYears(for: referenceDate)
        if activeRegionId == region.id,
           years.allSatisfy({ yearHasCachedHolidays(regionId: region.id, year: $0) }) {
            loadMergedCache(regionId: region.id, years: years)
            return
        }

        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        var cache = readCache(regionId: region.id) ?? CacheFile(regionId: region.id, years: [:], updatedAt: Date())
        for year in years where cache.years[String(year)] == nil {
            do {
                let fetched = try await fetchYear(region: region, year: year)
                cache.years[String(year)] = fetched
            } catch {
                lastErrorMessage = error.localizedDescription
                print("🔥🔥🔥 DEBUG: Bank holiday fetch failed for \(region.id) \(year): \(error.localizedDescription)")
            }
        }
        cache.updatedAt = Date()
        writeCache(cache)
        activeRegionId = region.id
        loadMergedCache(regionId: region.id, years: years)
    }

    /// Current year plus two years ahead (supports leave years that cross calendar years).
    static func prefetchYears(for referenceDate: Date, calendar: Calendar = .current) -> [Int] {
        let year = calendar.component(.year, from: referenceDate)
        return [year, year + 1, year + 2]
    }

    private func yearHasCachedHolidays(regionId: String, year: Int) -> Bool {
        guard let cache = readCache(regionId: regionId) else { return false }
        return cache.years[String(year)] != nil
    }

    private func loadMergedCache(regionId: String, years: [Int]) {
        guard let cache = readCache(regionId: regionId) else {
            holidaysByDayKey = [:]
            return
        }
        var merged: [String: BankHolidayDay] = [:]
        for year in years {
            for day in cache.years[String(year)] ?? [] {
                merged[day.id] = day
            }
        }
        holidaysByDayKey = merged
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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        return decoded.compactMap { dto -> BankHolidayDay? in
            guard matchesRegion(dto, region: region) else { return nil }
            guard let rawDate = formatter.date(from: dto.date) else { return nil }
            let sod = calendar.startOfDay(for: rawDate)
            let label = dto.localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? dto.name : dto.localName
            return BankHolidayDay(date: sod, name: label)
        }
        .sorted { $0.date < $1.date }
    }

    private func matchesRegion(_ dto: NagerHolidayDTO, region: BankHolidayRegion) -> Bool {
        guard dto.countryCode.uppercased() == region.countryCode.uppercased() else { return false }
        guard let countyCodes = region.countyCodes, !countyCodes.isEmpty else { return true }
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
