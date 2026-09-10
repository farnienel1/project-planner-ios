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

/// In-app preview for qualification certificates (PDF / JPEG) stored in Firebase Storage.
/// Fetches into a temp file and renders inside the app — does not hand off to Safari / Files.
struct InAppRemoteDocumentViewer: View {
    let remoteURL: URL
    var title: String = "Certificate"

    @Environment(\.dismiss) private var dismiss
    @State private var phase: LoadPhase = .loading
    @State private var localFileURL: URL?
    @State private var image: UIImage?

    private enum LoadPhase {
        case loading
        case readyPDF
        case readyImage
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Loading certificate…")
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
                        "Couldn’t open certificate",
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
            }
        }
        .task(id: remoteURL.absoluteString) {
            await loadDocument()
        }
    }

    @MainActor
    private func loadDocument() async {
        phase = .loading
        image = nil
        localFileURL = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                phase = .failed("Server returned status \(http.statusCode).")
                return
            }
            guard !data.isEmpty else {
                phase = .failed("The certificate file was empty.")
                return
            }

            let ext: String
            let lowerPath = remoteURL.pathExtension.lowercased()
            if lowerPath == "pdf" || isPDF(data) {
                ext = "pdf"
            } else if lowerPath == "png" {
                ext = "png"
            } else {
                ext = "jpg"
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qual-view-\(UUID().uuidString).\(ext)")
            try data.write(to: tempURL, options: .atomic)
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
                phase = .failed("Unsupported certificate format. Use PDF or JPEG.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func isPDF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // %PDF
        return data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46
    }
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
