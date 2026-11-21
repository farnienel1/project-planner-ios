import XCTest
@testable import Project_Planner

/// Dismissing an operative clash cluster (RULEBOOK §5, web #380). The cluster's own key is the pair of its first two
/// bookings by id, which need not overlap; the cluster is hidden only once every overlapping pair is resolved
/// (`isClashGroupApproved` over `resolvedWarningKeys`). A dismissal therefore writes every pair's
/// `clashResolutionKey` from `operativeClashGroups`, with status `dismissed` only.
@MainActor
final class ClashClusterDismissTests: XCTestCase {
    private let operativeId = "11111111-1111-1111-1111-111111111111"
    private let bookingA = "AAAAAAAA-0000-0000-0000-000000000001"
    private let bookingB = "BBBBBBBB-0000-0000-0000-000000000002"
    private let bookingC = "CCCCCCCC-0000-0000-0000-000000000003"

    private func booking(_ id: String, _ start: String, _ end: String) -> [String: Any] {
        [
            "id": id,
            "operativeId": operativeId,
            "dayKey": "2026-11-17",
            "timeSlot": "CUSTOM_HOURS",
            "workStartTime": start,
            "workEndTime": end,
            "status": "Confirmed",
        ]
    }

    /// `operativeClashGroups` for one person's day, read into the warning row the scan builds (the same mapping as
    /// `WarningsComputation.canonicalOperativeClashGroups`).
    private func clusterWarning(_ bookings: [[String: Any]], keepPairKeys: Bool = true) throws -> Warning {
        let payload: [String: Any] = [
            "managerIds": [String](),
            "people": ["accounts": [[String: Any]](), "operatives": [["id": operativeId, "email": ""]]],
            "day": [
                "standardDayStart": "07:30",
                "standardDayEnd": "16:00",
                "breakWindowStart": "12:00",
                "breakWindowEnd": "12:30",
            ],
            "operativeBookings": bookings,
        ]
        let groups = try XCTUnwrap(CanonicalBusinessEngine.operativeClashGroups(payload))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        let resolutionKey = try XCTUnwrap(group["resolutionKey"] as? String)
        let pairRows = group["pairs"] as? [[String: Any]] ?? []
        let pairs: [Warning.ClashPair] = pairRows.compactMap { row in
            guard let a = row["bookingAId"] as? String, let b = row["bookingBId"] as? String else { return nil }
            let key = keepPairKeys ? (row["clashResolutionKey"] as? String) : nil
            return Warning.ClashPair(bookingAId: a, bookingBId: b, clashResolutionKey: key)
        }
        let ids = try XCTUnwrap(group["bookingIds"] as? [String])
        let entry = Warning.ClashTimelineEntry(
            bookingId: UUID(uuidString: ids[0])!,
            managerBookingId: nil,
            jobNumber: nil,
            siteName: nil,
            isSmallWorks: false,
            locationLabel: "TEST-Job",
            timeLabel: "Custom",
            startMinutes: 0,
            endMinutes: 60,
            hoursLabel: "1h"
        )
        return Warning(
            resolutionKey: resolutionKey,
            type: .operativeBookingClash,
            title: "Booking clash",
            message: "TEST",
            severity: .high,
            occurrenceDate: Date(),
            operativeClash: Warning.OperativeClashWarningDetails(
                operativeId: UUID(uuidString: operativeId)!,
                operativeName: "TEST-Sam",
                date: Date(),
                bookingAId: UUID(uuidString: ids[0])!,
                bookingBId: UUID(uuidString: ids[1])!,
                entryA: entry,
                entryB: entry,
                overlapMinutes: 60,
                overlapSummary: "",
                overlapDetail: "",
                entries: nil,
                pairs: pairs
            ),
            managerClash: nil,
            unbookedLabour: nil,
            annualLeave: nil,
            materialsCutoff: nil,
            bookingClashDetails: nil,
            operativeEmail: nil
        )
    }

    /// `WarningDecisions` after these keys were written with status `dismissed` (and nothing else).
    private func decisionsAfterDismissing(_ keys: [String]) throws -> [String: Any] {
        let records: [[String: Any]] = try keys.map { key in
            let write = try XCTUnwrap(CanonicalBusinessEngine.warningResolutionWriteFields(
                resolutionKey: key,
                status: "dismissed",
                resolvedByUserId: "TEST-admin"
            ))
            XCTAssertEqual(write.fields["status"] as? String, "dismissed")
            return write.fields
        }
        let resolved = try XCTUnwrap(CanonicalBusinessEngine.resolvedWarningKeys(records))
        // A dismissal is never an approval.
        XCTAssertEqual(CanonicalBusinessEngine.approvedWarningKeys(records), [])
        return CanonicalBusinessEngine.warningDecisions(resolvedKeys: resolved, acceptedClashes: [])
    }

    private func clusterHidden(_ warning: Warning, decisions: [String: Any]) throws -> Bool {
        let clash = try XCTUnwrap(warning.operativeClash)
        return try XCTUnwrap(CanonicalBusinessEngine.isClashGroupApproved(
            pairs: clash.approvalPairs.map { (bookingAId: $0.bookingAId, bookingBId: $0.bookingBId) },
            decisions: decisions
        ))
    }

    /// A 07:00–10:00 and B 11:00–14:00 do not overlap; C 09:00–12:00 overlaps both. The cluster key is A|B.
    func testThreeBookingClusterIsGoneAfterDismissWhenFirstTwoDoNotOverlap() throws {
        let warning = try clusterWarning([
            booking(bookingA, "07:00", "10:00"),
            booking(bookingB, "11:00", "14:00"),
            booking(bookingC, "09:00", "12:00"),
        ])
        let clash = try XCTUnwrap(warning.operativeClash)
        let groupKey = try XCTUnwrap(CanonicalBusinessEngine.clashResolutionKey(bookingAId: bookingA, bookingBId: bookingB))
        XCTAssertEqual(warning.resolutionKey, groupKey)
        // The cluster key's pair (A, B) is not one of the overlapping pairs.
        XCTAssertFalse(clash.approvalPairs.contains { Set([$0.bookingAId, $0.bookingBId]) == Set([bookingA, bookingB]) })
        XCTAssertEqual(clash.approvalPairs.count, 2)

        // The bug: writing only the cluster key leaves the warning on both apps.
        XCTAssertFalse(try clusterHidden(warning, decisions: decisionsAfterDismissing([warning.resolutionKey])))

        let keys = WarningResolutionStore.dismissResolutionKeys(warning)
        let pairKeys = clash.approvalPairs.compactMap(\.clashResolutionKey)
        XCTAssertEqual(pairKeys.count, 2)
        XCTAssertEqual(keys, [groupKey] + pairKeys)
        XCTAssertTrue(try clusterHidden(warning, decisions: decisionsAfterDismissing(keys)))
        // Same as approval's keys: `clashApprovalWrites` writes `warningResolutions/{clashResolutionKey}` per pair.
        for pair in clash.approvalPairs {
            let approval = try XCTUnwrap(CanonicalBusinessEngine.clashApprovalWrites(
                bookingAId: pair.bookingAId,
                bookingBId: pair.bookingBId,
                resolutionKey: nil,
                approvedByUserId: "TEST-admin"
            ))
            XCTAssertTrue(keys.contains(try XCTUnwrap(approval.resolution?.documentId)))
        }
    }

    /// An older cache keeps the pairs without their keys; `clashResolutionKey` fills them in.
    func testOlderCacheWithoutPairKeysStillWritesEveryPair() throws {
        let warning = try clusterWarning([
            booking(bookingA, "07:00", "10:00"),
            booking(bookingB, "11:00", "14:00"),
            booking(bookingC, "09:00", "12:00"),
        ], keepPairKeys: false)
        XCTAssertTrue(warning.operativeClash?.approvalPairs.allSatisfy { $0.clashResolutionKey == nil } ?? false)
        let keys = WarningResolutionStore.dismissResolutionKeys(warning)
        XCTAssertEqual(keys.count, 3)
        XCTAssertTrue(try clusterHidden(warning, decisions: decisionsAfterDismissing(keys)))
    }

    /// A two-booking clash is its own pair: still one key, one document, as before.
    func testTwoBookingClashIsUnchanged() throws {
        let warning = try clusterWarning([
            booking(bookingA, "07:00", "10:00"),
            booking(bookingB, "09:00", "12:00"),
        ])
        XCTAssertEqual(warning.operativeClash?.approvalPairs.count, 1)
        let keys = WarningResolutionStore.dismissResolutionKeys(warning)
        XCTAssertEqual(keys, [warning.resolutionKey])
        XCTAssertTrue(try clusterHidden(warning, decisions: decisionsAfterDismissing(keys)))
    }

    /// A row that is not an operative clash writes only its own key.
    func testNonClashRowWritesOnlyItsOwnKey() {
        let warning = Warning(
            resolutionKey: "unbooked-TEST-2026-11-17",
            type: .unbookedLabour,
            title: "Unbooked labour",
            message: "TEST",
            severity: .high,
            occurrenceDate: Date(),
            operativeClash: nil,
            managerClash: nil,
            unbookedLabour: nil,
            annualLeave: nil,
            materialsCutoff: nil,
            bookingClashDetails: nil,
            operativeEmail: nil
        )
        XCTAssertEqual(WarningResolutionStore.dismissResolutionKeys(warning), ["unbooked-TEST-2026-11-17"])
    }
}
