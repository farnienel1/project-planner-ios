//
//  VariationDetailView.swift
//  Project Planner
//

import SwiftUI

struct VariationDetailView: View {
    let project: Project
    let variationId: String
    @ObservedObject var store: VariationStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @State private var showingEditor = false
    @State private var confirmSubmitted = false
    @State private var pendingStatus: VariationStatus?
    @State private var fullscreenURL: URL?

    private var variation: Variation? {
        store.variations.first(where: { $0.id == variationId && !$0.isDeleted })
    }

    private var canEdit: Bool {
        WorkAccess.canAccessVariations(project: project, userStore: userStore, operativeStore: operativeStore)
    }

    var body: some View {
        Group {
            if let variation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(variation)
                        statusControl(variation)
                        Text(variation.status.definition)
                            .font(.footnote)
                            .foregroundStyle(ProjectWorksRevampColors.muted)

                        sectionTitle("Labour · \(formatHours(variation.totalLabourHours)) hrs")
                        if variation.labour.isEmpty {
                            Text("No labour logged").foregroundStyle(ProjectWorksRevampColors.muted)
                        } else {
                            ForEach(variation.labour) { row in
                                HStack {
                                    Text(row.trade)
                                    Spacer()
                                    Text(formatHours(row.hours) + " hrs")
                                }
                                .font(.subheadline)
                            }
                        }

                        sectionTitle("Materials")
                        if variation.materials.isEmpty {
                            Text("No materials").foregroundStyle(ProjectWorksRevampColors.muted)
                        } else {
                            ForEach(variation.materials) { row in
                                HStack {
                                    Text(row.name)
                                    Spacer()
                                    Text(row.quantity).foregroundStyle(ProjectWorksRevampColors.muted)
                                }
                                .font(.subheadline)
                            }
                        }

                        sectionTitle("Evidence")
                        if variation.evidence.isEmpty {
                            Text("Please upload any supporting evidence here")
                                .foregroundStyle(.red)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                                ForEach(variation.evidence) { item in
                                    evidenceThumb(item)
                                }
                            }
                        }

                        sectionTitle("History")
                        ForEach(historyLines(variation), id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                        }
                    }
                    .padding(16)
                }
                .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            } else {
                ContentUnavailableView("Variation not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(variation?.voNumber ?? "Variation")
        .toolbar {
            if canEdit, variation != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showingEditor = true }
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            VariationEditorSheet(project: project, existing: variation, store: store, materialNames: [])
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(notificationService)
        }
        .confirmationDialog("Submit to client?", isPresented: $confirmSubmitted, titleVisibility: .visible) {
            Button("Mark submitted") {
                Task { await applyStatus(.submitted) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This variation has gone to the client and its number will be locked.")
        }
        .sheet(item: Binding(
            get: { fullscreenURL.map { IdentifiableURL($0) } },
            set: { fullscreenURL = $0?.url }
        )) { item in
            VariationEvidenceViewer(url: item.url)
        }
    }

    private func header(_ variation: Variation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(variation.voNumber)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if variation.origin == .tracker {
                    Text("From tracker")
                        .font(.caption2.weight(.semibold))
                }
                Spacer()
                Text(variation.status.title)
                    .font(.caption.weight(.semibold))
            }
            Text(variation.heading)
                .font(.title3.weight(.bold))
            Text(variation.description)
                .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerColor(variation.status))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusControl(_ variation: Variation) -> some View {
        Picker("Status", selection: Binding(
            get: { variation.status },
            set: { newValue in
                if newValue == .submitted && variation.status != .submitted {
                    pendingStatus = newValue
                    confirmSubmitted = true
                } else {
                    Task { await applyStatus(newValue) }
                }
            }
        )) {
            ForEach(VariationStatus.allCases, id: \.self) { status in
                Text(status.title).tag(status)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!canEdit)
    }

    private func applyStatus(_ status: VariationStatus) async {
        guard var variation else { return }
        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
            ?? await firebaseBackend.resolveOrganizationIdForFirebaseWrites(preferredFallback: nil)
            ?? ""
        guard !orgId.isEmpty else { return }
        let uid = userStore.displayUser?.id ?? ""
        let name = userStore.displayUser?.fullName.isEmpty == false ? (userStore.displayUser?.fullName ?? "") : (userStore.displayUser?.email ?? "")
        variation.status = status
        variation.updatedAt = Date()
        variation.updatedByUid = uid
        variation.statusHistory.append(VariationStatusHistoryEntry(status: status.rawValue, byUid: uid, byName: name, at: Date()))
        if status == .submitted {
            variation.submittedAt = Date()
            variation.voNumberLocked = true
        }
        if status == .closed {
            variation.closedAt = Date()
        }
        do {
            try await firebaseBackend.saveVariation(variation, organizationId: orgId)
            store.upsert(variation)
        } catch {
            print("❌ [Variations] status save failed: \(error.localizedDescription)")
        }
    }

    private func evidenceThumb(_ item: VariationEvidenceItem) -> some View {
        Button {
            if let url = URL(string: item.downloadURL) { fullscreenURL = url }
        } label: {
            VStack {
                Image(systemName: item.contentType.contains("pdf") ? "doc.fill" : "photo")
                    .font(.title2)
                Text(item.fileName)
                    .font(.caption2)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(8)
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func historyLines(_ variation: Variation) -> [String] {
        var lines: [String] = []
        lines.append("Raised by \(variation.createdByName) on \(variation.createdAt.formatted(date: .abbreviated, time: .shortened))")
        for entry in variation.statusHistory where entry.status != VariationStatus.open.rawValue {
            let label = VariationStatus(rawValue: entry.status)?.title ?? entry.status
            lines.append("\(label) by \(entry.byName) on \(entry.at.formatted(date: .abbreviated, time: .shortened))")
        }
        for entry in variation.numberHistory {
            lines.append("\(entry.from) → \(entry.to)")
        }
        return lines
    }

    private func headerColor(_ status: VariationStatus) -> Color {
        switch status {
        case .open: return .orange
        case .submitted: return .green
        case .closed: return .red
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    private func formatHours(_ value: Double) -> String {
        String(format: abs(value - value.rounded()) < 0.05 ? "%.0f" : "%.1f", value)
    }
}

private struct VariationEvidenceViewer: View {
    let url: URL
    var body: some View {
        InAppRemoteDocumentViewer(source: .remote(url), title: "Evidence")
    }
}
