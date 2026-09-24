import SwiftUI
import UIKit

enum HSImportedFile {
    /// Copies a security-scoped importer URL into a stable temp file the upload can read later.
    static func persist(_ url: URL) -> (url: URL, name: String)? {
        let name = url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-import-\(UUID().uuidString)-\(name)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return (dest, name)
        } catch {
            return nil
        }
    }
}

struct HSDocumentPreviewItem: Identifiable, Hashable {
    let id: String
    let title: String
    let source: InAppRemoteDocumentViewer.Source
    let noun: String

    init(title: String, remoteURL: URL, noun: String = "document") {
        self.id = "remote:" + remoteURL.absoluteString
        self.title = title
        self.source = .remote(remoteURL)
        self.noun = noun
    }

    init(title: String, localURL: URL, noun: String = "document") {
        self.id = "local:" + localURL.path
        self.title = title
        self.source = .local(localURL)
        self.noun = noun
    }
}

struct HSRamsDocumentDetailView: View {
    let document: HSRamsDocument
    var onSendForSignatures: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var preview: HSDocumentPreviewItem?
    @State private var shareURL: IdentifiableURL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HSMetric.rowGap) {
                    HStack(alignment: .top, spacing: 12) {
                        HSIconTile(systemName: "doc.richtext.fill", tint: HS.blue, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title)
                                .font(HSFont.cardTitleLg)
                                .foregroundStyle(HS.ink)
                                .hsNoClip(3)
                            Text(document.fileName ?? "RAMS document")
                                .font(HSFont.meta)
                                .foregroundStyle(HS.slate)
                                .hsNoClip(2)
                        }
                        Spacer(minLength: 6)
                        HSBadge(text: document.status.capitalized, tone: .ok, icon: "checkmark.circle.fill")
                    }
                    .hsCard()

                    VStack(alignment: .leading, spacing: 10) {
                        HSSectionHeader(title: "Form details")
                        detailRow("Trade / area", document.trade)
                        detailRow("Version", "v\(document.version)")
                        detailRow("Status", document.status.capitalized)
                        detailRow("Uploaded", document.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                        if let reviewDate = document.reviewDate {
                            detailRow("Review date", reviewDate.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let fileName = document.fileName, !fileName.isEmpty {
                            detailRow("File", fileName)
                        }
                    }
                    .hsCard()

                    if document.storedFileURL == nil {
                        HSEmptyState(
                            icon: "doc.badge.ellipsis",
                            title: "No file attached",
                            message: "This RAMS record has details but no uploaded file to preview."
                        )
                    } else {
                        VStack(spacing: 10) {
                            Button {
                                HSHaptic.tap()
                                if let url = document.storedFileURL {
                                    preview = HSDocumentPreviewItem(title: document.title, remoteURL: url, noun: "RAMS")
                                }
                            } label: {
                                Label("Preview RAMS", systemImage: "eye.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(HSFilledButton(tone: .blue))

                            Button {
                                HSHaptic.tap()
                                shareDocument()
                            } label: {
                                Label("Download / share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(HSGhostButton(tint: HS.blue))
                        }
                    }

                    if let onSendForSignatures {
                        Button {
                            HSHaptic.tap()
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onSendForSignatures()
                            }
                        } label: {
                            Label("Send for signatures", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HSFilledButton(tone: .teal))
                    }
                }
                .padding(.horizontal, HSMetric.screenPad)
                .padding(.vertical, 16)
            }
            .hsScreen()
            .navigationTitle("RAMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $preview) { item in
                InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
            }
            .sheet(item: $shareURL) { item in
                HSDocumentActivityView(activityItems: [item.url])
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(HSFont.sectionLabel)
                .tracking(0.7)
                .foregroundStyle(HS.slate2)
            Text(value)
                .font(HSFont.body)
                .foregroundStyle(HS.ink)
                .hsNoClip(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shareDocument() {
        guard let url = document.storedFileURL else { return }
        Task {
            if let local = await HSRemoteFileCache.download(url, suggestedName: document.fileName ?? "RAMS.pdf") {
                await MainActor.run { shareURL = IdentifiableURL(local) }
            }
        }
    }
}

struct HSOtherDocumentDetailView: View {
    let document: HSOtherDocument
    @Environment(\.dismiss) private var dismiss
    @State private var preview: HSDocumentPreviewItem?
    @State private var shareURL: IdentifiableURL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HSMetric.rowGap) {
                    HStack(alignment: .top, spacing: 12) {
                        HSIconTile(systemName: "folder.fill", tint: HS.navy, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title)
                                .font(HSFont.cardTitleLg)
                                .foregroundStyle(HS.ink)
                                .hsNoClip(3)
                            Text(document.fileName ?? "H&S document")
                                .font(HSFont.meta)
                                .foregroundStyle(HS.slate)
                                .hsNoClip(2)
                        }
                        Spacer(minLength: 6)
                    }
                    .hsCard()

                    VStack(alignment: .leading, spacing: 10) {
                        HSSectionHeader(title: "Form details")
                        detailRow("Trade", document.trade ?? "General")
                        detailRow("Category", document.category.replacingOccurrences(of: "_", with: " ").capitalized)
                        detailRow("Uploaded", document.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                        detailRow("Issuable to client", document.issuableToClient ? "Yes" : "No")
                        if let fileName = document.fileName, !fileName.isEmpty {
                            detailRow("File", fileName)
                        }
                    }
                    .hsCard()

                    if document.storedFileURL == nil {
                        HSEmptyState(
                            icon: "doc.badge.ellipsis",
                            title: "No file attached",
                            message: "This document has details but no uploaded file to preview."
                        )
                    } else {
                        VStack(spacing: 10) {
                            Button {
                                HSHaptic.tap()
                                if let url = document.storedFileURL {
                                    preview = HSDocumentPreviewItem(title: document.title, remoteURL: url, noun: "document")
                                }
                            } label: {
                                Label("Preview document", systemImage: "eye.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(HSFilledButton(tone: .blue))

                            Button {
                                HSHaptic.tap()
                                shareDocument()
                            } label: {
                                Label("Download / share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(HSGhostButton(tint: HS.blue))
                        }
                    }
                }
                .padding(.horizontal, HSMetric.screenPad)
                .padding(.vertical, 16)
            }
            .hsScreen()
            .navigationTitle("H&S document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $preview) { item in
                InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
            }
            .sheet(item: $shareURL) { item in
                HSDocumentActivityView(activityItems: [item.url])
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(HSFont.sectionLabel)
                .tracking(0.7)
                .foregroundStyle(HS.slate2)
            Text(value)
                .font(HSFont.body)
                .foregroundStyle(HS.ink)
                .hsNoClip(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shareDocument() {
        guard let url = document.storedFileURL else { return }
        Task {
            if let local = await HSRemoteFileCache.download(url, suggestedName: document.fileName ?? "HS-Document.pdf") {
                await MainActor.run { shareURL = IdentifiableURL(local) }
            }
        }
    }
}

/// Manager tracking page for a custom uploaded toolbox talk: signatures PDF preview / download.
struct HSCustomSignedTalkView: View {
    let talk: HSToolboxTalk
    let issue: HSToolboxIssue
    let signatures: [HSToolboxSignature]
    let users: [AppUser]

    @Environment(\.dismiss) private var dismiss
    @State private var preview: HSDocumentPreviewItem?
    @State private var shareURL: IdentifiableURL?
    @State private var generatedURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HSMetric.rowGap) {
                    VStack(alignment: .leading, spacing: 8) {
                        HSBadge(text: "Custom talk", tone: .scheduled, icon: "arrow.up.doc.fill")
                        Text(talk.title)
                            .font(HSFont.heroTitle)
                            .foregroundStyle(HS.ink)
                            .hsNoClip(3)
                        Text(talk.tradeLabel)
                            .font(HSFont.meta)
                            .foregroundStyle(HS.blue)
                        if !talk.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(talk.purpose)
                                .font(HSFont.body)
                                .foregroundStyle(HS.slate)
                                .hsNoClip(6)
                        }
                        Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate2)
                    }
                    .hsCard()

                    HSSectionHeader(title: "Acknowledgements")

                    let signed = signatures.filter { $0.status == .signed }
                    let pending = signatures.filter { $0.status != .signed }

                    if signed.isEmpty && pending.isEmpty {
                        HSEmptyState(icon: "checkmark.seal", title: "No signatures yet", message: "Signatures will appear here once operatives sign this custom talk.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(signed, id: \.id) { signature in
                                signatureBlock(signature, pending: false)
                                if signature.id != signed.last?.id || !pending.isEmpty {
                                    HSDivider()
                                }
                            }
                            ForEach(pending, id: \.id) { signature in
                                signatureBlock(signature, pending: true)
                                if signature.id != pending.last?.id {
                                    HSDivider()
                                }
                            }
                        }
                        .hsCard(padding: 12)
                    }

                    VStack(spacing: 10) {
                        Button {
                            HSHaptic.tap()
                            presentGenerated(preview: true)
                        } label: {
                            Label("Preview signature PDF", systemImage: "eye.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HSFilledButton(tone: .blue))

                        Button {
                            HSHaptic.tap()
                            presentGenerated(preview: false)
                        } label: {
                            Label("Download / share PDF", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HSGhostButton(tint: HS.blue))
                    }
                }
                .padding(.horizontal, HSMetric.screenPad)
                .padding(.vertical, 16)
            }
            .hsScreen()
            .navigationTitle("Signed toolbox talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $preview) { item in
                InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
            }
            .sheet(item: $shareURL) { item in
                HSDocumentActivityView(activityItems: [item.url])
            }
        }
        .onAppear {
            generatedURL = HSCustomSignedTalkPDFBuilder.makePDF(
                talk: talk,
                issue: issue,
                signatures: signatures,
                userLookup: users
            )
        }
    }

    @ViewBuilder
    private func signatureBlock(_ signature: HSToolboxSignature, pending: Bool) -> some View {
        let user = users.first(where: { $0.id == signature.userId })
        let name = (user?.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user?.fullName : user?.email) ?? signature.userId
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(HSFont.cardTitle)
                    .foregroundStyle(HS.ink)
                    .hsNoClip(1)
                Spacer()
                HSBadge(text: pending ? "Awaiting" : "Signed", tone: pending ? .warn : .ok)
            }
            if !pending,
               let b64 = signature.signatureImageBase64,
               let data = Data(base64Encoded: b64),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 90)
                    .background(HS.bgDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let signedAt = signature.signedAt {
                Text("\(HSTalkSignatureTimestamp.dateLine(signedAt))  ·  \(HSTalkSignatureTimestamp.timeLine(signedAt))")
                    .font(HSFont.meta)
                    .foregroundStyle(HS.slate2)
            }
        }
        .padding(.vertical, 8)
    }

    private func presentGenerated(preview: Bool) {
        let url = generatedURL ?? HSCustomSignedTalkPDFBuilder.makePDF(
            talk: talk,
            issue: issue,
            signatures: signatures,
            userLookup: users
        )
        guard let url else { return }
        generatedURL = url
        if preview {
            self.preview = HSDocumentPreviewItem(title: "\(talk.title) signatures", localURL: url, noun: "signature PDF")
        } else {
            shareURL = IdentifiableURL(url)
        }
    }
}

enum HSRemoteFileCache {
    static func download(_ remoteURL: URL, suggestedName: String) async -> URL? {
        do {
            let (data, _) = try await URLSession.shared.data(from: remoteURL)
            guard !data.isEmpty else { return nil }
            let ext = remoteURL.pathExtension.isEmpty ? (suggestedName as NSString).pathExtension : remoteURL.pathExtension
            let base = (suggestedName as NSString).deletingPathExtension
            let fileName = "\(base.isEmpty ? "document" : base)-\(Int(Date().timeIntervalSince1970)).\(ext.isEmpty ? "pdf" : ext)"
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }
}

/// Branded signature sheet for custom toolbox talks — title, what the talk was, name, signature, date/time.
enum HSCustomSignedTalkPDFBuilder {
    static func makePDF(
        talk: HSToolboxTalk,
        issue: HSToolboxIssue,
        signatures: [HSToolboxSignature],
        userLookup: [AppUser]
    ) -> URL? {
        let safeName = talk.title.replacingOccurrences(of: " ", with: "_")
        let fileName = "CustomTBT-Signatures-\(safeName)-\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let orgBadge = HSDocumentOrgBadge.currentDisplay

        let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
        let cyan = UIColor(red: 0.169, green: 0.733, blue: 0.937, alpha: 1)
        let amber = UIColor(red: 0.902, green: 0.624, blue: 0.161, alpha: 1)
        let ink = UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1)
        let slate = UIColor(red: 0.357, green: 0.42, blue: 0.5, alpha: 1)
        let line = UIColor(red: 0.902, green: 0.933, blue: 0.961, alpha: 1)
        let signatureInk = UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1)

        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()

                navy.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: pageRect.width, height: 92))
                amber.setFill()
                UIRectFill(CGRect(x: 0, y: 92, width: pageRect.width, height: 4))
                ("PROJECT " as NSString).draw(at: CGPoint(x: 26, y: 28), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor.white
                ])
                ("PLANNER" as NSString).draw(at: CGPoint(x: 88, y: 28), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: cyan
                ])
                drawOrganizationDocumentBadgePDF(text: orgBadge, in: CGRect(x: 168, y: 24, width: 50, height: 36))
                ("CUSTOM TOOLBOX TALK — SIGNATURES" as NSString).draw(at: CGPoint(x: 26, y: 48), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor(red: 0.62, green: 0.70, blue: 0.81, alpha: 1)
                ])
                ("REF" as NSString).draw(at: CGPoint(x: pageRect.width - 126, y: 24), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: UIColor(red: 0.5, green: 0.6, blue: 0.72, alpha: 1)
                ])
                (talk.id as NSString).draw(at: CGPoint(x: pageRect.width - 126, y: 40), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: UIColor.white
                ])

                let margin: CGFloat = 26
                var y: CGFloat = 114

                (talk.title as NSString).draw(
                    with: CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: 56),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                        .foregroundColor: ink
                    ],
                    context: nil
                )
                y += 50

                func sectionTitle(_ title: String) {
                    (title.uppercased() as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: cyan
                    ])
                    y += 16
                    line.setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: 2))
                    y += 10
                }

                sectionTitle("What this talk is")
                let meta = "Trade: \(talk.tradeLabel)    W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))"
                (meta as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: slate
                ])
                y += 22

                let purpose = talk.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
                if !purpose.isEmpty {
                    let purposeRect = CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: 72)
                    (purpose as NSString).draw(
                        with: purposeRect,
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                            .foregroundColor: ink
                        ],
                        context: nil
                    )
                    y += 78
                }

                sectionTitle("Signatures & acknowledgements")

                let sorted = signatures.sorted { lhs, rhs in
                    switch (lhs.signedAt, rhs.signedAt) {
                    case let (l?, r?): return l < r
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return lhs.userId < rhs.userId
                    }
                }

                for signature in sorted {
                    if y > pageRect.height - 160 {
                        pdf.beginPage()
                        y = 32
                    }
                    let user = userLookup.first(where: { $0.id == signature.userId })
                    let name = (user?.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user?.fullName : user?.email) ?? signature.userId
                    let trade = user?.displayTradeType == "—" ? "" : (user?.displayTradeType ?? "")
                    let rowH: CGFloat = 92
                    let rowRect = CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: rowH)
                    UIColor(red: 0.965, green: 0.976, blue: 0.988, alpha: 1).setFill()
                    UIBezierPath(roundedRect: rowRect, cornerRadius: 10).fill()
                    line.setStroke()
                    UIBezierPath(roundedRect: rowRect, cornerRadius: 10).stroke()

                    (name as NSString).draw(at: CGPoint(x: margin + 12, y: y + 10), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: ink
                    ])
                    if !trade.isEmpty {
                        (trade as NSString).draw(at: CGPoint(x: margin + 12, y: y + 28), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 11),
                            .foregroundColor: slate
                        ])
                    }
                    HSTalkSignatureTimestamp.draw(
                        signature.status == .signed ? signature.signedAt : nil,
                        awaiting: "Awaiting signature",
                        in: CGRect(x: margin + 12, y: y + 46, width: pageRect.width - margin * 2 - 230, height: 36),
                        color: signature.status == .signed ? slate : amber,
                        font: UIFont.systemFont(ofSize: 10.5, weight: .medium)
                    )

                    let sigRect = CGRect(x: pageRect.width - margin - 210, y: y + 10, width: 198, height: 72)
                    UIColor.white.setFill()
                    UIBezierPath(roundedRect: sigRect, cornerRadius: 8).fill()
                    if signature.status == .signed,
                       let b64 = signature.signatureImageBase64,
                       let data = Data(base64Encoded: b64),
                       let img = UIImage(data: data) {
                        img.draw(in: sigRect.insetBy(dx: 6, dy: 6))
                    } else {
                        signatureInk.withAlphaComponent(0.15).setFill()
                        UIRectFill(CGRect(x: sigRect.minX + 12, y: sigRect.midY, width: sigRect.width - 24, height: 1))
                    }

                    y += rowH + 10
                }

                let signedCount = sorted.filter { $0.status == .signed }.count
                ("\(signedCount) of \(max(sorted.count, 1)) operatives signed." as NSString).draw(at: CGPoint(x: margin, y: y + 4), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: slate
                ])

                let footerY = pageRect.height - 26
                line.setFill()
                UIRectFill(CGRect(x: margin, y: footerY - 8, width: pageRect.width - margin * 2, height: 1))
                ("Generated by Project Planner · \(talk.id) · custom talk signatures" as NSString).draw(at: CGPoint(x: margin, y: footerY), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: UIColor(red: 0.604, green: 0.651, blue: 0.706, alpha: 1)
                ])
            }
            return url
        } catch {
            return nil
        }
    }
}
