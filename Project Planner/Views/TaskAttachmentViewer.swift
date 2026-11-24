//
//  TaskAttachmentViewer.swift
//  Project Planner
//
//  RULEBOOK 1.89.0 §32 bug B8: a task attachment (photo or PDF) opens inside the app with Quick Look, never in
//  Safari at the raw Storage address. The file is fetched to a temporary file (Quick Look needs a local file), shown,
//  and can be shared or saved from Quick Look's own share button. Only `https` addresses are opened
//  (`CanonicalBusinessEngine.safeExternalURL`). Display only: nothing is written.
//

import QuickLook
import SwiftUI
import UIKit

/// One attachment to show.
struct TaskAttachmentViewerItem: Identifiable, Hashable {
    let url: String
    let title: String
    var id: String { url }
}

struct TaskAttachmentViewerSheet: View {
    let item: TaskAttachmentViewerItem

    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let localURL {
                    TaskQuickLookPreview(url: localURL)
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("This file can't be opened. Check your connection and try again.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Try again") {
                            failed = false
                            Task { await load() }
                        }
                        .accessibilityIdentifier("taskAttachmentViewer.retry")
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                } else {
                    ProgressView("Opening…")
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("taskAttachmentViewer.close")
                }
            }
        }
        .task { await load() }
        .onDisappear {
            if let localURL { try? FileManager.default.removeItem(at: localURL) }
        }
    }

    private func load() async {
        guard localURL == nil else { return }
        guard let remote = CanonicalBusinessEngine.safeExternalURL(item.url) else {
            failed = true
            return
        }
        do {
            let (temp, response) = try await URLSession.shared.download(from: remote)
            let ext = Self.fileExtension(remote: remote, mimeType: (response as? HTTPURLResponse)?.mimeType ?? response.mimeType)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("task-attachment-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.moveItem(at: temp, to: destination)
            localURL = destination
        } catch {
            failed = true
        }
    }

    /// Quick Look picks the viewer from the file extension: the Storage address's own, else from the content type.
    private static func fileExtension(remote: URL, mimeType: String?) -> String {
        let fromPath = remote.pathExtension.lowercased()
        if !fromPath.isEmpty, fromPath.count <= 5 { return fromPath }
        // A Firebase download URL keeps the object path percent-encoded in its last component.
        let decoded = remote.lastPathComponent.removingPercentEncoding ?? remote.lastPathComponent
        let fromDecoded = (decoded as NSString).pathExtension.lowercased()
        if !fromDecoded.isEmpty, fromDecoded.count <= 5 { return fromDecoded }
        switch (mimeType ?? "").lowercased() {
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }
}

/// `QLPreviewController` for one local file.
private struct TaskQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
