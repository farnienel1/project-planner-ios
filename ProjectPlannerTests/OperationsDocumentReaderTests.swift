import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// Rulebook 1.8.0 (§1 "Document readers", "Partial writes only" and "Job keys", §5, §13): the operations and record
/// collections are read through the packed readers (`parseMaterialLineDocument`, `parseMaterialCatalogueDocument`,
/// `parseNotificationDocument`, `parseHealthSafetyDocument`, `parseTaskDocument`, `parseWholesalerDocument`,
/// `parseVariationDocument`, `parseWarningResolutionDocument`) and saved with the shared partial-write helpers
/// (`materialLineFields`, `materialCatalogueWrites`, `healthSafetySignatureWriteFields`, `taskFields`,
/// `warningResolutionMigrationWrites`). Web locks the same functions in `lib/canonical/canonical.test.ts`. Expected
/// values were checked with Node against the packed `canonical-business.js` (pack 964ca86b…).
@MainActor
final class OperationsDocumentReaderTests: XCTestCase {
    /// 2026-07-14 00:00 Europe/London (BST) = 2026-07-13 23:00 UTC.
    private let julyFourteenthLondonMidnight: Int64 = 1_783_983_600

    func testTheScriptAnswersTheOperationsReaders() {
        XCTAssertEqual(CanonicalBusinessEngine.rulebookStamp()?.version, "1.9.0")
        XCTAssertNotNil(CanonicalBusinessEngine.parseMaterialLineDocument(documentId: "m", data: ["projectId": "j", "material": "x"]))
        XCTAssertNotNil(CanonicalBusinessEngine.parseHealthSafetyDocument([:], projectId: "j"))
    }

    // MARK: - Materials

    func testIosAndWebMaterialLinesReadOnTheSameOrganisationDayAcrossBST() throws {
        // iOS before 1.8.0: device midnight (London BST) as `date`, upper-case UUID ids.
        let iosLine = try XCTUnwrap(FirebaseBackend.materialItem(documentId: "A1B2C3D4-0000-4000-8000-0000000000AA", data: [
            "id": "A1B2C3D4-0000-4000-8000-0000000000AA",
            "projectId": "job-abc",
            "quantity": 2,
            "unit": "Box",
            "material": "Cable",
            "addedBy": "TEST-user",
            "date": Timestamp(seconds: julyFourteenthLondonMidnight, nanoseconds: 0),
            "status": "ordered",
        ]))
        // Web: a non-UUID id, `name`, a numeric-string quantity, a lower-case unit, a status synonym, `dayKey`.
        let webLine = try XCTUnwrap(FirebaseBackend.materialItem(documentId: "web-line-1", data: [
            "projectId": "job-abc",
            "quantity": "3",
            "unit": "number",
            "name": "Clips",
            "dayKey": "2026-07-14",
            "date": Timestamp(seconds: julyFourteenthLondonMidnight + 12 * 3600, nanoseconds: 0),
            "status": "Quoted",
        ]))
        XCTAssertEqual(OrganizationRulebookContext.dayKey(iosLine.date), "2026-07-14")
        XCTAssertEqual(OrganizationRulebookContext.dayKey(webLine.date), "2026-07-14")
        XCTAssertEqual(iosLine.status, .ordered)
        XCTAssertEqual(webLine.status, .sentForQuote)
        XCTAssertEqual(webLine.quantity, 3)
        XCTAssertEqual(webLine.unit, .number)
        XCTAssertEqual(webLine.material, "Clips")
        XCTAssertEqual(WorkDocumentKeys.storedId(for: webLine.id), "web-line-1", "a non-UUID line id is kept")
        XCTAssertEqual(iosLine.projectId, webLine.projectId)
        XCTAssertEqual(webLine.projectId, Manager.stableId(forFirestoreDocumentId: "job-abc"))

        // A save writes the organisation-zone day, never device midnight, and the job id as stored.
        let payload = try XCTUnwrap(FirebaseBackend.materialLinePayload(webLine, addedByUserId: "u1"))
        XCTAssertEqual(payload["dayKey"] as? String, "2026-07-14")
        XCTAssertEqual((payload["date"] as? Timestamp)?.seconds, julyFourteenthLondonMidnight)
        XCTAssertEqual(payload["projectId"] as? String, "job-abc")
        XCTAssertEqual(payload["id"] as? String, "web-line-1")
        XCTAssertEqual(payload["name"] as? String, "Clips")
    }

    func testAMaterialEditWritesOnlyChangedFields() throws {
        let write = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite(
            "materialLineWriteFields",
            before: ["material": "Cable", "name": "Cable", "quantity": 2, "addedBy": "A"],
            next: ["material": "Cable2", "name": "Cable2", "quantity": 2, "addedBy": "B", "notes": NSNull()]
        ))
        XCTAssertEqual(write.setKeys, ["material", "name"], "addedBy is create-only; a field the copy lacks is never deleted")
        XCTAssertEqual(write.removeKeys, [])
        let sent = try XCTUnwrap(CanonicalBusinessEngine.materialSendStatusWriteFields(currentStatus: "ordered", requestType: "Quote"))
        XCTAssertEqual(sent.status, "ordered", "an ordered line is never downgraded by a quote")
    }

    // MARK: - Catalogue

    func testTheCatalogueIsNeverWipedByAnEmptyOrFailedLoad() throws {
        let stored: [(id: String, data: [String: Any])] = [(id: "c1", data: ["name": "A"]), (id: "c2", data: ["name": "B"])]
        let empty = try XCTUnwrap(CanonicalBusinessEngine.materialCatalogueWrites(stored: stored, next: [], loaded: true))
        XCTAssertEqual(empty.remove, [], "an empty list never deletes the catalogue")
        let unloaded = try XCTUnwrap(CanonicalBusinessEngine.materialCatalogueWrites(
            stored: stored, next: [["id": "C1", "name": "A"]], loaded: false
        ))
        XCTAssertEqual(unloaded.remove, [], "nothing is deleted without a successful load")
        let loaded = try XCTUnwrap(CanonicalBusinessEngine.materialCatalogueWrites(
            stored: stored, next: [["id": "C1", "name": "A"]], loaded: true
        ))
        XCTAssertEqual(loaded.remove, ["c2"])
        XCTAssertEqual(loaded.write.first?.id, "c1", "ids match without case and keep the stored spelling")

        let item = try XCTUnwrap(FirebaseBackend.materialCatalogItem(documentId: "c1", data: ["name": "A"]))
        XCTAssertEqual(item.brand, "Custom")
        XCTAssertEqual(item.category, "Other")
    }

    // MARK: - Notifications

    func testANotificationWithAnUnknownTypeAndANonUUIDRelatedIdIsKept() throws {
        let row = try XCTUnwrap(FirebaseBackend.appNotification(
            documentId: "web-notif-1",
            data: ["type": "brand_new_type", "relatedId": "job-abc", "userId": "u1"],
            organizationId: "org-1"
        ))
        XCTAssertEqual(row.type, .unknown)
        XCTAssertEqual(row.typeText, "brand_new_type", "the stored type is written back unchanged")
        XCTAssertEqual(row.relatedKey, "job-abc")
        XCTAssertNil(row.relatedId)
        XCTAssertEqual(row.organizationId, "org-1")
        XCTAssertFalse(row.isRead)
        XCTAssertEqual(WorkDocumentKeys.storedId(for: row.id), "web-notif-1", "never a random id")

        let variation = try XCTUnwrap(FirebaseBackend.appNotification(
            documentId: "n2", data: ["type": "variation_renumbered", "relatedId": "B1F0C0DE-0000-4000-8000-000000000001"], organizationId: "org-1"
        ))
        XCTAssertEqual(variation.type, .variationRenumbered)
        XCTAssertNotNil(variation.relatedId)

        for type in CanonicalBusinessEngine.knownNotificationTypes {
            XCTAssertNotEqual(AppNotification.NotificationType(stored: type), .unknown, type)
        }
        XCTAssertFalse(CanonicalBusinessEngine.knownNotificationTypes.isEmpty)
    }

    // MARK: - Health & safety

    func testOneSignerWritesItsOwnKeyAndTwoSignersDoNotCollide() throws {
        let signedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let first = try XCTUnwrap(CanonicalBusinessEngine.healthSafetySignatureWriteFields(
            issueId: "ISSUE-1", userId: "UserA", signatureId: nil, status: "signed",
            readConfirmed: true, signatureImageBase64: "abc", signedAt: signedAt, reminderSentAt: nil
        ))
        let second = try XCTUnwrap(CanonicalBusinessEngine.healthSafetySignatureWriteFields(
            issueId: "ISSUE-1", userId: "UserB", signatureId: nil, status: "signed",
            readConfirmed: true, signatureImageBase64: "def", signedAt: signedAt, reminderSentAt: nil
        ))
        XCTAssertEqual(first.fieldPath, ["signatureRecords", "issue-1__usera"])
        XCTAssertEqual(second.fieldPath, ["signatureRecords", "issue-1__userb"])
        XCTAssertNotEqual(first.fieldPath, second.fieldPath)

        // Both entries (and a stale pending array row) read back as two signed signatures; web's `complete` reads
        // as completed.
        let data = try XCTUnwrap(FirebaseBackend.healthSafetyData(fromStored: [
            "issues": [["id": "ISSUE-1", "status": "complete", "recipientUserIds": ["UserA", "UserB"]] as [String: Any]],
            "signatures": [["id": "s1", "issueId": "ISSUE-1", "userId": "UserA", "status": "pending"]],
            "signatureRecords": ["issue-1__usera": first.value, "issue-1__userb": second.value] as [String: Any],
        ], jobId: "job-abc", fallbackProjectId: UUID()))
        XCTAssertEqual(data.issues.first?.status, .completed)
        XCTAssertEqual(data.signatures.count, 2)
        XCTAssertTrue(data.signatures.allSatisfy { $0.status == .signed })
        XCTAssertEqual(CanonicalBusinessEngine.healthSafetyStoredIssueStatus("complete"), "completed")
    }

    // MARK: - Warning resolutions

    func testALegacyWarningKeyReadsInItsSharedForm() throws {
        XCTAssertEqual(WarningResolutionStore.migratedResolutionKey("mgr-clash-uid1-1792623600.0-0"), "mgr-clash-uid1-2026-10-22-0")
        XCTAssertEqual(WarningResolutionStore.migratedResolutionKey("materials-ABC-1792623600"), "materials-ABC-2026-10-22")
        XCTAssertEqual(WarningResolutionStore.migratedResolutionKey("op-clash-x"), "op-clash-x")
        let writes = try XCTUnwrap(CanonicalBusinessEngine.warningResolutionMigrationWrites(
            documents: [(id: "mgr-clash-uid1-1792623600.0-0", data: ["resolutionKey": "mgr-clash-uid1-1792623600.0-0", "status": "dismissed"])],
            legacyKeyForms: [:],
            resolvedByUserId: "me"
        ))
        XCTAssertEqual(writes.map(\.documentId), ["mgr-clash-uid1-2026-10-22-0"])
        XCTAssertEqual(writes.first?.fields["status"] as? String, "dismissed")
    }

    // MARK: - Tasks, wholesalers, variations

    func testATaskWithoutAJobIdIsKeptAndItsItemsGetDerivedIds() throws {
        let task = try XCTUnwrap(FirebaseBackend.projectTask(documentId: "task-1", data: [
            "title": "Fix",
            "items": [["title": "a"]],
            "status": "done",
        ]))
        XCTAssertEqual(task.projectKey, "")
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.items.first?.id.uuidString, "52EFD11D-A7D8-8193-BF62-D3CB90E2C2CD", "derived, never random")
        XCTAssertEqual(FirebaseBackend.projectTask(documentId: "task-1", data: ["title": "Fix", "items": [["title": "a"]]])?.items.first?.id,
                       task.items.first?.id)
        let fields = try XCTUnwrap(FirebaseBackend.projectTaskFields(task, organizationId: "org-1"))
        XCTAssertEqual(fields["id"] as? String, "task-1")
        XCTAssertEqual(fields["projectId"] as? String, "", "a task with no job keeps no job")
        XCTAssertEqual(fields["status"] as? String, "Completed")
    }

    func testRowsStoredWithoutIdsGetTheSharedDerivedIds() throws {
        let firm = try XCTUnwrap(FirebaseBackend.wholesaler(documentId: "w1", data: [
            "name": "W", "contacts": [["name": "Bob", "email": "b@x"]],
        ]))
        XCTAssertEqual(firm.contacts.first?.id.uuidString, "62E27AE7-1816-8D7D-B3E1-11351F6EDD77")
        XCTAssertEqual(firm.primaryContactId, firm.contacts.first?.id)

        let variation = try XCTUnwrap(VariationCodec.variation(from: [
            "labour": [["trade": "Sparky", "hours": 2] as [String: Any], [:] as [String: Any]],
            "materials": [["name": "x"]],
        ], documentId: "v1"))
        XCTAssertEqual(variation.labour.map(\.id), ["603959BB-D490-8F4D-8690-AB35E79FCC0B"], "an empty line is dropped")
        XCTAssertEqual(variation.materials.count, 1)
    }

    // MARK: - Job keys

    func testJobKeysRoundTripForALowerCaseNonUUIDJobId() {
        XCTAssertEqual(CanonicalBusinessEngine.storedJobIdForKey("JOB-ABC", jobIds: ["other", "job-abc"]), "job-abc")
        XCTAssertEqual(CanonicalBusinessEngine.healthSafetyDocumentId(jobId: "job-abc", isSmallWorks: false), "healthSafety_projects_JOB-ABC")
        XCTAssertEqual(
            CanonicalBusinessEngine.healthSafetyDocumentIds(jobId: "job-abc", isSmallWorks: false),
            ["healthSafety_projects_JOB-ABC", "healthSafety_projects_job-abc"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.deadlineAssignedProjectIds(["projects": ["JOB-ABC": ["u1"]]], personIds: ["u1"], jobIds: ["job-abc"]),
            ["job-abc"]
        )
        let inApp = JobKeys.inAppId("job-abc")
        XCTAssertEqual(JobKeys.storedJobId(for: inApp), "job-abc")
        XCTAssertEqual(JobKeys.queryValues(for: inApp), ["job-abc", inApp.uuidString], "older iOS lines on the job are still found")
    }
}
