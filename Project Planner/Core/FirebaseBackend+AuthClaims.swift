//
//  FirebaseBackend+AuthClaims.swift
//  Project Planner
//
//  RULEBOOK 1.32.4 (§16): the security rules read role and company facts from the ID token's custom claims (`pp`).
//  A token carries the claims it was issued with, so after an admin changes someone's role, toggles, membership or
//  active state the phone must fetch a new token, or it is refused (or keeps the old access) until the SDK's hourly
//  refresh. The Cloud Function writes `users/{uid}/private/authClaims` `{ v }` after every change. While a person is
//  signed in this file keeps ONE listener on that marker; on each new `v` it asks the rulebook
//  (`CanonicalBusinessEngine.authClaimsTokenIsStale`) whether the current token is older, and if so forces a token
//  refresh and posts `.authClaimsDidRefresh` so the open organisation's data reloads the way returning to the app does
//  (`ContentView.reloadOpenOrganizationData`). Web: `lib/auth/authClaimsRefresh.ts` `watchAuthClaims`.
//
//  Before the 1.32.4 rules are published the marker read is refused: that is ignored (no sign-out, no error shown);
//  the token then refreshes hourly as before. Nothing here decides access from the claims.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension Notification.Name {
    /// The ID token was refreshed because the auth-claims marker named newer claims. The open organisation's data is
    /// reloaded with the new access (web `AUTH_CLAIMS_REFRESHED_EVENT`).
    static let authClaimsDidRefresh = Notification.Name("authClaimsDidRefresh")
}

/// The decision for one marker snapshot, without Firebase, so it can be tested. Owns the "last version handled" so
/// the same `v` delivered twice (cache then server, or a re-listen) refreshes at most once.
@MainActor
final class AuthClaimsMarkerCoordinator {
    /// The current token's claims, or nil when they could not be read.
    typealias ReadClaims = @MainActor () async -> [String: Any]?
    /// `CanonicalBusinessEngine.authClaimsTokenIsStale`; nil when the script did not answer.
    typealias IsStale = @MainActor (Double, [String: Any]?) -> Bool?
    typealias ForceRefresh = @MainActor () async throws -> Void
    typealias DidRefresh = @MainActor (Double) -> Void

    private let readClaims: ReadClaims
    private let isStale: IsStale
    private let forceRefresh: ForceRefresh
    private let didRefresh: DidRefresh
    private(set) var lastMarkerVersion: Double?

    init(
        readClaims: @escaping ReadClaims,
        isStale: @escaping IsStale = { CanonicalBusinessEngine.authClaimsTokenIsStale(markerVersion: $0, tokenClaims: $1) },
        forceRefresh: @escaping ForceRefresh,
        didRefresh: @escaping DidRefresh
    ) {
        self.readClaims = readClaims
        self.isStale = isStale
        self.forceRefresh = forceRefresh
        self.didRefresh = didRefresh
    }

    /// The marker's `v` when it is a finite number (not a Bool), else nil. A missing document is nil.
    nonisolated static func markerVersion(from data: [String: Any]?) -> Double? {
        guard let number = data?["v"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    /// One marker snapshot. Returns true when the token was refreshed (and `didRefresh` called).
    @discardableResult
    func markerChanged(version: Double?) async -> Bool {
        guard let version, version != lastMarkerVersion else { return false }
        lastMarkerVersion = version
        let claims = await readClaims()
        // Claims that could not be read are refreshed, as web does; a script that did not answer leaves the token
        // alone (the SDK still refreshes it hourly).
        if claims != nil {
            guard isStale(version, claims) == true else { return false }
        }
        do {
            try await forceRefresh()
        } catch {
            print("🔥🔥🔥 DEBUG: Auth claims: token refresh failed: \(error.localizedDescription)")
            return false
        }
        didRefresh(version)
        return true
    }

    /// A refused or failed marker read. Ignored on purpose: before the 1.32.4 rules are published the rules refuse
    /// it, and that must not sign the person out or show an error.
    func markerReadFailed(_ error: Error) {
        print("🔥🔥🔥 DEBUG: Auth claims marker not readable (ignored): \(error.localizedDescription)")
    }
}

/// The one marker listener this session holds, and whose it is.
@MainActor
final class AuthClaimsMarkerWatch {
    fileprivate var registration: ListenerRegistration?
    fileprivate var uid = ""
    fileprivate var coordinator: AuthClaimsMarkerCoordinator?

    var watchedUid: String { uid }

    fileprivate func stop() {
        registration?.remove()
        registration = nil
        uid = ""
        coordinator = nil
    }
}

extension FirebaseBackend {
    /// Follows the auth-claims marker of `user` (nil stops it). Called from the auth state listener: on sign-in, on a
    /// different uid (the old listener is removed first) and on sign-out.
    func watchAuthClaimsMarker(for user: FirebaseAuth.User?) {
        let watch = authClaimsMarkerWatch
        guard let user else {
            watch.stop()
            return
        }
        if watch.registration != nil, watch.uid == user.uid { return }
        watch.stop()
        guard let path = CanonicalBusinessEngine.authClaimsMarkerPath(uid: user.uid) else {
            print("🔥🔥🔥 DEBUG: Auth claims: rulebook gave no marker path; token refreshes hourly")
            return
        }
        let uid = user.uid
        let coordinator = AuthClaimsMarkerCoordinator(
            readClaims: { [weak self] in
                guard let current = self?.auth.currentUser, current.uid == uid else { return nil }
                return try? await current.getIDTokenResult(forcingRefresh: false).claims
            },
            forceRefresh: { [weak self] in
                guard let current = self?.auth.currentUser, current.uid == uid else { return }
                _ = try await current.getIDToken(forcingRefresh: true)
            },
            didRefresh: { [weak self] version in
                guard let self, self.auth.currentUser?.uid == uid else { return }
                self.authClaimsDidRefresh(uid: uid, version: version)
            }
        )
        watch.uid = uid
        watch.coordinator = coordinator
        watch.registration = db.document(path).addSnapshotListener { [weak self] snapshot, error in
            let version = AuthClaimsMarkerCoordinator.markerVersion(from: snapshot?.data())
            let failure = error
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A snapshot from a listener this session has since replaced (sign-out, another account) is ignored.
                guard let active = self.authClaimsMarkerWatch.coordinator, active === coordinator else { return }
                if let failure {
                    self.authClaimsMarkerReadFailed(failure)
                    return
                }
                await coordinator.markerChanged(version: version)
            }
        }
    }

    /// A refused marker read: logged and ignored. No sign-out, no `errorMessage`. The listener is dropped (Firestore
    /// ends a refused listen); the next sign-in attaches it again.
    func authClaimsMarkerReadFailed(_ error: Error) {
        authClaimsMarkerWatch.coordinator?.markerReadFailed(error)
        authClaimsMarkerWatch.registration?.remove()
        authClaimsMarkerWatch.registration = nil
    }

    /// The token now carries the marker's claims: reload the open organisation's data with the new access.
    private func authClaimsDidRefresh(uid: String, version: Double) {
        print("🔥🔥🔥 DEBUG: Auth claims refreshed (v=\(version)); reloading the open organisation")
        guard currentOrganization != nil else { return }
        NotificationCenter.default.post(
            name: .authClaimsDidRefresh,
            object: nil,
            userInfo: ["uid": uid, "version": version]
        )
    }
}
