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

    /// One settings document per variation — same collection H&S already writes.
    private func variationItemDocument(organizationId: String, variationId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
            .document("variationItem_\(variationId)")
    }

    private func settingsCollection(organizationId: String) -> CollectionReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
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
                            bag.receivedCollection = true
                            if bag.receivedFallback || bag.receivedItemDocs {
                                onChange(
                                    mergeVariationSources(
                                        collection: bag.collectionItems,
                                        fallback: bag.fallbackItems,
                                        itemDocs: bag.itemDocItems
                                    )
                                )
                            }
                        }
                        return
                    }
                    guard let snapshot else { return }
                    let parsed = snapshot.documents.compactMap { doc in
                        VariationCodec.variation(from: doc.data(), documentId: doc.documentID)
                    }
                    Task { @MainActor in
                        bag.collectionItems = parsed
                        bag.receivedCollection = true
                        if parsed.isEmpty && !bag.receivedFallback && !bag.receivedItemDocs {
                            return
                        }
                        onChange(
                            mergeVariationSources(
                                collection: bag.collectionItems,
                                fallback: bag.fallbackItems,
                                itemDocs: bag.itemDocItems
                            )
                        )
                    }
                }
        )

        bag.add(
            variationsFallbackDocument(organizationId: orgId, parentId: parentId)
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] fallback listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            bag.receivedFallback = true
                            onChange(
                                mergeVariationSources(
                                    collection: bag.collectionItems,
                                    fallback: bag.fallbackItems,
                                    itemDocs: bag.itemDocItems
                                )
                            )
                        }
                        return
                    }
                    let parsed = variationsFromFallbackDocument(snapshot?.data())
                    Task { @MainActor in
                        bag.fallbackItems = parsed
                        bag.receivedFallback = true
                        onChange(
                            mergeVariationSources(
                                collection: bag.collectionItems,
                                fallback: bag.fallbackItems,
                                itemDocs: bag.itemDocItems
                            )
                        )
                    }
                }
        )

        bag.add(
            settingsCollection(organizationId: orgId)
                .whereField("recordType", isEqualTo: "variationItem")
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] item-doc listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            bag.receivedItemDocs = true
                            onChange(
                                mergeVariationSources(
                                    collection: bag.collectionItems,
                                    fallback: bag.fallbackItems,
                                    itemDocs: bag.itemDocItems
                                )
                            )
                        }
                        return
                    }
                    let parsed = (snapshot?.documents ?? []).compactMap { doc -> Variation? in
                        let data = doc.data()
                        guard (data["parentId"] as? String) == parentId else { return nil }
                        let rawId = (data["id"] as? String)
                            ?? doc.documentID.replacingOccurrences(of: "variationItem_", with: "")
                        return VariationCodec.variation(from: data, documentId: rawId)
                    }
                    Task { @MainActor in
                        bag.itemDocItems = parsed
                        bag.receivedItemDocs = true
                        onChange(
                            mergeVariationSources(
                                collection: bag.collectionItems,
                                fallback: bag.fallbackItems,
                                itemDocs: bag.itemDocItems
                            )
                        )
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
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save a variation."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId: String
        do {
            orgId = try await ensureReadableOrganization(resolved)
        } catch {
            print("⚠️ [Variations] Org root check skipped: \(error.localizedDescription)")
            orgId = resolved
        }
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

        // Production still denies `variations/{id}` until those rules are published.
        // H&S / deadlines already persist on `settings/{docId}` — that is the success path.
        var lastError: Error?
        var wrote = false

        do {
            try await saveVariationToSettingsFallback(payload, map: map, organizationId: orgId)
            wrote = true
        } catch {
            lastError = error
            print("⚠️ [Variations] Settings log write failed: \(error.localizedDescription)")
        }

        do {
            try await saveVariationItemDocument(payload, map: map, organizationId: orgId)
            wrote = true
        } catch {
            lastError = lastError ?? error
            print("⚠️ [Variations] Settings item write failed: \(error.localizedDescription)")
        }

        do {
            try await variationsCollection(organizationId: orgId)
                .document(payload.id)
                .setData(map, merge: true)
            wrote = true
        } catch {
            lastError = lastError ?? error
            print("⚠️ [Variations] Collection write skipped: \(error.localizedDescription)")
        }

        guard wrote else {
            throw lastError ?? NSError(
                domain: "FirebaseBackend",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Could not save this variation to Firebase."]
            )
        }
    }

    private func saveVariationToSettingsFallback(
        _ variation: Variation,
        map: [String: Any],
        organizationId: String
    ) async throws {
        let ref = variationsFallbackDocument(organizationId: organizationId, parentId: variation.parentId)
        var items: [[String: Any]] = []
        if let existing = try? await ref.getDocument(), let data = existing.data() {
            items = fallbackItemMaps(from: data)
        }
        if let idx = items.firstIndex(where: { ($0["id"] as? String) == variation.id }) {
            items[idx] = map
        } else {
            items.append(map)
        }
        try await ref.setData(
            [
                "parentId": variation.parentId,
                "parentType": variation.parentType.rawValue,
                "organizationId": organizationId,
                "recordType": "variationLog",
                "items": items,
                "updatedAt": Timestamp(date: Date())
            ],
            merge: true
        )
    }

    private func saveVariationItemDocument(
        _ variation: Variation,
        map: [String: Any],
        organizationId: String
    ) async throws {
        var data = map
        data["recordType"] = "variationItem"
        data["parentId"] = variation.parentId
        data["parentType"] = variation.parentType.rawValue
        data["organizationId"] = organizationId
        try await variationItemDocument(organizationId: organizationId, variationId: variation.id)
            .setData(data, merge: true)
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
        async let itemSnap = settingsCollection(organizationId: orgId)
            .whereField("recordType", isEqualTo: "variationItem")
            .getDocuments()
        let collectionItems = ((try? await collectionSnap)?.documents ?? []).compactMap {
            VariationCodec.variation(from: $0.data(), documentId: $0.documentID)
        }
        let fallbackItems = variationsFromFallbackDocument((try? await fallbackSnap)?.data())
        let itemDocs = ((try? await itemSnap)?.documents ?? []).compactMap { doc -> Variation? in
            let data = doc.data()
            guard (data["parentId"] as? String) == parentId else { return nil }
            let rawId = (data["id"] as? String)
                ?? doc.documentID.replacingOccurrences(of: "variationItem_", with: "")
            return VariationCodec.variation(from: data, documentId: rawId)
        }
        return mergeVariationSources(collection: collectionItems, fallback: fallbackItems, itemDocs: itemDocs)
            .filter { !$0.isDeleted && $0.status == .open }
            .count
    }

    #if canImport(FirebaseStorage)
    func uploadVariationEvidence(
        data: Data,
        fileName: String,
        contentType: String,
        organizationId: String,
        parentId: String,
        variationId: String,
        evidenceId: String
    ) async throws -> (storagePath: String, downloadURL: String) {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        if data.count > 20 * 1024 * 1024 {
            throw NSError(
                domain: "FirebaseBackend",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "That file is too large. Evidence must be 20 MB or smaller."]
            )
        }
        let orgId = normalizedOrganizationId(
            await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
                ?? organizationId
        )
        guard !orgId.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("⚠️ [Variations] upload ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        let ext = (fileName as NSString).pathExtension.isEmpty ? "bin" : (fileName as NSString).pathExtension
        let safeName = fileName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let timestamp = Int(Date().timeIntervalSince1970)
        let folderId = parentId.isEmpty ? variationId : parentId
        // Canonical variations path may be missing from Storage rules. H&S / tasks / site
        // audit prefixes already accept authenticated org uploads in this app.
        let paths = [
            "organizations/\(orgId)/healthSafety/\(folderId)/variationEvidence/\(userId)_\(timestamp)_\(safeName)",
            "organizations/\(orgId)/tasks/\(folderId)/files/\(userId)_\(timestamp)_\(safeName)",
            "organizations/\(orgId)/siteAudits/\(folderId)/images/\(userId)_\(timestamp)_\(safeName)",
            "organizations/\(orgId)/variations/\(variationId)/\(evidenceId).\(ext.lowercased())"
        ]
        var lastError: Error?
        for path in paths {
            do {
                let result = try await putVariationEvidenceData(data, path: path, contentType: contentType)
                print("✅ [Variations] Evidence uploaded to \(path)")
                return result
            } catch {
                lastError = error
                print("⚠️ [Variations] Storage path failed \(path): \(error.localizedDescription)")
            }
        }
        throw lastError ?? NSError(
            domain: "FirebaseBackend",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Could not upload evidence to Firebase Storage."]
        )
    }

    private func putVariationEvidenceData(
        _ data: Data,
        path: String,
        contentType: String
    ) async throws -> (storagePath: String, downloadURL: String) {
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
        parentId: String,
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

nonisolated private func fallbackItemMaps(from data: [String: Any]) -> [[String: Any]] {
    if let items = data["items"] as? [[String: Any]] {
        return items
    }
    if let items = data["items"] as? [String: Any] {
        return items.compactMap { id, value in
            guard var row = value as? [String: Any] else { return nil }
            if ((row["id"] as? String) ?? "").isEmpty {
                row["id"] = id
            }
            return row
        }
    }
    return []
}

nonisolated private func variationsFromFallbackDocument(_ data: [String: Any]?) -> [Variation] {
    guard let data else { return [] }
    return fallbackItemMaps(from: data).compactMap { row in
        VariationCodec.variation(from: row, documentId: (row["id"] as? String) ?? UUID().uuidString)
    }
}

nonisolated private func mergeVariationSources(
    collection: [Variation],
    fallback: [Variation],
    itemDocs: [Variation] = []
) -> [Variation] {
    var byId: [String: Variation] = [:]
    for item in fallback + itemDocs + collection {
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
    var itemDocItems: [Variation] = []
    var receivedCollection = false
    var receivedFallback = false
    var receivedItemDocs = false

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
