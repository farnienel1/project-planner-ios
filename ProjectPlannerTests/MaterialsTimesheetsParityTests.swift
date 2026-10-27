import XCTest
@testable import Project_Planner

/// Material order push, wholesaler mobile, WhatsApp rulebook bridge, and User Timesheets scope (October 2026).
@MainActor
final class MaterialsTimesheetsParityTests: XCTestCase {
    private let orgId = "0F9E8D7C-0000-4000-8000-0000000000BB"

    private func user(
        id: String,
        role: UserRole,
        permissions: UserPermissions,
        isActive: Bool = true,
        lineManagers: [String] = [],
        formerIds: [String] = []
    ) -> AppUser {
        var person = AppUser(
            id: id,
            email: "\(id)@test.com",
            organizationId: orgId,
            role: role,
            firstName: "TEST",
            surname: id,
            isActive: isActive,
            passwordSet: true,
            permissions: permissions
        )
        person.setLineManagerUserIds(lineManagers)
        person.formerUserIds = formerIds
        return person
    }

    // MARK: - Material orders reach the recipient's phone

    func testNewMaterialLineUsesThePushedRulebookType() {
        XCTAssertEqual(AppNotification.NotificationType.materialOrderPlaced.rawValue, "material_order_placed")
        XCTAssertEqual(CanonicalBusinessEngine.notificationDeliversDevicePush("material_order_placed"), true)
        // The old iOS type never reached the push function's allow-list.
        XCTAssertEqual(CanonicalBusinessEngine.notificationDeliversDevicePush("material_added"), false)
    }

    func testMaterialTypesShareTheNewMaterialOrderToggle() {
        XCTAssertEqual(UserNotificationToggle.preference(for: .materialOrderPlaced), .materialAdded)
        XCTAssertEqual(UserNotificationToggle.preference(for: .materialAdded), .materialAdded)
        XCTAssertEqual(AppNotification.NotificationType(rawValue: "material_added"), .materialAdded)
    }

    func testMaterialRecipientPayloadNamesTheJobManagersAndTheAdder() throws {
        let managerRow = Manager(firstName: "TEST", lastName: "Manager", email: "mgr@test.com", mobileNumber: "")
        let adder = user(id: "op-1", role: .operative, permissions: UserPermissions(operativeMode: true), formerIds: ["op-old"])
        let payload = MaterialOrderRecipientsRulebook.payload(
            jobManagerIds: [managerRow.id.uuidString],
            managers: [managerRow],
            accounts: [adder],
            adder: adder,
            adderUserId: "op-1"
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertEqual(payload["jobManagerIds"] as? [String], [managerRow.id.uuidString])
        XCTAssertEqual((payload["managers"] as? [[String: Any]])?.first?["email"] as? String, "mgr@test.com")
        XCTAssertEqual(Set(payload["adderIds"] as? [String] ?? []), ["op-1", "op-old"])
        let account = try XCTUnwrap((payload["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual((account["role"] as? [String: Any])?["isOperativeMode"] as? Bool, true)
    }

    func testMaterialRecipientsWaitForTheScript() {
        let ids = MaterialOrderRecipientsRulebook.recipientUserIds(
            jobManagerIds: [], managers: [], accounts: [], adder: nil, adderUserId: nil
        )
        if MaterialOrderRecipientsRulebook.isAvailable {
            XCTAssertEqual(ids, [])
        } else {
            XCTAssertNil(ids)
        }
    }

    /// Order and quote history: admins and managers, never operatives, and not the Wholesalers toggle.
    func testOrderHistoryRuleIsStaffOnly() {
        let admin = user(id: "admin-1", role: .admin, permissions: UserPermissions(adminAccess: true))
        var manager = user(id: "mgr-1", role: .manager, permissions: UserPermissions(manager: true))
        manager.permissions.wholesalersOrderHistory = false
        let operative = user(id: "op-1", role: .operative, permissions: UserPermissions(operativeMode: true))
        XCTAssertTrue(CanonicalBusinessEngine.isStaffAccount(UserStore.staffAccountRole(for: admin)))
        XCTAssertTrue(CanonicalBusinessEngine.isStaffAccount(UserStore.staffAccountRole(for: manager)))
        XCTAssertFalse(CanonicalBusinessEngine.isStaffAccount(UserStore.staffAccountRole(for: operative)))
    }

    // MARK: - Wholesaler contact mobile (web `phone`)

    func testContactWithoutPhoneStillDecodes() throws {
        let json = """
        {"id":"6B1C9E8A-0000-4000-8000-000000000001","name":"TEST-Sam","email":"sam@test.com","isPrimary":true,"createdAt":0}
        """
        let contact = try JSONDecoder().decode(WholesalerContact.self, from: Data(json.utf8))
        XCTAssertNil(contact.phone)
    }

    func testContactKeepsPhone() throws {
        let contact = WholesalerContact(name: "TEST-Sam", email: "sam@test.com", phone: "07700 900123")
        let decoded = try JSONDecoder().decode(WholesalerContact.self, from: JSONEncoder().encode(contact))
        XCTAssertEqual(decoded.phone, "07700 900123")
    }

    // MARK: - WhatsApp rulebook bridge

    private func whatsAppInput(deliveryAt: Date?) -> MaterialWhatsAppRulebook.Input {
        MaterialWhatsAppRulebook.Input(
            requestType: .order,
            organisationName: "TEST-Org",
            requestingUserName: "TEST-User",
            jobNumber: "J-1",
            projectName: "TEST-Kitchen refit",
            projectAddress: "1 Test Street",
            deliveryAt: deliveryAt,
            countryCode: "GB",
            materials: [
                MaterialWhatsAppRulebook.Line(material: "Pipe", quantity: 2, unit: "Length", brand: " ", productCode: "P1", notes: nil, lengthDisplay: "3 m")
            ],
            recipients: [
                MaterialWhatsAppRulebook.Recipient(id: "c1", name: "Sam", wholesalerName: "TEST-Supplies", phone: "07700 900123")
            ]
        )
    }

    func testWhatsAppPayloadMatchesTheRulebookInput() throws {
        let deliveryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = MaterialWhatsAppRulebook.payload(for: whatsAppInput(deliveryAt: deliveryAt))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertEqual(payload["requestType"] as? String, "order")
        XCTAssertEqual(payload["countryCode"] as? String, "GB")
        XCTAssertEqual(payload["deliveryAt"] as? String, CanonicalBusinessEngine.isoString(from: deliveryAt))
        let line = try XCTUnwrap((payload["materials"] as? [[String: Any]])?.first)
        XCTAssertEqual(line["unit"] as? String, "Length")
        XCTAssertTrue(line["brand"] is NSNull, "A blank brand goes as null, as web leaves it out")
        XCTAssertEqual(line["lengthDisplay"] as? String, "3 m")
        let recipient = try XCTUnwrap((payload["recipients"] as? [[String: Any]])?.first)
        XCTAssertEqual(recipient["phone"] as? String, "07700 900123")
        XCTAssertTrue(MaterialWhatsAppRulebook.payload(for: whatsAppInput(deliveryAt: nil))["deliveryAt"] is NSNull)
    }

    func testWhatsAppRowParsing() throws {
        let row = try XCTUnwrap(MaterialWhatsAppRulebook.row(from: [
            "recipientId": "c1",
            "message": "Hi Sam,",
            "ok": true,
            "digits": "447700900123",
            "reason": NSNull(),
            "url": "https://wa.me/447700900123?text=Hi%20Sam%2C"
        ]))
        XCTAssertTrue(row.ok)
        XCTAssertEqual(row.digits, "447700900123")
        XCTAssertNil(row.reason)
        XCTAssertEqual(row.url?.host, "wa.me")
        XCTAssertNil(MaterialWhatsAppRulebook.row(from: ["ok": true]))
    }

    func testWhatsAppStaysHiddenUntilTheScriptHasTheFunction() {
        if !MaterialWhatsAppRulebook.isAvailable {
            XCTAssertNil(MaterialWhatsAppRulebook.rows(for: whatsAppInput(deliveryAt: nil)))
        } else {
            let rows = MaterialWhatsAppRulebook.rows(for: whatsAppInput(deliveryAt: nil))
            XCTAssertEqual(rows?.count, 1)
            XCTAssertEqual(rows?.first?.recipientId, "c1")
        }
    }

    // MARK: - User Timesheets scope

    private func managerStore(reports: [AppUser], managerFormerIds: [String] = []) -> UserStore {
        let store = UserStore()
        store.currentUser = user(
            id: "manager-1",
            role: .manager,
            permissions: UserPermissions(manager: true),
            formerIds: managerFormerIds
        )
        store.organizationUsers = reports
        return store
    }

    func testManagerSeesOperativeReport() {
        let report = user(id: "op-1", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["manager-1"])
        let store = managerStore(reports: [report])
        XCTAssertTrue(store.canAccessOperativeTimesheets())
        XCTAssertEqual(store.userTimesheetSubjectUsers().map(\.id), ["op-1"])
    }

    func testInactiveOrOtherPeopleAreNotInAManagersScope() {
        let store = managerStore(reports: [
            user(id: "op-gone", role: .operative, permissions: UserPermissions(operativeMode: true), isActive: false, lineManagers: ["manager-1"]),
            user(id: "op-other", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["manager-2"])
        ])
        XCTAssertTrue(store.userTimesheetSubjectUsers().isEmpty)
        XCTAssertFalse(store.canAccessOperativeTimesheets())
    }

    /// The reported bug: a line manager whose report is not in operative mode had no User Timesheets.
    /// The list already showed that report; only the gate required operative mode. `userTimesheetSubjects`
    /// fixes it; until the packed script has that function, iOS keeps the old gate.
    func testManagerOfANonOperativeReport() {
        let report = user(id: "staff-1", role: .manager, permissions: UserPermissions(manager: true), lineManagers: ["manager-1"])
        let store = managerStore(reports: [report])
        XCTAssertEqual(store.userTimesheetSubjectUsers().map(\.id), ["staff-1"])
        XCTAssertEqual(store.canAccessOperativeTimesheets(), UserTimesheetAccessRulebook.isAvailable)
    }

    /// A report saved against the manager's former invite id.
    func testReportUnderTheManagersFormerId() {
        let report = user(id: "op-1", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["manager-old"])
        let store = managerStore(reports: [report], managerFormerIds: ["manager-old"])
        XCTAssertEqual(store.userTimesheetSubjectUsers().isEmpty, !UserTimesheetAccessRulebook.isAvailable)
    }

    func testRulebookPayloadCarriesEveryViewerId() throws {
        let viewer = user(id: "manager-1", role: .manager, permissions: UserPermissions(manager: true), formerIds: ["manager-old"])
        let report = user(id: "op-1", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["manager-old"])
        let payload = UserTimesheetAccessRulebook.payload(viewer: viewer, members: [report])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        let viewerRow = try XCTUnwrap(payload["viewer"] as? [String: Any])
        XCTAssertEqual(viewerRow["formerIds"] as? [String], ["manager-old"])
        let role = try XCTUnwrap(viewerRow["role"] as? [String: Any])
        XCTAssertEqual(role["isManager"] as? Bool, true)
        let member = try XCTUnwrap((payload["members"] as? [[String: Any]])?.first)
        XCTAssertEqual(member["assignedManagerUserIds"] as? [String], ["manager-old"])
        XCTAssertEqual(member["isActive"] as? Bool, true)
        XCTAssertEqual(member["hasNoLineManager"] as? Bool, false)
    }

    func testAdminScopeKeepsEveryActiveTimesheetUser() {
        let store = UserStore()
        store.currentUser = user(id: "admin-1", role: .admin, permissions: UserPermissions(adminAccess: true))
        store.organizationUsers = [
            user(id: "op-1", role: .operative, permissions: UserPermissions(operativeMode: true)),
            user(id: "mgr-1", role: .manager, permissions: UserPermissions(manager: true)),
            user(id: "op-gone", role: .operative, permissions: UserPermissions(operativeMode: true), isActive: false)
        ]
        XCTAssertTrue(store.canAccessOperativeTimesheets())
        XCTAssertEqual(Set(store.userTimesheetSubjectUsers().map(\.id)), ["op-1", "mgr-1"])
    }
}
