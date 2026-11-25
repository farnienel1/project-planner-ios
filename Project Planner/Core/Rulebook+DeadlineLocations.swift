import Foundation

// RULEBOOK 1.92.0 §1 "A deadline on several floors": `deadlineLocationWriteFields(locations)` and
// `deadlineOnLocation(item, location)`. `parseDeadlineItem` (read through `parseDeadlineDocument`) returns `locations`.
extension CanonicalBusinessEngine {
    /// `deadlineLocationWriteFields(locations)` → `{ location: first floor or "", locations: the list }`. Nil when the
    /// script did not answer.
    nonisolated static func deadlineLocationWriteFields(_ locations: [String]) -> (location: String, locations: [String])? {
        guard let row = callJSON("deadlineLocationWriteFields", arguments: [locations]) as? [String: Any] else { return nil }
        let list = (row["locations"] as? [Any])?.compactMap { $0 as? String } ?? []
        return (row["location"] as? String ?? "", list)
    }

    /// `deadlineOnLocation(item, location)`: the deadline is on that floor (any of its floors, without case). Nil when
    /// the script did not answer.
    nonisolated static func deadlineOnLocation(location: String?, locations: [String], on floor: String) -> Bool? {
        let item: [String: Any] = ["location": location.map { $0 as Any } ?? NSNull(), "locations": locations]
        return callJSON("deadlineOnLocation", arguments: [item, floor]) as? Bool
    }
}
