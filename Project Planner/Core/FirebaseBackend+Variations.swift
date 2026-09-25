//
//  FirebaseBackend+Variations.swift
//  Project Planner
//

import Foundation
import UIKit
import FirebaseFirestore
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

    func observeVariations(
        organizationId: String,
        parentId: String,
        onChange: @escaping @MainActor ([Variation]) -> Void
    ) -> ListenerRegistration {
        let orgId = normalizedOrganizationId(organizationId)
        return variationsCollection(organizationId: orgId)
            .whereField("parentId", isEqualTo: parentId)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("❌ [Variations] listen error: \(error.localizedDescription)")
                    return
                }
                let items = (snapshot?.documents ?? []).compactMap { doc in
                    VariationCodec.variation(from: doc.data(), documentId: doc.documentID)
                }
                Task { @MainActor in
                    onChange(items)
                }
            }
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
        var payload = variation
        payload.orgId = normalizedOrganizationId(organizationId)
        payload.recomputeCounts()
        try await variationsCollection(organizationId: organizationId)
            .document(payload.id)
            .setData(VariationCodec.firestoreMap(from: payload), merge: true)
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
        let snap = try? await variationsCollection(organizationId: organizationId)
            .whereField("parentId", isEqualTo: parentId)
            .getDocuments()
        let items = (snap?.documents ?? []).compactMap { VariationCodec.variation(from: $0.data(), documentId: $0.documentID) }
        return items.filter { !$0.isDeleted && $0.status == .open }.count
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
