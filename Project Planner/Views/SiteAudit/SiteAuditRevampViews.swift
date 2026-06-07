//
//  SiteAuditRevampViews.swift
//  Project Planner
//
//  Redesigned site audit screens (site_audit_full_flow.html)
//

import SwiftUI
import PhotosUI

// MARK: - Audits list (project scoped)

struct SiteAuditProjectListView: View {
    let project: Project
    @Binding var audits: [SiteAudit]
    @Binding var selectedTypeTab: String
    let isLoading: Bool
    let onSelect: (SiteAudit) -> Void
    let onCreate: () -> Void
    var showsCreateButton = true

    private var filteredAudits: [SiteAudit] {
        selectedTypeTab == "All" ? audits : audits.filter { $0.type.rawValue == selectedTypeTab }
    }

    private var chipLabels: [(String, Int?)] {
        var chips: [(String, Int?)] = [("All", audits.count)]
        for type in SiteAuditType.allCases {
            let n = audits.filter { $0.type == type }.count
            chips.append((type.rawValue, n))
        }
        return chips
    }

    private var selectedChipIndex: Binding<Int> {
        Binding(
            get: {
                if selectedTypeTab == "All" { return 0 }
                if let idx = SiteAuditType.allCases.firstIndex(where: { $0.rawValue == selectedTypeTab }) {
                    return idx + 1
                }
                return 0
            },
            set: { newValue in
                if newValue == 0 {
                    selectedTypeTab = "All"
                } else if newValue - 1 < SiteAuditType.allCases.count {
                    selectedTypeTab = SiteAuditType.allCases[newValue - 1].rawValue
                }
            }
        )
    }

    private var photoCount: Int {
        audits.reduce(0) { $0 + $1.items.count }
    }

    private var lastSubmittedLine: String? {
        guard let latest = audits.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let rel = latest.createdAt.formatted(.relative(presentation: .named))
        return "Last submitted \(rel) by \(latest.authorName)"
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading site audits...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SiteAuditProjectHero(
                            auditCount: audits.count,
                            photoCount: photoCount,
                            lastSubmittedLine: lastSubmittedLine
                        )

                        SiteAuditFilterChipsRow(chips: chipLabels, selectedIndex: selectedChipIndex)

                        if filteredAudits.isEmpty {
                            SiteAuditCard {
                                VStack(spacing: 8) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.title2)
                                        .foregroundStyle(SiteAuditColors.textDisabled)
                                    Text("No site audits")
                                        .font(.system(size: 14, weight: .medium))
                                    Text("Create your first audit for this project.")
                                        .font(.caption)
                                        .foregroundStyle(SiteAuditColors.textSecondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(24)
                            }
                        } else {
                            ForEach(filteredAudits) { audit in
                                Button { onSelect(audit) } label: {
                                    SiteAuditAuditListCard(audit: audit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .siteAuditScreenBackground()
        .navigationTitle("Site audits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(project.jobNumber)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SiteAuditColors.textSecondary)
                    Text("Site audits")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            if showsCreateButton {
                ToolbarItem(placement: .topBarTrailing) {
                    SiteAuditIconCircleButton(systemName: "plus", primary: true, action: onCreate)
                }
            }
        }
    }
}

struct SiteAuditAuditListCard: View {
    let audit: SiteAudit
    var dashedCreate = false
    var showsChevron = true
    var onTap: (() -> Void)?

    private var style: SiteAuditTypeStyle { SiteAuditTypeStyle.forType(audit.type) }

    private var pillStyle: SiteAuditPill.Style {
        switch style {
        case .preStart: return .amber
        case .general: return .blue
        case .variations: return .purple
        case .snags: return .red
        }
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        SiteAuditCard {
            HStack(alignment: .top, spacing: 10) {
                SiteAuditRowIconChip(systemName: style.icon, tint: style.accent, background: style.tint, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(audit.type.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        SiteAuditPill(text: style.pillLabel, style: pillStyle)
                        if dashedCreate {
                            SiteAuditPill(text: "Draft", style: .draft)
                        }
                    }
                    Text("\(audit.projectJobNumber) \(audit.projectName)")
                        .font(.system(size: 11))
                        .foregroundStyle(SiteAuditColors.textSecondary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 9) {
                        Label(audit.authorName, systemImage: "person.fill")
                        Label("\(audit.items.count) items", systemImage: "cube.box")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(SiteAuditColors.textSecondary)
                    .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SiteAuditColors.textDisabled)
                        .accessibilityHidden(onTap == nil)
                }
            }
            .padding(12)
        }
        .overlay {
            if dashedCreate {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SiteAuditColors.textDisabled, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }
}

// MARK: - Create flow: details step

struct SiteAuditDetailsStepView: View {
    @Binding var selectedType: SiteAuditType
    @Binding var selectedProject: Project?
    @Binding var customTitle: String
    @Binding var authorName: String
    @Binding var selectedDate: Date
    @Binding var operativeAccessVisibleToOperatives: Bool
    let lockProjectSelection: Bool
    let initialProject: Project?
    let canManageVisibility: Bool
    let onPickProject: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SiteAuditSectionLabel(title: "Type")
                SiteAuditTypePickerGrid(selected: $selectedType)

                SiteAuditSectionLabel(title: "Details")
                SiteAuditCard {
                    VStack(spacing: 0) {
                        projectRow
                        divider
                        titleRow
                        divider
                        detailFieldRow(
                            icon: "person.fill",
                            iconTint: SiteAuditColors.pink,
                            iconBg: SiteAuditColors.pinkTint,
                            label: "Author"
                        ) {
                            TextField("Author", text: $authorName)
                                .font(.system(size: 13, weight: .medium))
                        }
                        divider
                        detailFieldRow(
                            icon: "calendar",
                            iconTint: SiteAuditColors.purple,
                            iconBg: SiteAuditColors.purpleTint,
                            label: "Date"
                        ) {
                            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                }

                if canManageVisibility {
                    SiteAuditSectionLabel(title: "Visibility")
                    SiteAuditCard {
                        Toggle(isOn: $operativeAccessVisibleToOperatives) {
                            HStack(spacing: 11) {
                                SiteAuditRowIconChip(
                                    systemName: "eye.fill",
                                    tint: SiteAuditColors.success,
                                    background: SiteAuditColors.successTint,
                                    size: 30
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Visible to operatives")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Ops working on this job can view it")
                                        .font(.system(size: 10))
                                        .foregroundStyle(SiteAuditColors.textSecondary)
                                }
                            }
                        }
                        .tint(SiteAuditColors.primary)
                        .padding(12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .siteAuditScreenBackground()
    }

    @ViewBuilder
    private var projectRow: some View {
        if lockProjectSelection, let p = selectedProject ?? initialProject {
            detailRow(icon: "folder.fill", iconTint: SiteAuditColors.success, iconBg: SiteAuditColors.successTint, label: "Project", value: "\(p.jobNumber) · \(p.siteName)", showChevron: false) { EmptyView() }
        } else {
            Button(action: onPickProject) {
                detailRow(icon: "folder.fill", iconTint: SiteAuditColors.success, iconBg: SiteAuditColors.successTint, label: "Project", value: selectedProject.map { "\($0.jobNumber) · \($0.siteName)" } ?? "Select project", showChevron: true) { EmptyView() }
            }
            .buttonStyle(.plain)
        }
    }

    private var titleRow: some View {
        detailFieldRow(
            icon: "pencil",
            iconTint: SiteAuditColors.primary,
            iconBg: SiteAuditColors.primaryTint,
            label: "Title · optional"
        ) {
            TextField("e.g. Plant room snags", text: $customTitle)
                .font(.system(size: 13, weight: .medium))
        }
    }

    private var divider: some View {
        Rectangle().fill(SiteAuditColors.border).frame(height: 0.5)
    }

    private func detailFieldRow<Content: View>(
        icon: String,
        iconTint: Color,
        iconBg: Color,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            SiteAuditRowIconChip(systemName: icon, tint: iconTint, background: iconBg)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(SiteAuditColors.textSecondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
    }

    private func detailRow<Accessory: View>(
        icon: String,
        iconTint: Color,
        iconBg: Color,
        label: String,
        value: String,
        showChevron: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            SiteAuditRowIconChip(systemName: icon, tint: iconTint, background: iconBg)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(SiteAuditColors.textSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(value == "Select project" ? SiteAuditColors.textSecondary : SiteAuditColors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(SiteAuditColors.textDisabled)
                    .padding(.top, 14)
            }
        }
        .padding(.vertical, 11)
    }
}

// MARK: - Items step

struct SiteAuditItemsStepView: View {
    let auditType: SiteAuditType
    let project: Project
    let authorName: String
    @Binding var items: [SiteAuditDraftItem]
    @Binding var multiSelection: [PhotosPickerItem]
    var isProcessingPhotos = false
    let onAddItem: () -> Void
    let onEditItem: (SiteAuditDraftItem) -> Void
    let onDelete: (IndexSet) -> Void

    private var style: SiteAuditTypeStyle { SiteAuditTypeStyle.forType(auditType) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SiteAuditCard {
                        HStack(spacing: 10) {
                            SiteAuditRowIconChip(systemName: style.icon, tint: style.accent, background: style.tint, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(auditType.rawValue) · \(project.jobNumber) \(project.siteName)")
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text(items.isEmpty ? "Started today by \(authorName)" : "\(items.count) item\(items.count == 1 ? "" : "s") · Auto-saved")
                                    .font(.system(size: 9))
                                    .foregroundStyle(SiteAuditColors.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                    }

                    HStack(spacing: 7) {
                        SiteAuditPrimaryButton(title: "Add item", systemImage: "plus", action: onAddItem)
                            .disabled(isProcessingPhotos)
                        PhotosPicker(selection: $multiSelection, maxSelectionCount: 20, matching: .images) {
                            HStack(spacing: 5) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text(isProcessingPhotos ? "Processing…" : "Multi-add")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(isProcessingPhotos ? SiteAuditColors.textDisabled : SiteAuditColors.primary)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(SiteAuditColors.primary, lineWidth: 0.5)
                            )
                        }
                        .disabled(isProcessingPhotos)
                    }

                    if isProcessingPhotos {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing photos — this may take a moment for large batches.")
                                .font(.system(size: 11))
                                .foregroundStyle(SiteAuditColors.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if items.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { onEditItem(item) } label: {
                                SiteAuditDraftItemCard(
                                    index: index + 1,
                                    item: item,
                                    onDelete: {
                                        if let i = items.firstIndex(where: { $0.id == item.id }) {
                                            items.remove(at: i)
                                        }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                                        items.remove(at: i)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                                        items.remove(at: i)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .siteAuditScreenBackground()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SiteAuditColors.card)
                    .frame(width: 70, height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(SiteAuditColors.border, lineWidth: 0.5)
                    )
                    .overlay {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32))
                            .foregroundStyle(SiteAuditColors.textDisabled)
                    }
                Circle()
                    .fill(SiteAuditColors.primary)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 4, y: 4)
            }
            Text("No items yet")
                .font(.system(size: 14, weight: .medium))
            Text("Tap Add item for one entry, or Multi-add to pick several photos at once.")
                .font(.system(size: 11))
                .foregroundStyle(SiteAuditColors.textSecondary)
                .multilineTextAlignment(.center)

            SiteAuditCard {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(SiteAuditColors.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tip")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SiteAuditColors.primary)
                        Text("Photos get auto-timestamped so the PDF shows when each was taken.")
                            .font(.system(size: 10))
                            .foregroundStyle(SiteAuditColors.primary.opacity(0.85))
                    }
                }
                .padding(12)
            }
            .background(SiteAuditColors.primaryTint)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct SiteAuditDraftItemCard: View {
    let index: Int
    let item: SiteAuditDraftItem
    var onDelete: (() -> Void)? = nil

    var body: some View {
        SiteAuditCard {
            HStack(spacing: 10) {
                Group {
                    if let image = item.image {
                        SiteAuditBoundedThumbnail(image: image)
                    } else {
                        LinearGradient(
                            colors: [SiteAuditColors.primaryTint, SiteAuditColors.primary.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("#\(index)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SiteAuditColors.textSecondary)
                        Text(item.title.isEmpty ? "Untitled item" : item.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    if !item.comments.isEmpty {
                        Text(item.comments)
                            .font(.system(size: 10))
                            .foregroundStyle(SiteAuditColors.textSecondary)
                            .lineLimit(2)
                    }
                    if !item.assignee.isEmpty {
                        Label(item.assignee, systemImage: "person.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(SiteAuditColors.textSecondary)
                    } else if item.title == "Photo item" {
                        SiteAuditPill(text: "Needs review", style: .amber)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SiteAuditColors.danger)
                                .frame(width: 26, height: 26)
                                .background(SiteAuditColors.dangerTint)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13))
                        .foregroundStyle(SiteAuditColors.textDisabled)
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Preview step

struct SiteAuditPreviewStepView: View {
    let auditType: SiteAuditType
    let project: Project
    let customTitle: String
    let authorName: String
    let date: Date
    let clientName: String?
    let items: [SiteAuditDraftItem]
    let organizationName: String?
    let onEdit: () -> Void
    let onSubmit: () -> Void
    let isSubmitting: Bool
    var submitStatusMessage: String = ""
    var submitButtonTitle: String = "Submit & generate PDF"

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    previewHero
                    SiteAuditSectionLabel(title: "Summary")
                    SiteAuditCard {
                        VStack(spacing: 0) {
                            summaryRow("Author", authorName, pill: "Manager")
                            divider
                            if let clientName, !clientName.isEmpty {
                                summaryRow("Client", clientName, pill: nil)
                                divider
                            }
                            summaryRow("Items", "\(items.count) photo item\(items.count == 1 ? "" : "s")", pill: "Ready", pillStyle: .green)
                        }
                        .padding(.horizontal, 14)
                    }

                    SiteAuditSectionLabel(title: "Items", suffix: "· \(items.count)")
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SiteAuditCard {
                            HStack(spacing: 10) {
                                thumbnail(item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(index + 1) · \(item.title.isEmpty ? "Untitled" : item.title)")
                                        .font(.system(size: 11, weight: .medium))
                                    if !item.comments.isEmpty {
                                        Text(item.comments)
                                            .font(.system(size: 10))
                                            .foregroundStyle(SiteAuditColors.textSecondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            .padding(10)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
            }

            VStack(spacing: 0) {
                Divider()
                if isSubmitting, !submitStatusMessage.isEmpty {
                    Text(submitStatusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(SiteAuditColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                HStack(spacing: 7) {
                    SiteAuditPrimaryButton(title: "Edit", systemImage: "pencil", style: .outline, action: onEdit)
                        .disabled(isSubmitting)
                    SiteAuditPrimaryButton(
                        title: isSubmitting ? "Working…" : submitButtonTitle,
                        systemImage: "arrow.up.circle.fill",
                        disabled: isSubmitting,
                        action: onSubmit
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white)
            }
        }
        .siteAuditScreenBackground()
    }

    private var previewHero: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [SiteAuditColors.headerGradientStart, SiteAuditColors.headerGradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.094, green: 0.373, blue: 0.647).opacity(0.35))
                .frame(width: 120, height: 120)
                .offset(x: 30, y: -30)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Site audit report")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .textCase(.uppercase)
                        Text(auditType.rawValue)
                            .font(.system(size: 15, weight: .medium))
                        if !customTitle.isEmpty {
                            Text(customTitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    Spacer()
                    orgBadge
                }
                Divider().overlay(Color.white.opacity(0.18))
                HStack {
                    metaCol("Project", "\(project.jobNumber) · \(project.siteName)")
                    metaCol("Date", date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var orgBadge: some View {
        let initials = organizationInitials(organizationName)
        return Text(initials)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(
                LinearGradient(colors: [SiteAuditColors.heroGradientStart, SiteAuditColors.heroGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metaCol(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased())
                .font(.system(size: 9))
                .opacity(0.6)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thumbnail(_ item: SiteAuditDraftItem) -> some View {
        if let image = item.image {
            SiteAuditBoundedThumbnail(image: image, size: 70, cornerRadius: 8)
        } else {
            SiteAuditColors.primaryTint
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var divider: some View {
        Rectangle().fill(SiteAuditColors.border).frame(height: 0.5)
    }

    private func summaryRow(_ label: String, _ value: String, pill: String?, pillStyle: SiteAuditPill.Style = .grey) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(SiteAuditColors.textSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer()
            if let pill {
                SiteAuditPill(text: pill, style: pillStyle)
            }
        }
        .padding(.vertical, 11)
    }

    private func organizationInitials(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "PP" }
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
