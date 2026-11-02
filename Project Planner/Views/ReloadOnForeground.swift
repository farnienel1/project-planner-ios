//
//  ReloadOnForeground.swift
//  Project Planner
//
//  RULEBOOK 1.9.0 §1 live screens (`LIVE_COLLECTIONS`, `screenMustListen`): a screen showing shared data holds a
//  snapshot listener while it is open. For the collections a screen loads itself (wholesalers, site audits, H&S,
//  deadlines, the material catalogue, pay-rate history), `listensWhileOpen` attaches one listener through
//  `OrgLiveListeners` when the screen appears and removes it when the screen goes; each server snapshot runs the
//  screen's own load again, which reads through the same rulebook reader. App plumbing only.
//

import SwiftUI
import UIKit
@preconcurrency import FirebaseFirestore

private struct ReloadOnForegroundModifier: ViewModifier {
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { @MainActor in await action() }
        }
    }
}

private struct ListensWhileOpenModifier: ViewModifier {
    let collectionId: String
    let key: String
    let targetSuffix: String
    let firebaseBackend: FirebaseBackend
    let query: (DocumentReference) -> Query
    let action: @MainActor () async -> Void

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }

    func body(content: Content) -> some View {
        content
            .onAppear { attach() }
            .onDisappear { firebaseBackend.stopLiveListener(key: key) }
            .onChange(of: organizationId) { _, _ in attach() }
            // A listener that failed removed itself; returning to the app attaches it again (no-op when attached).
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                attach()
            }
    }

    private func attach() {
        assert(IOSLiveListenerCoverage.listeners[collectionId] != nil, "\(collectionId) is not in IOSLiveListenerCoverage")
        let orgId = organizationId
        guard !orgId.isEmpty else { return }
        let action = action
        firebaseBackend.listenOrganizationQuery(
            key: key,
            organizationId: orgId,
            targetSuffix: targetSuffix,
            query: query
        ) { _, fromCache in
            // Only server data: a cache snapshot is what the screen already loaded.
            guard !fromCache else { return }
            Task { @MainActor in await action() }
        }
    }
}

extension View {
    /// Runs `action` each time the app returns to the foreground while this view is on screen.
    func reloadsOnForeground(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ReloadOnForegroundModifier(action: action))
    }

    /// While this view is on screen it holds one listener (`key`) on `query` under the open organisation, for the
    /// `LIVE_COLLECTIONS` row `collectionId`; every server snapshot runs `action` (the screen's own load). The
    /// listener is removed when the view disappears and on an organisation switch (`OrgListenerRegistry`).
    func listensWhileOpen(
        _ collectionId: String,
        key: String,
        targetSuffix: String = "",
        firebaseBackend: FirebaseBackend,
        query: @escaping (DocumentReference) -> Query,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(ListensWhileOpenModifier(
            collectionId: collectionId,
            key: key,
            targetSuffix: targetSuffix,
            firebaseBackend: firebaseBackend,
            query: query,
            action: action
        ))
    }
}
