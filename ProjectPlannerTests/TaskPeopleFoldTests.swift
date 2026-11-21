import XCTest
@testable import Project_Planner

/// Owner decision 17 Nov ("fix on both apps", web #364 `lib/tasks/taskAssigneePeople.test.ts`): a person with more
/// than one record appears once in the task pickers, the task filter and the task assignee names, folded with the
/// rulebook's `personIdSet` (and `isGhostUser`) through `TaskPersonIndex`. Stored ids never change (guardrail 3).
@MainActor
final class TaskPeopleFoldTests: XCTestCase {
    private func operative(
        _ docId: String,
        email: String,
        first: String,
        last: String,
        linkedUserId: String? = nil,
        isActive: Bool = true
    ) -> Operative {
        var row = Operative(
            id: WorkDocumentKeys.inAppId(for: docId),
            firstName: first,
            lastName: last,
            email: email,
            startDate: Date(timeIntervalSince1970: 0),
            dayRate: 200
        )
        row.firestoreDocumentId = docId
        row.linkedUserId = linkedUserId
        row.isActive = isActive
        return row
    }

    private func manager(_ docId: String, email: String, first: String, last: String) -> Manager {
        Manager(
            id: WorkDocumentKeys.inAppId(for: docId),
            firstName: first,
            lastName: last,
            email: email,
            mobileNumber: "",
            firestoreDocumentId: docId
        )
    }

    private func user(_ id: String, email: String, ghost: Bool = false, formerUserIds: [String] = []) -> AppUser {
        var row = LogicFixtures.selfEmployedUser(id: id, email: email)
        row.isGhost = ghost
        row.formerUserIds = formerUserIds
        return row
    }

    // A converted ghost (RULEBOOK §11): users/ROW-A is the ghost; its old operatives row keeps the id with the email
    // cleared; a duplicate row on the old email is linked to it and made inactive (its id on formerUserIds).
    private var ghostRoster: [AppUser] {
        [user("ROW-A", email: "", ghost: true, formerUserIds: ["row-b"]), user("u-pat", email: "pat@site.com")]
    }
    private var ghostRow: Operative { operative("row-a", email: "", first: "Gus", last: "Ghost", linkedUserId: "ROW-A") }
    private var ghostDuplicate: Operative {
        operative("row-b", email: "gus@old.com", first: "Gus", last: "Ghost", linkedUserId: "row-a", isActive: false)
    }
    private var patRow: Operative { operative("op-pat", email: "pat@site.com", first: "Pat", last: "Lee") }

    private func index(managers: [Manager] = [], operatives: [Operative], users: [AppUser]) -> TaskPersonIndex {
        TaskPersonIndex(managers: managers, operatives: operatives, users: users)
    }

    func testAConvertedGhostAndItsDuplicateRowAreOnePerson() {
        let all = [ghostRow, ghostDuplicate, patRow]
        let index = index(operatives: all, users: ghostRoster)
        XCTAssertEqual(index.key(.operative, ghostRow.id), index.key(.operative, ghostDuplicate.id))
        // An id stored in another letter case is the same row.
        XCTAssertEqual(index.key(.operative, WorkDocumentKeys.inAppId(for: "ROW-A")), index.key(.operative, ghostRow.id))
        XCTAssertNotEqual(index.key(.operative, ghostRow.id), index.key(.operative, patRow.id))
        XCTAssertTrue(index.isGhost(index.key(.operative, ghostRow.id)))
        XCTAssertFalse(index.isGhost(index.key(.operative, patRow.id)))
        let folded = TaskPeopleRulebook.filterOperatives(all, index: index)
        XCTAssertEqual(folded.map(\.documentId), ["row-a", "op-pat"])
    }

    func testTheNewTaskPickerNeverOffersAGhostAndListsEachPersonOnce() {
        let all = [ghostRow, ghostDuplicate, patRow]
        let index = index(operatives: all, users: ghostRoster)
        let active = all.filter(\.isActive)
        let picker = TaskPeopleRulebook.pickerPeople(managers: [], operatives: active, route: .operatives, index: index)
        XCTAssertEqual(picker.operatives.map(\.documentId), ["op-pat"])
        // A second row of the same person on the same email (another letter case) is not listed twice.
        let twin = operative("op-pat-2", email: "PAT@site.com", first: "Pat", last: "Lee")
        let twinIndex = self.index(operatives: [patRow, twin], users: ghostRoster)
        let twice = TaskPeopleRulebook.pickerPeople(managers: [], operatives: [patRow, twin], route: .operatives, index: twinIndex)
        XCTAssertEqual(twice.operatives.map(\.documentId), ["op-pat"])
    }

    func testAnOperativesRowLinkedToAnAccountIsTheSamePersonAsThatAccountsManagersRow() {
        let roster = [user("u-ada", email: "ada@site.com")]
        let mgr = manager("m-ada", email: "ada@site.com", first: "Ada", last: "Admin")
        let linked = operative("op-ada", email: "ada.other@site.com", first: "Ada", last: "Admin", linkedUserId: "U-ADA")
        let without = index(managers: [mgr], operatives: [linked], users: [])
        let before = TaskPeopleRulebook.pickerPeople(managers: [mgr], operatives: [linked], route: .combined, index: without)
        XCTAssertEqual(before.managers.count + before.operatives.count, 2, "without the roster the link is unknown")
        let with = index(managers: [mgr], operatives: [linked], users: roster)
        let after = TaskPeopleRulebook.pickerPeople(managers: [mgr], operatives: [linked], route: .combined, index: with)
        XCTAssertEqual(after.managers.map(\.firestoreDocumentId), ["m-ada"])
        XCTAssertTrue(after.operatives.isEmpty)
        // The operatives-only picker still offers their operatives row (web route `operatives`).
        let operativesOnly = TaskPeopleRulebook.pickerPeople(managers: [mgr], operatives: [linked], route: .operatives, index: with)
        XCTAssertEqual(operativesOnly.operatives.map(\.documentId), ["op-ada"])
    }

    func testGuardrail3AnOldRowIdStaysShownRemovableNamedAndFiltered() {
        let all = [ghostRow, ghostDuplicate, patRow]
        let index = index(operatives: all, users: ghostRoster)
        let selected: Set<UUID> = [ghostDuplicate.id]
        // The ghost is not offered, so the old assignment is listed as already assigned (never hidden).
        let extras = TaskPeopleRulebook.extras(
            shown: [(kind: .operative, id: patRow.id)],
            managers: [],
            operatives: Array(selected),
            index: index
        )
        XCTAssertEqual(extras, [TaskPickerExtra(kind: .operative, id: ghostDuplicate.id, label: "Gus Ghost")])
        XCTAssertTrue(TaskPeopleRulebook.isSelected(.operative, ghostRow.id, managers: [], operatives: selected, index: index))
        // Unticking removes every id of the person; nothing else is touched.
        let cleared = TaskPeopleRulebook.toggle(
            .operative,
            ghostRow.id,
            managers: [],
            operatives: [ghostDuplicate.id, ghostRow.id, patRow.id],
            index: index
        )
        XCTAssertEqual(cleared.operatives, [patRow.id])
        XCTAssertTrue(cleared.managers.isEmpty)

        let names = TaskPeopleRulebook.assigneeNames(
            managerIds: [],
            operativeIds: [ghostRow.id, WorkDocumentKeys.inAppId(for: "ROW-B"), patRow.id],
            index: index
        )
        XCTAssertEqual(names.map(\.name), ["Gus Ghost", "Pat Lee"])

        let both = ProjectTask(projectId: UUID(), title: "Both", createdBy: "TEST", assignedOperativeIds: [ghostRow.id, patRow.id])
        let oldOnly = ProjectTask(projectId: UUID(), title: "Old", createdBy: "TEST", assignedOperativeIds: [ghostDuplicate.id])
        let other = ProjectTask(projectId: UUID(), title: "Other", createdBy: "TEST", assignedOperativeIds: [patRow.id])
        let filtered = [both, oldOnly, other].filter {
            TaskPeopleRulebook.task($0, isAssignedTo: .operative, ghostRow.id, index: index)
        }
        XCTAssertEqual(filtered.map(\.title), ["Both", "Old"])
    }

    func testAnAssignmentWhoseRowIsGoneStaysListedAsUnknown() {
        let index = index(operatives: [patRow], users: ghostRoster)
        let gone = WorkDocumentKeys.inAppId(for: "deleted-row-1234")
        let extras = TaskPeopleRulebook.extras(shown: [], managers: [], operatives: [gone], index: index)
        XCTAssertEqual(extras.count, 1)
        XCTAssertTrue(extras[0].label.hasPrefix("Unknown person · "), extras[0].label)
        // Names leave it out, as before.
        XCTAssertTrue(TaskPeopleRulebook.assigneeNames(managerIds: [], operativeIds: [gone], index: index).isEmpty)
    }

    func testTickingAddsTheRowShownAndASecondTickRemovesAllTheirIds() {
        let twin = operative("op-pat-2", email: "PAT@site.com", first: "Pat", last: "Lee", isActive: false)
        let index = index(operatives: [patRow, twin], users: ghostRoster)
        let added = TaskPeopleRulebook.toggle(.operative, patRow.id, managers: [], operatives: [], index: index)
        XCTAssertEqual(added.operatives, [patRow.id])
        let removed = TaskPeopleRulebook.toggle(.operative, patRow.id, managers: [], operatives: [twin.id], index: index)
        XCTAssertTrue(removed.operatives.isEmpty)
    }

    /// Web "review of #364: every record of one person gets the same key (closure first)".
    func testReviewOf364EveryRecordOfOnePersonGetsTheSameKey() {
        let roster = [user("u-a", email: "a@x"), user("u-b", email: "b@x")]
        let opA = operative("op-a", email: "b@x", first: "Ann", last: "A", linkedUserId: "u-a")
        let opB = operative("op-b", email: "b@x", first: "Ann", last: "B")
        let index = index(operatives: [opA, opB], users: roster)
        XCTAssertEqual(index.key(.operative, opA.id), index.key(.operative, opB.id))
        XCTAssertEqual(index.key(.operative, opA.id), "account:u-a")
        let picked = TaskPeopleRulebook.pickerPeople(managers: [], operatives: [opA, opB], route: .operatives, index: index)
        XCTAssertEqual(picked.operatives.count, 1)
    }

    /// Web "review of #364: a person is a ghost only when every account is a ghost".
    func testReviewOf364APersonIsAGhostOnlyWhenEveryAccountIsAGhost() {
        let roster = [user("g1", email: "c@x", ghost: true), user("u-c", email: "c@x")]
        let opC = operative("op-c", email: "c@x", first: "Cal", last: "Cee")
        let index = index(operatives: [opC], users: roster)
        XCTAssertFalse(index.isGhost(index.key(.operative, opC.id)))
        let picked = TaskPeopleRulebook.pickerPeople(managers: [], operatives: [opC], route: .operatives, index: index)
        XCTAssertEqual(picked.operatives.map(\.documentId), ["op-c"])

        let ghostOnly = self.index(operatives: [opC], users: [user("g1", email: "c@x", ghost: true)])
        XCTAssertTrue(ghostOnly.isGhost(ghostOnly.key(.operative, opC.id)))
    }

    /// An anonymised deleted profile ("Deleted user", no email) is never offered (web `isCurrentLabourNamedPerson`).
    func testAnAnonymisedDeletedManagerIsNotOffered() {
        let deleted = manager("m-gone", email: "", first: "Deleted", last: "user")
        let live = manager("m-live", email: "live@x", first: "Liv", last: "E")
        let index = index(managers: [deleted, live], operatives: [], users: [])
        let picked = TaskPeopleRulebook.pickerPeople(managers: [deleted, live], operatives: [], route: .managers, index: index)
        XCTAssertEqual(picked.managers.map(\.firestoreDocumentId), ["m-live"])
    }

    /// The cached index is rebuilt only when a field it reads changes: a `lastSeenAt` write does not, a rename does.
    func testTheIndexHashIgnoresUnrelatedUserFields() {
        let users = ghostRoster
        let rows = [ghostRow, patRow]
        let base = TaskPersonIndex.contentHash(managers: [], operatives: rows, users: users)
        var seen = users
        seen[1].lastSeenAt = Date(timeIntervalSince1970: 1_000)
        seen[1].mobileNumber = "07000 000000"
        XCTAssertEqual(TaskPersonIndex.contentHash(managers: [], operatives: rows, users: seen), base)
        var renamed = rows
        renamed[1].firstName = "Patricia"
        XCTAssertNotEqual(TaskPersonIndex.contentHash(managers: [], operatives: renamed, users: users), base)
        var relinked = users
        relinked[1].formerUserIds = ["op-pat"]
        XCTAssertNotEqual(TaskPersonIndex.contentHash(managers: [], operatives: rows, users: relinked), base)
    }

    /// My tasks (`tasksAssignedToViewer`) still finds a task assigned to an old operatives row id.
    func testMyTasksStillMatchesATaskAssignedToAnOldRowId() {
        let viewer = user("u-sam", email: "sam@site.com", formerUserIds: ["old-row"])
        let oldRow = operative("old-row", email: "", first: "Sam", last: "Smith")
        let task = ProjectTask(projectId: UUID(), title: "Mine", createdBy: "TEST", assignedOperativeIds: [oldRow.id])
        let mine = TaskAssignmentRulebook.assignedTasks([task], viewer: viewer, organizationUsers: [viewer], operatives: [oldRow], managers: [])
        XCTAssertEqual(mine.map(\.id), [task.id])
    }

    /// The task screens call the fold; nothing keeps its own per-row list.
    func testTheTaskScreensUseTheFold() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/ProjectDetailView.swift"), encoding: .utf8)
        XCTAssertFalse(text.contains("operativesEligible"))
        XCTAssertFalse(text.contains("excludedOperativeEmails"))
        XCTAssertFalse(text.contains("struct OperativeMultiSelectView"))
        XCTAssertFalse(text.contains("struct ManagerMultiSelectView"))
        XCTAssertTrue(text.contains("TaskPeopleRulebook.pickerPeople("))
        XCTAssertTrue(text.contains("TaskPeopleRulebook.filterOperatives("))
        XCTAssertTrue(text.contains("TaskPeopleRulebook.assigneeNames("))
    }
}
