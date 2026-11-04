import XCTest
import UIKit
@testable import Project_Planner

/// RULEBOOK 1.30.0 on iOS through `CanonicalBusinessEngine` (`Rulebook+PayeClaims.swift`): PAYE price work and
/// expenses (validation, approver candidates, write fields, readers with the owner's evidence filter, ranges, totals,
/// report readiness, the report snapshot and its pages, the §24 clean-up selection), who sees whose items, the
/// self-employed timesheet rows, personal site audits and the privacy sentence. Every answer comes from the packed
/// script; these tests lock the Swift inputs and readings, the same cases web's `canonical.test.ts` asserts.
/// RULEBOOK 1.30.1 (`priceWorkJobNumber.ts`): price work needs a job number — `priceWorkJobNumberError`,
/// `priceWorkJobNumberText`, `timesheetPriceWorkJobNumberError` — locked here too.
@MainActor
final class Rulebook1300Tests: XCTestCase {
    private let org = "TEST-ORG-130"

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 130"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    /// The roster as `PayeClaimPeople.approverRow` builds it (line-manager row plus the users document's organisation).
    private func row(
        _ id: String,
        role: String,
        organizationId: String? = nil,
        isActive: Bool = true,
        manager: Bool = false,
        admin: Bool = false,
        operativeMode: Bool = false,
        lineManagers: [String] = []
    ) -> [String: Any] {
        [
            "id": id,
            "email": "\(id)@test.example",
            "isActive": isActive,
            "role": role,
            "isSuperAdmin": false,
            "adminAccess": admin,
            "isAdmin": admin,
            "manager": manager,
            "operativeMode": operativeMode,
            "firstName": id.capitalized,
            "surname": "Test",
            "name": "\(id.capitalized) Test",
            "passwordSet": true,
            "organizationId": organizationId ?? org,
            "assignedManagerUserIds": lineManagers,
            "formerUserIds": [String](),
            "sameEmailUserIds": [String](),
        ]
    }

    private var roster: [[String: Any]] {
        [
            row("sam", role: "operative", operativeMode: true, lineManagers: ["mia"]),
            row("mia", role: "manager", manager: true),
            row("ada", role: "admin", admin: true),
            row("op2", role: "operative", operativeMode: true, lineManagers: ["mia"]),
            // Membership only: a manager whose users document names another company.
            row("max", role: "manager", organizationId: "TEST-OTHER-ORG", manager: true),
            row("old", role: "manager", isActive: false, manager: true),
        ]
    }

    private func person(_ id: String) -> [String: Any] {
        roster.first { ($0["id"] as? String) == id } ?? [:]
    }

    private func evidencePath(_ user: String, _ ms: Int64, _ ext: String = "jpg") throws -> String {
        try XCTUnwrap(CanonicalBusinessEngine.payeClaimEvidencePath(organizationId: org, userId: user, unixMs: ms, fileExtension: ext))
    }

    // MARK: Packed script

    func testThePackedScriptIsRulebook1300OrLaterAndExportsTheClaimRules() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 30, 0]), "rulebook \(stamp.version) predates 1.30.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "priceWorkApproverCandidates", "priceWorkValidationError", "expenseValidationError", "priceWorkWriteFields",
            "expenseWriteFields", "parsePriceWorkDocument", "parseExpenseDocument", "parsePayeClaimEvidence",
            "payeClaimEvidencePath", "payeClaimEvidenceToDelete", "payeClaimsInRange", "payeClaimsTotal",
            "payeClaimReportReady", "payeClaimListRow", "payeClaimReportSnapshot", "parsePayeClaimReportDocument",
            "payeClaimReportRows", "payeClaimEvidencePages", "payeClaimReportsOfKind", "canViewPayeClaims",
            "canWritePayeClaim", "timesheetClaimRows", "personalSiteAuditWriteFields", "personalSiteAuditValidationError",
            "parsePersonalSiteAuditDocument", "personalSiteAuditsFor", "personalSiteAuditImagePath",
            "personalSiteAuditPdfRows", "personalSiteAuditEvidence", "PERSONAL_SITE_AUDIT_PRIVACY_NOTICE",
        ] {
            XCTAssertTrue(exports.contains(name), "missing export \(name)")
        }
        XCTAssertEqual(PayeClaimKind.priceWork.collection, "priceWorkItems")
        XCTAssertEqual(PayeClaimKind.expense.collection, "expenseItems")
        XCTAssertEqual(PayeClaimKind.priceWork.addLabel, "Add Price Work")
        XCTAssertEqual(PayeClaimKind.expense.generateReportLabel, "Generate expenses report")
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimEvidenceMax, 20)
    }

    // MARK: Approvers

    func testApproverCandidatesAreActiveAdminsAndManagersOfThisOrganisationNeverOperativesSelfOrMembershipOnly() {
        let forSam = CanonicalBusinessEngine.priceWorkApproverCandidates(person: person("sam"), roster: roster, organizationId: org)
        XCTAssertEqual(Set(forSam.map(\.id)), ["ada", "mia"], "no operative, no inactive manager, no other company's manager")
        XCTAssertEqual(forSam.first { $0.id == "ada" }?.level, "admin")
        let forMia = CanonicalBusinessEngine.priceWorkApproverCandidates(person: person("mia"), roster: roster, organizationId: org)
        XCTAssertFalse(forMia.contains { $0.id == "mia" }, "never the person")
        XCTAssertEqual(forMia.map(\.id), ["ada"])
    }

    /// Review fix: the approver row carries the organisation the users document STORES (`storedOrganizationId`, web
    /// `homeOrganizationId`), never the open organisation a roster reader fills in when the field is missing — the
    /// rules' `homeOrgIs` reads the stored field, so such a person must not be offered.
    func testApproverRowsUseTheStoredOrganisationSoAPersonWithNoneIsNotOffered() {
        func user(_ id: String, role: String, extra: [String: Any]) -> AppUser {
            var data: [String: Any] = [
                "email": "\(id)@test.example", "firstName": id.capitalized, "surname": "Test",
                "role": role, "isActive": true, "passwordSet": true,
            ]
            data.merge(extra) { $1 }
            return FirebaseBackend.parseAppUserDocument(userId: id, data: data)
        }
        let sam = user("sam", role: "operative", extra: ["operativeMode": true, "organizationId": org, "assignedManagerUserIds": ["mia"]])
        let mia = user("mia", role: "manager", extra: ["manager": true, "organizationId": org])
        var noOrg = user("nox", role: "manager", extra: ["manager": true])
        XCTAssertNil(noOrg.storedOrganizationId)
        // What `getOrganizationUsers` and the roster listener do for a document with no `organizationId`.
        noOrg.organizationId = org
        let viaPath = user("pat", role: "manager", extra: ["manager": true, "organizationId": "organizations/\(org)"])
        XCTAssertEqual(mia.storedOrganizationId, org)
        let ids = Set(CanonicalBusinessEngine.priceWorkApproverCandidates(
            person: PayeClaimPeople.approverRow(sam),
            roster: PayeClaimPeople.approverRoster([sam, mia, noOrg, viaPath]),
            organizationId: org
        ).map(\.id))
        XCTAssertTrue(ids.contains("mia"))
        XCTAssertFalse(ids.contains("nox"), "no stored organisation: the rules refuse them, so they are not offered")
        XCTAssertTrue(ids.contains("pat"), "a stored organisation path names this organisation")
        XCTAssertFalse(ids.contains("sam"))
    }

    /// Review fix: the frozen audit copy draws photos downscaled, and a copy over the claim folder's 10 MB limit is
    /// refused before any upload with a clear message.
    func testFrozenAuditCopiesAreDownscaledAndSizeGuarded() throws {
        XCTAssertNil(PersonalSiteAuditPDF.attachRefusal(byteCount: StorageUploadPolicy.standardMaxBytes))
        XCTAssertEqual(
            PersonalSiteAuditPDF.attachRefusal(byteCount: StorageUploadPolicy.standardMaxBytes + 1),
            "This audit is too large to attach — remove some photos or attach it as separate photos."
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let small = try XCTUnwrap(PersonalSiteAuditPDF.downscaledPhoto(big))
        let pixels = max(small.image.size.width * small.image.scale, small.image.size.height * small.image.scale)
        XCTAssertLessThanOrEqual(pixels, 1600.5)
        XCTAssertGreaterThan(pixels, 1500, "scaled to the limit, not further")
        let tiny = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { _ in }
        let kept = try XCTUnwrap(PersonalSiteAuditPDF.downscaledPhoto(tiny))
        XCTAssertEqual(kept.image.size.width * kept.image.scale, 300, accuracy: 0.5, "never enlarged")
        XCTAssertEqual(UIImage(data: small.jpeg)?.cgImage?.width, Int(pixels.rounded()))
    }

    // MARK: Validation

    func testPriceWorkValidationNeedsNameDatesAndAnApproverFromTheCandidates() {
        let base: [String: Any] = [
            "title": "TEST-Tiling", "details": "", "jobNumber": "J-1042", "startDate": "2026-11-04", "endDate": "2026-11-05",
            "approvedByUserId": "mia", "amount": "150",
        ]
        func error(_ change: [String: Any]) -> String? {
            CanonicalBusinessEngine.priceWorkValidationError(
                draft: base.merging(change) { $1 }, person: person("sam"), roster: roster, organizationId: org
            )
        }
        XCTAssertNil(error([:]))
        XCTAssertEqual(error(["title": ""]), "Enter a name.")
        XCTAssertEqual(error(["jobNumber": ""]), "Add the job number for this price work.", "1.30.1: required")
        XCTAssertEqual(error(["jobNumber": String(repeating: "9", count: 61)]), "The job number can be up to 60 characters.")
        XCTAssertEqual(error(["endDate": "2026-11-01"]), "Choose the dates from and to (the same day is allowed).")
        XCTAssertNil(error(["endDate": "2026-11-04"]), "the same day is allowed")
        XCTAssertEqual(error(["approvedByUserId": ""]), "Choose who approved this price work.")
        XCTAssertEqual(error(["approvedByUserId": "op2"]), "Choose an active admin or manager other than yourself.")
        XCTAssertEqual(error(["approvedByUserId": "max"]), "Choose an active admin or manager other than yourself.")
        XCTAssertEqual(error(["amount": "0"]), "Enter an amount greater than zero.")
    }

    func testAnExpenseNeedsAtLeastOnePieceOfEvidenceInThePersonsOwnFolder() throws {
        let own = try evidencePath("sam", 1_762_250_000_000)
        let foreign = try evidencePath("op2", 1_762_250_000_001)
        let base: [String: Any] = ["title": "TEST-Fuel", "date": "2026-11-04", "amount": "12.50"]
        XCTAssertEqual(
            CanonicalBusinessEngine.expenseValidationError(draft: base.merging(["evidence": [[String: Any]]()]) { $1 }, organizationId: nil, userId: nil),
            "Add at least one piece of evidence (a file, photo or personal site audit)."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.expenseValidationError(draft: base, organizationId: nil, userId: nil),
            "Add at least one piece of evidence (a file, photo or personal site audit)."
        )
        XCTAssertNil(CanonicalBusinessEngine.expenseValidationError(
            draft: base.merging(["evidence": [["path": own, "name": "r.jpg", "kind": "photo"]]]) { $1 }, organizationId: org, userId: "sam"
        ))
        XCTAssertEqual(
            CanonicalBusinessEngine.expenseValidationError(
                draft: base.merging(["evidence": [["path": foreign, "name": "r.jpg", "kind": "photo"]]]) { $1 }, organizationId: org, userId: "sam"
            ),
            "Evidence must be uploaded to your own claim folder."
        )
        let fields = try XCTUnwrap(CanonicalBusinessEngine.expenseWriteFields(
            userId: "sam",
            draft: base.merging(["jobNumber": "J-1", "evidence": [PayeClaimEvidence(path: own, name: "r.jpg", kind: "photo", contentType: "image/jpeg", auditId: nil).json]]) { $1 },
            currency: "GBP",
            organizationId: org
        ))
        XCTAssertEqual(Set(fields.keys), ["userId", "title", "details", "jobNumber", "date", "amount", "currency", "evidence", "createdBy"],
                       "the keys the 1.30 rules allow (plus createdAt and the write metadata the app adds)")
        XCTAssertEqual((fields["amount"] as? NSNumber)?.doubleValue, 12.5)
        XCTAssertEqual(fields["createdBy"] as? String, "sam")
        let evidence = try XCTUnwrap(fields["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.first?["path"] as? String, own)
        XCTAssertNil(evidence.first?["auditId"], "no empty optional fields")
    }

    func testPriceWorkWriteFieldsStoreTheApproverNameAndOnlyTheAllowedKeys() throws {
        let draft: [String: Any] = [
            "title": "TEST-Tiling", "details": "Bathroom", "jobNumber": " J-1042 ", "startDate": "2026-11-04", "endDate": "2026-11-06",
            "approvedByUserId": "mia", "amount": "150", "evidence": [[String: Any]](),
        ]
        let fields = try XCTUnwrap(CanonicalBusinessEngine.priceWorkWriteFields(
            userId: "sam", draft: draft, person: person("sam"), roster: roster, currency: "GBP", organizationId: org
        ))
        XCTAssertEqual(fields["approvedByUserId"] as? String, "mia")
        XCTAssertEqual(fields["approvedByName"] as? String, "Mia Test")
        XCTAssertEqual(Set(fields.keys), [
            "userId", "title", "details", "jobNumber", "startDate", "endDate", "approvedByUserId", "approvedByName", "amount",
            "currency", "evidence", "createdBy",
        ])
        XCTAssertEqual(fields["jobNumber"] as? String, "J-1042", "1.30.1: stored trimmed")
        XCTAssertNil(CanonicalBusinessEngine.priceWorkWriteFields(
            userId: "op2", draft: draft, person: person("sam"), roster: roster, currency: "GBP", organizationId: org
        ), "only the person writes their own price work")
    }

    // MARK: Readers, evidence filter, ranges

    func testReadersDropEvidenceThatIsNotThePersonsOwnClaimFile() throws {
        let own = try evidencePath("sam", 1_762_250_000_000)
        let foreign = try evidencePath("op2", 1_762_250_000_001)
        let auditPhoto = "organizations/\(org)/personalSiteAudits/sam/A1/sam_1762250000000.jpg"
        let otherOrg = "organizations/TEST-OTHER-ORG/payeClaims/sam/sam_1762250000000.jpg"
        let stored: [[String: Any]] = [
            ["path": own, "name": "receipt", "kind": "photo"],
            ["path": foreign, "name": "theirs"],
            ["path": auditPhoto, "name": "private audit photo"],
            ["path": otherOrg, "name": "other company"],
            ["path": "https://example.com/x.jpg", "name": "url"],
        ]
        XCTAssertEqual(
            CanonicalBusinessEngine.parsePayeClaimEvidence(stored, ownerUserId: "sam", organizationId: org).map(\.path),
            [own]
        )
        let item = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense,
            docId: "E1",
            data: ["userId": "sam", "title": "TEST-Fuel", "date": "2026-11-04", "amount": 12.5, "currency": "GBP", "evidence": stored],
            organizationId: org
        ))
        XCTAssertEqual(item.kind, "expense")
        XCTAssertEqual(item.id, "E1")
        XCTAssertEqual(item.date, "2026-11-04")
        XCTAssertEqual(item.evidence.map(\.path), [own], "a viewer is never offered another person's file")
    }

    func testRangesTotalsAndReportReadiness() throws {
        let expense = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: "E1",
            data: ["userId": "sam", "title": "TEST-Fuel", "date": "2026-11-04", "amount": 12.5], organizationId: org
        ))
        let late = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: "E2",
            data: ["userId": "sam", "title": "TEST-Parking", "date": "2026-12-02", "amount": 4.2], organizationId: org
        ))
        let priceWork = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .priceWork, docId: "P1",
            data: ["userId": "sam", "title": "TEST-Tiling", "startDate": "2026-10-20", "endDate": "2026-10-27", "amount": 150,
                   "approvedByUserId": "mia", "approvedByName": "Mia Test"],
            organizationId: org
        ))
        let november = CanonicalBusinessEngine.payeClaimsInRange([late, expense], start: "2026-10-26", end: "2026-11-25")
        XCTAssertEqual(november.map(\.id), ["E1"], "an expense by its date")
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimsInRange([priceWork], start: "2026-10-26", end: "2026-11-25").map(\.id), ["P1"],
                       "price work whose from–to overlaps the range")
        XCTAssertTrue(CanonicalBusinessEngine.payeClaimsInRange([priceWork], start: "2026-11-01", end: "2026-11-25").isEmpty)
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimsTotal(amounts: [12.5, 4.2, 0.1]), 16.8, accuracy: 0.0001)
        XCTAssertFalse(CanonicalBusinessEngine.payeClaimReportReady(itemCount: 0))
        XCTAssertTrue(CanonicalBusinessEngine.payeClaimReportReady(itemCount: 1), "green after the first item")
        let row = try XCTUnwrap(CanonicalBusinessEngine.payeClaimListRow(priceWork, currency: "GBP"))
        XCTAssertEqual(row.figure, "£150.00")
        XCTAssertTrue(row.subtitle.contains("Approved by Mia Test"))
    }

    // MARK: Who sees what

    func testClaimsAreSeenByThePersonTheirLineManagerAndAdminsOnlyAndWrittenByThePersonOnly() {
        XCTAssertTrue(CanonicalBusinessEngine.canViewPayeClaims(viewer: person("sam"), subject: person("sam"), roster: roster))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPayeClaims(viewer: person("mia"), subject: person("sam"), roster: roster))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPayeClaims(viewer: person("ada"), subject: person("sam"), roster: roster))
        XCTAssertFalse(CanonicalBusinessEngine.canViewPayeClaims(viewer: person("op2"), subject: person("sam"), roster: roster))
        XCTAssertTrue(CanonicalBusinessEngine.canWritePayeClaim(viewerId: "sam", itemUserId: "sam"))
        XCTAssertFalse(CanonicalBusinessEngine.canWritePayeClaim(viewerId: "ada", itemUserId: "sam"), "admins read only")
    }

    // MARK: §24 clean-up

    func testCleanupDeletesOnlyThePersonsOwnJustUploadedFiles() throws {
        let uploadedMs: Int64 = 1_762_250_000_000
        let own = PayeClaimEvidence(path: try evidencePath("sam", uploadedMs), name: "r", kind: "photo", contentType: "image/jpeg", auditId: nil)
        let foreign = PayeClaimEvidence(path: try evidencePath("op2", uploadedMs), name: "x", kind: "photo", contentType: "image/jpeg", auditId: nil)
        let soon = Double(uploadedMs) + 60_000
        XCTAssertEqual(
            CanonicalBusinessEngine.payeClaimEvidenceToDelete([own, foreign], organizationId: org, viewerUserId: "sam", nowMs: soon),
            [own.path],
            "inside the undo window: the person's own upload only"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.payeClaimEvidenceToDelete([own], organizationId: org, viewerUserId: "sam", nowMs: Double(uploadedMs) + 3 * 86_400_000),
            [],
            "after the undo window the file is kept for recovery"
        )
    }

    // MARK: Reports

    func testTheReportSnapshotRoundTripsAndGivesOnePagePerPieceOfEvidence() throws {
        let photo = try evidencePath("sam", 1_762_250_000_000)
        let pdf = try evidencePath("sam", 1_762_250_000_001, "pdf")
        let expense = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: "E1",
            data: [
                "userId": "sam", "title": "TEST-Fuel", "date": "2026-11-04", "amount": 12.5, "jobNumber": "J-1",
                "evidence": [
                    ["path": photo, "name": "receipt.jpg", "kind": "photo", "contentType": "image/jpeg"],
                    ["path": pdf, "name": "invoice.pdf", "kind": "file", "contentType": "application/pdf"],
                ],
            ],
            organizationId: org
        ))
        var snapshot = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReportSnapshot(
            kind: .expense, userId: "sam", userName: "Sam Test", companyName: "TEST-Company 130", currency: "GBP",
            rangeStart: "2026-10-26", rangeEnd: "2026-11-25", items: [expense], generatedBy: "sam"
        ))
        XCTAssertEqual(Set(snapshot.keys).subtracting([
            "userId", "userName", "companyName", "kind", "rangeStart", "rangeEnd", "currency", "items", "totals", "generatedBy",
        ]), [], "the keys the 1.30 rules allow")
        snapshot["generatedAt"] = 1_762_250_100_000.0
        let report = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReportDocument(docId: "R1", data: snapshot))
        XCTAssertEqual(report.totals.amount, 12.5, accuracy: 0.001)
        XCTAssertEqual(report.totals.itemCount, 1)
        XCTAssertEqual(report.totals.evidenceCount, 2)
        let rows = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReportRows(report))
        XCTAssertEqual(rows.title, "Expenses report · Sam Test")
        XCTAssertEqual(rows.total, "Total expenses: £12.50")
        let pages = CanonicalBusinessEngine.payeClaimEvidencePages(report)
        XCTAssertEqual(pages.map(\.drawAs), ["image", "pdf"])
        XCTAssertEqual(pages.last?.details.first, "Evidence 2 of 2: invoice.pdf")
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimReportsOfKind([report], kind: .priceWork).count, 0)
        XCTAssertEqual(CanonicalBusinessEngine.payeClaimReportsOfKind([report], kind: .expense).map(\.id), ["R1"])
        XCTAssertEqual(
            CanonicalBusinessEngine.payeClaimEvidenceDrawAs(PayeClaimEvidence(path: "x/a.svg", name: "a.svg", kind: "file", contentType: "image/svg+xml", auditId: nil)),
            "listed",
            "an SVG is never drawn"
        )
    }

    // MARK: Self-employed

    func testSelfEmployedRowsAreTheirTimesheetEntriesInTheRange() throws {
        let entries = try XCTUnwrap(CanonicalBusinessEngine.parseTimesheetEntries(
            sheetDocumentId: "timesheet_op2_1",
            sheet: [
                "expenseEntries": [["id": "X1", "title": "Fuel", "amount": 10, "date": "2026-11-04T09:00:00Z", "receiptName": "receipt.jpg"]],
                "priceWorkEntries": [["id": "PW1", "title": "Tiles", "amount": 200, "startDate": "2026-10-20T09:00:00Z", "endDate": "2026-11-02T09:00:00Z", "agreedManagerName": "Bo"]],
            ],
            timeZone: "Europe/London"
        ))
        let sheets: [[String: Any]] = [["id": "timesheet_op2_1", "entries": entries.raw]]
        let expenses = CanonicalBusinessEngine.timesheetClaimRows(sheets: sheets, kind: .expense, start: "2026-10-26", end: "2026-11-25")
        XCTAssertEqual(expenses.map(\.id), ["X1"])
        XCTAssertEqual(expenses.first?.startDate, "2026-11-04")
        XCTAssertEqual(expenses.first?.amount, 10)
        let priceWork = CanonicalBusinessEngine.timesheetClaimRows(sheets: sheets, kind: .priceWork, start: "2026-10-26", end: "2026-11-25")
        XCTAssertEqual(priceWork.map(\.id), ["PW1"])
        XCTAssertEqual(priceWork.first?.approvedByName, "Bo")
    }

    // MARK: Personal site audits

    func testPersonalSiteAuditsAreOwnerOnlyWithTheFrozenCopyAsEvidence() throws {
        let imagePath = try XCTUnwrap(CanonicalBusinessEngine.personalSiteAuditImagePath(
            organizationId: org, ownerUserId: "sam", auditId: "A1", unixMs: 1_700_000_000_000, fileExtension: "jpg"
        ))
        XCTAssertEqual(imagePath, "organizations/\(org)/personalSiteAudits/sam/A1/sam_1700000000000.jpg")
        let draft: [String: Any] = [
            "jobNumber": "J-77", "jobName": "TEST-Garden wall", "date": "2026-11-04", "authorName": "Sam",
            "items": [["id": "i1", "title": "Crack", "imagePath": imagePath]],
        ]
        XCTAssertEqual(
            CanonicalBusinessEngine.personalSiteAuditValidationError(draft: draft.merging(["jobName": ""]) { $1 }, organizationId: nil, ownerUserId: nil),
            "Enter a job name."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.personalSiteAuditValidationError(draft: draft, organizationId: org, ownerUserId: "mia"),
            "Add at least one photo.",
            "a photo outside the owner's folder is refused"
        )
        XCTAssertNil(CanonicalBusinessEngine.personalSiteAuditValidationError(draft: draft, organizationId: org, ownerUserId: "sam"))
        let fields = try XCTUnwrap(CanonicalBusinessEngine.personalSiteAuditWriteFields(ownerUserId: "sam", draft: draft, organizationId: org))
        XCTAssertEqual(Set(fields.keys), ["ownerUserId", "jobNumber", "jobName", "type", "customTitle", "date", "authorName", "items"])
        let audit = try XCTUnwrap(CanonicalBusinessEngine.parsePersonalSiteAuditDocument(docId: "A1", data: fields))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPersonalSiteAudit(viewerUserId: "sam", ownerUserId: audit.ownerUserId))
        XCTAssertFalse(CanonicalBusinessEngine.canViewPersonalSiteAudit(viewerUserId: "ada", ownerUserId: audit.ownerUserId), "admins never see it")
        var other = audit
        other.id = "A2"
        other.ownerUserId = "mia"
        XCTAssertEqual(CanonicalBusinessEngine.personalSiteAuditsFor([audit, other], viewerUserId: "sam").map(\.id), ["A1"])
        XCTAssertEqual(CanonicalBusinessEngine.personalSiteAuditPdfRows(audit)?.lines.first, "Job number: J-77")
        let copyPath = try evidencePath("sam", 1_700_000_000_009, "pdf")
        let evidence = try XCTUnwrap(CanonicalBusinessEngine.personalSiteAuditEvidence(audit, path: copyPath))
        XCTAssertEqual(evidence.kind, "personalSiteAudit")
        XCTAssertEqual(evidence.contentType, "application/pdf")
        XCTAssertEqual(evidence.auditId, "A1")
        XCTAssertEqual(evidence.name, CanonicalBusinessEngine.personalSiteAuditTitle(audit))
        XCTAssertTrue(CanonicalBusinessEngine.payeClaimEvidencePathBelongsTo(copyPath, organizationId: org, userId: "sam"),
                      "the frozen copy sits in the claim folder, where line managers and admins may read it")
    }

    // MARK: 1.30.1 price work job number

    func testPriceWorkJobNumberIsRequiredOnNewItemsAndShownAsADashWhenAnOlderItemHasNone() throws {
        XCTAssertNil(CanonicalBusinessEngine.priceWorkJobNumberError("J-1042"))
        XCTAssertEqual(CanonicalBusinessEngine.priceWorkJobNumberError("  "), "Add the job number for this price work.")
        XCTAssertEqual(CanonicalBusinessEngine.priceWorkJobNumberMax, 60)
        XCTAssertEqual(CanonicalBusinessEngine.priceWorkJobNumberText(nil), "—")
        XCTAssertEqual(CanonicalBusinessEngine.priceWorkJobNumberText(" J-7 "), "J-7")
        let older = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .priceWork, docId: "P0",
            data: ["userId": "sam", "title": "TEST-Old", "startDate": "2026-11-02", "endDate": "2026-11-02", "amount": 40,
                   "approvedByUserId": "mia", "approvedByName": "Mia Test"],
            organizationId: org
        ))
        XCTAssertEqual(older.jobNumber, "", "an item stored before 1.30.1 stays valid")
        let row = try XCTUnwrap(CanonicalBusinessEngine.payeClaimListRow(older, currency: "GBP"))
        XCTAssertTrue(row.subtitle.contains("—"), "the list shows — for the missing job number")
        let current = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .priceWork, docId: "P1",
            data: ["userId": "sam", "title": "TEST-Tiling", "jobNumber": "J-1042", "startDate": "2026-11-04", "endDate": "2026-11-04",
                   "amount": 150, "approvedByUserId": "mia", "approvedByName": "Mia Test"],
            organizationId: org
        ))
        XCTAssertEqual(current.jobNumber, "J-1042")
        var snapshot = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReportSnapshot(
            kind: .priceWork, userId: "sam", userName: "Sam Test", companyName: "", currency: "GBP",
            rangeStart: "2026-11-01", rangeEnd: "2026-11-30", items: [older, current], generatedBy: "sam"
        ))
        snapshot["generatedAt"] = 1_762_250_100_000.0
        let report = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimReportDocument(docId: "R2", data: snapshot))
        let headings = try XCTUnwrap(CanonicalBusinessEngine.payeClaimReportRows(report)).rows.map(\.heading)
        XCTAssertTrue(headings.contains { $0.contains("—") && $0.contains("TEST-Old") })
        XCTAssertTrue(headings.contains { $0.contains("J-1042") && $0.contains("TEST-Tiling") })
    }

    func testTheOwnersTimesheetSaveAsksForAJobNumberOnlyOnAddedOrEditedPriceWork() {
        let old: [String: Any] = [
            "id": "PW-OLD", "title": "Tiles", "details": "", "jobNumber": "", "agreedManagerName": "Bo",
            "startDate": 1_762_000_000_000.0, "endDate": NSNull(), "amount": 200,
        ]
        XCTAssertNil(CanonicalBusinessEngine.timesheetPriceWorkJobNumberError(previous: [old], next: [old]),
                     "an untouched older entry without a job number never blocks a save")
        var reviewed = old
        reviewed["managerDecision"] = "declined"
        XCTAssertNil(CanonicalBusinessEngine.timesheetPriceWorkJobNumberError(previous: [old], next: [reviewed]),
                     "a reviewer's decision is not an owner edit")
        var edited = old
        edited["amount"] = 250
        XCTAssertEqual(CanonicalBusinessEngine.timesheetPriceWorkJobNumberError(previous: [old], next: [edited]),
                       "Add the job number for this price work.")
        let added: [String: Any] = [
            "id": "PW-NEW", "title": "Grout", "details": "", "jobNumber": "J-9", "agreedManagerName": "Bo",
            "startDate": 1_762_100_000_000.0, "endDate": NSNull(), "amount": 50,
        ]
        XCTAssertNil(CanonicalBusinessEngine.timesheetPriceWorkJobNumberError(previous: [old], next: [old, added]))
        var addedWithout = added
        addedWithout["jobNumber"] = ""
        XCTAssertEqual(CanonicalBusinessEngine.timesheetPriceWorkJobNumberError(previous: [old], next: [old, addedWithout]),
                       "Add the job number for this price work.")
    }

    func testThePrivacyPolicyCarriesThePersonalSiteAuditSentenceWithoutAPackVersionChange() throws {
        let notice = CanonicalBusinessEngine.personalSiteAuditPrivacyNotice
        XCTAssertTrue(notice.hasPrefix("Personal site audits are private to the person who created them."))
        let privacy = try XCTUnwrap(CustomerLegalPack.documents.first { $0.id == .privacy })
        XCTAssertTrue(privacy.body.contains(notice))
        XCTAssertEqual(CustomerLegalPack.version, "1.1")
    }
}
