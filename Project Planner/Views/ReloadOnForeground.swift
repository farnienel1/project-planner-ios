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

/// Several listeners on one `LIVE_COLLECTIONS` row while the view is on screen (one per query; keys `keyPrefix.<id>`),
/// for a screen whose read plan is more than one query (pay history under `rateHistoryQueryPlan` `people`). Each server
/// snapshot hands that query's rows to `onRows`; listeners no longer in `queries` are removed, all of them when the view
/// goes, and `OrgLiveListeners` drops them on an organisation switch (re-attached here for the new one).
private struct ListensWhileOpenQueriesModifier: ViewModifier {
    let collectionId: String
    let keyPrefix: String
    let firebaseBackend: FirebaseBackend
    let queries: [(key: String, query: (DocumentReference) -> Query)]
    let onRows: @MainActor (_ queryKey: String, _ rows: LiveDocumentRows) -> Void

    @State private var attachedKeys: Set<String> = []

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }
    private var plannedKeys: [String] { queries.map(\.key) }

    func body(content: Content) -> some View {
        content
            .onAppear { attach() }
            .onDisappear { detachAll() }
            .onChange(of: organizationId) { _, _ in attach() }
            .onChange(of: plannedKeys) { _, _ in attach() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                attach()
            }
    }

    private func listenerKey(_ queryKey: String) -> String { "\(keyPrefix).\(queryKey)" }

    private func attach() {
        assert(IOSLiveListenerCoverage.listeners[collectionId] != nil, "\(collectionId) is not in IOSLiveListenerCoverage")
        let wanted = Set(plannedKeys)
        for stale in attachedKeys.subtracting(wanted) { firebaseBackend.stopLiveListener(key: listenerKey(stale)) }
        let orgId = organizationId
        guard !orgId.isEmpty else {
            attachedKeys = []
            return
        }
        for entry in queries {
            let queryKey = entry.key
            let onRows = onRows
            firebaseBackend.listenOrganizationQuery(
                key: listenerKey(queryKey),
                organizationId: orgId,
                query: entry.query
            ) { rows, fromCache in
                // Only server data: a cache snapshot is what the screen already loaded.
                guard !fromCache else { return }
                onRows(queryKey, rows)
            }
        }
        attachedKeys = wanted
    }

    private func detachAll() {
        for key in attachedKeys.union(plannedKeys) { firebaseBackend.stopLiveListener(key: listenerKey(key)) }
        attachedKeys = []
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

    /// While this view is on screen it holds one listener per entry of `queries` (keys `keyPrefix.<entry key>`) under the
    /// open organisation, for the `LIVE_COLLECTIONS` row `collectionId`; each server snapshot hands that entry's rows to
    /// `onRows`. Entries that leave `queries` are removed; all are removed when the view disappears.
    func listensWhileOpen(
        _ collectionId: String,
        keyPrefix: String,
        firebaseBackend: FirebaseBackend,
        queries: [(key: String, query: (DocumentReference) -> Query)],
        onRows: @escaping @MainActor (_ queryKey: String, _ rows: LiveDocumentRows) -> Void
    ) -> some View {
        modifier(ListensWhileOpenQueriesModifier(
            collectionId: collectionId,
            keyPrefix: keyPrefix,
            firebaseBackend: firebaseBackend,
            queries: queries,
            onRows: onRows
        ))
    }
}
