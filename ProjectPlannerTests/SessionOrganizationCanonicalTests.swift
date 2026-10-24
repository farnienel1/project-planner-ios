import XCTest
@testable import Project_Planner

final class SessionOrganizationCanonicalTests: XCTestCase {
    func testChooseSessionOrganizationPrefersCachedIdOverUserDocument() throws {
        for probe in ["allowed", "unknown"] {
            let choice = try XCTUnwrap(CanonicalBusinessEngine.chooseSessionOrganization(
                explicitOrganizationId: nil,
                rememberedOrganizationId: "org-phone",
                documentOrganizationId: "org-other",
                probes: ["org-phone": probe, "org-other": "allowed"]
            ))
            XCTAssertEqual(choice.organizationId, "org-phone", probe)
            XCTAssertEqual(choice.persistOrganizationId, "org-phone", probe)
        }
    }

    func testTimeoutOrPermissionDeniedProbeDoesNotDropRememberedOrganization() throws {
        let fromError = try XCTUnwrap(CanonicalBusinessEngine.accessProbeFromReadError())
        XCTAssertEqual(fromError, "unknown")
        let fromReads = try XCTUnwrap(CanonicalBusinessEngine.orgAccessProbeFromReads(
            orgRead: "failed",
            membershipRead: "failed",
            listed: false,
            isCreator: false
        ))
        XCTAssertEqual(fromReads, "unknown")
        let missing = try XCTUnwrap(CanonicalBusinessEngine.orgAccessProbeFromReads(
            orgRead: "missing",
            membershipRead: "failed",
            listed: false,
            isCreator: false
        ))
        XCTAssertEqual(missing, "unknown")
        let choice = try XCTUnwrap(CanonicalBusinessEngine.chooseSessionOrganization(
            explicitOrganizationId: nil,
            rememberedOrganizationId: "org-remembered",
            documentOrganizationId: "org-document",
            probes: ["org-remembered": fromReads, "org-document": "allowed"]
        ))
        XCTAssertEqual(choice.organizationId, "org-remembered")
        XCTAssertEqual(choice.persistOrganizationId, "org-remembered")
    }

    func testSameUserSignOutKeepsRememberedOrganization() throws {
        XCTAssertEqual(try XCTUnwrap(CanonicalBusinessEngine.rememberedOrganizationSurvivesSignOut()), true)
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.shouldClearRememberedOrganization(
                signedOutUserId: "user-1",
                nextUserId: ""
            )),
            false
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.shouldClearRememberedOrganization(
                signedOutUserId: "user-1",
                nextUserId: "user-1"
            )),
            false
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.shouldClearRememberedOrganization(
                signedOutUserId: "user-1",
                nextUserId: "user-2"
            )),
            true
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.webSessionOrganizationStorageKey(userId: "user-1")),
            "pp.webActiveOrg:user-1"
        )
        XCTAssertEqual(try XCTUnwrap(CanonicalBusinessEngine.iosSessionOrganizationStorageKey), "cached_organizationId")
    }

    func testUserDocumentFallbackDoesNotPersistIntoCachedOrganizationId() throws {
        let choice = try XCTUnwrap(CanonicalBusinessEngine.chooseSessionOrganization(
            explicitOrganizationId: nil,
            rememberedOrganizationId: "",
            documentOrganizationId: "org-user-doc",
            probes: ["org-user-doc": "allowed"]
        ))
        XCTAssertEqual(choice.organizationId, "org-user-doc")
        XCTAssertNil(choice.persistOrganizationId)
        let deniedRemembered = try XCTUnwrap(CanonicalBusinessEngine.chooseSessionOrganization(
            explicitOrganizationId: nil,
            rememberedOrganizationId: "org-remembered",
            documentOrganizationId: "org-user-doc",
            probes: ["org-remembered": "denied", "org-user-doc": "allowed"]
        ))
        XCTAssertEqual(deniedRemembered.organizationId, "org-user-doc")
        XCTAssertNil(deniedRemembered.persistOrganizationId)
    }

    func testFinishedMembershipQueryKeepsRememberedOrganization() throws {
        let finished = try XCTUnwrap(CanonicalBusinessEngine.sessionMembershipIds(
            discoveredIds: ["org-document"],
            previousIds: [],
            rememberedOrganizationId: "org-remembered",
            documentOrganizationId: "org-document",
            explicitOrganizationId: nil,
            discoveryIncomplete: false
        ))
        XCTAssertEqual(finished, ["org-document", "org-remembered"])
        let incomplete = try XCTUnwrap(CanonicalBusinessEngine.sessionMembershipIds(
            discoveredIds: ["org-document"],
            previousIds: ["org-document"],
            rememberedOrganizationId: "org-remembered",
            documentOrganizationId: "org-document",
            explicitOrganizationId: nil,
            discoveryIncomplete: true
        ))
        XCTAssertEqual(incomplete, ["org-document", "org-remembered"])
    }

    func testKnownCompaniesAreAvailableBeforeTheMembershipScan() throws {
        let rows = OrganizationSwitcherCatalog.knownCompaniesBeforeScan(
            previous: [],
            rememberedOrganizationId: "org-remembered",
            documentOrganizationId: "org-document",
            explicitOrganizationId: nil,
            currentOrganizationId: nil,
            currentOrganizationName: nil,
            cachedNameForRemembered: "Remembered Co"
        )
        XCTAssertEqual(rows.map(\.id), ["org-remembered", "org-document"])
        XCTAssertEqual(rows.first { $0.id == "org-remembered" }?.name, "Remembered Co")
        let omitted = try XCTUnwrap(CanonicalBusinessEngine.sessionMembershipIds(
            discoveredIds: ["org-document"],
            previousIds: [],
            rememberedOrganizationId: "org-remembered",
            documentOrganizationId: "org-document",
            explicitOrganizationId: nil,
            discoveryIncomplete: false
        ))
        XCTAssertTrue(omitted.contains("org-remembered"))
    }

    func testSessionPackStillExportsBookingAndMaterialFunctions() {
        for name in [
            "unbookedLabourRowsOnDay",
            "sortWarningsByDate",
            "defaultMaterialDeliveryRequiredAt",
            "chooseSessionOrganization",
            "provisionalOrganizationId",
            "orgAccessProbeFromReads",
            "sessionMembershipIds",
            "shouldClearRememberedOrganization",
            "organizationNameWriteFields",
            "coalesceOrganizationName"
        ] {
            XCTAssertEqual(CanonicalBusinessEngine.exportKind(name), "function", name)
        }
    }

    @MainActor
    func testCurrentOrganisationBookingSnapshotIsAppliedAndADifferentOneIsNot() {
        let org = "2C67391E-D1FE-4F9F-8055-7149ACDE1F96"
        let other = "11111111-2222-3333-4444-555555555555"
        XCTAssertTrue(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: org,
            currentOrganizationId: "",
            sessionOrganizationId: org
        ))
        XCTAssertTrue(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: org,
            currentOrganizationId: other,
            sessionOrganizationId: org
        ))
        XCTAssertFalse(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: other,
            currentOrganizationId: other,
            sessionOrganizationId: org
        ))
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 0,
                incomingCount: 150,
                listenerOrganizationId: org,
                currentOrganizationId: other,
                sessionOrganizationId: org
            ),
            150
        )
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 150,
                incomingCount: 0,
                listenerOrganizationId: other,
                currentOrganizationId: "",
                sessionOrganizationId: org
            ),
            150
        )
    }
}
