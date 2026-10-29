//
//  VariationDetailView.swift
//  Project Planner
//

import SwiftUI
import FirebaseAuth

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
    @State private var reportTarget: FileReportTarget?

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
                    VStack(alignment: .leading, spacing: 0) {
                        header(variation)

                        VStack(alignment: .leading, spacing: 0) {
                            statusControl(variation)
                                .padding(16)
                                .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                                .padding(.top, 16)
                            Text(variation.status.definition)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 10)

                            sectionTitle("Labour · \(formatHours(variation.totalLabourHours)) hrs")
                            PPGroupedCard {
                                if variation.labour.isEmpty {
                                    Text("No labour logged")
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                } else {
                                    ForEach(variation.labour) { row in
                                        HStack(spacing: 13) {
                                            PPIconTile(symbol: "person.fill", family: .people)
                                            Text(row.trade)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Text(formatHours(row.hours) + " hrs")
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                        .font(.subheadline)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 50)
                                    }
                                }
                            }

                            sectionTitle("Materials")
                            PPGroupedCard {
                                if variation.materials.isEmpty {
                                    Text("No materials")
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                } else {
                                    ForEach(variation.materials) { row in
                                        HStack(spacing: 13) {
                                            PPIconTile(symbol: "shippingbox.fill", family: .trade)
                                            Text(row.name)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Text(row.quantity).foregroundStyle(.secondary)
                                        }
                                        .font(.subheadline)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 50)
                                    }
                                }
                            }

                            sectionTitle("Evidence")
                            if variation.evidence.isEmpty {
                                Text("Please upload any supporting evidence here")
                                    .font(.subheadline)
                                    .foregroundStyle(PPColor.danger)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                                    ForEach(variation.evidence) { item in
                                        evidenceThumb(item)
                                    }
                                }
                            }

                            sectionTitle("History")
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(historyLines(variation), id: \.self) { line in
                                    Text(line)
                                        .font(.footnote)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(16)
                            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        }
                        .padding(.bottom, 28)
                        .ppContentSheet()
                    }
                }
                .background(PPColor.page.ignoresSafeArea())
            } else {
                ContentUnavailableView("Variation not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(variation?.voNumber ?? "Variation")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .fileReportSheet($reportTarget)
        .toolbar {
            if canEdit, variation != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showingEditor = true }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
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

    /// Navy header: VO number, origin and status pills, heading, description, and the variation's own totals.
    private func header(_ variation: Variation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PPOnNavyPill(text: variation.voNumber)
                if variation.origin == .tracker {
                    PPOnNavyPill(text: "From tracker", symbol: "list.bullet.rectangle")
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(headerColor(variation.status)).frame(width: 7, height: 7)
                    Text(variation.status.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(headerColor(variation.status).opacity(0.28)))
                .overlay(Capsule().strokeBorder(headerColor(variation.status).opacity(0.6), lineWidth: 0.5))
            }
            Text(variation.heading)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Text(variation.description)
                .font(.subheadline)
                .foregroundStyle(PPColor.onNavySecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: formatHours(variation.totalLabourHours), label: "Hours")
                PPStatDivider()
                PPStat(value: "\(variation.materialLineCount)", label: "Materials")
                PPStatDivider()
                PPStat(value: "\(variation.evidenceCount)", label: "Evidence", highlight: variation.evidenceCount == 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func statusControl(_ variation: Variation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status".uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
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
                            .foregroundStyle(variation.status == status ? Color.white : Color.primary)
                            .background(variation.status == status ? headerColor(status) : PPColor.well)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                .foregroundStyle(.secondary)
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
            VStack(spacing: 6) {
                PPIconTile(symbol: item.contentType.contains("pdf") ? "doc.fill" : "photo", family: .plan, size: 36)
                Text(item.fileName)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(8)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityIdentifier("variationDetail.pdf")
        .buttonStyle(.plain)
        .contextMenu {
            // Not on the viewer's own uploads, nor on files still uploading.
            if !item.isPending, item.uploadedByUid != firebaseBackend.currentUser?.uid {
                FileReportMenuButton(
                    target: FileReportTarget(
                        surface: "variation_evidence",
                        parentId: variationId,
                        fileRef: item.storagePath,
                        fileName: item.fileName
                    ),
                    presented: $reportTarget
                )
            }
        }
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
        PPSectionHeader(text)
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
