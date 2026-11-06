//
//  Rulebook+AuthClaims.swift
//  Project Planner
//
//  RULEBOOK 1.32.4 (§16): the security rules read the signed-in person's role and company facts from the ID token's
//  custom claims (`pp`). The Cloud Function writes the marker `users/{uid}/private/authClaims` `{ v }` after every
//  change; the app refreshes its token when the token's claims are older. Web `lib/canonical/authClaims.ts`
//  (`authClaimsMarkerPath`, `authClaimsTokenIsStale`), called through `CanonicalBusinessEngine`. The claims are for
//  the rules only: nothing on iOS decides access from them.
//

import Foundation

extension CanonicalBusinessEngine {
    /// `authClaimsMarkerPath(uid)`: the marker document's path (`users/{uid}/private/authClaims`). Nil when the
    /// script did not answer or the uid is empty.
    nonisolated static func authClaimsMarkerPath(uid: String) -> String? {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let path = callJSON("authClaimsMarkerPath", arguments: [trimmed]) as? String,
              !path.isEmpty else { return nil }
        return path
    }

    /// `authClaimsTokenIsStale(markerVersion, tokenClaims)`: true when the token's claims are not the ones the marker
    /// names (missing claims included). `tokenClaims` is the ID token's claims dictionary as the SDK returns it.
    /// Nil when the script did not answer.
    nonisolated static func authClaimsTokenIsStale(markerVersion: Double, tokenClaims: [String: Any]?) -> Bool? {
        guard markerVersion.isFinite else { return false }
        let claims: Any = tokenClaims.map { FirebaseBackend.firestoreJSON($0) } ?? NSNull()
        return callJSON("authClaimsTokenIsStale", arguments: [markerVersion, claims]) as? Bool
    }
}
