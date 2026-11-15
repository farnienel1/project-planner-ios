//
//  VariationsListView.swift
//  Project Planner
//

import SwiftUI

struct VariationsListView: View {
    let project: Project
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @StateObject private var store: VariationStore
    @State private var filter: VariationListFilter = .all
    @State private var showingEditor = false
    @State private var editingVariation: Variation?
    @State private var materialNames: [String] = []
    /// RULEBOOK 1.52.0 §22: the workbook to share (`variationExportRows`).
    @State private var exportFile: IdentifiableURL?
    @State private var exportError: String?

    private var parentType: VariationParentType {
        project.isSmallWorksDocument ? .smallWork : .project
    }

    init(project: Project) {
        self.project = project
        let type: VariationParentType = project.isSmallWorksDocument ? .smallWork : .project
        _store = StateObject(wrappedValue: VariationStore(parentId: project.documentId, parentType: type))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summaryCard

                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Status", selection: $filter) {
                            Text("All \(store.visibleVariations.count)").tag(VariationListFilter.all)
                            Text("Open \(count(for: .open))").tag(VariationListFilter.open)
                            Text("Submitted \(count(for: .submitted))").tag(VariationListFilter.submitted)
                            Text("Closed \(count(for: .closed))").tag(VariationListFilter.closed)
                        }
                        .accessibilityIdentifier("variationsList.status")
                        .pickerStyle(.segmented)
                        .padding(.top, 16)

                        if let status = filter.status {
                            Text(status.definition)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(PPColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        if filteredVariations.isEmpty {
                            ContentUnavailableView(
                                "No variations",
                                systemImage: "plus.rectangle.on.folder",
                                description: Text("Variations add up on a project, so capturing the materials and labour is key.")
                            )
                            .padding(.top, 24)
                        } else {
                            ForEach(filteredVariations) { variation in
                                NavigationLink {
                                    VariationDetailView(project: project, variationId: variation.id, store: store)
                                } label: {
                                    variationCard(variation)
                                }
                                .accessibilityIdentifier("variationsList.row.\(variation.id)")
                                .buttonStyle(.plain)
                            }
                        }

                        Color.clear.frame(height: canEditContent ? 88 : 16)
                    }
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())

            if canEditContent {
                VStack {
                    LinearGradient(colors: [Color.clear, PPColor.page], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                    Button {
                        editingVariation = nil
                        showingEditor = true
                    } label: {
                        Label("Add variation", systemImage: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(PPColor.brand, in: Capsule())
                            .shadow(color: PPColor.brand.opacity(0.28), radius: 10, x: 0, y: 5)
                    }
                    .buttonStyle(PPPressableButtonStyle())
                    .accessibilityIdentifier("variationsList.addVariation")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .background(PPColor.page.opacity(0.92).ignoresSafeArea(edges: .bottom))
            }
        }
        .navigationTitle("Variations")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    exportWorkbook()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("variationsList.export")
                .accessibilityLabel("Export variations to Excel")
                .disabled(store.visibleVariations.isEmpty)
            }
            if store.tracker.enabled {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        VariationTrackerReadOnlyView(store: store, parentName: VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName))
                    } label: {
                        Text("Tracker")
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                        .accessibilityIdentifier("variationsList.tracker")
                }
            }
        }
        .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
            guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
            store.start(firebaseBackend: firebaseBackend)
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
               let items = try? await firebaseBackend.loadMaterialCatalogue(organizationId: orgId) {
                materialNames = items.map(\.name).filter { !$0.isEmpty }
            }
        }
        .onChange(of: firebaseBackend.currentOrganization?.firestoreDocumentId) { _, _ in
            store.start(firebaseBackend: firebaseBackend)
        }
        .onDisappear { store.stop() }
        .sheet(item: $exportFile) { file in
            HSDocumentActivityView(activityItems: [file.url])
        }
        .alert("Could not export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showingEditor) {
            VariationEditorSheet(
                project: project,
                existing: editingVariation,
                store: store,
                materialNames: materialNames
            )
            .environmentObject(firebaseBackend)
            .environmentObject(userStore)
            .environmentObject(notificationService)
        }
    }

    private var canEditContent: Bool {
        WorkAccess.canAccessVariations(project: project, userStore: userStore, operativeStore: operativeStore)
    }

    private var filteredVariations: [Variation] {
        switch filter {
        case .all: return store.visibleVariations
        case .open: return store.visibleVariations.filter { $0.status == .open }
        case .submitted: return store.visibleVariations.filter { $0.status == .submitted }
        case .closed: return store.visibleVariations.filter { $0.status == .closed }
        }
    }

    private func count(for status: VariationStatus) -> Int {
        store.visibleVariations.filter { $0.status == status }.count
    }

    /// Navy header: parent name, intro line, and the same counts / hours / status bar the summary card showed.
    private var summaryCard: some View {
        let open = Double(count(for: .open))
        let submitted = Double(count(for: .submitted))
        let closed = Double(count(for: .closed))
        let total = max(open + submitted + closed, 1)
        // RULEBOOK 1.52.0 §22 `variationListTotals` (deleted ones left out).
        let listTotals = CanonicalBusinessEngine.variationListTotals(store.visibleVariations.map(\.rulebookInput)) ?? .zero
        let hours = listTotals.labourHours
        return VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                eyebrow: project.jobNumber.isEmpty ? project.siteName : VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName),
                title: "Variations",
                subtitle: "Variations add up on a project, so capturing the materials and labour is key."
            )

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(store.visibleVariations.count)", label: "Variations")
                PPStatDivider()
                PPStat(value: formatHours(hours), label: "Hours logged")
                if canSeeCosts, listTotals.customCount + listTotals.subcontractorCount > 0 {
                    PPStatDivider()
                    PPStat(value: OrgMoney.format(listTotals.costTotal), label: "Cost")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.orange).frame(width: geo.size.width * CGFloat(open / total))
                    Rectangle().fill(Color.green).frame(width: geo.size.width * CGFloat(submitted / total))
                    Rectangle().fill(Color.red).frame(width: geo.size.width * CGFloat(closed / total))
                }
            }
            .frame(height: 6)
            .background(Capsule().fill(PPColor.onNavyFill))
            .clipShape(Capsule())
            .padding(.top, 16)

            HStack(spacing: 12) {
                legend(color: .orange, title: "Open \(Int(open))")
                legend(color: .green, title: "Submitted \(Int(submitted))")
                legend(color: .red, title: "Closed \(Int(closed))")
            }
            .font(.caption)
            .padding(.top, 10)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func variationCard(_ variation: Variation) -> some View {
        // RULEBOOK 1.52.0 §22 `variationPreviousNumbers`: "was VO-003, VO-005".
        let previous = CanonicalBusinessEngine.variationPreviousNumbers(voNumber: variation.voNumber, history: variation.numberHistory.map(\.from))
        let recentRenumber: String? = previous.isEmpty ? nil : "was " + previous.joined(separator: ", ")
        let totals = variation.totals ?? .zero
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(variation.voNumber)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ProjectWorksRevampColors.blue.opacity(0.12))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if variation.origin == .tracker {
                    Text("From tracker")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12))
                        .foregroundStyle(Color.purple)
                        .clipShape(Capsule())
                }
                Spacer()
                statusTag(variation.status)
            }
            Text(variation.heading.isEmpty ? "Untitled variation" : variation.heading)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
            if let recentRenumber {
                Text(recentRenumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(variation.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // RULEBOOK 1.52.0 §22 `variationTotals`: hours, counts, cost (staff) and a paperclip with the evidence count.
            HStack(spacing: 8) {
                chip("\(formatHours(totals.labourHours)) hrs")
                chip("\(totals.materialsCount) materials")
                if canSeeCosts, totals.customCount + totals.subcontractorCount > 0 {
                    chip(OrgMoney.format(totals.costTotal))
                }
                Label("\(totals.evidenceCount)", systemImage: "paperclip")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PPColor.well, in: Capsule())
                    .accessibilityLabel("\(totals.evidenceCount) evidence file\(totals.evidenceCount == 1 ? "" : "s")")
                Spacer(minLength: 0)
            }
            // RULEBOOK 1.52.0 §22 `variationDateText`: the organisation zone, never the device.
            Text("Raised by \(variation.createdByName) · \(CanonicalBusinessEngine.variationDateText(variation.createdAt, timeZone: OrganizationRulebookContext.timeZoneIdentifier))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .opacity(variation.status.listOpacity)
        .saturation(variation.status == .open ? 1 : 0.85)
    }

    /// RULEBOOK 1.52.0 §22 `canSeeVariationCosts`.
    private var canSeeCosts: Bool {
        guard let user = userStore.displayUser else { return false }
        return CanonicalBusinessEngine.canSeeVariationCosts(UserStore.staffAccountRole(for: user))
    }

    /// RULEBOOK 1.52.0 §22: the variations workbook from `variationExportRows` (every variation not removed), written
    /// by `VariationWorkbookBuilder` with the company logo, shared with the share sheet.
    private func exportWorkbook() {
        let org = firebaseBackend.currentOrganization
        let generatedBy = userStore.displayUser.map { $0.fullName.isEmpty ? $0.email : $0.fullName } ?? ""
        let input = VariationWorkbookBuilder.Input(
            variations: store.variations.map(\.rulebookInput),
            companyName: org?.name ?? "",
            jobNumber: project.jobNumber,
            jobName: project.siteName,
            generatedBy: generatedBy,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            currency: OrganizationRulebookContext.currencyCode,
            includeCost: canSeeCosts,
            logoURL: org?.companyLogoURL
        )
        Task {
            do {
                let url = try await VariationWorkbookBuilder.writeFile(input)
                exportFile = IdentifiableURL(url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func statusTag(_ status: VariationStatus) -> some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.16))
            .foregroundStyle(statusColor(status))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: VariationStatus) -> Color {
        switch status {
        case .open: return .orange
        case .submitted: return .green
        case .closed: return .red
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PPColor.well, in: Capsule())
    }

    private func formatHours(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

private enum VariationListFilter: Hashable {
    case all, open, submitted, closed

    var status: VariationStatus? {
        switch self {
        case .all: return nil
        case .open: return .open
        case .submitted: return .submitted
        case .closed: return .closed
        }
    }
}
