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

    private var parentType: VariationParentType {
        project.jobType == .smallWorks ? .smallWork : .project
    }

    init(project: Project) {
        self.project = project
        let type: VariationParentType = project.jobType == .smallWorks ? .smallWork : .project
        _store = StateObject(wrappedValue: VariationStore(parentId: project.id.uuidString, parentType: type))
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
        let hours = store.visibleVariations.reduce(0) { $0 + $1.totalLabourHours }
        return VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                eyebrow: project.jobNumber.isEmpty ? project.siteName : VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName),
                title: "Variations",
                subtitle: "Variations add up on a project, so capturing the materials and labour is key."
            )

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(store.visibleVariations.count)", label: "Variations")
                PPStatDivider()
                PPStat(value: String(format: hours.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", hours), label: "Hours logged")
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
        let previous = variation.numberHistory.last
        let recentRenumber = previous.flatMap { entry -> String? in
            guard Date().timeIntervalSince(entry.at) < 7 * 24 * 3600 else { return nil }
            return "was \(entry.from)"
        }
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
            HStack(spacing: 8) {
                chip("\(formatHours(variation.totalLabourHours)) hrs")
                chip("\(variation.materialLineCount) materials")
                if variation.evidenceCount == 0 {
                    Text("No evidence")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.14))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                } else {
                    chip("\(variation.evidenceCount) evidence")
                }
                Spacer(minLength: 0)
            }
            Text("Raised by \(variation.createdByName) · \(variation.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .opacity(variation.status.listOpacity)
        .saturation(variation.status == .open ? 1 : 0.85)
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
