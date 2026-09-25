//
//  VariationStore.swift
//  Project Planner
//

import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class VariationStore: ObservableObject {
    @Published var variations: [Variation] = []
    @Published var tracker: VariationTracker
    @Published var customTrades: [String] = []
    @Published var isLoading = false

    private let parentId: String
    private let parentType: VariationParentType
    private var variationListener: ListenerRegistration?
    private var trackerListener: ListenerRegistration?

    init(parentId: String, parentType: VariationParentType) {
        self.parentId = parentId
        self.parentType = parentType
        self.tracker = .disabled(parentId: parentId, parentType: parentType)
    }

    var visibleVariations: [Variation] {
        let live = variations.filter { !$0.isDeleted }
        if tracker.enabled {
            return live.sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.createdAt > $1.createdAt
            }
        }
        return live.sorted { $0.createdAt > $1.createdAt }
    }

    func start(firebaseBackend: FirebaseBackend) {
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
            attachListeners(firebaseBackend: firebaseBackend, orgId: orgId)
            return
        }
        Task {
            guard let orgId = await firebaseBackend.resolveOrganizationIdForFirebaseWrites(preferredFallback: nil),
                  !orgId.isEmpty else { return }
            attachListeners(firebaseBackend: firebaseBackend, orgId: orgId)
        }
    }

    private func attachListeners(firebaseBackend: FirebaseBackend, orgId: String) {
        variationListener?.remove()
        trackerListener?.remove()
        isLoading = true
        variationListener = firebaseBackend.observeVariations(organizationId: orgId, parentId: parentId) { [weak self] items in
            guard let self else { return }
            if items.isEmpty && !self.variations.isEmpty {
                self.isLoading = false
                return
            }
            self.variations = items
            self.isLoading = false
        }
        trackerListener = firebaseBackend.observeVariationTracker(
            organizationId: orgId,
            parentId: parentId,
            parentType: parentType
        ) { [weak self] tracker in
            self?.tracker = tracker
        }
        Task {
            customTrades = await firebaseBackend.loadCustomVariationTrades(organizationId: orgId)
        }
    }

    func upsert(_ variation: Variation) {
        if let idx = variations.firstIndex(where: { $0.id == variation.id }) {
            variations[idx] = variation
        } else {
            variations.insert(variation, at: 0)
        }
        isLoading = false
    }

    func stop() {
        variationListener?.remove()
        trackerListener?.remove()
        variationListener = nil
        trackerListener = nil
    }

    func nextVoNumber() -> String {
        VariationNumbering.nextFree(
            existing: variations,
            prefix: tracker.prefix,
            padding: tracker.padding
        )
    }

    func voNumberIsDuplicate(_ voNumber: String, excludingId: String?) -> Bool {
        let needle = voNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return variations.contains {
            guard !$0.isDeleted else { return false }
            if let excludingId, $0.id == excludingId { return false }
            return $0.voNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }
}
