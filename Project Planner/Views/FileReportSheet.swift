//
//  FileReportSheet.swift
//  Project Planner
//
//  "Report a problem with this file". Reasons, labels, limits and the document come from the
//  rulebook (`fileReports.ts`); this file is layout only.
//

import SwiftUI

/// Menu item for a context menu or "…" menu. Hidden when the rulebook has no label or the file
/// reference is not a Storage file (for example a preview before upload).
struct FileReportMenuButton: View {
    let target: FileReportTarget
    @Binding var presented: FileReportTarget?

    var body: some View {
        if let label = CanonicalBusinessEngine.fileReportLinkLabel,
           CanonicalBusinessEngine.fileReportStoragePath(target.fileRef) != nil {
            Button {
                presented = target
            } label: {
                Label(label, systemImage: "exclamationmark.bubble")
            }
        }
    }
}

extension View {
    /// Presents the report sheet for whichever file `target` is set to.
    func fileReportSheet(_ target: Binding<FileReportTarget?>) -> some View {
        sheet(item: target) { item in
            FileReportSheet(target: item)
        }
    }

    /// Long-press menu with only the report item, for a photo or file someone else uploaded.
    func fileReportContextMenu(_ target: FileReportTarget, presented: Binding<FileReportTarget?>) -> some View {
        contextMenu {
            FileReportMenuButton(target: target, presented: presented)
        }
    }
}

struct FileReportSheet: View {
    let target: FileReportTarget

    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var reason: String?
    @State private var details = ""
    @State private var isSending = false
    @State private var failed = false
    @State private var sent = false

    private var reasons: [String] { CanonicalBusinessEngine.fileReportReasons ?? [] }
    private var detailsMax: Int { CanonicalBusinessEngine.fileReportDetailsMax ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if sent {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green)
                        Text(CanonicalBusinessEngine.fileReportSentCopy ?? "")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    form
                }
            }
            .navigationTitle("Report this file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !sent {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSending)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSending ? "Sending…" : "Send report") { send() }
                            .disabled(reason == nil || isSending)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSending)
    }

    private var form: some View {
        Form {
            Section {
                ForEach(reasons, id: \.self) { code in
                    Button {
                        reason = code
                    } label: {
                        HStack {
                            Text(CanonicalBusinessEngine.fileReportReasonCopy(code) ?? code)
                                .foregroundStyle(.primary)
                            Spacer()
                            if reason == code {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .tint(.primary)
                    .accessibilityAddTraits(reason == code ? .isSelected : [])
                }
            } header: {
                Text("An admin in your company will review it.")
                    .textCase(nil)
            }

            Section("Details (optional)") {
                TextField("", text: $details, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: details) { _, newValue in
                        if detailsMax > 0, newValue.count > detailsMax {
                            details = String(newValue.prefix(detailsMax))
                        }
                    }
            }

            if failed {
                Section {
                    Text("The report could not be sent. Try again.")
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(isSending)
    }

    private func send() {
        guard let reason else { return }
        isSending = true
        failed = false
        Task {
            do {
                try await firebaseBackend.submitFileReport(target, reason: reason, details: details)
                isSending = false
                sent = true
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            } catch {
                isSending = false
                failed = true
            }
        }
    }
}
