//
//  ProfilePhotoAvatar.swift
//  Project Planner
//
//  Profile photo from `users/{uid}.profilePhotoURL` (RULEBOOK §12). Display and caching only:
//  nothing here writes or clears the stored photo.
//  - `profilePhotoUpdatedAt` is part of the cache key, so a new photo is fetched fresh instead of
//    showing the cached old one (the URL can stay the same after a re-upload to the same path).
//  - A re-upload issues a new download token, so an older copy of the URL answers 403. On a failed
//    load the avatar asks Storage for the current download URL of the same path (as web
//    `UserAvatar` does) and remembers it for every avatar showing that photo.
//  - A failed load is never final: it is retried after a delay (`ProfilePhotoAvatarRetry`), when the
//    app becomes active again, and whenever the URL or `profilePhotoUpdatedAt` changes.
//  - While a new photo loads, the picture already on screen stays (no flash of initials); a load the
//    system cancelled (the view left the screen) is not counted as a failure.
//

import SwiftUI
import UIKit
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

struct ProfilePhotoAvatar<Placeholder: View>: View {
    let urlString: String?
    let updatedAt: Date?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedKey: String?
    @State private var failedKey: String?
    @State private var retryRound = 0
    @State private var failures = 0
    @State private var failuresForKey: String?

    private var trimmedURL: String {
        urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The photo: URL and `profilePhotoUpdatedAt`.
    private var cacheKey: String {
        ProfilePhotoAvatarRetry.cacheKey(url: trimmedURL, updatedAt: updatedAt)
    }

    /// One load attempt: the photo plus the retry round, so a retry is a new `.task` id.
    private var attemptKey: String {
        "\(cacheKey)#\(retryRound)"
    }

    var body: some View {
        Group {
            if let image, !trimmedURL.isEmpty, failedKey != cacheKey || loadedKey == cacheKey {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: attemptKey) {
            await load()
        }
        .task(id: "\(failedKey ?? "")#\(failures)") {
            await retryAfterDelay()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if failedKey == cacheKey { retryRound += 1 }
        }
    }

    private func load() async {
        let key = cacheKey
        if failuresForKey != key {
            failuresForKey = key
            failures = 0
        }
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            image = nil
            loadedKey = key
            failedKey = nil
            return
        }
        if let cached = ProfilePhotoAvatarCache.image(for: key) {
            image = cached
            loadedKey = key
            failedKey = nil
            return
        }
        // A known photo change skips the HTTP cache so the old picture is not shown again.
        let policy: URLRequest.CachePolicy = updatedAt == nil ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData
        let start = ProfilePhotoAvatarCache.currentURL(for: trimmedURL) ?? url
        var loaded = await Self.fetchImage(url: start, cachePolicy: policy)
        if loaded == nil, !Task.isCancelled, let fresh = await Self.currentDownloadURL(for: trimmedURL), fresh != start {
            loaded = await Self.fetchImage(url: fresh, cachePolicy: .reloadIgnoringLocalCacheData)
            if loaded != nil { ProfilePhotoAvatarCache.setCurrentURL(fresh, for: trimmedURL) }
        }
        // The view left the screen or a newer photo arrived: this attempt decides nothing.
        guard !Task.isCancelled, key == cacheKey else { return }
        if let loaded {
            ProfilePhotoAvatarCache.store(loaded, for: key)
            image = loaded
            loadedKey = key
            failedKey = nil
            failures = 0
        } else {
            failedKey = key
            failures += 1
        }
    }

    private func retryAfterDelay() async {
        guard failedKey == cacheKey, let delay = ProfilePhotoAvatarRetry.delay(afterFailures: failures) else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled, failedKey == cacheKey else { return }
        retryRound += 1
    }

    private static func fetchImage(url: URL, cachePolicy: URLRequest.CachePolicy) async -> UIImage? {
        let request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 20)
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return UIImage(data: data)
    }

    /// The object path in a Firebase Storage download URL
    /// (`https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{encoded path}?alt=media&token=…`).
    static func storagePath(fromDownloadURL value: String) -> String? {
        ProfilePhotoAvatarRetry.storagePath(fromDownloadURL: value)
    }

    private static func currentDownloadURL(for value: String) async -> URL? {
        #if canImport(FirebaseStorage)
        guard let path = ProfilePhotoAvatarRetry.storagePath(fromDownloadURL: value) else { return nil }
        return try? await Storage.storage().reference(withPath: path).downloadURL()
        #else
        return nil
        #endif
    }
}

/// Keys, Storage paths and retry waits for `ProfilePhotoAvatar` (pure, unit-tested).
nonisolated enum ProfilePhotoAvatarRetry {
    /// Waits before the automatic retries after a failed load (as web `AVATAR_RETRY_DELAYS_MS`). After the last
    /// one, only the app becoming active or a new URL / `profilePhotoUpdatedAt` retries.
    static let delays: [TimeInterval] = [5, 30, 120]

    static func delay(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }

    /// The URL with `profilePhotoUpdatedAt` in milliseconds ("none" when missing).
    static func cacheKey(url: String, updatedAt: Date?) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = updatedAt.map { String(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "none"
        return "\(trimmed)#\(stamp)"
    }

    /// The object path in a Firebase Storage download URL.
    static func storagePath(fromDownloadURL value: String) -> String? {
        let prefix = "https://firebasestorage.googleapis.com/v0/b/"
        guard value.hasPrefix(prefix) else { return nil }
        let rest = value.dropFirst(prefix.count)
        guard let objectMarker = rest.range(of: "/o/") else { return nil }
        var encoded = rest[objectMarker.upperBound...]
        if let end = encoded.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            encoded = encoded[..<end]
        }
        let path = String(encoded).removingPercentEncoding ?? String(encoded)
        return path.isEmpty ? nil : path
    }
}

/// Process-wide store behind `ProfilePhotoAvatar` (generic types cannot hold static stored properties).
/// Main-actor only: SwiftUI `.task` bodies run there.
enum ProfilePhotoAvatarCache {
    static var images: [String: UIImage] = [:]
    /// Stored URL → the current download URL Storage gave after the stored one failed (a newer token).
    static var currentURLs: [String: URL] = [:]

    static func image(for key: String) -> UIImage? { images[key] }
    static func store(_ image: UIImage, for key: String) { images[key] = image }
    static func currentURL(for stored: String) -> URL? { currentURLs[stored] }
    static func setCurrentURL(_ url: URL, for stored: String) { currentURLs[stored] = url }
}
