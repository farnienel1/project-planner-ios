//
//  MaterialsSendListSheet.swift
//  Project Planner
//

import SwiftUI

struct MaterialsSendListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var smartCache: SmartCacheService

    let project: Project
    let materials: [MaterialItem]
    var materialsDay: Date?
    @Binding var isPresented: Bool

    @State private var wholesalers: [Wholesaler] = []
    @State private var selectedContactIds: Set<UUID> = []
    struct OneOffRecipient: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var email: String
    }

    @State private var oneOffRecipients: [OneOffRecipient] = []
    @State private var newRecipientName = ""
    @State private var newEmail = ""
    @State private var selectedMaterialIds: Set<UUID> = []
    @State private var materialSelectionExpanded = false
    @State private var isSending = false
    @State private var showingMultipleWholesalerAlert = false
    @State private var pendingRequestType: MaterialOrderRequest.RequestType?
    @State private var resendDialog: ResendDialogState?
    @State private var sendConfirmation: SendConfirmationState?
    @State private var expandedWholesalerIds: Set<UUID> = []

    struct ResendDialogState: Identifiable {
        let id = UUID()
        let requestType: MaterialOrderRequest.RequestType
        let alreadyQuoted: [MaterialItem]
        let alreadyOrdered: [MaterialItem]
        let fresh: [MaterialItem]

        var alreadySent: [MaterialItem] { alreadyQuoted + alreadyOrdered }
    }

    struct SendConfirmationState: Identifiable {
        let id = UUID()
        let requestType: MaterialOrderRequest.RequestType
        let itemCount: Int
        let recipientCount: Int
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        projectCard
                        wholesalerSection
                        oneOffSection
                    }
                    .padding(16)
                    .padding(.bottom, 120)
                }
                footerBar
            }
            .background(MaterialsOrderingTheme.pageBackground)
            .navigationTitle("Send list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .task {
                await loadWholesalers()
                selectedMaterialIds = Set(materials.map(\.id))
            }
            .alert("Multiple wholesalers", isPresented: $showingMultipleWholesalerAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Orders can only go to one wholesaler at a time.")
            }
            .sheet(item: $resendDialog) { dialog in
                MaterialsResendIncludeExcludeSheet(
                    dialog: dialog,
                    onContinue: { materialIds in
                        proceedSend(type: dialog.requestType, materialIds: materialIds)
                    },
                    onCancel: { resendDialog = nil }
                )
            }
            .sheet(item: $sendConfirmation) { conf in
                MaterialsSendConfirmationView(
                    project: project,
                    confirmation: conf,
                    wholesalers: wholesalers,
                    selectedContactIds: selectedContactIds,
                    oneOffRecipients: oneOffRecipients,
                    onDone: {
                        sendConfirmation = nil
                        isPresented = false
                        NotificationCenter.default.post(name: NSNotification.Name("reloadMaterials"), object: nil)
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.jobNumber)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.primary)
                Text(project.siteName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(materials) { material in
                        let selected = selectedMaterialIds.contains(material.id)
                        Button {
                            if selected { selectedMaterialIds.remove(material.id) }
                            else { selectedMaterialIds.insert(material.id) }
                        } label: {
                            Label(material.material, systemImage: selected ? "checkmark.square.fill" : "square")
                        }
                    }
                } label: {
                    Text("\(selectedMaterialIds.count) items")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(MaterialsOrderingTheme.successTint)
                        .foregroundStyle(MaterialsOrderingTheme.success)
                        .clipShape(Capsule())
                }
            }
            Text(project.siteAddress)
                .font(.system(size: 10))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            if !materials.isEmpty {
                Button {
                    materialSelectionExpanded.toggle()
                } label: {
                    HStack {
                        Text("Materials in this send")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                        Spacer()
                        Image(systemName: materialSelectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }
                }
                .buttonStyle(.plain)
            }
            if materialSelectionExpanded {
                VStack(spacing: 8) {
                    ForEach(materials) { item in
                        let isSelected = selectedMaterialIds.contains(item.id)
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                if isSelected {
                                    selectedMaterialIds.remove(item.id)
                                } else {
                                    selectedMaterialIds.insert(item.id)
                                }
                            } label: {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isSelected ? MaterialsOrderingTheme.primary : MaterialsOrderingTheme.disabled)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.material)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isSelected ? MaterialsOrderingTheme.ink : MaterialsOrderingTheme.muted)
                                HStack(spacing: 6) {
                                    MaterialsStatusPill(status: item.status)
                                    if let sentAt = item.lastSentAt {
                                        Text(sentAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 10))
                                            .foregroundStyle(MaterialsOrderingTheme.muted)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .opacity(isSelected ? 1 : 0.6)
                    }
                }
                .padding(8)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(11)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var wholesalerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHOLESALERS · \(selectedContactIds.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            VStack(spacing: 0) {
                ForEach(wholesalers) { wholesaler in
                    wholesalerGroupRow(wholesaler: wholesaler)
                    if wholesaler.id != wholesalers.last?.id {
                        Divider()
                    }
                }
            }
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func wholesalerGroupRow(wholesaler: Wholesaler) -> some View {
        let expanded = expandedWholesalerIds.contains(wholesaler.id)
        let selectedInGroup = wholesaler.contacts.filter { selectedContactIds.contains($0.id) }.count
        return VStack(spacing: 0) {
            Button {
                if expanded { expandedWholesalerIds.remove(wholesaler.id) }
                else { expandedWholesalerIds.insert(wholesaler.id) }
            } label: {
                HStack(spacing: 10) {
                    Text(String(wholesaler.name.prefix(2)).uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(MaterialsOrderingTheme.primaryGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wholesaler.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.ink)
                        Text("\(wholesaler.contacts.count) contact\(wholesaler.contacts.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }
                    Spacer()
                    if selectedInGroup > 0 {
                        Text("\(selectedInGroup) selected")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(wholesaler.contacts) { contact in
                    wholesalerContactRow(wholesaler: wholesaler, contact: contact)
                    if contact.id != wholesaler.contacts.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    private func wholesalerContactRow(wholesaler: Wholesaler, contact: WholesalerContact) -> some View {
        let selected = selectedContactIds.contains(contact.id)
        return Button {
            if selected { selectedContactIds.remove(contact.id) }
            else { selectedContactIds.insert(contact.id) }
        } label: {
            HStack(spacing: 10) {
                Color.clear.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.ink)
                    Text(contact.email)
                        .font(.system(size: 10))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? MaterialsOrderingTheme.primary : MaterialsOrderingTheme.disabled)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }

    private var oneOffSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ONE-OFF EMAIL · not saved to wholesalers")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            ForEach(oneOffRecipients) { recipient in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipient.name.isEmpty ? "No name" : recipient.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(recipient.email)
                            .font(.system(size: 11))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }
                    Spacer()
                    Button { oneOffRecipients.removeAll { $0.id == recipient.id } } label: {
                        Image(systemName: "xmark")
                    }
                }
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 8) {
                TextField("Name (for email greeting)", text: $newRecipientName)
                TextField("Email", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    let trimmedName = newRecipientName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.contains("@") else { return }
                    guard !trimmedName.isEmpty else { return }
                    oneOffRecipients.append(OneOffRecipient(name: trimmedName, email: trimmed))
                    newRecipientName = ""
                    newEmail = ""
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(10)
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footerBar: some View {
        VStack(spacing: 9) {
            HStack {
                Text("\(selectedMaterialIds.count) items · \(recipientCount) recipients")
                    .font(.system(size: 11))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Spacer()
                Text("Cut-off 16:00")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.primary)
            }
            HStack(spacing: 8) {
                Button { beginSend(type: .quote) } label: {
                    Label("Quote", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(MaterialsOrderingTheme.primary)
                Button { beginSend(type: .order) } label: {
                    Label("Order", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MaterialsOrderingTheme.success)
            }
            .disabled(selectedMaterialIds.isEmpty || recipientCount == 0 || isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(MaterialsOrderingTheme.cardBackground)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(MaterialsOrderingTheme.border), alignment: .top)
    }

    private var recipientCount: Int {
        selectedContactIds.count + oneOffRecipients.count
    }

    private func loadWholesalers() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        wholesalers = (try? await firebaseBackend.loadWholesalers(organizationId: organizationId)) ?? []
    }

    private func beginSend(type: MaterialOrderRequest.RequestType) {
        guard !selectedMaterialIds.isEmpty, recipientCount > 0 else { return }
        if type == .order {
            let wholesalerIds = Set(wholesalers.compactMap { w in
                w.contacts.contains(where: { selectedContactIds.contains($0.id) }) ? w.id : nil
            })
            if wholesalerIds.count > 1 {
                showingMultipleWholesalerAlert = true
                return
            }
        }
        let selected = materials.filter { selectedMaterialIds.contains($0.id) }
        let alreadyQuoted = selected.filter { $0.status == .sentForQuote }
        let alreadyOrdered = selected.filter { $0.status == .ordered }
        let fresh = selected.filter { $0.status == .draft }
        let needsDialog = type == .quote
            ? !alreadyQuoted.isEmpty
            : (!alreadyQuoted.isEmpty || !alreadyOrdered.isEmpty)
        if needsDialog {
            resendDialog = ResendDialogState(
                requestType: type,
                alreadyQuoted: alreadyQuoted,
                alreadyOrdered: alreadyOrdered,
                fresh: fresh
            )
        } else {
            proceedSend(type: type, materialIds: selected.map(\.id))
        }
    }

    private func proceedSend(type: MaterialOrderRequest.RequestType, materialIds: [UUID]) {
        resendDialog = nil
        guard !materialIds.isEmpty else { return }
        isSending = true
        let items = materials.filter { materialIds.contains($0.id) }
        var contacts = wholesalers.flatMap(\.contacts).filter { selectedContactIds.contains($0.id) }
        for recipient in oneOffRecipients {
            contacts.append(WholesalerContact(name: recipient.name, email: recipient.email))
        }
        let userName = userStore.currentUser?.fullName ?? "Unknown"
        let userPhone = userStore.currentUser?.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userEmail = userStore.currentUser?.email ?? ""
        let orgName = firebaseBackend.currentOrganization?.name ?? ""
        var senderSignature = userName
        if let phone = userPhone, !phone.isEmpty { senderSignature += "\n\(phone)" }
        if !userEmail.isEmpty { senderSignature += "\n\(userEmail)" }
        if !orgName.isEmpty { senderSignature += "\n\(orgName)" }

        let request = MaterialOrderRequest(
            projectId: project.id,
            projectNumber: project.jobNumber,
            projectName: project.siteName,
            siteAddress: project.siteAddress,
            materials: items,
            requestType: type,
            sentBy: senderSignature,
            recipientContacts: contacts,
            senderName: userName,
            senderEmail: userEmail,
            senderPhone: userPhone?.isEmpty == false ? userPhone : nil,
            senderCompany: orgName,
            companyLogoURL: firebaseBackend.currentOrganization?.companyLogoURL
        )
        let recipientSnapshots = buildRecipientSnapshots(for: contacts)
        let calendar = Calendar.current
        let dayForHistory: Date = {
            if let materialsDay {
                return calendar.startOfDay(for: materialsDay)
            }
            let days = items.map { calendar.startOfDay(for: $0.date) }
            return days.min() ?? calendar.startOfDay(for: Date())
        }()
        let sendRecord = MaterialSendRecord(
            projectId: project.id,
            requestType: type,
            materialsDate: dayForHistory,
            sentBy: userName,
            recipients: recipientSnapshots,
            lines: items.map(\.sendLineSnapshot)
        )

        Task {
            guard let organizationId = MaterialOfflineService.resolvedOrganizationId(firebaseBackend: firebaseBackend) else {
                await MainActor.run { isSending = false }
                return
            }
            do {
                let result = try await MaterialOfflineService.sendMaterialRequest(
                    request,
                    sendRecord: sendRecord,
                    organizationId: organizationId,
                    firebaseBackend: firebaseBackend,
                    isOnline: smartCache.isOnline
                )
                await MainActor.run {
                    isSending = false
                    if result == .queuedForSync {
                        sendConfirmation = SendConfirmationState(
                            requestType: type,
                            itemCount: items.count,
                            recipientCount: contacts.count
                        )
                        NotificationCenter.default.post(
                            name: NSNotification.Name("materialSendHistoryDidChange"),
                            object: nil
                        )
                        return
                    }
                    sendConfirmation = SendConfirmationState(
                        requestType: type,
                        itemCount: items.count,
                        recipientCount: contacts.count
                    )
                    NotificationCenter.default.post(
                        name: NSNotification.Name("materialSendHistoryDidChange"),
                        object: nil
                    )
                }
            } catch {
                await MainActor.run { isSending = false }
            }
        }
    }

    private func buildRecipientSnapshots(for contacts: [WholesalerContact]) -> [MaterialSendRecipientSnapshot] {
        contacts.map { contact in
            let wholesalerName = wholesalers.first { wholesaler in
                wholesaler.contacts.contains(where: { $0.id == contact.id })
            }?.name
            return MaterialSendRecipientSnapshot(
                name: contact.name,
                email: contact.email,
                wholesalerName: wholesalerName
            )
        }
    }
}

private struct MaterialsResendIncludeExcludeSheet: View {
    let dialog: MaterialsSendListSheet.ResendDialogState
    let onContinue: ([UUID]) -> Void
    let onCancel: () -> Void

    @State private var excludedMaterialIds: Set<UUID> = []

    private var previouslySentMaterials: [MaterialItem] {
        dialog.alreadyQuoted + dialog.alreadyOrdered
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(headline)
                        .font(.headline)
                    Text(subheadline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !dialog.alreadyQuoted.isEmpty {
                        materialSection(
                            title: "Already sent for quote",
                            subtitle: "Tap the red × to exclude an item from this send.",
                            items: dialog.alreadyQuoted,
                            tint: MaterialsOrderingTheme.primary
                        )
                    }

                    if !dialog.alreadyOrdered.isEmpty {
                        materialSection(
                            title: "Already ordered",
                            subtitle: "Tap the red × to exclude an item from this send.",
                            items: dialog.alreadyOrdered,
                            tint: MaterialsOrderingTheme.success
                        )
                    }

                    if !dialog.fresh.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New items")
                                .font(.subheadline.weight(.semibold))
                            ForEach(dialog.fresh) { item in
                                materialRow(item, isExcluded: false, canToggle: false)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Review materials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onContinue(selectedMaterialIds)
                    }
                    .disabled(selectedMaterialIds.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedMaterialIds: [UUID] {
        let sentIncluded = previouslySentMaterials
            .filter { !excludedMaterialIds.contains($0.id) }
            .map(\.id)
        return sentIncluded + dialog.fresh.map(\.id)
    }

    private var headline: String {
        let hasQuotes = !dialog.alreadyQuoted.isEmpty
        let hasOrders = !dialog.alreadyOrdered.isEmpty
        if hasQuotes && hasOrders {
            return "Some items have been quoted and some have been ordered"
        }
        if hasOrders {
            return "Some items on this list have already been ordered"
        }
        return "Some items on this list have already been sent for quote"
    }

    private var subheadline: String {
        if dialog.requestType == .quote {
            return "Choose which previously sent items to include in this quote request."
        }
        return "Choose which previously sent items to include in this order."
    }

    @ViewBuilder
    private func materialSection(
        title: String,
        subtitle: String,
        items: [MaterialItem],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                materialRow(
                    item,
                    isExcluded: excludedMaterialIds.contains(item.id),
                    canToggle: true
                )
            }
        }
    }

    private func materialRow(_ item: MaterialItem, isExcluded: Bool, canToggle: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.material)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(isExcluded, color: .secondary)
                    .foregroundStyle(isExcluded ? .secondary : .primary)
                Text(item.status.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canToggle {
                Button {
                    if excludedMaterialIds.contains(item.id) {
                        excludedMaterialIds.remove(item.id)
                    } else {
                        excludedMaterialIds.insert(item.id)
                    }
                } label: {
                    Image(systemName: isExcluded ? "plus.circle.fill" : "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isExcluded ? MaterialsOrderingTheme.primary : .red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExcluded ? "Include \(item.material)" : "Exclude \(item.material)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MaterialsSendConfirmationView: View {
    let project: Project
    let confirmation: MaterialsSendListSheet.SendConfirmationState
    let wholesalers: [Wholesaler]
    let selectedContactIds: Set<UUID>
    let oneOffRecipients: [MaterialsSendListSheet.OneOffRecipient]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(MaterialsOrderingTheme.success)
                    Text(confirmation.requestType == .quote ? "Quote sent" : "Order placed")
                        .font(.title2.weight(.semibold))
                    Text("Sent to \(confirmation.recipientCount) recipients · \(confirmation.itemCount) items")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .tint(MaterialsOrderingTheme.success)
                        .padding(.top, 12)
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

