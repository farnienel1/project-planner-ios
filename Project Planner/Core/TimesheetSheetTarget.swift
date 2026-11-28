import Foundation

/// Which stored timesheet document a screen opens and saves, and whether a save may write its `userId`
/// (web `timesheetSaveTarget` / `keepStoredUserId`).
///
/// RULEBOOK 1.66.0 §8: User Timesheets → Awaiting sign-off and Signed off list a person's sheets under every id they go
/// by (a former invite id, a second users document on their email). The review screen must open, listen to and save the
/// document the row lists — `timesheet_{sheetUserId}_{start}` — never `timesheet_{personId}_{start}`, which would be a
/// different (often blank) sheet, and a signature there a second copy.
///
/// RULEBOOK §16 (`timesheetSubjectFiled`, 1.54.1): an update never changes a stored `userId`; it may only add a missing
/// one that the document id names. A save that wrote a different spelling would be refused whole.
nonisolated enum TimesheetSheetTarget {
    /// The id the sheet is filed under: the listed row's stored id when it has one, else the person's own id.
    static func userId(sheetUserId: String?, personId: String) -> String {
        guard let sheetUserId, !sheetUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return personId }
        return sheetUserId
    }

    /// The `userId` a save writes, or nil to write none. A new document gets it; an existing one only when it has no
    /// `userId` key at all (the document id was built from `userId`, so it names it). A stored `userId` — any value,
    /// any letter case — is never rewritten. An existing document whose stored copy is not known gets none.
    static func userIdWrite(stored: [String: Any]?, exists: Bool, userId: String) -> String? {
        guard exists else { return userId }
        guard let stored else { return nil }
        return stored.keys.contains("userId") ? nil : userId
    }
}
