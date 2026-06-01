import SwiftUI

struct SubcontractorsView: View {
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var userStore: UserStore
    @State private var showingAdd = false
    @State private var searchText = ""
    @State private var selectedTradeFilter: String?

    private var availableTradeFilters: [String] {
        Array(
            Set(
                subcontractorStore.subcontractors
                    .map { $0.subcontractorType.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryHero
                searchBar
                if !availableTradeFilters.isEmpty {
                    tradeFilterRow
                }
                if filteredSubcontractors.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredSubcontractors) { subcontractor in
                        NavigationLink {
                            SubcontractorFirmDetailView(subcontractorId: subcontractor.id)
                                .environmentObject(subcontractorStore)
                        } label: {
                            subcontractorCard(subcontractor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sub contractors")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundColor(Color.theme.primary)
                    .fontWeight(.medium)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if userStore.canManageSubcontractors() {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd, onDismiss: {
            Task { await subcontractorStore.loadData() }
        }) {
            SubcontractorFirmEditorView(existingSubcontractor: nil)
                .environmentObject(subcontractorStore)
        }
        .task {
            await subcontractorStore.loadData()
        }
    }

    private var filteredSubcontractors: [Subcontractor] {
        subcontractorStore.subcontractors
            .filter { sub in
                if let selectedTradeFilter,
                   sub.subcontractorType.caseInsensitiveCompare(selectedTradeFilter) != .orderedSame {
                    return false
                }
                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { return true }
                return sub.name.localizedCaseInsensitiveContains(q) || sub.subcontractorType.localizedCaseInsensitiveContains(q)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var tradeFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tradeFilterChip(label: "All", isSelected: selectedTradeFilter == nil) {
                    selectedTradeFilter = nil
                }
                ForEach(availableTradeFilters, id: \.self) { trade in
                    tradeFilterChip(label: trade, isSelected: selectedTradeFilter == trade) {
                        selectedTradeFilter = trade
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func tradeFilterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Color(red: 0.278, green: 0.333, blue: 0.412))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? (label == "All" ? Color(red: 0.325, green: 0.29, blue: 0.72) : tradeChipColors(for: label).foreground) : Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color(.systemGray5), lineWidth: isSelected ? 0 : 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private var summaryHero: some View {
        let firms = subcontractorStore.subcontractors.count
        let operatives = subcontractorStore.subcontractors.reduce(0) { $0 + $1.contacts.count }
        return VStack(alignment: .leading, spacing: 2) {
            Text("YOUR SUB CONTRACTORS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("\(firms) Firm\(firms == 1 ? "" : "s") · \(operatives) Operative\(operatives == 1 ? "" : "s")")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color(red: 0.325, green: 0.29, blue: 0.72), Color(red: 0.50, green: 0.47, blue: 0.87)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search firms or trades…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No sub contractors yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Add your first sub contractor to start booking them to projects and small works.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func subcontractorCard(_ subcontractor: Subcontractor) -> some View {
        let previewContacts = Array(subcontractor.contacts.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(initials(for: subcontractor.name))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(
                            colors: tradeChipColors(for: subcontractor.subcontractorType).gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(subcontractor.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(subcontractor.subcontractorType)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tradeChipColors(for: subcontractor.subcontractorType).foreground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(tradeChipColors(for: subcontractor.subcontractorType).background)
                            .clipShape(Capsule())
                        Text("\(subcontractor.contacts.count) Operative\(subcontractor.contacts.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !previewContacts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(previewContacts.enumerated()), id: \.element.id) { idx, contact in
                        HStack(spacing: 8) {
                            Text(initials(for: contact.name))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(avatarColor(index: idx))
                                .clipShape(Circle())
                            Text(contact.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !contact.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(contact.email)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("More")
                            .font(.system(size: 10, weight: .semibold))
                        if subcontractor.contacts.count > 3 {
                            Text("(+\(subcontractor.contacts.count - 3))")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.theme.primary)
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func avatarColor(index: Int) -> Color {
        switch index % 4 {
        case 0: return Color(red: 0.09, green: 0.37, blue: 0.65)
        case 1: return Color(red: 0.06, green: 0.43, blue: 0.34)
        case 2: return Color(red: 0.60, green: 0.21, blue: 0.34)
        default: return Color(red: 0.33, green: 0.29, blue: 0.72)
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let result = parts.compactMap { $0.first }.map { String($0) }.joined()
        return result.isEmpty ? "SC" : result
    }

    private func tradeChipColors(for trade: String) -> (foreground: Color, background: Color, gradient: [Color]) {
        let key = trade.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "electrical", "electrician":
            return (
                Color(red: 0.09, green: 0.37, blue: 0.65),
                Color(red: 0.90, green: 0.94, blue: 0.99),
                [Color(red: 0.09, green: 0.37, blue: 0.65), Color(red: 0.15, green: 0.55, blue: 0.92)]
            )
        case "plumbing", "plumbing & hvac", "hvac":
            return (
                Color(red: 0.06, green: 0.43, blue: 0.34),
                Color(red: 0.88, green: 0.97, blue: 0.93),
                [Color(red: 0.06, green: 0.43, blue: 0.34), Color(red: 0.12, green: 0.62, blue: 0.48)]
            )
        case "carpentry", "carpenter":
            return (
                Color(red: 0.55, green: 0.32, blue: 0.08),
                Color(red: 0.99, green: 0.93, blue: 0.85),
                [Color(red: 0.71, green: 0.33, blue: 0.04), Color(red: 0.85, green: 0.47, blue: 0.10)]
            )
        case "drylining", "dryliner":
            return (
                Color(red: 0.45, green: 0.28, blue: 0.58),
                Color(red: 0.95, green: 0.91, blue: 0.98),
                [Color(red: 0.45, green: 0.28, blue: 0.58), Color(red: 0.58, green: 0.38, blue: 0.72)]
            )
        case "bricklaying", "bricklayer":
            return (
                Color(red: 0.60, green: 0.21, blue: 0.34),
                Color(red: 0.99, green: 0.91, blue: 0.94),
                [Color(red: 0.60, green: 0.21, blue: 0.34), Color(red: 0.78, green: 0.30, blue: 0.42)]
            )
        case "mechanical", "ac engineer", "ventilation":
            return (
                Color(red: 0.05, green: 0.52, blue: 0.55),
                Color(red: 0.88, green: 0.97, blue: 0.98),
                [Color(red: 0.05, green: 0.52, blue: 0.55), Color(red: 0.10, green: 0.68, blue: 0.72)]
            )
        default:
            let hash = abs(key.hashValue)
            let palette: [(Color, Color, [Color])] = [
                (Color(red: 0.33, green: 0.29, blue: 0.72), Color(red: 0.92, green: 0.91, blue: 0.98), [Color(red: 0.33, green: 0.29, blue: 0.72), Color(red: 0.50, green: 0.47, blue: 0.87)]),
                (Color(red: 0.09, green: 0.37, blue: 0.65), Color(red: 0.90, green: 0.94, blue: 0.99), [Color(red: 0.09, green: 0.37, blue: 0.65), Color(red: 0.20, green: 0.50, blue: 0.80)]),
                (Color(red: 0.55, green: 0.32, blue: 0.08), Color(red: 0.99, green: 0.93, blue: 0.85), [Color(red: 0.71, green: 0.33, blue: 0.04), Color(red: 0.85, green: 0.47, blue: 0.10)])
            ]
            let pick = palette[hash % palette.count]
            return (pick.0, pick.1, pick.2)
        }
    }
}

private struct SubcontractorFirmDetailView: View {
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    let subcontractorId: UUID
    @State private var showingEdit = false
    @State private var showingAddOperative = false
    @State private var editingContact: SubcontractorContact?

    private var subcontractor: Subcontractor? {
        subcontractorStore.subcontractors.first(where: { $0.id == subcontractorId })
    }

    var body: some View {
        ScrollView {
            if let subcontractor {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard(subcontractor)

                    HStack {
                        sectionLabel("Operatives · \(subcontractor.contacts.count)")
                        Spacer()
                        Button {
                            showingAddOperative = true
                        } label: {
                            Label("Add", systemImage: "plus")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }

                    operativesCard(subcontractor)

                    sectionLabel("Firm contact")
                    contactCard(subcontractor)
                }
                .padding(16)
            } else {
                ContentUnavailableView("Firm not found", systemImage: "exclamationmark.triangle")
                    .padding(.top, 80)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Firm details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if subcontractor != nil {
                    Button {
                        showingEdit = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let subcontractor {
                SubcontractorFirmEditorView(existingSubcontractor: subcontractor)
                    .environmentObject(subcontractorStore)
            }
        }
        .sheet(isPresented: $showingAddOperative) {
            if let subcontractor {
                SubcontractorOperativeEditorSheet(firmName: subcontractor.name) { newContact in
                    appendOperative(newContact)
                }
            }
        }
        .sheet(item: $editingContact) { contact in
            if let subcontractor {
                SubcontractorOperativeEditorSheet(
                    firmName: subcontractor.name,
                    existingContact: contact
                ) { updatedContact in
                    upsertOperative(updatedContact)
                }
            }
        }
    }

    private func appendOperative(_ contact: SubcontractorContact) {
        guard var subcontractor else { return }
        subcontractor.contacts.append(contact)
        subcontractor.updatedAt = Date()
        Task { await subcontractorStore.saveSubcontractor(subcontractor) }
    }

    private func upsertOperative(_ contact: SubcontractorContact) {
        guard var subcontractor else { return }
        if let idx = subcontractor.contacts.firstIndex(where: { $0.id == contact.id }) {
            subcontractor.contacts[idx] = contact
        } else {
            subcontractor.contacts.append(contact)
        }
        subcontractor.updatedAt = Date()
        Task { await subcontractorStore.saveSubcontractor(subcontractor) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    private func headerCard(_ subcontractor: Subcontractor) -> some View {
        VStack(spacing: 8) {
            Text(initials(for: subcontractor.name))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.325, green: 0.29, blue: 0.72), Color(red: 0.50, green: 0.47, blue: 0.87)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(subcontractor.name)
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                Text(subcontractor.subcontractorType)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.52, green: 0.31, blue: 0.04))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.98, green: 0.93, blue: 0.85))
                    .clipShape(Capsule())
                Text("\(subcontractor.contacts.count) Operative\(subcontractor.contacts.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.33, green: 0.29, blue: 0.72))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.93, green: 0.93, blue: 0.99))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func operativesCard(_ subcontractor: Subcontractor) -> some View {
        VStack(spacing: 0) {
            if subcontractor.contacts.isEmpty {
                Text("No operatives added yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ForEach(Array(subcontractor.contacts.enumerated()), id: \.element.id) { idx, contact in
                    Button {
                        editingContact = contact
                    } label: {
                        HStack(spacing: 10) {
                            Text(initials(for: contact.name))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color(red: 0.09, green: 0.37, blue: 0.65))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(contact.position.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if idx < subcontractor.contacts.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func contactCard(_ subcontractor: Subcontractor) -> some View {
        VStack(spacing: 0) {
            contactRow(icon: "globe", title: "Website", value: subcontractor.website ?? "Not set")
            Divider().padding(.leading, 12)
            contactRow(icon: "location.fill", title: "Address", value: subcontractor.address ?? "Not set")
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func contactRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.theme.primary)
                .frame(width: 26, height: 26)
                .background(Color.theme.primary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "SC" : value
    }
}

private struct SubcontractorFirmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    let existingSubcontractor: Subcontractor?

    @State private var name = ""
    @State private var subcontractorType = ""
    @State private var website = ""
    @State private var address = ""
    @State private var contacts: [SubcontractorContact] = []
    @State private var showingAddOperative = false
    @State private var saveErrorMessage: String?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !subcontractorType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var knownTradeTypes: [String] {
        let extras = subcontractorStore.subcontractors.map(\.subcontractorType)
        return TradeTypeInventory.knownTrades(extra: extras)
    }

    private var tradeSuggestions: [String] {
        let query = subcontractorType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return knownTradeTypes
            .filter {
                $0.localizedCaseInsensitiveContains(query) &&
                $0.compare(query, options: .caseInsensitive) != .orderedSame
            }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Firm details")
                    detailsCard

                    HStack {
                        sectionLabel("Operatives")
                        Spacer()
                        Text("Names only · no logins")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    operativesCard

                    Button {
                        showingAddOperative = true
                    } label: {
                        Label("Add operative", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.theme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [5]))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)

                if let saveErrorMessage {
                    Text(saveErrorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(existingSubcontractor == nil ? "New sub contractor" : "Edit sub contractor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showingAddOperative) {
                SubcontractorOperativeEditorSheet(firmName: name) { newContact in
                    contacts.append(newContact)
                }
            }
            .onAppear {
                guard let existingSubcontractor else { return }
                name = existingSubcontractor.name
                subcontractorType = existingSubcontractor.subcontractorType
                website = existingSubcontractor.website ?? ""
                address = existingSubcontractor.address ?? ""
                contacts = existingSubcontractor.contacts
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            inputRow("Sub Contractor Name *", text: $name, placeholder: "Enter sub contractor name", autocap: .words)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                inputRow("Trade *", text: $subcontractorType, placeholder: "Enter trade type here", autocap: .words)
                if !tradeSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tradeSuggestions, id: \.self) { suggestion in
                                Button {
                                    subcontractorType = suggestion
                                } label: {
                                    Text(suggestion)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.theme.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.theme.primary.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            Divider()
            inputRow("Website · optional", text: $website, placeholder: "Firm website", autocap: .never)
            Divider()
            inputRow("Address · optional", text: $address, placeholder: "Firm address", autocap: .words)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func inputRow(_ label: String, text: Binding<String>, placeholder: String, autocap: TextInputAutocapitalization?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.system(size: 14, weight: .medium))
                .textInputAutocapitalization(autocap)
                .autocorrectionDisabled()
        }
        .padding(.vertical, 10)
    }

    private var operativesCard: some View {
        VStack(spacing: 0) {
            if contacts.isEmpty {
                Text("No operatives added yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ForEach(Array(contacts.enumerated()), id: \.element.id) { idx, contact in
                    HStack(spacing: 10) {
                        Text(initials(for: contact.name))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color(red: 0.09, green: 0.37, blue: 0.65))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(contact.position.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            contacts.removeAll(where: { $0.id == contact.id })
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    if idx < contacts.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func initials(for fullName: String) -> String {
        let parts = fullName.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "OP" : value
    }

    private func save() {
        let id = existingSubcontractor?.id ?? UUID()
        let createdAt = existingSubcontractor?.createdAt ?? Date()
        let subcontractor = Subcontractor(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            subcontractorType: subcontractorType.trimmingCharacters(in: .whitespacesAndNewlines),
            website: website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : website.trimmingCharacters(in: .whitespacesAndNewlines),
            address: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines),
            contacts: contacts,
            createdAt: createdAt,
            updatedAt: Date()
        )
        Task {
            TradeTypeInventory.register(subcontractor.subcontractorType)
            await subcontractorStore.saveSubcontractor(subcontractor)
            if let message = subcontractorStore.errorMessage, !message.isEmpty {
                await MainActor.run {
                    saveErrorMessage = message
                }
            } else {
                dismiss()
            }
        }
    }
}

private struct SubcontractorOperativeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let firmName: String
    var existingContact: SubcontractorContact? = nil
    let onSave: (SubcontractorContact) -> Void

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var position: SubcontractorContactPosition = .installer
    @State private var tradeSearchText = ""

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tradeSuggestions: [String] {
        let query = tradeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let seeded = SubcontractorContactPosition.allCases.map(\.rawValue)
        return TradeTypeInventory.knownTrades(extra: seeded)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    firmContextCard

                    label("Name")
                    card {
                        rowField("First name *", text: $firstName, autocap: .words)
                        Divider()
                        rowField("Last name *", text: $lastName, autocap: .words)
                    }

                    label("Contact · optional")
                    card {
                        rowField("Email", text: $email, autocap: .never)
                        Divider()
                        rowField("Phone", text: $phone, autocap: .never, keyboard: .phonePad)
                    }

                    label("Trade type")
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text("Search trade type suggestions")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            rowField("Trade type", text: $tradeSearchText, autocap: .words)
                            if !tradeSuggestions.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(tradeSuggestions, id: \.self) { suggestion in
                                            Button {
                                                tradeSearchText = suggestion
                                                if let matched = SubcontractorContactPosition.allCases.first(where: {
                                                    $0.rawValue.compare(suggestion, options: .caseInsensitive) == .orderedSame
                                                }) {
                                                    position = matched
                                                }
                                            } label: {
                                                Text(suggestion)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(Color.theme.primary)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(Color.theme.primary.opacity(0.1))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            Picker("Role", selection: $position) {
                                ForEach(SubcontractorContactPosition.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: position) { _, newValue in
                                tradeSearchText = newValue.rawValue
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(existingContact == nil ? "Add operative" : "Edit operative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let resolvedPosition = SubcontractorContactPosition.allCases.first(where: {
                            $0.rawValue.compare(
                                tradeSearchText.trimmingCharacters(in: .whitespacesAndNewlines),
                                options: .caseInsensitive
                            ) == .orderedSame
                        }) ?? position
                        let fullName = "\(firstName.trimmingCharacters(in: .whitespacesAndNewlines)) \(lastName.trimmingCharacters(in: .whitespacesAndNewlines))".trimmingCharacters(in: .whitespacesAndNewlines)
                        let contact = SubcontractorContact(
                            id: existingContact?.id ?? UUID(),
                            name: fullName,
                            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                            contactNumber: phone.trimmingCharacters(in: .whitespacesAndNewlines),
                            position: resolvedPosition,
                            createdAt: existingContact?.createdAt ?? Date()
                        )
                        TradeTypeInventory.register(tradeSearchText)
                        onSave(contact)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                guard let existingContact else { return }
                let parts = existingContact.name.split(separator: " ")
                firstName = parts.first.map(String.init) ?? existingContact.name
                lastName = parts.dropFirst().joined(separator: " ")
                email = existingContact.email
                phone = existingContact.contactNumber
                position = existingContact.position
                tradeSearchText = existingContact.position.rawValue
            }
        }
    }

    private var firmContextCard: some View {
        HStack(spacing: 10) {
            Text(initials(for: firmName))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.325, green: 0.29, blue: 0.72), Color(red: 0.50, green: 0.47, blue: 0.87)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(firmName)
                    .font(.system(size: 12, weight: .semibold))
                Text("Adding to this firm's roster")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.8)
        )
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.systemGray5), lineWidth: 0.8)
            )
    }

    private func rowField(_ label: String, text: Binding<String>, autocap: TextInputAutocapitalization?, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .font(.system(size: 14, weight: .medium))
                .textInputAutocapitalization(autocap)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
        }
        .padding(.vertical, 10)
    }

    private func initials(for fullName: String) -> String {
        let parts = fullName.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "SC" : value
    }
}
