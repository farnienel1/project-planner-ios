import XCTest
@testable import Project_Planner

final class RosterSegmentTests: XCTestCase {
    private let orgId = "2C67391E-D1FE-4F9F-8055-7149ACDE1F96"

    private func person(
        id: String,
        email: String,
        firstName: String,
        surname: String = "",
        passwordSet: Bool,
        isActive: Bool = true,
        mobileNumber: String? = nil,
        documentName: String = "",
        documentDisplayName: String = ""
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: orgId,
            role: .operative,
            firstName: firstName,
            surname: surname,
            mobileNumber: mobileNumber,
            isActive: isActive,
            passwordSet: passwordSet,
            permissions: UserPermissions(operativeMode: true),
            documentName: documentName,
            documentDisplayName: documentDisplayName
        )
    }

    private func listed(_ users: [AppUser], claimedEmails: Set<String>?) throws -> [AppUser] {
        let fromScreens = try XCTUnwrap(CanonicalBusinessEngine.listedRosterUsers(users, claimedEmails: claimedEmails))
        let profiles = users.map { CanonicalBusinessEngine.CanonicalRosterProfile(user: $0) }
        let fromProfiles = try XCTUnwrap(CanonicalBusinessEngine.listedRosterUsers(
            profiles,
            claimedEmails: claimedEmails.map(Array.init)
        ))
        XCTAssertEqual(fromScreens.map(\.id), fromProfiles.map(\.id))
        for user in fromScreens {
            let profile = CanonicalBusinessEngine.CanonicalRosterProfile(user: user)
            XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(user), CanonicalBusinessEngine.rosterSegment(profile))
            XCTAssertEqual(
                CanonicalBusinessEngine.isAnonymisedDeletedProfile(user),
                CanonicalBusinessEngine.isAnonymisedDeletedProfile(profile)
            )
        }
        return fromScreens
    }

    func testAnonymisedDeletedProfileIsInactiveOnly() {
        let deleted = person(
            id: "QAlPe29vLLP4spK554UtpaBLW7N2",
            email: "",
            firstName: "Deleted",
            surname: "user",
            passwordSet: true,
            isActive: true,
            documentName: "Deleted user",
            documentDisplayName: "Deleted user"
        )
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(deleted), true)
        XCTAssertEqual(deleted.fullName, "Deleted user")
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(deleted), "inactive")

        let displayNameOnly = person(
            id: "auth-uid",
            email: "  ",
            firstName: "",
            passwordSet: true,
            isActive: true,
            documentDisplayName: "Deleted user"
        )
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(displayNameOnly), true)
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(displayNameOnly), "inactive")

        let nameOnly = person(
            id: "name-only",
            email: "",
            firstName: "Pat",
            surname: "Stone",
            passwordSet: true,
            isActive: true,
            documentName: "Deleted user"
        )
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(nameOnly), true)
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(nameOnly), "inactive")
    }

    func testNamedAccountWithEmptyEmailStaysActive() {
        let named = person(
            id: "real",
            email: "",
            firstName: "Pat",
            surname: "Stone",
            passwordSet: true
        )
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(named), false)
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(named), "active")
    }

    func testDeletedUserNameWithAnEmailIsNotTreatedAsDeleted() {
        let homonym = person(
            id: "homonym",
            email: "deleted.user@site.com",
            firstName: "Deleted",
            surname: "user",
            passwordSet: true,
            documentName: "Deleted user",
            documentDisplayName: "Deleted user"
        )
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(homonym), false)
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(homonym), "active")
    }

    func testUnclaimedPendingDuplicateIsNotListedWithNameEmailOrPhone() throws {
        let deleted = person(
            id: "QAlPe29vLLP4spK554UtpaBLW7N2",
            email: "",
            firstName: "Deleted",
            surname: "user",
            passwordSet: true,
            documentName: "Deleted user",
            documentDisplayName: "Deleted user"
        )
        let leftover = person(
            id: "57CC31FC-2115-4083-AD1F-58D9D44FE5B5",
            email: "farnienel@hotmail.com",
            firstName: "Test",
            surname: "Operative",
            passwordSet: false,
            mobileNumber: "07700900123"
        )
        let liveInvite = person(
            id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            email: "new.operative@site.com",
            firstName: "New",
            surname: "Operative",
            passwordSet: false,
            mobileNumber: "07700900456"
        )
        let active = person(
            id: "active-1",
            email: "ada@site.com",
            firstName: "Ada",
            surname: "Lovelace",
            passwordSet: true
        )
        let deactivated = person(
            id: "old-1",
            email: "old@site.com",
            firstName: "Old",
            surname: "Hand",
            passwordSet: true,
            isActive: false
        )

        let rows = [deleted, leftover, liveInvite, active, deactivated]
        let claimed: Set<String> = ["new.operative@site.com"]
        let shown = try listed(rows, claimedEmails: claimed)
        XCTAssertEqual(Set(shown.map(\.id)), [deleted.id, liveInvite.id, active.id, deactivated.id])
        let pending = shown.filter { CanonicalBusinessEngine.rosterSegment($0) == "pending" }
        XCTAssertEqual(pending.map(\.id), [liveInvite.id])
        XCTAssertFalse(pending.contains { $0.fullName == "Test Operative" })
        XCTAssertFalse(pending.contains { $0.email == "farnienel@hotmail.com" })
        XCTAssertFalse(pending.contains { $0.mobileNumber == "07700900123" })
        XCTAssertEqual(
            shown.filter { CanonicalBusinessEngine.rosterSegment($0) == "inactive" }.map(\.id).sorted(),
            [deactivated.id, deleted.id].sorted()
        )
        XCTAssertEqual(shown.filter { CanonicalBusinessEngine.rosterSegment($0) == "active" }.map(\.id), [active.id])
    }

    func testPendingInviteStaysWhenEmailClaimReadFails() throws {
        let leftover = person(
            id: "57CC31FC-2115-4083-AD1F-58D9D44FE5B5",
            email: "farnienel@hotmail.com",
            firstName: "Test",
            surname: "Operative",
            passwordSet: false
        )
        let shown = try listed([leftover], claimedEmails: nil)
        XCTAssertEqual(shown.map(\.id), [leftover.id])
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(leftover), "pending")
    }

    func testPendingRowWithRealNameAndNoEmailIsNotListed() throws {
        let phoneOnly = person(
            id: "phone-left",
            email: "",
            firstName: "Test",
            surname: "Operative",
            passwordSet: false,
            mobileNumber: "07700900123"
        )
        let shown = try listed([phoneOnly], claimedEmails: nil)
        XCTAssertTrue(shown.isEmpty)
    }
}

@MainActor
final class AnonymisedDeletedLabourTests: XCTestCase {
    private let orgId = "2C67391E-D1FE-4F9F-8055-7149ACDE1F96"

    private func deletedUser() -> AppUser {
        AppUser(
            id: "QAlPe29vLLP4spK554UtpaBLW7N2",
            email: "",
            organizationId: orgId,
            role: .operative,
            firstName: "Deleted",
            surname: "user",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true),
            documentName: "Deleted user",
            documentDisplayName: "Deleted user"
        )
    }

    private func liveUser() -> AppUser {
        AppUser(
            id: "U-LIVE",
            email: "ada@site.test",
            organizationId: orgId,
            role: .operative,
            firstName: "Ada",
            surname: "Lovelace",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true)
        )
    }

    func testParseKeepsEmptyEmailOnAnonymisedProfile() {
        let parsed = FirebaseBackend.parseAppUserDocument(
            userId: "QAlPe29vLLP4spK554UtpaBLW7N2",
            data: [
                "email": "",
                "firstName": "Deleted",
                "surname": "user",
                "name": "Deleted user",
                "displayName": "Deleted user",
                "organizationId": orgId,
            ]
        )
        XCTAssertEqual(parsed.email, "")
        XCTAssertEqual(parsed.organizationId, orgId)
        XCTAssertEqual(parsed.firstName, "Deleted")
        XCTAssertEqual(parsed.surname, "user")
        XCTAssertEqual(parsed.documentName, "Deleted user")
        XCTAssertEqual(parsed.documentDisplayName, "Deleted user")
        XCTAssertEqual(parsed.passwordSet, true)
        XCTAssertEqual(parsed.isActive, true)
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(parsed), true)
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(parsed), "inactive")

        let named = FirebaseBackend.parseAppUserDocument(
            userId: "real",
            data: [
                "email": "",
                "firstName": "Pat",
                "surname": "Stone",
                "organizationId": orgId,
                "passwordSet": true,
                "isActive": true,
            ]
        )
        XCTAssertEqual(named.email, "")
        XCTAssertEqual(CanonicalBusinessEngine.isAnonymisedDeletedProfile(named), false)
        XCTAssertEqual(CanonicalBusinessEngine.rosterSegment(named), "active")
    }

    func testListedCurrentLabourPeopleOmitsAnonymisedProfile() throws {
        let deleted = deletedUser()
        let live = liveUser()
        let listed = try XCTUnwrap(CanonicalBusinessEngine.listedCurrentLabourPeople([deleted, live]))
        XCTAssertEqual(listed.map(\.id), [live.id])

        let deletedOperative = Operative(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            firstName: "Deleted",
            lastName: "user",
            email: "",
            startDate: Date(timeIntervalSince1970: 0)
        )
        let liveOperative = LogicFixtures.operative(id: UUID(), email: live.email)
        let listedOperatives = try XCTUnwrap(
            CanonicalBusinessEngine.listedCurrentLabourPeople([deletedOperative, liveOperative])
        )
        XCTAssertEqual(listedOperatives.map(\.id), [liveOperative.id])
    }

    func testUnbookedRowOmitsAnonymisedProfile() throws {
        let deleted = CanonicalUnbookedLabourPerson(
            id: "QAlPe29vLLP4spK554UtpaBLW7N2",
            email: "",
            name: "Deleted user",
            isActive: true,
            passwordSet: true,
            isOperativeMode: true,
            isManager: false,
            isAdmin: false,
            isSuperAdmin: false
        )
        let live = CanonicalUnbookedLabourPerson(
            id: "U-LIVE",
            email: "ada@site.test",
            name: "Ada Lovelace",
            isActive: true,
            passwordSet: true,
            isOperativeMode: true,
            isManager: false,
            isAdmin: false,
            isSuperAdmin: false
        )
        let input = CanonicalUnbookedLabourInput(
            timeZone: "Europe/London",
            startDayKey: "2026-10-12",
            endDayKey: "2026-10-12",
            includeWeekends: false,
            excludedUserIds: [],
            standardPaidHours: 8,
            saturdayCountsAsHours: 0,
            sundayCountsAsHours: 0,
            standardDayStart: "07:30",
            standardDayEnd: "16:00",
            breakWindowStart: "12:00",
            breakWindowEnd: "12:30",
            people: [deleted, live],
            operatives: [
                CanonicalUnbookedLabourOperative(
                    id: "OP-DEL",
                    email: "",
                    name: "Deleted user",
                    isActive: true,
                    isPlaceholder: false,
                    profileWeight: 1
                ),
            ],
            bookings: [],
            holidays: []
        )
        let rows = try XCTUnwrap(CanonicalBusinessEngine.unbookedLabourRows(input))
        XCTAssertEqual(rows.map(\.personKey), ["U-LIVE"])
        XCTAssertFalse(rows.contains { $0.operativeName == "Deleted user" || $0.personKey == deleted.id })
    }

    func testHistoricBookingKeepsStoredDeletedUserName() throws {
        let operativeId = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let deletedOperative = Operative(
            id: operativeId,
            firstName: "Deleted",
            lastName: "user",
            email: "",
            startDate: Date(timeIntervalSince1970: 0)
        )
        let booking = Booking(
            operativeId: operativeId,
            projectId: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            timeSlot: .fullDay,
            bookedBy: "Site lead",
            notes: "Stored note"
        )
        let shown = rosterNameForLabourBooking(
            operativeId: operativeId,
            operatives: [deletedOperative],
            users: [deletedUser()]
        )
        XCTAssertEqual(shown, "Deleted user")
        XCTAssertEqual(booking.bookedBy, "Site lead")
        XCTAssertEqual(booking.notes, "Stored note")
        XCTAssertEqual(booking.operativeId, operativeId)

        let liveOperative = LogicFixtures.operative(id: UUID(), email: "ada@site.test")
        let people = ScheduleBookablePersonBuilder.build(
            operatives: [deletedOperative, liveOperative],
            users: [deletedUser(), liveUser()],
            projectId: booking.projectId,
            bookings: [booking]
        )
        XCTAssertEqual(people.map(\.operativeId), [liveOperative.id])
        XCTAssertEqual(people.map(\.name), ["Ada Lovelace"])
        let current = try XCTUnwrap(CanonicalBusinessEngine.listedCurrentLabourPeople([deletedOperative]))
        XCTAssertTrue(current.isEmpty)
    }

    func testLiveEmailClaimBlocksAndTombstoneDoesNot() throws {
        let inviteEmail = "farnienel@hotmail.com"
        let tombstone = CanonicalBusinessEngine.CanonicalInviteEmailClaimUser(
            userId: "QAlPe29vLLP4spK554UtpaBLW7N2",
            email: "",
            firstName: "Deleted",
            surname: "user",
            lastName: nil,
            name: "Deleted user",
            displayName: "Deleted user",
            passwordSet: true,
            isActive: true,
            mobileNumber: nil
        )
        let live = CanonicalBusinessEngine.CanonicalInviteEmailClaimUser(
            userId: "auth-live",
            email: inviteEmail,
            firstName: "Pat",
            surname: "Live",
            lastName: nil,
            name: "Pat Live",
            displayName: "",
            passwordSet: true,
            isActive: true,
            mobileNumber: nil
        )
        let liveDecision = try XCTUnwrap(CanonicalBusinessEngine.resolveInviteEmailClaim(
            CanonicalBusinessEngine.CanonicalInviteEmailClaimInput(
                inviteEmail: inviteEmail,
                existingUsers: [live],
                emailPointer: CanonicalBusinessEngine.CanonicalInviteEmailPointer(
                    exists: true,
                    pointedUserId: live.userId,
                    pointedUser: live
                )
            )
        ))
        XCTAssertEqual(liveDecision.action, "block")
        XCTAssertEqual(
            CanonicalBusinessEngine.inviteEmailHasLiveClaim(
                CanonicalBusinessEngine.CanonicalInviteEmailClaimInput(
                    inviteEmail: inviteEmail,
                    existingUsers: [live],
                    emailPointer: CanonicalBusinessEngine.CanonicalInviteEmailPointer(exists: false, pointedUserId: nil, pointedUser: nil)
                )
            ),
            true
        )

        let tombstoneInput = CanonicalBusinessEngine.CanonicalInviteEmailClaimInput(
            inviteEmail: inviteEmail,
            existingUsers: [tombstone],
            emailPointer: CanonicalBusinessEngine.CanonicalInviteEmailPointer(
                exists: true,
                pointedUserId: tombstone.userId,
                pointedUser: tombstone
            )
        )
        let tombstoneDecision = try XCTUnwrap(CanonicalBusinessEngine.resolveInviteEmailClaim(tombstoneInput))
        XCTAssertEqual(tombstoneDecision.action, "allow")
        XCTAssertNil(tombstoneDecision.reuseUserId)
        XCTAssertEqual(CanonicalBusinessEngine.inviteEmailHasLiveClaim(tombstoneInput), false)

        let emptyEmailOnly = CanonicalBusinessEngine.CanonicalInviteEmailClaimInput(
            inviteEmail: inviteEmail,
            existingUsers: [tombstone],
            emailPointer: CanonicalBusinessEngine.CanonicalInviteEmailPointer(exists: false, pointedUserId: nil, pointedUser: nil)
        )
        let emptyDecision = try XCTUnwrap(CanonicalBusinessEngine.resolveInviteEmailClaim(emptyEmailOnly))
        XCTAssertEqual(emptyDecision.action, "allow")
        XCTAssertNil(emptyDecision.reuseUserId)

        let generatedId = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let writtenId = FirebaseBackend.invitedUserDocumentId(decision: tombstoneDecision, generatedId: generatedId)
        XCTAssertEqual(writtenId, generatedId)
        XCTAssertNotEqual(writtenId, tombstone.userId)
    }

    func testInviteLookupIsOrgPlusEmailAndPlaceholderOmitsAge() throws {
        let lookup = try XCTUnwrap(CanonicalBusinessEngine.inviteEmailOrgLookupConstraints(
            organizationId: " Org-1 ",
            email: "Pat@Site.COM"
        ))
        XCTAssertEqual(lookup.organizationId, "Org-1")
        XCTAssertEqual(lookup.email, "pat@site.com")
        let query = try XCTUnwrap(FirebaseBackend.inviteEmailUsersQuery(organizationId: " Org-1 ", email: "Pat@Site.COM"))
        XCTAssertEqual(query.organizationId, lookup.organizationId)
        XCTAssertEqual(query.email, lookup.email)
        XCTAssertNil(FirebaseBackend.inviteEmailUsersQuery(organizationId: "   ", email: "pat@site.com"))
        XCTAssertNil(FirebaseBackend.inviteEmailUsersQuery(organizationId: "Org-1", email: "  "))

        let flags = try XCTUnwrap(CanonicalBusinessEngine.invitePlaceholderUserWriteFields())
        XCTAssertEqual(flags.passwordSet, false)
        XCTAssertEqual(flags.isActive, true)
        XCTAssertEqual(flags.isSuperAdmin, false)
        XCTAssertEqual(flags.policyAccepted, false)
        let ageFields = try XCTUnwrap(CanonicalBusinessEngine.userSelfCreateAgeFields)
        XCTAssertEqual(ageFields, ["ageConfirmed", "ageConfirmedAt", "ageConfirmedYears"])
        let writtenKeys: Set<String> = ["passwordSet", "isActive", "isSuperAdmin", "policyAccepted"]
        XCTAssertTrue(writtenKeys.isDisjoint(with: ageFields))

        XCTAssertEqual(
            CanonicalBusinessEngine.userCreateRequiresAgeConfirmation(
                creatorUserId: "admin-uid",
                targetUserId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            ),
            false
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.userCreateRequiresAgeConfirmation(
                creatorUserId: "self-uid",
                targetUserId: "self-uid"
            ),
            true
        )
    }

    func testInviteDoesNotWriteOperativeProfile() throws {
        XCTAssertEqual(CanonicalBusinessEngine.inviteWritesOperativeProfile(), false)
        let collections = try XCTUnwrap(FirebaseBackend.inviteWriteCollectionNames())
        XCTAssertEqual(collections, ["invitations", "users", "userEmails"])
        XCTAssertFalse(collections.contains("operativeProfiles"))
        let rates = try XCTUnwrap(FirebaseBackend.inviteUserRateFields(dayRate: 250))
        XCTAssertEqual(rates.payBasis, "day")
        XCTAssertEqual(rates.dayRate, 250)
        XCTAssertNil(rates.hourlyRate)
        XCTAssertNil(FirebaseBackend.inviteUserRateFields(dayRate: nil))
    }

    func testPendingOperativeWithoutProfileIsSchedulableAndDeletedUserIsNot() throws {
        XCTAssertEqual(CanonicalBusinessEngine.inviteWritesOperativeProfile(), false)
        let pendingId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let pending = AppUser(
            id: pendingId.uuidString,
            email: "new.op@site.test",
            organizationId: orgId,
            role: .operative,
            firstName: "New",
            surname: "Operative",
            isActive: true,
            passwordSet: false,
            permissions: UserPermissions(operativeMode: true)
        )
        let tombstoneOperative = Operative(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            firstName: "Deleted",
            lastName: "user",
            email: "",
            startDate: Date(timeIntervalSince1970: 0)
        )
        let projectId = UUID()
        let people = ScheduleBookablePersonBuilder.build(
            operatives: [tombstoneOperative],
            users: [pending, deletedUser()],
            projectId: projectId,
            bookings: []
        )
        XCTAssertEqual(people.map(\.operativeId), [pendingId])
        XCTAssertEqual(people.map(\.userId), [pending.id])
        XCTAssertEqual(people.map(\.name), ["New Operative"])
        XCTAssertFalse(people.contains { $0.name == "Deleted user" || $0.userId == deletedUser().id || $0.email.isEmpty })

        let catalogue = ScheduleBookablePersonBuilder.operativesForScheduling(
            operatives: [tombstoneOperative],
            users: [pending, deletedUser()]
        )
        XCTAssertEqual(catalogue.map(\.id), [pendingId])
        XCTAssertEqual(catalogue.map(\.email), ["new.op@site.test"])
        let listed = try XCTUnwrap(CanonicalBusinessEngine.listedCurrentLabourPeople([pending, deletedUser()]))
        XCTAssertEqual(listed.map(\.id), [pending.id])
    }
}
