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

    /// Title-only navy header shown while the list loads, so the page doesn't jump when it arrives.
    private var loadingNavyHeader: some View {
        PPNavyPageTitle(
            eyebrow: "This project",
            title: project.jobNumber,
            subtitle: project.siteName
        )
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 0) {
                    loadingNavyHeader
                    ProgressView("Loading site audits...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ppContentSheet()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SiteAuditProjectHero(
                            jobNumber: project.jobNumber,
                            siteName: project.siteName,
                            auditCount: audits.count,
                            photoCount: photoCount,
                            lastSubmittedLine: lastSubmittedLine
                        )

                        VStack(alignment: .leading, spacing: 12) {
                            SiteAuditFilterChipsRow(chips: chipLabels, selectedIndex: selectedChipIndex)

                            if filteredAudits.isEmpty {
                                VStack(spacing: 12) {
                                    PPIconTile(symbol: "doc.text.magnifyingglass", family: .system, size: 56, lifted: true)
                                    Text("No site audits")
                                        .font(.system(.title3, design: .rounded).weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text("Create your first audit for this project.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 36)
                                .padding(.horizontal, 16)
                                .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                            } else {
                                ForEach(filteredAudits) { audit in
                                    Button { onSelect(audit) } label: {
                                        SiteAuditAuditListCard(audit: audit)
                                    }
                                    .accessibilityIdentifier("siteAuditProjectList.row.\(audit.id)")
                                    .buttonStyle(PPPressableButtonStyle())
                                }
                            }
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                        .ppContentSheet()
                    }
                }
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Site audits")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(project.jobNumber)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PPColor.onNavySecondary)
                    Text("Site audits")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                }
            }
            if showsCreateButton {
                ToolbarItem(placement: .topBarTrailing) {
                    SiteAuditIconCircleButton(systemName: "plus", primary: true, onNavy: true, action: onCreate)
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
                .accessibilityIdentifier("siteAuditAuditListCard.button")
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        SiteAuditCard {
            HStack(alignment: .center, spacing: 13) {
                SiteAuditRowIconChip(systemName: style.icon, tint: style.accent, background: style.tint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(audit.type.rawValue)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(SiteAuditColors.text)
                        SiteAuditPill(text: style.pillLabel, style: pillStyle)
                        if dashedCreate {
                            SiteAuditPill(text: "Draft", style: .draft)
                        }
                    }
                    Text("\(audit.projectJobNumber) \(audit.projectName)")
                        .font(.subheadline)
                        .foregroundStyle(SiteAuditColors.textSecondary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Label(audit.authorName, systemImage: "person.fill")
                        Label("\(audit.items.count) items", systemImage: "cube.box")
                    }
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textSecondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SiteAuditColors.textDisabled)
                        .accessibilityHidden(onTap == nil)
                }
            }
            .padding(14)
        }
        .overlay {
            if dashedCreate {
                RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous)
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
            VStack(alignment: .leading, spacing: 12) {
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
                                .accessibilityIdentifier("siteAuditDetailsStep.author")
                                .font(.body)
                        }
                        divider
                        detailFieldRow(
                            icon: "calendar",
                            iconTint: SiteAuditColors.purple,
                            iconBg: SiteAuditColors.purpleTint,
                            label: "Date"
                        ) {
                            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                                .accessibilityIdentifier("siteAuditDetailsStep.datePicker")
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
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
                                    size: PPMetrics.menuIcon
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Visible to operatives")
                                        .font(.body)
                                    Text("Ops working on this job can view it")
                                        .font(.footnote)
                                        .foregroundStyle(SiteAuditColors.textSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("siteAuditDetailsStep.eyeFill")
                        .tint(SiteAuditColors.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .siteAuditScreenBackground()
    }

    @ViewBuilder
    private var projectRow: some View {
        if lockProjectSelection, let p = selectedProject ?? initialProject {
            detailRow(icon: "folder.fill", iconTint: SiteAuditColors.success, iconBg: SiteAuditColors.successTint, label: "Project", value: "\(p.jobNumber) · \(p.siteName)", showChevron: false) { EmptyView() }
        } else {
            Button(action: onPickProject) {
                detailRow(icon: "folder.fill", iconTint: SiteAuditColors.success, iconBg: SiteAuditColors.successTint, label: "Project or Small works", value: selectedProject.map { job in
                    let kind = job.jobType == .smallWorks ? "Small works" : "Project"
                    return "\(kind) · \(job.jobNumber) · \(job.siteName)"
                } ?? "Select Project/Small Works", showChevron: true) { EmptyView() }
            }
            .accessibilityIdentifier("siteAuditDetailsStep.folderFill")
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
                .accessibilityIdentifier("siteAuditDetailsStep.eGPlantRoomSnags")
                .font(.body)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SiteAuditColors.border)
            .frame(height: 0.5)
            .padding(.leading, PPMetrics.menuIcon + 13)
    }

    private func detailFieldRow<Content: View>(
        icon: String,
        iconTint: Color,
        iconBg: Color,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 13) {
            SiteAuditRowIconChip(systemName: icon, tint: iconTint, background: iconBg, size: PPMetrics.menuIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textSecondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .frame(minHeight: 60)
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
        HStack(alignment: .center, spacing: 13) {
            SiteAuditRowIconChip(systemName: icon, tint: iconTint, background: iconBg, size: PPMetrics.menuIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textSecondary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(value == "Select Project/Small Works" ? SiteAuditColors.textSecondary : SiteAuditColors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SiteAuditColors.textDisabled)
            }
        }
        .padding(.vertical, 11)
        .frame(minHeight: 60)
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
                        HStack(spacing: 13) {
                            SiteAuditRowIconChip(systemName: style.icon, tint: style.accent, background: style.tint, size: PPMetrics.menuIcon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(auditType.rawValue) · \(project.jobNumber) \(project.siteName)")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(items.isEmpty ? "Started today by \(authorName)" : "\(items.count) item\(items.count == 1 ? "" : "s") · Auto-saved")
                                    .font(.footnote)
                                    .foregroundStyle(SiteAuditColors.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }

                    HStack(spacing: 10) {
                        SiteAuditPrimaryButton(title: "Add item", systemImage: "plus", action: onAddItem)
                            .disabled(isProcessingPhotos)
                        PhotosPicker(selection: $multiSelection, maxSelectionCount: 20, matching: .images) {
                            HStack(spacing: 5) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text(isProcessingPhotos ? "Processing…" : "Multi-add")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .foregroundStyle(isProcessingPhotos ? SiteAuditColors.textDisabled : SiteAuditColors.primary)
                            .background(PPColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(SiteAuditColors.primary, lineWidth: 1)
                            )
                        }
                        .accessibilityIdentifier("siteAuditItemsStep.photoOnRectangleAngled")
                        .disabled(isProcessingPhotos)
                    }

                    if isProcessingPhotos {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing photos — this may take a moment for large batches.")
                                .font(.footnote)
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
                            .accessibilityIdentifier("siteAuditItemsStep.row.\(item.id)")
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                                        items.remove(at: i)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                    .accessibilityIdentifier("siteAuditItemsStep.row.\(item.id).delete")
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                                        items.remove(at: i)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                    .accessibilityIdentifier("siteAuditItemsStep.row.\(item.id).delete2")
                            }
                        }
                    }
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .siteAuditScreenBackground()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                PPIconTile(symbol: "photo.on.rectangle.angled", family: .plan, size: 56, lifted: true)
                PPPlusBadge()
            }
            Text("No items yet")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text("Tap Add item for one entry, or Multi-add to pick several photos at once.")
                .font(.subheadline)
                .foregroundStyle(SiteAuditColors.textSecondary)
                .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: 13) {
                PPIconTile(symbol: "lightbulb.fill", family: .trade, size: PPMetrics.menuIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tip")
                        .font(.subheadline.weight(.semibold))
                    Text("Photos get auto-timestamped so the PDF shows when each was taken.")
                        .font(.footnote)
                        .foregroundStyle(SiteAuditColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("#\(index)")
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(SiteAuditColors.textSecondary)
                        Text(item.title.isEmpty ? "Untitled item" : item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    if !item.comments.isEmpty {
                        Text(item.comments)
                            .font(.footnote)
                            .foregroundStyle(SiteAuditColors.textSecondary)
                            .lineLimit(2)
                    }
                    if !item.assignee.isEmpty {
                        Label(item.assignee, systemImage: "person.fill")
                            .font(.caption)
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SiteAuditColors.danger)
                                .frame(width: 30, height: 30)
                                .background(SiteAuditColors.dangerTint)
                                .clipShape(Circle())
                        }
                        .accessibilityIdentifier("siteAuditDraftItemCard.delete")
                        .buttonStyle(.plain)
                    }
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13))
                        .foregroundStyle(SiteAuditColors.textDisabled)
                }
            }
            .padding(12)
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
    var organizationAbbreviation: String? = nil
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
                            HStack(spacing: 12) {
                                thumbnail(item)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(index + 1) · \(item.title.isEmpty ? "Untitled" : item.title)")
                                        .font(.subheadline.weight(.semibold))
                                    if !item.comments.isEmpty {
                                        Text(item.comments)
                                            .font(.footnote)
                                            .foregroundStyle(SiteAuditColors.textSecondary)
                                            .lineLimit(3)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.top, 12)
                .padding(.bottom, 110)
            }

            VStack(spacing: 0) {
                Divider()
                if isSubmitting, !submitStatusMessage.isEmpty {
                    Text(submitStatusMessage)
                        .font(.footnote)
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
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.vertical, 12)
            }
            .background(PPColor.card.ignoresSafeArea(edges: .bottom))
        }
        .siteAuditScreenBackground()
    }

    private var previewHero: some View {
        ZStack(alignment: .topTrailing) {
            PPNavyBackdrop()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Site audit report")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.1)
                            .foregroundStyle(PPColor.onNavySecondary)
                            .textCase(.uppercase)
                        Text(auditType.rawValue)
                            .font(.system(.title2, design: .rounded))
                            .fontWeight(.bold)
                        if !customTitle.isEmpty {
                            Text(customTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PPColor.onNavySecondary)
                        }
                    }
                    Spacer()
                    orgBadge
                }
                Rectangle()
                    .fill(PPColor.onNavyHairline)
                    .frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    metaCol("Project", "\(project.jobNumber) · \(project.siteName)")
                    metaCol("Date", date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var orgBadge: some View {
        let initials = OrganizationDocumentAbbreviation.display(
            abbreviation: organizationAbbreviation,
            organizationName: organizationName
        )
        return Text(initials)
            .font(.system(size: initials.count >= 3 ? 10 : 11, weight: .semibold))
            .minimumScaleFactor(0.65)
            .lineLimit(1)
            .foregroundStyle(.white)
            .frame(width: 46, height: 40)
            .background(
                LinearGradient(colors: [SiteAuditColors.heroGradientStart, SiteAuditColors.heroGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
            )
    }

    private func metaCol(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(PPColor.onNavyCaption)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thumbnail(_ item: SiteAuditDraftItem) -> some View {
        if let image = item.image {
            SiteAuditBoundedThumbnail(image: image, size: 70, cornerRadius: 12)
        } else {
            SiteAuditColors.primaryTint
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var divider: some View {
        Rectangle().fill(SiteAuditColors.border).frame(height: 0.5)
    }

    private func summaryRow(_ label: String, _ value: String, pill: String?, pillStyle: SiteAuditPill.Style = .grey) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textSecondary)
                Text(value)
                    .font(.body)
            }
            Spacer()
            if let pill {
                SiteAuditPill(text: pill, style: pillStyle)
            }
        }
        .padding(.vertical, 11)
        .frame(minHeight: 60)
    }
}
