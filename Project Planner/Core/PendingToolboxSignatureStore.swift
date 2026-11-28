//
//  PendingToolboxSignatureStore.swift
//  Project Planner
//
//  A toolbox talk / RAMS signature made while offline, kept on this device until the server has it. Firestore queues
//  the signature write itself (`healthSafetySignatureWriteFields`, a field-path update plus `arrayUnion`) and sends
//  it when the connection returns; this store only makes sure the screen never shows a signature queued here as
//  unsigned (the server read cannot see it yet), and drops the entry once the server copy shows it, or says plainly
//  when the server never got it.
//
//  Only used when the rulebook allows signing offline (`offlineAvailability("health_safety.sign_toolbox_talk")`).
//  Today that action is not in `OFFLINE_ACTIONS`, so it is online only and nothing is stored here.
//

import Foundation

struct PendingToolboxSignature: Codable, Hashable {
    let organizationId: String
    let jobId: String
    let signature: HSToolboxSignature
    let queuedAt: Date

    /// One entry per org / job / issue / signer (signer id compared without case or spaces).
    var key: String {
        PendingToolboxSignature.key(organizationId: organizationId, jobId: jobId, issueId: signature.issueId, userId: signature.userId)
    }

    static func key(organizationId: String, jobId: String, issueId: String, userId: String) -> String {
        [organizationId, jobId, issueId, userId]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }
}

/// What a load does with the pending signatures of one job.
struct PendingToolboxSignatureOverlay: Equatable {
    /// The signatures to show: the loaded ones, with each pending signature laid over its row (or added).
    var signatures: [HSToolboxSignature]
    /// Keys still waiting for the server (shown "Signed — will sync when online").
    var stillPending: Set<String>
    /// Keys the server copy now shows signed: drop them.
    var confirmed: Set<String>
    /// Keys the server never got (online, and the loaded copy — which includes this device's queued writes — does not
    /// show them): drop them and tell the person to sign again.
    var lost: Set<String>
}

enum PendingToolboxSignatureRules {
    /// Lays `pending` over `loaded`. A loaded signature for the same issue and signer that is signed means the write
    /// reached Firestore (the read includes this device's queued writes, online or from the cache): `confirmed` when
    /// online, else still shown as pending sync. A loaded copy that is NOT signed while online means the write was
    /// lost or refused: `lost`, and the loaded (unsigned) row is shown — never a signature that is not stored.
    /// Offline, a pending signature is always shown signed.
    static func overlay(
        loaded: [HSToolboxSignature],
        pending: [PendingToolboxSignature],
        isOnline: Bool
    ) -> PendingToolboxSignatureOverlay {
        func idKey(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var signatures = loaded
        var stillPending: Set<String> = []
        var confirmed: Set<String> = []
        var lost: Set<String> = []
        for entry in pending {
            let mine = entry.signature
            let index = signatures.firstIndex {
                $0.issueId == mine.issueId && idKey($0.userId) == idKey(mine.userId)
            }
            let storedSigned = index.map { signatures[$0].isSigned } ?? false
            if storedSigned {
                if isOnline { confirmed.insert(entry.key) } else { stillPending.insert(entry.key) }
                continue
            }
            if isOnline {
                lost.insert(entry.key)
                continue
            }
            stillPending.insert(entry.key)
            if let index {
                signatures[index].status = mine.status
                signatures[index].readConfirmed = mine.readConfirmed
                signatures[index].signatureImageBase64 = mine.signatureImageBase64
                signatures[index].signedAt = mine.signedAt
            } else {
                signatures.insert(mine, at: 0)
            }
        }
        return PendingToolboxSignatureOverlay(signatures: signatures, stillPending: stillPending, confirmed: confirmed, lost: lost)
    }
}

/// Device storage (UserDefaults) for `PendingToolboxSignature`. A cache only (RULEBOOK §1): the signature itself is in
/// Firestore's own queue.
final class PendingToolboxSignatureStore {
    static let shared = PendingToolboxSignatureStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, storageKey: String = "pending_toolbox_signatures_v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func all() -> [PendingToolboxSignature] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    func entries(organizationId: String, jobId: String) -> [PendingToolboxSignature] {
        let org = organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let job = jobId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all().filter {
            $0.organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == org
                && $0.jobId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == job
        }
    }

    /// Adds or replaces the entry for that org / job / issue / signer.
    func add(_ entry: PendingToolboxSignature) {
        lock.lock(); defer { lock.unlock() }
        var list = read().filter { $0.key != entry.key }
        list.append(entry)
        write(list)
    }

    func remove(keys: Set<String>) {
        guard !keys.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        write(read().filter { !keys.contains($0.key) })
    }

    private func read() -> [PendingToolboxSignature] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PendingToolboxSignature].self, from: data)) ?? []
    }

    private func write(_ list: [PendingToolboxSignature]) {
        if list.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
