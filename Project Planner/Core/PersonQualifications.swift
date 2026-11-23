//
//  PersonQualifications.swift
//  Project Planner
//
//  Owner issues 17 Nov (#17–#19, "fix on both apps"): every user's profile summary lists their qualifications — admins,
//  the Super Admin, managers, operatives and ghosts alike — each with its expiry date and a "View certificate" button.
//
//  Who the person is (guardrail 1): qualifications live on `operatives` catalogue rows, and one person can have
//  several. The rows are the rulebook's `operativeRowsForPerson` (RULEBOOK 1.73.0 §5: the person fold `taskPersonIndex`,
//  placeholder rows left out by `isPlaceholderOperativeRow`) — never "one operatives row by email".
//
//  The list and each expiry are `personQualifications` (1.73.0): the expiry is `qualificationExpiryDates[id]` read by
//  `qualificationExpiryDate` (exact key first, else the id in another letter case); the assignment row's own `endDate`
//  is never an expiry. Dates go to the script as epoch milliseconds and come back as `expiryIso`.
//
//  Expired / expiring soon is `qualificationExpiryRows` (RULEBOOK §5, the Warnings rule: organisation day, one calendar
//  month ahead). Certificate links are `qualificationCertificateUrl` (inside `personQualifications`) then
//  `safeExternalUrl` (https only, §24).
//
//  Display only: nothing here writes.
//

import Foundation

/// One qualification on a person's profile.
struct PersonQualificationRow: Identifiable, Equatable {
    enum Tone: Equatable {
        case none
        case expiringSoon
        case expired
    }

    /// The qualification id as stored on the assignment row.
    let id: String
    let name: String
    /// The expiry (`qualificationExpiryDates` read by `qualificationExpiryDate`); nil = no expiry.
    let expiry: Date?
    /// The certificate as a safe link (`safeExternalUrl`); nil = none uploaded, or not an https link.
    let certificateURL: URL?
    /// The `operatives` row the qualification sits on (stored id).
    let operativeDocumentId: String
    let tone: Tone
}

enum PersonQualifications {
    // MARK: Which rows are the person's

    /// The person's `operatives` rows (`operativeRowsForPerson`). Nil when the script did not answer — the caller
    /// shows nothing rather than a guess.
    static func operativeRows(
        for person: AppUser,
        users: [AppUser],
        operatives: [Operative]
    ) -> [Operative]? {
        CanonicalBusinessEngine.operativeRowsForPerson(person: person, operatives: operatives, roster: users)
    }

    // MARK: Expiry (editor display)

    /// The expiry the editor shows for `qualificationId` (`qualificationExpiryDate`); nil = no expiry.
    static func expiryDate(qualificationId: String, expiryDates: [String: Date]) -> Date? {
        CanonicalBusinessEngine.qualificationExpiryDate(dates: expiryDates, qualificationId: qualificationId)
    }

    /// The expiry map after the editor sets (or, with nil, clears) one qualification's date
    /// (`withQualificationExpiry`: every other spelling of the id removed). When the script does not answer, the map
    /// is returned unchanged.
    static func settingExpiry(_ date: Date?, qualificationId: String, in dates: [String: Date]) -> [String: Date] {
        let day = date.map { OrganizationRulebookContext.calendar.startOfDay(for: $0) }
        return CanonicalBusinessEngine.withQualificationExpiry(dates: dates, qualificationId: qualificationId, date: day) ?? dates
    }

    // MARK: Rows for the profile

    /// The profile rows from every row of the person (`personQualifications`), sorted by name for display.
    /// `preferredRowId` is the row the editor saves to.
    static func rows(
        for person: AppUser,
        users: [AppUser],
        operatives: [Operative],
        preferredRowId: String? = nil,
        reference: Date = Date()
    ) -> [PersonQualificationRow]? {
        guard let own = operativeRows(for: person, users: users, operatives: operatives) else { return nil }
        return rows(fromOwnRows: own, preferredRowId: preferredRowId, reference: reference)
    }

    static func rows(
        fromOwnRows own: [Operative],
        preferredRowId: String? = nil,
        reference: Date = Date()
    ) -> [PersonQualificationRow]? {
        guard !own.isEmpty else { return [] }
        guard let chosen = CanonicalBusinessEngine.personQualifications(rows: own, preferredRowId: preferredRowId) else {
            return nil
        }
        let tones = expiryTones(chosen.map { ($0.id, $0.name, $0.expiry) }, reference: reference)
        return chosen
            .map { item in
                PersonQualificationRow(
                    id: item.id,
                    name: item.name,
                    expiry: item.expiry,
                    certificateURL: item.certificateUrl.flatMap { CanonicalBusinessEngine.safeExternalURL($0) },
                    operativeDocumentId: item.operativeId,
                    tone: tones[idKey(item.id)] ?? .none
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func idKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Expired / expiring soon from `qualificationExpiryRows` (the Warnings rule). Keyed by qualification id, lower case.
    private static let profileRowId = "profile"

    static func expiryTones(_ items: [(id: String, name: String, expiry: Date?)], reference: Date) -> [String: PersonQualificationRow.Tone] {
        let expiries: [[String: Any]] = items.compactMap { item in
            guard let expiry = item.expiry else { return nil }
            return [
                "qualificationId": item.id,
                "name": item.name.isEmpty ? item.id : item.name,
                "expiryIso": CanonicalBusinessEngine.isoString(from: expiry),
            ]
        }
        guard !expiries.isEmpty,
              let rows = CanonicalBusinessEngine.qualificationExpiryRows(
                operatives: [["id": profileRowId, "isActive": true, "email": "", "name": "Profile", "expiries": expiries]],
                reference: reference
              ) else { return [:] }
        var tones: [String: PersonQualificationRow.Tone] = [:]
        let prefix = "qual-\(profileRowId)-"
        for row in rows where row.id.hasPrefix(prefix) {
            let id = idKey(String(row.id.dropFirst(prefix.count)))
            tones[id] = row.daysUntilExpiry < 0 ? .expired : .expiringSoon
        }
        return tones
    }

    // MARK: Text

    /// "Expires 12 Mar 2027", "Expired 3 Jan 2026" or "No expiry", the date on the organisation's calendar.
    static func expiryText(_ row: PersonQualificationRow) -> String {
        guard let expiry = row.expiry else { return "No expiry" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy"
        let date = formatter.string(from: expiry)
        return row.tone == .expired ? "Expired \(date)" : "Expires \(date)"
    }
}
