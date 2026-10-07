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
    @State private var statusError: String?
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
                        .accessibilityIdentifier("variationDetail.edit")
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
                .accessibilityIdentifier("variationDetail.markSubmitted")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("variationDetail.cancel")
        } message: {
            Text("This variation has gone to the client and its number will be locked.")
        }
        .alert("Could not update status", isPresented: Binding(
            get: { statusError != nil },
            set: { if !$0 { statusError = nil } }
        )) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("variationDetail.statusOk")
        } message: {
            Text(statusError ?? "")
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            HStack(spacing: 8) {
                ForEach(VariationStatus.allCases, id: \.self) { status in
                    Button {
                        guard canEdit, status != variation.status else { return }
                        if status == .submitted {
                            confirmSubmitted = true
                        } else {
                            Task { await applyStatus(status) }
                        }
                    } label: {
                        Text(status.title)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(variation.status == status ? .white : ProjectWorksRevampColors.ink)
                            .background(variation.status == status ? headerColor(status) : ProjectWorksRevampColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(headerColor(status).opacity(variation.status == status ? 0 : 0.45), lineWidth: 1)
                            )
                    }
                    .accessibilityIdentifier("variationDetail.status.\(status.rawValue)")
                    .buttonStyle(.plain)
                    .disabled(!canEdit || status == variation.status)
                }
            }
            .accessibilityIdentifier("variationDetail.status")
            Text(canEdit
                 ? "An admin, or a manager assigned to this job, can mark it submitted or closed."
                 : "Only an admin, or a manager assigned to this job, can change the status.")
                .font(.caption)
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
    }

    private func applyStatus(_ status: VariationStatus) async {
        guard var variation else { return }
        let orgId = (await firebaseBackend.resolveOrganizationIdForFirebaseWrites(
            preferredFallback: firebaseBackend.currentOrganization?.firestoreDocumentId
        )) ?? ""
        guard !orgId.isEmpty else {
            statusError = "The organisation is still loading. Wait a moment and try again."
            return
        }
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
            statusError = error.localizedDescription
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
        .accessibilityIdentifier("variationDetail.pdf")
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
