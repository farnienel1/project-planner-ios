import SwiftUI
import PDFKit
import UIKit

/// Identifiable wrapper so remote certificate URLs can drive `.sheet(item:)`.
struct IdentifiableURL: Identifiable, Hashable {
    let id: String
    let url: URL

    init(_ url: URL) {
        self.url = url
        self.id = url.absoluteString
    }
}

/// Preview a remote or already-local PDF / image inside the app, with share/download.
struct InAppRemoteDocumentViewer: View {
    enum Source: Hashable {
        case remote(URL)
        case local(URL)

        var id: String {
            switch self {
            case .remote(let url): return "remote:" + url.absoluteString
            case .local(let url): return "local:" + url.path
            }
        }
    }

    let source: Source
    var title: String = "Certificate"
    var noun: String = "document"

    @Environment(\.dismiss) private var dismiss
    @State private var phase: LoadPhase = .loading
    @State private var localFileURL: URL?
    @State private var image: UIImage?
    @State private var shareItem: IdentifiableURL?

    private enum LoadPhase {
        case loading
        case readyPDF
        case readyImage
        case failed(String)
    }

    init(remoteURL: URL, title: String = "Certificate", noun: String = "certificate") {
        self.source = .remote(remoteURL)
        self.title = title
        self.noun = noun
    }

    init(localURL: URL, title: String = "Document", noun: String = "document") {
        self.source = .local(localURL)
        self.title = title
        self.noun = noun
    }

    init(source: Source, title: String, noun: String = "document") {
        self.source = source
        self.title = title
        self.noun = noun
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Loading \(noun)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .readyPDF:
                    if let localFileURL {
                        PDFKitRepresentedView(url: localFileURL)
                            .ignoresSafeArea(edges: .bottom)
                    }
                case .readyImage:
                    if let image {
                        ScrollView {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        }
                    }
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn’t open \(noun)",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let localFileURL {
                        Button {
                            shareItem = IdentifiableURL(localFileURL)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                HSDocumentActivityView(activityItems: [item.url])
            }
        }
        .task(id: source.id) {
            await loadDocument()
        }
    }

    @MainActor
    private func loadDocument() async {
        phase = .loading
        image = nil
        localFileURL = nil

        do {
            let data: Data
            let sourceURL: URL
            switch source {
            case .local(let url):
                sourceURL = url
                data = try Data(contentsOf: url)
            case .remote(let url):
                sourceURL = url
                let (fetched, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    phase = .failed("Server returned status \(http.statusCode).")
                    return
                }
                data = fetched
            }
            guard !data.isEmpty else {
                phase = .failed("The \(noun) file was empty.")
                return
            }

            let ext: String
            let lowerPath = sourceURL.pathExtension.lowercased()
            if lowerPath == "pdf" || isPDF(data) {
                ext = "pdf"
            } else if lowerPath == "png" {
                ext = "png"
            } else if ["jpg", "jpeg", "heic", "gif", "webp"].contains(lowerPath) {
                ext = lowerPath == "jpeg" ? "jpg" : lowerPath
            } else if UIImage(data: data) != nil {
                ext = "jpg"
            } else {
                ext = lowerPath.isEmpty ? "pdf" : lowerPath
            }

            let tempURL: URL
            switch source {
            case .local(let url):
                tempURL = url
            case .remote:
                tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hs-view-\(UUID().uuidString).\(ext)")
                try data.write(to: tempURL, options: .atomic)
            }
            localFileURL = tempURL

            if ext == "pdf" || isPDF(data) {
                guard PDFDocument(url: tempURL) != nil else {
                    phase = .failed("This file doesn’t look like a readable PDF.")
                    return
                }
                phase = .readyPDF
            } else if let uiImage = UIImage(data: data) {
                image = uiImage
                phase = .readyImage
            } else {
                phase = .failed("Unsupported \(noun) format. Use PDF or an image.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func isPDF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46
    }
}

struct HSDocumentActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
