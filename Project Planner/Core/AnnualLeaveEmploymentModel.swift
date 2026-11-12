//
//  AnnualLeaveEmploymentModel.swift
//  Project Planner
//
//  RULEBOOK 1.40.0 §4.4 (review r306 #2; web `lib/annualLeave/useLeaveEmployment.ts`): the employment-type input of a
//  person's leave balance, from the same pay record every pay screen uses. While `privatePay` is off it is the users
//  document as read (nothing else is loaded). While it is on, the person's pay profile (`payProfiles/{id}`, else one of
//  their `formerUserIds`) is read and laid over by the packed script (`annualLeaveEmploymentInput`), because the
//  employment type is pay data and a stripped users document no longer holds it. A refused read gives `nil` (the
//  balance counts the whole year, as before 1.40.0). Screens show no figure until `ready`.
//

import Foundation
import Combine
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// Reads `payProfiles/{subjectId}`: `read` false when the read was refused or failed (never "no profile").
    func readPayProfileForLeave(subjectId: String) async -> (read: Bool, data: [String: Any]?) {
        guard let orgId = currentOrganization?.firestoreDocumentId,
              let path = CanonicalBusinessEngine.payProfilePath(organizationId: orgId, subjectId: subjectId) else {
            return (false, nil)
        }
        do {
            let snap = try await db.document(path).getDocument(source: .server)
            guard snap.exists, let data = snap.data() else { return (true, nil) }
            return (true, FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? data)
        } catch {
            return (false, nil)
        }
    }
}

@MainActor
final class AnnualLeaveEmploymentModel: ObservableObject {
    /// Per person (and their stored fields): the answer, `nil` inside meaning unreadable (count the whole year).
    @Published private(set) var answers: [String: AnnualLeaveEmployment?] = [:]
    private var inFlight: Set<String> = []

    private static func key(_ user: AppUser) -> String {
        let stored = AnnualLeaveEmployment(user)
        return [user.id, stored.employmentType, stored.transitionFrom ?? "", stored.effectiveAt.map { "\($0.timeIntervalSince1970)" } ?? "",
                user.formerUserIds.joined(separator: ",")].joined(separator: "|")
    }

    /// The employment input for `user`'s balance and whether it is known yet. While `privatePay` is off it is ready at
    /// once (the users document); while it is on, the first call starts the pay-profile read and returns not ready.
    func employment(for user: AppUser, backend: FirebaseBackend) -> (ready: Bool, employment: AnnualLeaveEmployment?) {
        let stored = AnnualLeaveEmployment(user)
        guard SecuritySwitchContext.privatePay else { return (true, stored) }
        let key = Self.key(user)
        if let answer = answers[key] { return (true, answer) }
        if !inFlight.contains(key) {
            inFlight.insert(key)
            Task { [weak self] in await self?.load(user: user, key: key, backend: backend) }
        }
        return (false, nil)
    }

    private func load(user: AppUser, key: String, backend: FirebaseBackend) async {
        let stored = AnnualLeaveEmployment(user)
        var readAny = false
        var fields: [String: Any]?
        for id in [user.id] + user.formerUserIds where !id.isEmpty {
            let result = await backend.readPayProfileForLeave(subjectId: id)
            if result.read { readAny = true }
            if let data = result.data {
                fields = data
                break
            }
        }
        let answer = CanonicalBusinessEngine.annualLeaveEmploymentInput(
            person: stored.json,
            payProfileFields: fields,
            privatePay: true,
            payProfileRead: readAny
        )
        inFlight.remove(key)
        // The script did not answer: keep the stored fields (as before the review), never block the screen.
        answers[key] = answer ?? .some(stored)
    }
}
