//
//  PersonQualifications.swift
//  Project Planner
//
//  Owner issues 17 Nov (#17–#19, "fix on both apps"): every user's profile summary lists their qualifications — admins,
//  the Super Admin, managers, operatives and ghosts alike — each with its expiry date and a "View certificate" button.
//
//  Who the person is (guardrail 1): qualifications live on `operatives` catalogue rows, and one person can have
//  several (a converted ghost's old row, a duplicate linked to it, a row linked to an account by `linkedUserId`, a row
//  on another of their emails through a same-email users document). The rows are matched with the rulebook's
//  `taskPersonKeys` (RULEBOOK 1.59.0 §21: `personIdSet` over the whole roster, the rows' emails and account links, one
//  key per person) — never "one operatives row by email".
//
//  Which date is the expiry (#19): `operatives/{id}.qualificationExpiryDates[qualificationId]` (read by the rulebook's
//  `parseOperativeDocument`; the map the editor writes and the Warnings / Home counts read), else the assignment row's
//  own `endDate` when it says `hasEndDate`. Web read only `hasEndDate && endDate` and showed "No expiry" for a date kept
//  in the map. The map key is matched in its stored case first, then without case (ids keep their stored case and
//  compare without case, RULEBOOK §1).
//
//  Expired / expiring soon is `qualificationExpiryRows` (RULEBOOK §5, the Warnings rule: organisation day, one calendar
//  month ahead). Certificate links are `qualificationCertificateUrl` then `safeExternalUrl` (https only, §24).
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
    /// The expiry (`qualificationExpiryDates`, else the row's `endDate`); nil = no expiry.
    let expiry: Date?
    /// The certificate as a safe link (`safeExternalUrl`); nil = none uploaded, or not an https link.
    let certificateURL: URL?
    /// The `operatives` row the qualification sits on (stored id).
    let operativeDocumentId: String
    let tone: Tone
}

enum PersonQualifications {
    // MARK: Which rows are the person's

    /// The `taskPersonKeys` input for the roster and the catalogue rows.
    private static func keyInput(users: [AppUser], operatives: [Operative], managers: [Manager]) -> [String: Any] {
        let roster: [[String: Any]] = users.map { user in
            [
                "id": user.id,
                "email": user.email,
                "formerUserIds": user.formerUserIds,
                "sameEmailUserIds": user.sameEmailUserIds,
                "ghost": user.isGhost,
            ]
        }
        let catalogue: ([(String, String, String?)]) -> [[String: Any]] = { rows in
            rows.map { id, email, linked in
                var row: [String: Any] = ["id": id, "email": email]
                if let linked, !linked.isEmpty { row["linkedUserId"] = linked }
                return row
            }
        }
        return [
            "roster": roster,
            "operatives": catalogue(operatives.map { ($0.documentId, $0.email, $0.linkedUserId) }),
            "managers": catalogue(managers.map { ($0.firestoreDocumentId, $0.email, $0.linkedUserId) }),
        ]
    }

    private static func idKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The last `taskPersonKeys` answer and the hash of exactly the fields it reads (review of #269: not one script
    /// call per redraw; a roster or row change rebuilds it).
    private static var keysCache: (hash: Int, keys: [String: String])?

    static func personKeys(users: [AppUser], operatives: [Operative], managers: [Manager]) -> [String: String]? {
        var hasher = Hasher()
        for user in users {
            hasher.combine(user.id); hasher.combine(user.email); hasher.combine(user.formerUserIds)
            hasher.combine(user.sameEmailUserIds); hasher.combine(user.isGhost)
        }
        hasher.combine(-1)
        for row in operatives { hasher.combine(row.documentId); hasher.combine(row.email); hasher.combine(row.linkedUserId) }
        hasher.combine(-2)
        for row in managers { hasher.combine(row.firestoreDocumentId); hasher.combine(row.email); hasher.combine(row.linkedUserId) }
        let hash = hasher.finalize()
        if let cached = keysCache, cached.hash == hash { return cached.keys }
        let input = keyInput(users: users, operatives: operatives, managers: managers)
        guard let answer = CanonicalBusinessEngine.callJSON("taskPersonKeys", arguments: [input]) as? [String: Any],
              let keys = answer["keys"] as? [String: String] else { return nil }
        keysCache = (hash, keys)
        return keys
    }

    /// The person's `operatives` rows: every row `taskPersonKeys` gives the same key as the person's users id (or any
    /// id they go by). Nil when the script did not answer — the caller shows nothing rather than a guess.
    static func operativeRows(
        for person: AppUser,
        users: [AppUser],
        operatives: [Operative],
        managers: [Manager]
    ) -> [Operative]? {
        var roster = users
        if !roster.contains(where: { idKey($0.id) == idKey(person.id) }) { roster.append(person) }
        guard let keys = personKeys(users: roster, operatives: operatives, managers: managers) else { return nil }
        let personIds = [person.id] + person.formerUserIds + person.sameEmailUserIds
        let personKeys = Set(personIds.compactMap { keys[idKey($0)] })
        guard !personKeys.isEmpty else { return [] }
        return operatives.filter { row in
            guard let key = keys[idKey(row.documentId)] else { return false }
            return personKeys.contains(key)
        }
    }

    // MARK: Expiry and certificate

    /// The stored expiry of `qualification` on `operative` (#19): the expiry map under the qualification id (stored
    /// case first, then without case), else the assignment row's `endDate` when it says `hasEndDate`.
    static func expiryDate(of qualification: Qualification, on operative: Operative) -> Date? {
        expiryDate(qualification: qualification, expiryDates: operative.qualificationExpiryDates)
    }

    static func expiryDate(qualification: Qualification, expiryDates: [String: Date]) -> Date? {
        if let exact = expiryDates[qualification.id] { return exact }
        let target = idKey(qualification.id)
        if !target.isEmpty {
            // Several keys of one id in other cases: the latest date (a renewal written under the other spelling).
            let matches = expiryDates.filter { idKey($0.key) == target }.map(\.value)
            if let latest = matches.max() { return latest }
        }
        if qualification.hasEndDate, let endDate = qualification.endDate { return endDate }
        return nil
    }

    /// Display only (#19, review of #269 item 2): for each assigned qualification with no entry under its own id in
    /// the stored map, the expiry `expiryDate` finds elsewhere (another spelling of the id, or the assignment's
    /// `endDate`), keyed by the qualification id. The editor shows these but never writes them back unless the person
    /// changes that expiry (RULEBOOK §1: never re-save what you didn't change).
    static func derivedExpiryDates(for operative: Operative) -> [String: Date] {
        var derived: [String: Date] = [:]
        for qualification in operative.qualifications where operative.qualificationExpiryDates[qualification.id] == nil {
            if let date = expiryDate(of: qualification, on: operative) {
                derived[qualification.id] = date
            }
        }
        return derived
    }

    /// The certificate link for `qualificationId` (`qualificationCertificateUrl`, then `safeExternalUrl`).
    static func certificateURL(qualificationId: String, urls: [String: String]) -> URL? {
        guard let stored = CanonicalBusinessEngine.qualificationCertificateUrl(urls: urls, qualificationId: qualificationId)
        else { return nil }
        return CanonicalBusinessEngine.safeExternalURL(stored)
    }

    // MARK: Rows for the profile

    /// The profile rows: each qualification once (by id, without case), from every row of the person. When two rows
    /// hold one qualification, the copy with a certificate wins, then the later expiry, then an active row. Sorted by name.
    static func rows(
        for person: AppUser,
        users: [AppUser],
        operatives: [Operative],
        managers: [Manager],
        reference: Date = Date()
    ) -> [PersonQualificationRow]? {
        guard let own = operativeRows(for: person, users: users, operatives: operatives, managers: managers) else { return nil }
        return rows(fromOwnRows: own, reference: reference)
    }

    static func rows(fromOwnRows own: [Operative], reference: Date = Date()) -> [PersonQualificationRow] {
        struct Candidate {
            let qualification: Qualification
            let operative: Operative
            let expiry: Date?
            let certificate: URL?
        }
        var best: [String: Candidate] = [:]
        var order: [String] = []
        func better(_ a: Candidate, than b: Candidate) -> Bool {
            if (a.certificate != nil) != (b.certificate != nil) { return a.certificate != nil }
            switch (a.expiry, b.expiry) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.operative.isActive != b.operative.isActive { return a.operative.isActive }
            return false
        }
        for row in own.sorted(by: { $0.documentId < $1.documentId }) {
            for qualification in row.qualifications {
                let key = idKey(qualification.id)
                guard !key.isEmpty else { continue }
                let candidate = Candidate(
                    qualification: qualification,
                    operative: row,
                    expiry: expiryDate(of: qualification, on: row),
                    certificate: certificateURL(qualificationId: qualification.id, urls: row.qualificationCertificateURLs)
                )
                if let current = best[key] {
                    if better(candidate, than: current) { best[key] = candidate }
                } else {
                    best[key] = candidate
                    order.append(key)
                }
            }
        }
        let chosen = order.compactMap { best[$0] }
        let tones = expiryTones(chosen.map { ($0.qualification.id, $0.qualification.name, $0.expiry) }, reference: reference)
        return chosen
            .map { candidate in
                PersonQualificationRow(
                    id: candidate.qualification.id,
                    name: candidate.qualification.name,
                    expiry: candidate.expiry,
                    certificateURL: candidate.certificate,
                    operativeDocumentId: candidate.operative.documentId,
                    tone: tones[idKey(candidate.qualification.id)] ?? .none
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
