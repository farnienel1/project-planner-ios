//
//  FirebaseBackend+Variations.swift
//  Project Planner
//

import Foundation
import UIKit
import FirebaseAuth
@preconcurrency import FirebaseFirestore
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

extension FirebaseBackend {
    private func variationsCollection(organizationId: String) -> CollectionReference {
        db.collection("organizations").document(normalizedOrganizationId(organizationId)).collection("variations")
    }

    private func variationTrackerDocument(organizationId: String, parentId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("variationTrackers")
            .document(parentId)
    }

    private func variationTradesDocument(organizationId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
            .document("variationTrades")
    }

    /// Writable even before `variations` collection rules are published (same pattern as H&S).
    private func variationsFallbackDocument(organizationId: String, parentId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
            .document("variations_\(parentId)")
    }

    func observeVariations(
        organizationId: String,
        parentId: String,
        onChange: @escaping @MainActor ([Variation]) -> Void
    ) -> ListenerRegistration {
        let orgId = normalizedOrganizationId(organizationId)
        let bag = VariationListenerBag()

        bag.add(
            variationsCollection(organizationId: orgId)
                .whereField("parentId", isEqualTo: parentId)
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            onChange(mergeVariationSources(collection: bag.collectionItems, fallback: bag.fallbackItems))
                        }
                        return
                    }
                    guard let snapshot else { return }
                    if snapshot.documents.isEmpty && snapshot.metadata.isFromCache {
                        Task { @MainActor in
                            onChange(mergeVariationSources(collection: bag.collectionItems, fallback: bag.fallbackItems))
                        }
                        return
                    }
                    let parsed = snapshot.documents.compactMap { doc in
                        VariationCodec.variation(from: doc.data(), documentId: doc.documentID)
                    }
                    Task { @MainActor in
                        bag.collectionItems = parsed
                        onChange(mergeVariationSources(collection: bag.collectionItems, fallback: bag.fallbackItems))
                    }
                }
        )

        bag.add(
            variationsFallbackDocument(organizationId: orgId, parentId: parentId)
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] fallback listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            onChange(mergeVariationSources(collection: bag.collectionItems, fallback: bag.fallbackItems))
                        }
                        return
                    }
                    let parsed = variationsFromFallbackDocument(snapshot?.data())
                    Task { @MainActor in
                        bag.fallbackItems = parsed
                        onChange(mergeVariationSources(collection: bag.collectionItems, fallback: bag.fallbackItems))
                    }
                }
        )

        return bag
    }

    func observeVariationTracker(
        organizationId: String,
        parentId: String,
        parentType: VariationParentType,
        onChange: @escaping @MainActor (VariationTracker) -> Void
    ) -> ListenerRegistration {
        return variationTrackerDocument(organizationId: organizationId, parentId: parentId)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("❌ [Variations] tracker listen error: \(error.localizedDescription)")
                    return
                }
                let tracker: VariationTracker
                if let data = snapshot?.data() {
                    tracker = VariationCodec.tracker(from: data, parentId: parentId)
                } else {
                    tracker = .disabled(parentId: parentId, parentType: parentType)
                }
                Task { @MainActor in
                    onChange(tracker)
                }
            }
    }

    func saveVariation(_ variation: Variation, organizationId: String) async throws {
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId = try await ensureReadableOrganization(resolved)
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("⚠️ [Variations] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)

        var payload = variation
        payload.orgId = orgId
        payload.recomputeCounts()
        let map = VariationCodec.firestoreMap(from: payload)

        do {
            try await variationsCollection(organizationId: orgId)
                .document(payload.id)
                .setData(map, merge: true)
        } catch {
            guard isVariationPermissionDenied(error) else { throw error }
            print("⚠️ [Variations] Collection write denied — saving via settings fallback")
            try await saveVariationToSettingsFallback(payload, map: map, organizationId: orgId)
        }
    }

    private func saveVariationToSettingsFallback(
        _ variation: Variation,
        map: [String: Any],
        organizationId: String
    ) async throws {
        let ref = variationsFallbackDocument(organizationId: organizationId, parentId: variation.parentId)
        try await ref.setData(
            [
                "parentId": variation.parentId,
                "parentType": variation.parentType.rawValue,
                "organizationId": organizationId,
                "items.\(variation.id)": map,
                "updatedAt": Timestamp(date: Date())
            ],
            merge: true
        )
    }

    private func isVariationPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7
    }

    func loadCustomVariationTrades(organizationId: String) async -> [String] {
        let snap = try? await variationTradesDocument(organizationId: organizationId).getDocument()
        return (snap?.data()?["customTrades"] as? [String]) ?? []
    }

    func addCustomVariationTrade(_ trade: String, organizationId: String) async {
        let trimmed = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var existing = await loadCustomVariationTrades(organizationId: organizationId)
        let key = trimmed.lowercased()
        if existing.contains(where: { $0.lowercased() == key }) { return }
        if VariationTrades.standard.contains(where: { $0.lowercased() == key }) { return }
        existing.append(trimmed)
        try? await variationTradesDocument(organizationId: organizationId).setData(
            ["customTrades": existing],
            merge: true
        )
    }

    func countOpenVariations(organizationId: String, parentId: String) async -> Int {
        let orgId = normalizedOrganizationId(organizationId)
        async let collectionSnap = variationsCollection(organizationId: orgId)
            .whereField("parentId", isEqualTo: parentId)
            .getDocuments()
        async let fallbackSnap = variationsFallbackDocument(organizationId: orgId, parentId: parentId)
            .getDocument()
        let collectionItems = ((try? await collectionSnap)?.documents ?? []).compactMap {
            VariationCodec.variation(from: $0.data(), documentId: $0.documentID)
        }
        let fallbackItems = variationsFromFallbackDocument((try? await fallbackSnap)?.data())
        return mergeVariationSources(collection: collectionItems, fallback: fallbackItems)
            .filter { !$0.isDeleted && $0.status == .open }
            .count
    }

    #if canImport(FirebaseStorage)
    func uploadVariationEvidence(
        data: Data,
        fileName: String,
        contentType: String,
        organizationId: String,
        variationId: String,
        evidenceId: String
    ) async throws -> (storagePath: String, downloadURL: String) {
        guard currentUser?.uid != nil else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        if data.count > 20 * 1024 * 1024 {
            throw NSError(
                domain: "FirebaseBackend",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "That file is too large. Evidence must be 20 MB or smaller."]
            )
        }
        let ext = (fileName as NSString).pathExtension.isEmpty ? "bin" : (fileName as NSString).pathExtension
        let path = "organizations/\(normalizedOrganizationId(organizationId))/variations/\(variationId)/\(evidenceId).\(ext.lowercased())"
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(data, metadata: metadata) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
        let url: String
        do {
            url = try await storageRef.downloadURL().absoluteString
        } catch {
            url = "gs://\(storageRef.bucket)/\(storageRef.fullPath)"
        }
        return (path, url)
    }

    func deleteVariationEvidenceFile(storagePath: String) async {
        guard !storagePath.isEmpty else { return }
        let ref = storage.reference().child(storagePath)
        try? await ref.delete()
    }
    #else
    func uploadVariationEvidence(
        data: Data,
        fileName: String,
        contentType: String,
        organizationId: String,
        variationId: String,
        evidenceId: String
    ) async throws -> (storagePath: String, downloadURL: String) {
        throw NSError(
            domain: "FirebaseBackend",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "Firebase Storage is not available in this build."]
        )
    }

    func deleteVariationEvidenceFile(storagePath: String) async {}
    #endif
}

nonisolated private func variationsFromFallbackDocument(_ data: [String: Any]?) -> [Variation] {
    guard let data else { return [] }
    if let items = data["items"] as? [String: Any] {
        return items.compactMap { id, value in
            guard let row = value as? [String: Any] else { return nil }
            return VariationCodec.variation(from: row, documentId: (row["id"] as? String) ?? id)
        }
    }
    if let items = data["items"] as? [[String: Any]] {
        return items.compactMap { row in
            VariationCodec.variation(from: row, documentId: (row["id"] as? String) ?? UUID().uuidString)
        }
    }
    return []
}

nonisolated private func mergeVariationSources(collection: [Variation], fallback: [Variation]) -> [Variation] {
    var byId: [String: Variation] = [:]
    for item in fallback {
        byId[item.id] = item
    }
    for item in collection {
        if let existing = byId[item.id] {
            byId[item.id] = item.updatedAt >= existing.updatedAt ? item : existing
        } else {
            byId[item.id] = item
        }
    }
    return Array(byId.values)
}

nonisolated private final class VariationListenerBag: NSObject, ListenerRegistration, @unchecked Sendable {
    private var listeners: [ListenerRegistration] = []
    var collectionItems: [Variation] = []
    var fallbackItems: [Variation] = []

    func add(_ listener: ListenerRegistration) {
        listeners.append(listener)
    }

    func remove() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }
}

enum VariationEvidenceProcessor {
    static let maxBytes = 20 * 1024 * 1024
    static let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "pdf"]

    static func isAllowed(fileName: String, contentType: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if allowedExtensions.contains(ext) { return true }
        let type = contentType.lowercased()
        return type.contains("jpeg") || type.contains("jpg") || type.contains("png") || type.contains("heic") || type.contains("pdf")
    }

    static func preparedImageData(_ image: UIImage) -> Data? {
        let resized = resized(image, maxPixelDimension: 2000)
        return resized.jpegData(compressionQuality: 0.7)
    }

    private static func resized(_ image: UIImage, maxPixelDimension: CGFloat) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let longest = max(width, height)
        guard longest > maxPixelDimension, longest > 0 else { return image }
        let scale = maxPixelDimension / longest
        let newSize = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
