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
        // RULEBOOK 1.63.0: until the tracker document loads, a job reads as having none — on by default.
        self.tracker = VariationCodec.tracker(from: [:], parentId: parentId, parentType: parentType)
    }

    var visibleVariations: [Variation] {
        let live = variations.filter { !$0.isDeleted }
        if tracker.enabled {
            // RULEBOOK 1.63.0 `variationTrackerOrder` (sequence, VO number, id): the tracker's own order.
            let rows: [[String: Any]] = live.map { ["id": $0.id, "voNumber": $0.voNumber, "sequence": $0.sequence] }
            if let order = CanonicalBusinessEngine.variationTrackerOrder(rows: rows) {
                var rank: [String: Int] = [:]
                for (index, id) in order.enumerated() { rank[id.lowercased()] = index }
                return live.sorted { (rank[$0.id.lowercased()] ?? Int.max) < (rank[$1.id.lowercased()] ?? Int.max) }
            }
            return live.sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.createdAt > $1.createdAt
            }
        }
        return live.sorted { $0.createdAt > $1.createdAt }
    }

    func start(firebaseBackend: FirebaseBackend) {
        // AGENTS rule 2: only the open organisation. With none open yet nothing is attached; the list view calls
        // `start` again when `currentOrganization` changes (never the home company in `users/{uid}`).
        guard let orgId = FirebaseBackend.openOrganizationIdForWrites(
            requested: nil,
            openOrganizationId: firebaseBackend.currentOrganization?.firestoreDocumentId
        ) else { return }
        attachListeners(firebaseBackend: firebaseBackend, orgId: orgId)
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

    /// RULEBOOK 1.22.0 §22 `CanonicalBusinessEngine.nextVariationNumber` over every variation, deleted ones included.
    /// Blank when the script did not answer (the person types the number; the duplicate check still runs).
    func nextVoNumber() -> String {
        VariationNumbering.nextFree(
            existing: variations,
            prefix: tracker.prefix,
            padding: tracker.padding
        ) ?? ""
    }

    /// RULEBOOK 1.22.0 §22 `CanonicalBusinessEngine.variationNumberTaken`: a deleted variation still holds its number
    /// (owner decision), the variation being edited is skipped by id, both without case. True (taken) when the script
    /// did not answer, so a duplicate is never saved on a guess.
    func voNumberIsDuplicate(_ voNumber: String, excludingId: String?) -> Bool {
        CanonicalBusinessEngine.variationNumberTaken(
            existing: variations.map { (id: $0.id, voNumber: $0.voNumber, isDeleted: $0.isDeleted) },
            voNumber: voNumber,
            exceptId: excludingId
        ) ?? true
    }
}
