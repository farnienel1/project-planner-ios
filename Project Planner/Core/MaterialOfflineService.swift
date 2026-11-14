//
//  MaterialOfflineService.swift
//  Project Planner
//
//  Offline-aware save/delete/send for materials.
//

import Foundation

enum MaterialOfflineSaveResult {
    case syncedImmediately
    case queuedForSync
}

@MainActor
enum MaterialOfflineService {

    static func resolvedOrganizationId(firebaseBackend: FirebaseBackend) -> String? {
        firebaseBackend.resolvedOrganizationIdForOfflineWrites()
    }

    static func mergedMaterials(
        organizationId: String,
        projectId: UUID,
        remote: [MaterialItem]
    ) -> [MaterialItem] {
        OfflineMaterialLocalStore.shared.mergedMaterials(
            organizationId: organizationId,
            projectId: projectId,
            remote: remote
        )
    }

    static func saveMaterial(
        _ material: MaterialItem,
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        isOnline: Bool
    ) async throws -> MaterialOfflineSaveResult {
        OfflineMaterialLocalStore.shared.upsert(material, organizationId: organizationId)

        if !isOnline {
            OfflineOutboxStore.shared.enqueueSaveMaterialItem(material, organizationId: organizationId)
            return .queuedForSync
        }

        do {
            try await firebaseBackend.saveMaterialItem(material, organizationId: organizationId)
            OfflineMaterialLocalStore.shared.markSynced(materialId: material.id, projectId: material.projectId)
            return .syncedImmediately
        } catch where OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) {
            OfflineOutboxStore.shared.enqueueSaveMaterialItem(material, organizationId: organizationId)
            return .queuedForSync
        }
    }

    static func deleteMaterial(
        _ materialId: UUID,
        projectId: UUID,
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        isOnline: Bool
    ) async throws -> MaterialOfflineSaveResult {
        OfflineMaterialLocalStore.shared.markPendingDelete(
            materialId: materialId,
            projectId: projectId,
            organizationId: organizationId
        )

        if !isOnline {
            OfflineOutboxStore.shared.enqueueDeleteMaterialItem(materialId, organizationId: organizationId)
            return .queuedForSync
        }

        do {
            try await firebaseBackend.deleteMaterialItem(materialId, organizationId: organizationId)
            OfflineMaterialLocalStore.shared.markDeletedSynced(materialId: materialId)
            return .syncedImmediately
        } catch where OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) {
            OfflineOutboxStore.shared.enqueueDeleteMaterialItem(materialId, organizationId: organizationId)
            return .queuedForSync
        }
    }

    static func sendMaterialRequest(
        _ request: MaterialOrderRequest,
        sendRecord: MaterialSendRecord?,
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        isOnline: Bool
    ) async throws -> MaterialOfflineSaveResult {
        if !isOnline {
            OfflineOutboxStore.shared.enqueueSendMaterialRequest(
                request,
                sendRecord: sendRecord,
                organizationId: organizationId
            )
            return .queuedForSync
        }

        // Online: a dropped connection or a timeout is retried straight away (`MaterialRequestSendRetry`), with the
        // same `requestId`, so the function sends it at most once (it answers a repeat from the first send, or 409
        // "still sending"). Only when the quick retries also fail is the email queued for the next sync.
        // Only a request with an id is retried: without one the function cannot tell a retry from a new send.
        let canRetry = MaterialRequestEmailPayload.requestIdValue(request.requestId) != nil
        let outcome = try await MaterialRequestSendRetry.perform(isOnline: isOnline, canRetry: canRetry) {
            try await firebaseBackend.sendMaterialRequest(request, organizationId: organizationId)
        }
        switch outcome {
        case .sent:
            if let sendRecord {
                do {
                    try await firebaseBackend.saveMaterialSendRecord(sendRecord, organizationId: organizationId)
                } catch {
                    print("🔥🔥🔥 DEBUG: [materials/send] email sent; send-record write failed: \(error.localizedDescription)")
                }
            }
            return .syncedImmediately
        case .queue:
            // Offline after the retries, or an earlier press of this same email (same `requestId`) is still sending:
            // queue it with its request id; the replay is answered from that send, never emailed twice.
            OfflineOutboxStore.shared.enqueueSendMaterialRequest(
                request,
                sendRecord: sendRecord,
                organizationId: organizationId
            )
            return .queuedForSync
        }
    }

    /// Shown only when the wholesaler email did not go. A permission failure after a successful send is not this path.
    static func sendFailureMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        let lowered = message.lowercased()
        if lowered.contains("insufficient permissions") || lowered.contains("permission-denied") {
            return "Could not send this list. Check you are signed in to this organisation and try again."
        }
        return message
    }
}

/// What to do when sending a material quote / order email fails while the phone thinks it is online.
///
/// Before, any error whose text mentioned "network", "offline" or "internet" queued the email at once, even with a
/// working connection, and it then waited for the next sync. Now a dropped connection or a timeout is retried
/// straight away (up to `maxQuickRetries`, a timeout once) with the same `requestId` — the `sendEmail` function never
/// sends one request id twice (web functions/email/requestDedupe.js), so a retry after a send that did go through is
/// answered from that send. Only then is it queued; a refusal (wrong job number, not allowed) still fails at once.
enum MaterialRequestSendRetry {
    enum Action: Equatable {
        case retry(after: TimeInterval)
        case queue
        case fail
    }

    enum Outcome: Equatable {
        case sent
        case queue
    }

    static let maxQuickRetries = 2
    /// A timeout already waited `MaterialRequestEmailPayload.requestTimeout`; retry it once only.
    static let maxTimeoutRetries = 1
    static let delays: [TimeInterval] = [0.5, 1.5]

    private static let transientURLCodes: Set<URLError.Code> = [
        .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]

    static func isTimeout(_ error: Error) -> Bool {
        // The function's own "not confirmed" (502 `unconfirmed`) is answered like a timeout: it may have gone.
        if let emailError = error as? MaterialRequestEmailError, emailError == .timedOut || emailError == .unconfirmed { return true }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        return false
    }

    /// A failure of the connection, not an answer from the function.
    static func isTransient(_ error: Error) -> Bool {
        if isTimeout(error) { return true }
        if error is MaterialRequestEmailError { return false }
        if let urlError = error as? URLError, transientURLCodes.contains(urlError.code) { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, transientURLCodes.contains(URLError.Code(rawValue: nsError.code)) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain,
           transientURLCodes.contains(URLError.Code(rawValue: underlying.code)) {
            return true
        }
        return OfflineWriteSupport.shouldQueue(error: error, isOnline: true)
    }

    /// `retriesSoFar` is how many quick retries have already been made for this press.
    /// `canRetry` is false for a request without a `requestId`: it is never sent again straight away (the old
    /// queue-or-fail answer applies), because the function could not tell the retry from a new send.
    static func action(after error: Error, isOnline: Bool, retriesSoFar: Int, canRetry: Bool = true) -> Action {
        if (error as? MaterialRequestEmailError) == .stillSending { return .queue }
        if !isOnline { return .queue }
        if canRetry, isTransient(error) {
            let limit = isTimeout(error) ? maxTimeoutRetries : maxQuickRetries
            if retriesSoFar < limit {
                return .retry(after: delays[min(retriesSoFar, delays.count - 1)])
            }
            // The connection is still failing after the quick retries: queue it (the next sync sends it with the same
            // request id). A timeout keeps its old answer below ("did not answer in time"): it may have been sent.
            if !isTimeout(error) { return .queue }
        }
        return OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) ? .queue : .fail
    }

    /// Runs `operation`, retrying it as `action` says. Throws the last error when the answer is `.fail`.
    static func perform(
        isOnline: Bool,
        canRetry: Bool = true,
        sleep: (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        operation: () async throws -> Void
    ) async throws -> Outcome {
        var retries = 0
        while true {
            do {
                try await operation()
                return .sent
            } catch {
                switch action(after: error, isOnline: isOnline, retriesSoFar: retries, canRetry: canRetry) {
                case .retry(let delay):
                    print("⚠️ [materials/send] connection problem, retrying (\(retries + 1)): \(error.localizedDescription)")
                    retries += 1
                    await sleep(delay)
                case .queue:
                    return .queue
                case .fail:
                    throw error
                }
            }
        }
    }
}
