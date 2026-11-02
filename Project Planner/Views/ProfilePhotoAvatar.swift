//
//  ProfilePhotoAvatar.swift
//  Project Planner
//
//  Profile photo from `users/{uid}.profilePhotoURL` (RULEBOOK §12).
//  - `profilePhotoUpdatedAt` is part of the cache key, so a new photo is fetched fresh instead of
//    showing the cached old one (the URL can stay the same after a re-upload to the same path).
//  - A re-upload issues a new download token, so an older copy of the URL answers 403. On a failed
//    load the avatar asks Storage once for the current download URL of the same path (as web
//    `UserAvatar` does).
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

    /// In-memory images for this run, keyed by URL and `profilePhotoUpdatedAt`.
    private static var memoryCache: [String: UIImage] {
        get { ProfilePhotoAvatarCache.images }
        set { ProfilePhotoAvatarCache.images = newValue }
    }

    private var trimmedURL: String {
        urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var cacheKey: String {
        let stamp = updatedAt.map { String(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "none"
        return "\(trimmedURL)#\(stamp)"
    }

    var body: some View {
        Group {
            if let image, loadedKey == cacheKey {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: cacheKey) {
            await load()
        }
    }

    private func load() async {
        let key = cacheKey
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            image = nil
            loadedKey = key
            return
        }
        if let cached = Self.memoryCache[key] {
            image = cached
            loadedKey = key
            return
        }
        // A known photo change skips the HTTP cache so the old picture is not shown again.
        let policy: URLRequest.CachePolicy = updatedAt == nil ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData
        var loaded = await Self.fetchImage(url: url, cachePolicy: policy)
        if loaded == nil, let fresh = await Self.currentDownloadURL(for: trimmedURL), fresh != url {
            loaded = await Self.fetchImage(url: fresh, cachePolicy: .reloadIgnoringLocalCacheData)
        }
        guard key == cacheKey else { return }
        if let loaded {
            Self.memoryCache[key] = loaded
        }
        image = loaded
        loadedKey = key
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

    private static func currentDownloadURL(for value: String) async -> URL? {
        #if canImport(FirebaseStorage)
        guard let path = storagePath(fromDownloadURL: value) else { return nil }
        return try? await Storage.storage().reference(withPath: path).downloadURL()
        #else
        return nil
        #endif
    }
}

/// Process-wide store behind `ProfilePhotoAvatar.memoryCache` (generic types cannot hold static stored properties).
enum ProfilePhotoAvatarCache {
    static var images: [String: UIImage] = [:]
}
