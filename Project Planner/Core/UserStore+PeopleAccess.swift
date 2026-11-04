//
//  UserStore+PeopleAccess.swift
//  Project Planner
//
//  RULEBOOK 1.31.0 §11, §13 (web `lib/stores/userStore.ts` `removeFromManagedJobs`, `components/users/EditUserProfile.tsx`
//  `lineManagerBlocks`): the line-manager change block, taking a person off the jobs they manage, and the company
//  activity notices around it. Every decision is the packed script's (`lineManagerChangeBlock`,
//  `jobManagerRemovalWrites`, `changeRemovesJobManager`); this file only gathers inputs and commits the writes.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

extension UserStore {
    /// The person as the people-and-access rules read them (`RulebookPeople.person` with the name).
    func peopleAccessPerson(_ user: AppUser) -> [String: Any] {
        var row = RulebookPeople.person(user)
        row["firstName"] = user.firstName
        row["surname"] = user.surname
        row["organizationId"] = user.storedOrganizationId ?? user.organizationId
        return row
    }

    /// `lineManagerChangeBlock`: the refusal shown when `change` would leave people without their line manager — the
    /// rulebook message followed by the people who report to `person` — else nil. Uses the unfolded roster, so a report
    /// stored against the person's other users document is found too.
    func lineManagerChangeBlockMessage(for person: AppUser, change: RulebookPersonAccessChange) -> String? {
        guard let block = CanonicalBusinessEngine.lineManagerChangeBlock(
            person: peopleAccessPerson(person),
            roster: unfoldedRosterRows,
            change: change
        ) else {
            return nil
        }
        guard block.blocked else { return nil }
        let message = block.message ?? CanonicalBusinessEngine.lineManagerReportsBlockMessage
        let names = block.reports.map { "• \($0.name)" }.joined(separator: "\n")
        return names.isEmpty ? message : "\(message)\n\n\(names)"
    }

    /// The signed-in account is a manager with the Operatives permission (not an admin): RULEBOOK 1.31.0 owner decision 7
    /// lets them add, edit, deactivate and delete operatives only (`userDeleteRefusal` `actorManagesOperatives`).
    var actorManagesOperativesOnly: Bool {
        guard let me = currentUser else { return false }
        let role = Self.staffAccountRole(for: me)
        if role.isOperativeMode || role.isAdmin || role.isSuperAdmin { return false }
        return role.isManager && me.effectivePermissions.operatives
    }

    /// RULEBOOK 1.31.0 §11 `jobManagerRemovalWrites`: when `change` takes `person` off their jobs (made an operative,
    /// deactivated, deleted — `changeRemovesJobManager`), every job naming any of their ids loses them (the job stays,
    /// with no manager when none is left) and the admins are told (`job_manager_removed`). Reads every job of the open
    /// organisation, as web `removeFromManagedJobs` does. Returns the number of jobs changed (0 when nothing changed or a
    /// read failed). `roster` is the unfolded roster as it was before the change.
    @discardableResult
    func removeFromManagedJobs(
        _ person: AppUser,
        change: RulebookPersonAccessChange,
        roster: [[String: Any]]? = nil
    ) async -> Int {
        let personRow = peopleAccessPerson(person)
        guard CanonicalBusinessEngine.changeRemovesJobManager(person: personRow, change: change),
              let orgId = firebaseBackend?.currentOrganization?.firestoreDocumentId,
              !orgId.isEmpty else { return 0 }
        let db = Firestore.firestore()
        let orgRef = db.collection("organizations").document(orgId)
        func strings(_ value: Any?) -> [String] { (value as? [Any] ?? []).compactMap { $0 as? String } }
        var jobs: [[String: Any]] = []
        do {
            for collection in ["projects", "smallWorks"] {
                let snapshot = try await orgRef.collection(collection).getDocuments(source: .server)
                for document in snapshot.documents {
                    let data = document.data()
                    var job: [String: Any] = [
                        "id": document.documentID,
                        "collection": collection,
                        "managerIds": strings(data["managerIds"]),
                        "managerUserIds": strings(data["managerUserIds"]),
                        "assignedManagerUserIds": strings(data["assignedManagerUserIds"]),
                    ]
                    if let primary = data["managerId"] as? String { job["managerId"] = primary }
                    jobs.append(job)
                }
            }
        } catch {
            NSLog("JOB_MANAGER_REMOVAL_READ_FAILED %@", error.localizedDescription)
            errorMessage = "Saved, but removing them from their jobs failed: \(error.localizedDescription)"
            return 0
        }
        let managers = (try? await orgRef.collection("managers").getDocuments(source: .server))?.documents.map {
            ["id": $0.documentID, "email": ($0.data()["email"] as? String) ?? ""] as [String: Any]
        } ?? JobAccessContext.managers
        let writes = CanonicalBusinessEngine.jobManagerRemovalWrites(
            organizationId: orgId,
            person: personRow,
            change: change,
            jobs: jobs,
            roster: roster ?? unfoldedRosterRows,
            managers: managers
        )
        guard !writes.isEmpty else { return 0 }
        let actor = Auth.auth().currentUser?.uid
        do {
            for start in stride(from: 0, to: writes.count, by: 400) {
                let batch = db.batch()
                for write in writes[start..<min(start + 400, writes.count)] {
                    var fields: [String: Any] = [:]
                    for (key, ids) in write.setLists { fields[key] = ids }
                    if let primary = write.setManagerId { fields["managerId"] = primary }
                    for key in write.remove { fields[key] = FieldValue.delete() }
                    batch.updateData(WriteMetadata.stamped(fields, userId: actor), forDocument: db.document(write.path))
                }
                try await batch.commit()
            }
        } catch {
            NSLog("JOB_MANAGER_REMOVAL_REFUSED %@", error.localizedDescription)
            errorMessage = "Saved, but removing them from their jobs failed: \(error.localizedDescription)"
            return 0
        }
        let name = person.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? person.email : person.fullName
        await notificationService?.notifyJobManagerRemoved(personId: person.id, name: name, jobCount: writes.count)
        return writes.count
    }
}
