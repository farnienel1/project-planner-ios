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
                VStack(alignment: .leading, spacing: 14) {
                    Text(project.jobNumber.isEmpty ? project.siteName : VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName))
                        .font(.subheadline)
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text("Variations add up on a project, so capturing the materials and labour is key.")
                        .font(.footnote)
                        .foregroundStyle(ProjectWorksRevampColors.muted)

                    summaryCard

                    Picker("Status", selection: $filter) {
                        Text("All \(store.visibleVariations.count)").tag(VariationListFilter.all)
                        Text("Open \(count(for: .open))").tag(VariationListFilter.open)
                        Text("Submitted \(count(for: .submitted))").tag(VariationListFilter.submitted)
                        Text("Closed \(count(for: .closed))").tag(VariationListFilter.closed)
                    }
                    .pickerStyle(.segmented)

                    if let status = filter.status {
                        Text(status.definition)
                            .font(.footnote)
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ProjectWorksRevampColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                            .buttonStyle(.plain)
                        }
                    }

                    Color.clear.frame(height: canEditContent ? 88 : 16)
                }
                .padding(16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())

            if canEditContent {
                VStack {
                    LinearGradient(colors: [Color.clear, ProjectWorksRevampColors.canvas], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                    Button {
                        editingVariation = nil
                        showingEditor = true
                    } label: {
                        Text("Add variation")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ProjectWorksRevampColors.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .background(ProjectWorksRevampColors.canvas.opacity(0.92).ignoresSafeArea(edges: .bottom))
            }
        }
        .navigationTitle("Variations")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if store.tracker.enabled {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        VariationTrackerReadOnlyView(store: store, parentName: VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName))
                    } label: {
                        Text("Tracker")
                    }
                }
            }
        }
        .task {
            store.start(firebaseBackend: firebaseBackend)
        }
        .onDisappear { store.stop() }
        .sheet(isPresented: $showingEditor) {
            VariationEditorSheet(
                project: project,
                existing: editingVariation,
                store: store,
                materialNames: []
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

    private var summaryCard: some View {
        let open = Double(count(for: .open))
        let submitted = Double(count(for: .submitted))
        let closed = Double(count(for: .closed))
        let total = max(open + submitted + closed, 1)
        let hours = store.visibleVariations.reduce(0) { $0 + $1.totalLabourHours }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                summaryStat(title: "Variations", value: "\(store.visibleVariations.count)")
                Spacer()
                summaryStat(title: "Hours logged", value: String(format: hours.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", hours))
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.orange).frame(width: geo.size.width * CGFloat(open / total))
                    Rectangle().fill(Color.green).frame(width: geo.size.width * CGFloat(submitted / total))
                    Rectangle().fill(Color.red).frame(width: geo.size.width * CGFloat(closed / total))
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack(spacing: 12) {
                legend(color: .orange, title: "Open \(Int(open))")
                legend(color: .green, title: "Submitted \(Int(submitted))")
                legend(color: .red, title: "Closed \(Int(closed))")
            }
            .font(.caption2)
        }
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func summaryStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
        }
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(ProjectWorksRevampColors.muted)
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
                .font(.headline)
                .foregroundStyle(ProjectWorksRevampColors.ink)
            if let recentRenumber {
                Text(recentRenumber)
                    .font(.caption)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Text(variation.description)
                .font(.subheadline)
                .foregroundStyle(ProjectWorksRevampColors.muted)
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
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .background(Color(.systemGray6))
            .clipShape(Capsule())
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
