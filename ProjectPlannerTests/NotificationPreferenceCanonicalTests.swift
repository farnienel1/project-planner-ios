import XCTest
@testable import Project_Planner

@MainActor
final class NotificationPreferenceCanonicalTests: XCTestCase {
    func testParseMapsLegacyBookingConflictsAndKeepsOtherKeys() throws {
        let parsed = try XCTUnwrap(
            CanonicalBusinessEngine.parseUserNotificationPreferences([
                "bookingConflicts": false,
                "projectDeadlines": false,
                "timesheetSignOff": false,
            ])
        )
        XCTAssertEqual(parsed["bookingClashes"], false)
        XCTAssertEqual(parsed["timesheetSignOff"], false)
        XCTAssertEqual(parsed["materialOrderCutOff"], true)
        XCTAssertEqual(parsed["timesheetSubmissionReminder"], true)
        XCTAssertEqual(parsed["bookedOntoJob"], true)
        let explicit = try XCTUnwrap(
            CanonicalBusinessEngine.parseUserNotificationPreferences([
                "bookingConflicts": false,
                "bookingClashes": true,
            ])
        )
        XCTAssertEqual(explicit["bookingClashes"], true)
    }

    func testPreferenceFieldPatchIsADottedKey() throws {
        let patch = try XCTUnwrap(
            CanonicalBusinessEngine.userNotificationPreferenceFieldPatch(["bookingClashes": false])
        )
        XCTAssertEqual(patch["notificationPreferences.bookingClashes"], false)
        XCTAssertNil(patch["notificationPreferences"])
        XCTAssertEqual(patch.count, 1)
        XCTAssertFalse(patch.keys.contains { $0.contains("bookingConflicts") })
    }

    func testDeliveryFollowsTheToggleAndAllowsTypesWithNoKey() throws {
        let off = try XCTUnwrap(
            CanonicalBusinessEngine.parseUserNotificationPreferences([
                "bookedOntoJob": false,
                "timesheetSubmissionReminder": false,
            ])
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: off, type: "booking_created"),
            false
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: off, type: "timesheet_submission_reminder"),
            false
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: off, type: "client_created"),
            true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: off, type: "variation"),
            true
        )
        let on = try XCTUnwrap(CanonicalBusinessEngine.defaultUserNotificationPreferences)
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: on, type: "booking_created"),
            true
        )
    }

    func testBookingDestinationsFollowRoleAndMissingIds() throws {
        let admin = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "booking_created",
            relatedId: "JOB-1",
            dayKey: "2026-10-12",
            catalogue: "projects",
            role: "admin",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(admin.kind, "dailyOverviewDay")
        XCTAssertEqual(admin.dayKey, "2026-10-12")
        XCTAssertNil(admin.relatedId)

        let manager = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "booking_created",
            relatedId: "JOB-1",
            dayKey: "2026-10-12",
            catalogue: "projects",
            role: "manager",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(manager.kind, "projectScheduling")
        XCTAssertEqual(manager.relatedId, "JOB-1")
        XCTAssertEqual(manager.dayKey, "2026-10-12")

        let smallWorks = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "booking_created",
            relatedId: "SW-9",
            dayKey: "2026-10-12",
            catalogue: "smallWorks",
            role: "manager",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(smallWorks.kind, "smallWorksScheduling")
        XCTAssertEqual(smallWorks.relatedId, "SW-9")

        let operative = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "booking_created",
            relatedId: "JOB-1",
            dayKey: "2026-10-12",
            catalogue: "projects",
            role: "operative",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(operative.kind, "mySchedule")
        XCTAssertEqual(operative.dayKey, "2026-10-12")

        let missingJob = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "booking_created",
            relatedId: nil,
            dayKey: "2026-10-12",
            catalogue: "projects",
            role: "manager",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(missingJob.kind, "dailyOverviewDay")

        let missingProject = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "project_created",
            relatedId: nil,
            dayKey: nil,
            catalogue: nil,
            role: "admin",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(missingProject.kind, "projectsList")

        let missingSmallWorks = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "small_works_created",
            relatedId: nil,
            dayKey: nil,
            catalogue: nil,
            role: "manager",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(missingSmallWorks.kind, "smallWorksList")

        let unknown = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "not_a_real_type",
            relatedId: nil,
            dayKey: nil,
            catalogue: nil,
            role: "admin",
            deepLinkUserId: nil
        ))
        XCTAssertEqual(unknown.kind, "notifications")
    }

    func testUserDocumentFieldsKeepNotificationPreferencesAndPushTokens() throws {
        let fields = try XCTUnwrap(CanonicalBusinessEngine.userDocumentFields)
        XCTAssertTrue(fields.contains("notificationPreferences"))
        XCTAssertTrue(fields.contains("pushTokens"))
        XCTAssertTrue(fields.contains("pushTokenUpdatedAt"))
    }

    func testUnreadBadgeAndDevicePushAllowList() throws {
        let rows = [
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "u1", isRead: false),
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "u1", isRead: true),
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "u2", isRead: false),
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "", isRead: false),
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: "u1", isRead: false),
        ]
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.unreadNotificationBadgeCount(notifications: rows, userId: "u1")),
            3
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.unreadNotificationBadgeCount(notifications: rows, userId: "")),
            0
        )

        XCTAssertTrue(try XCTUnwrap(CanonicalBusinessEngine.notificationDeliversDevicePush("booking_created")))
        XCTAssertTrue(try XCTUnwrap(CanonicalBusinessEngine.notificationDeliversDevicePush("timesheet_submission_reminder")))
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.notificationDeliversDevicePush("material_order_cut_off")))
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.notificationDeliversDevicePush("qualification_expiry")))
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.notificationDeliversDevicePush("deadline_reminder")))
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.notificationDeliversDevicePush("deadline_due")))

        let types = try XCTUnwrap(CanonicalBusinessEngine.devicePushNotificationTypes())
        XCTAssertEqual(types.filter { $0 == "timesheet_submission_reminder" }.count, 1)
        XCTAssertFalse(types.contains("material_order_cut_off"))
        XCTAssertFalse(types.contains("qualification_expiry"))
        XCTAssertFalse(types.contains("deadline_reminder"))
        XCTAssertFalse(types.contains("deadline_due"))

        let first = CanonicalBusinessEngine.timesheetSubmissionNoticeDedupKey(
            organizationId: "org-1",
            paymentDayKey: "2026-10-20",
            runIndex: 0,
            userId: "u1"
        )
        let second = CanonicalBusinessEngine.timesheetSubmissionNoticeDedupKey(
            organizationId: "org-1",
            paymentDayKey: "2026-10-20",
            runIndex: 0,
            userId: "u1"
        )
        XCTAssertEqual(first, second)
        XCTAssertFalse(first?.isEmpty ?? true)

        XCTAssertEqual(try XCTUnwrap(CanonicalBusinessEngine.notificationIconBadgeClearsOnForeground), true)
    }

    func testPackStillExportsSessionAndDeliveryFunctions() {
        for name in [
            "chooseSessionOrganization",
            "unbookedLabourRowsOnDay",
            "sortWarningsByDate",
            "materialDeliveryInstant",
            "parseUserNotificationPreferences",
            "notificationDestination",
            "visibleNotificationPreferenceKeys",
            "notificationPreferenceIsVisible",
            "notificationPreferenceCopy",
        ] {
            XCTAssertEqual(CanonicalBusinessEngine.exportKind(name), "function", name)
        }
    }

    func testVisiblePreferenceKeysFollowRoleCatalogueAndFlags() throws {
        let operative = CanonicalBusinessEngine.CanonicalNotificationPreferenceAudience(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(
                isSuperAdmin: false,
                isAdmin: false,
                isManager: false,
                isOperativeMode: true
            ),
            catalogue: CanonicalBusinessEngine.CanonicalWorkCatalogueToggles(projects: true, smallWorks: true),
            canManagePeople: false,
            canManageClients: false,
            canManageMaterials: true
        )
        let operativeKeys = try XCTUnwrap(CanonicalBusinessEngine.visibleNotificationPreferenceKeys(operative))
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceIsVisible("annualLeaveRequested", audience: operative),
            false
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceIsVisible("materialOrderPlaced", audience: operative),
            false
        )
        XCTAssertFalse(operativeKeys.contains("annualLeaveRequested"))
        XCTAssertFalse(operativeKeys.contains("materialOrderPlaced"))
        for key in ["materialOrderCutOff", "bookedOntoJob", "qualificationExpiry", "annualLeaveDecision"] {
            XCTAssertEqual(
                CanonicalBusinessEngine.notificationPreferenceIsVisible(key, audience: operative),
                true,
                key
            )
            XCTAssertTrue(operativeKeys.contains(key), key)
        }

        let staffWithoutOperatives = CanonicalBusinessEngine.CanonicalNotificationPreferenceAudience(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(
                isSuperAdmin: false,
                isAdmin: false,
                isManager: true,
                isOperativeMode: false
            ),
            catalogue: CanonicalBusinessEngine.CanonicalWorkCatalogueToggles(projects: true, smallWorks: false),
            canManagePeople: false,
            canManageClients: true,
            canManageMaterials: true
        )
        let staffKeys = try XCTUnwrap(CanonicalBusinessEngine.visibleNotificationPreferenceKeys(staffWithoutOperatives))
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceIsVisible("operativeCreated", audience: staffWithoutOperatives),
            false
        )
        XCTAssertFalse(staffKeys.contains("operativeCreated"))
        for key in ["materialOrderCutOff", "bookedOntoJob", "qualificationExpiry"] {
            XCTAssertEqual(
                CanonicalBusinessEngine.notificationPreferenceIsVisible(key, audience: staffWithoutOperatives),
                true,
                key
            )
            XCTAssertTrue(staffKeys.contains(key), key)
        }

        let superAdmin = CanonicalBusinessEngine.CanonicalNotificationPreferenceAudience(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(
                isSuperAdmin: true,
                isAdmin: true,
                isManager: false,
                isOperativeMode: false
            ),
            catalogue: CanonicalBusinessEngine.CanonicalWorkCatalogueToggles(projects: false, smallWorks: false),
            canManagePeople: true,
            canManageClients: true,
            canManageMaterials: true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceIsVisible("operativeCreated", audience: superAdmin),
            true
        )
        XCTAssertTrue(
            try XCTUnwrap(CanonicalBusinessEngine.visibleNotificationPreferenceKeys(superAdmin)).contains("operativeCreated")
        )

        let omittedFlags = CanonicalBusinessEngine.CanonicalNotificationPreferenceAudience(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(
                isSuperAdmin: false,
                isAdmin: true,
                isManager: false,
                isOperativeMode: false
            ),
            catalogue: CanonicalBusinessEngine.CanonicalWorkCatalogueToggles(projects: true, smallWorks: true)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceIsVisible("operativeCreated", audience: omittedFlags),
            true
        )
        XCTAssertTrue(
            try XCTUnwrap(CanonicalBusinessEngine.visibleNotificationPreferenceKeys(omittedFlags)).contains("operativeCreated")
        )

        let decision = try XCTUnwrap(
            CanonicalBusinessEngine.notificationPreferenceCopy("annualLeaveDecision", audience: operative)
        )
        XCTAssertEqual(decision.description, "When your annual leave is approved or declined.")
        XCTAssertEqual(
            CanonicalBusinessEngine.notificationPreferenceCopy("annualLeaveDecision")?.description,
            "When your annual leave is approved or declined."
        )
    }
}
