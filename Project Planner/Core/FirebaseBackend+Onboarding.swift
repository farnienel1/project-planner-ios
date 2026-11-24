//
//  FirebaseBackend+Onboarding.swift
//  Project Planner
//
//  RULEBOOK 1.85.0 §32: an admin hides the Getting started card for the company — one partial update of
//  `organizations/{orgId}` (`onboardingDismissWriteFields` + `onboardingDismissedAt` as the server time + write
//  metadata). The security rules already let an admin of the organisation write it. Online only.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// Hides the card at once on this device and queues the write (offline it is sent when back online; never waited
    /// on). `onFailure` runs on the main actor when the server refuses it, so the card can come back.
    @MainActor
    func dismissOnboardingChecklist(organizationId: String, onFailure: @escaping @MainActor (Error) -> Void = { _ in }) {
        guard let uid = auth.currentUser?.uid, !organizationId.isEmpty,
              var fields = CanonicalBusinessEngine.onboardingDismissWriteFields(userId: uid) else { return }
        fields["onboardingDismissedAt"] = FieldValue.serverTimestamp()
        let previous = currentOrganization
        if var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, organizationId) {
            var doc = OnboardingOrganizationDocument.document(json: org.onboardingDocumentJSON)
            doc["onboardingDismissedAt"] = Int(Date().timeIntervalSince1970 * 1000)
            if JSONSerialization.isValidJSONObject(doc),
               let bytes = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) {
                org.onboardingDocumentJSON = String(data: bytes, encoding: .utf8)
                currentOrganization = org
            }
        }
        db.collection("organizations").document(organizationId).updateData(WriteMetadata.stamped(fields, userId: uid)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                if let self, let previous, organizationIdsMatch(self.currentOrganization?.firestoreDocumentId, organizationId) {
                    var org = self.currentOrganization ?? previous
                    org.onboardingDocumentJSON = previous.onboardingDocumentJSON
                    self.currentOrganization = org
                }
                onFailure(error)
            }
        }
    }
}
