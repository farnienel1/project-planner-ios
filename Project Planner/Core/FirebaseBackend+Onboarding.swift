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
    @MainActor
    func dismissOnboardingChecklist(organizationId: String) async throws {
        guard let uid = auth.currentUser?.uid, !organizationId.isEmpty,
              var fields = CanonicalBusinessEngine.onboardingDismissWriteFields(userId: uid) else { return }
        fields["onboardingDismissedAt"] = FieldValue.serverTimestamp()
        try await db.collection("organizations").document(organizationId).updateData(WriteMetadata.stamped(fields, userId: uid))
        // Hide it at once on this device; the organisation listener brings the stored value back.
        if var org = currentOrganization, organizationIdsMatch(org.firestoreDocumentId, organizationId) {
            var doc = OnboardingOrganizationDocument.document(json: org.onboardingDocumentJSON)
            doc["onboardingDismissedAt"] = Int(Date().timeIntervalSince1970 * 1000)
            if JSONSerialization.isValidJSONObject(doc),
               let bytes = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) {
                org.onboardingDocumentJSON = String(data: bytes, encoding: .utf8)
                currentOrganization = org
            }
        }
    }
}
