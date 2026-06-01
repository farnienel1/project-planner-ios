//
//  WholesalersRevampViews.swift
//  Project Planner
//
//  Visual redesign per WHOLESALERS_SPEC.md / wholesalers.html
//

import SwiftUI

enum WholesalersTheme {
    static let indigo = Color(red: 0.325, green: 0.29, blue: 0.717)
    static let indigoDeep = Color(red: 0.392, green: 0.361, blue: 0.843)
    static let pageBackground = Color(red: 0.933, green: 0.945, blue: 0.965)
    static let card = Color.white
    static let ink = Color(red: 0.043, green: 0.071, blue: 0.125)
    static let inkSoft = Color(red: 0.278, green: 0.333, blue: 0.412)
    static let inkMut = Color(red: 0.486, green: 0.541, blue: 0.627)
    static let border = Color(red: 0.89, green: 0.91, blue: 0.937)
    static let chipIndigoBg = Color(red: 0.922, green: 0.914, blue: 0.976)
    static let chipBlueBg = Color(red: 0.902, green: 0.941, blue: 0.988)
    static let chipGreenBg = Color(red: 0.882, green: 0.969, blue: 0.929)
    static let chipAmberBg = Color(red: 0.992, green: 0.933, blue: 0.859)
    static let green = Color(red: 0.086, green: 0.639, blue: 0.290)
}

// MARK: - List

struct WholesalersListContent: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    var presentedAsSheet: Bool = false
    @Binding var wholesalers: [Wholesaler]
    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var sendRecords: [MaterialSendRecord] = []

    private var filtered: [Wholesaler] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = wholesalers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { wholesaler in
            wholesaler.name.localizedCaseInsensitiveContains(q)
                || (wholesaler.trade?.localizedCaseInsensitiveContains(q) ?? false)
                || (wholesaler.cityFromAddress?.localizedCaseInsensitiveContains(q) ?? false)
                || wholesaler.contacts.contains {
                    $0.name.localizedCaseInsensitiveContains(q) || $0.email.localizedCaseInsensitiveContains(q)
                }
        }
    }

    private var totalContacts: Int {
        wholesalers.reduce(0) { $0 + $1.contacts.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryBanner
                addWholesalerButton
                searchField
                if filtered.isEmpty {
                    emptyState
                } else {
                    ForEach(filtered) { wholesaler in
                        NavigationLink(value: wholesaler.id) {
                            WholesalerListCard(wholesaler: wholesaler)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(WholesalersTheme.pageBackground)
        .navigationDestination(for: UUID.self) { wholesalerId in
            if let wholesaler = wholesalers.first(where: { $0.id == wholesalerId }) {
                WholesalerDetailView(
                    wholesaler: wholesaler,
                    sendRecords: sendRecords,
                    onUpdated: { Task { await reload() } }
                )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            } else {
                EmptyView()
            }
        }
        .navigationTitle("Wholesalers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    if presentedAsSheet {
                        dismiss()
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }
                }
                .fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color(red: 0.145, green: 0.388, blue: 0.922))
                        .clipShape(Circle())
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            WholesalerEditorSheet(mode: .create, wholesaler: nil, isPresented: $showingAdd) {
                Task { await reload() }
            }
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
        .task { await reloadSendRecords() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("reloadWholesalers"))) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("materialSendHistoryDidChange"))) { _ in
            Task { await reloadSendRecords() }
        }
    }

    func reload() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            wholesalers = try await firebaseBackend.loadWholesalers(organizationId: organizationId)
            await reloadSendRecords()
        } catch {
            print("Error loading wholesalers: \(error.localizedDescription)")
        }
    }

    private func reloadSendRecords() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            let all = try await firebaseBackend.loadAllMaterialSendRecords(organizationId: organizationId)
            await MainActor.run { sendRecords = all }
        } catch {
            print("Error loading send records: \(error.localizedDescription)")
        }
    }

    private var addWholesalerButton: some View {
        Button { showingAdd = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text("Add wholesaler")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(WholesalersTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(WholesalersTheme.border, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private var summaryBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("YOUR WHOLESALERS")
                .font(.system(size: 10.5, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(0.88))
            Text("\(wholesalers.count) Wholesaler\(wholesalers.count == 1 ? "" : "s") · \(totalContacts) Contact\(totalContacts == 1 ? "" : "s")")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(
                colors: [WholesalersTheme.indigoDeep, WholesalersTheme.indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: WholesalersTheme.indigo.opacity(0.3), radius: 12, y: 6)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WholesalersTheme.inkMut)
            TextField("Search by name, trade or contact…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(WholesalersTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(WholesalersTheme.border, lineWidth: 0.8)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 28))
                .foregroundStyle(WholesalersTheme.indigo)
                .frame(width: 54, height: 54)
                .background(WholesalersTheme.chipIndigoBg)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("No wholesalers yet")
                .font(.system(size: 16, weight: .heavy))
            Text("Add your first wholesaler to send material orders and quote requests from your projects.")
                .font(.system(size: 13))
                .foregroundStyle(WholesalersTheme.inkMut)
                .multilineTextAlignment(.center)
            Button { showingAdd = true } label: {
                Text("+ Add Wholesaler")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.145, green: 0.388, blue: 0.922))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(WholesalersTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private func openMail(for wholesaler: Wholesaler, quote: Bool) {
        guard let contact = wholesaler.primaryContact,
              !contact.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "mailto:\(contact.email)") else { return }
        UIApplication.shared.open(url)
    }
}

private struct WholesalerListCard: View {
    let wholesaler: Wholesaler

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                Text(WholesalerFormatting.monogram(for: wholesaler.name))
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        LinearGradient(colors: [WholesalersTheme.indigoDeep, WholesalersTheme.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(wholesaler.name)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(WholesalersTheme.ink)
                    HStack(spacing: 8) {
                        if let trade = wholesaler.trade?.trimmingCharacters(in: .whitespacesAndNewlines), !trade.isEmpty {
                            Text(trade)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(Color(red: 0.706, green: 0.325, blue: 0.035))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(WholesalersTheme.chipAmberBg)
                                .clipShape(Capsule())
                        }
                        if let city = wholesaler.cityFromAddress {
                            Label(city, systemImage: "mappin.and.ellipse")
                                .font(.system(size: 11.5))
                                .foregroundStyle(WholesalersTheme.inkMut)
                        }
                        Text("\(wholesaler.contacts.count) contact\(wholesaler.contacts.count == 1 ? "" : "s")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(WholesalersTheme.inkMut)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WholesalersTheme.inkMut)
            }
            .padding(16)

            if !wholesaler.contacts.isEmpty {
                VStack(spacing: 8) {
                    ForEach(wholesaler.contacts.prefix(2)) { contact in
                        HStack(spacing: 10) {
                            Text(String(contact.name.prefix(1)).uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(WholesalersTheme.indigo)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(contact.name)
                                        .font(.system(size: 13, weight: .bold))
                                    if contact.isPrimary {
                                        Text("PRIMARY")
                                            .font(.system(size: 9.5, weight: .heavy))
                                            .foregroundStyle(WholesalersTheme.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(WholesalersTheme.chipGreenBg)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                }
                                Text(contact.email.isEmpty ? "No email" : contact.email)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(WholesalersTheme.inkMut)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color(red: 0.969, green: 0.976, blue: 0.988))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                    if wholesaler.contacts.count > 2 {
                        Text("+\(wholesaler.contacts.count - 2) more contacts")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(WholesalersTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Detail

struct WholesalerDetailView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let wholesaler: Wholesaler
    let sendRecords: [MaterialSendRecord]
    var onUpdated: () -> Void

    @State private var showingEdit = false
    @State private var showingSendHistory = false
    @State private var jobProjects: [Project] = []

    private var stats: (orders: Int, lastOrder: Date?) {
        WholesalerActivity.stats(for: wholesaler, records: sendRecords)
    }

    private var recentActivity: [MaterialSendRecord] {
        WholesalerActivity.recent(for: wholesaler, records: sendRecords, limit: 5)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroCard
                quickActions
                contactsSection
                detailsSection
                if !recentActivity.isEmpty {
                    activitySection
                }
            }
            .padding(16)
        }
        .background(WholesalersTheme.pageBackground)
        .navigationTitle("Wholesaler")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingEdit = true } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            WholesalerEditorSheet(mode: .edit(wholesaler), wholesaler: wholesaler, isPresented: $showingEdit, onSaved: onUpdated)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingSendHistory) {
            WholesalerSendHistoryView(
                wholesaler: wholesaler,
                records: sendRecords,
                projects: jobProjects
            )
            .environmentObject(userStore)
        }
        .task { await loadJobProjects() }
    }

    private func loadJobProjects() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            let projects = try await firebaseBackend.loadProjects(organizationId: organizationId)
            let smallWorks = try await firebaseBackend.loadSmallWorks(organizationId: organizationId)
            await MainActor.run { jobProjects = projects + smallWorks }
        } catch {
            print("Error loading jobs for wholesaler history: \(error.localizedDescription)")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Text(WholesalerFormatting.monogram(for: wholesaler.name))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(wholesaler.name)
                        .font(.system(size: 18, weight: .heavy))
                    Text(subtitleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.88))
                }
            }
            HStack(spacing: 10) {
                statTile(value: "\(stats.orders)", label: "Total orders")
                statTile(value: "\(wholesaler.contacts.count)", label: "Contacts")
                statTile(value: WholesalerActivity.relativeLastOrder(stats.lastOrder), label: "Last order")
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(
            LinearGradient(colors: [WholesalersTheme.indigoDeep, WholesalersTheme.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: WholesalersTheme.indigo.opacity(0.3), radius: 12, y: 6)
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let trade = wholesaler.trade?.trimmingCharacters(in: .whitespacesAndNewlines), !trade.isEmpty {
            parts.append(trade)
        }
        if let city = wholesaler.cityFromAddress { parts.append(city) }
        return parts.isEmpty ? "Wholesaler" : parts.joined(separator: " · ")
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .heavy))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Color.white.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var quickActions: some View {
        if userStore.canViewWholesalerOrderHistory() {
            Button { showingSendHistory = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.706, green: 0.325, blue: 0.035))
                        .frame(width: 40, height: 40)
                        .background(WholesalersTheme.chipAmberBg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quote & order history")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(WholesalersTheme.ink)
                        Text("Search sends across all projects and small works")
                            .font(.system(size: 12))
                            .foregroundStyle(WholesalersTheme.inkMut)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WholesalersTheme.inkMut)
                }
                .padding(14)
                .background(WholesalersTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(WholesalersTheme.border, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func quickTile(title: String, icon: String, bg: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(fg)
                    .frame(width: 34, height: 34)
                    .background(bg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(title)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(WholesalersTheme.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(WholesalersTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTACTS · \(wholesaler.contacts.count)")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(WholesalersTheme.inkMut)
            VStack(spacing: 0) {
                if wholesaler.contacts.isEmpty {
                    Text("Add your first contact in Edit.")
                        .font(.system(size: 13))
                        .foregroundStyle(WholesalersTheme.inkMut)
                        .padding(16)
                } else {
                    ForEach(Array(wholesaler.contacts.enumerated()), id: \.element.id) { index, contact in
                        HStack(spacing: 12) {
                            contactAvatar(contact, index: index)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(contact.name)
                                        .font(.system(size: 13.5, weight: .bold))
                                    if contact.isPrimary {
                                        Text("PRIMARY")
                                            .font(.system(size: 9.5, weight: .heavy))
                                            .foregroundStyle(WholesalersTheme.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(WholesalersTheme.chipGreenBg)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                }
                                Text(contact.email.isEmpty ? "No email" : contact.email)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(WholesalersTheme.inkMut)
                            }
                            Spacer(minLength: 0)
                            Button {
                                openMail(contact: contact)
                            } label: {
                                Image(systemName: "envelope.fill")
                                    .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                                    .frame(width: 30, height: 30)
                                    .background(WholesalersTheme.chipBlueBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .disabled(contact.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.vertical, 13)
                        .padding(.horizontal, 16)
                        if contact.id != wholesaler.contacts.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
            }
            .background(WholesalersTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DETAILS")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(WholesalersTheme.inkMut)
            VStack(spacing: 0) {
                if let address = wholesaler.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
                    detailRow(icon: "mappin.and.ellipse", tint: WholesalersTheme.chipBlueBg, title: "Address", value: address)
                }
                if let account = wholesaler.accountNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "archivebox.fill")
                            .foregroundStyle(WholesalersTheme.inkSoft)
                            .frame(width: 30, height: 30)
                            .background(WholesalersTheme.chipGreenBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ACCOUNT NUMBER")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(WholesalersTheme.inkMut)
                            Text(account)
                                .font(.system(size: 14.5, weight: .bold))
                        }
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = account
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(WholesalersTheme.inkMut)
                        }
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 16)
                }
            }
            .background(WholesalersTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT ACTIVITY")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(WholesalersTheme.inkMut)
            VStack(spacing: 0) {
                ForEach(recentActivity) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.requestType == .quote ? "doc.text.fill" : "paperplane.fill")
                            .foregroundStyle(record.requestType == .quote ? WholesalersTheme.green : Color(red: 0.145, green: 0.388, blue: 0.922))
                            .frame(width: 30, height: 30)
                            .background(record.requestType == .quote ? WholesalersTheme.chipGreenBg : WholesalersTheme.chipBlueBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.requestTypeLabel) · \(record.itemCountLabel)")
                                .font(.system(size: 13, weight: .bold))
                            Text(record.lines.prefix(2).map(\.name).joined(separator: ", "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(WholesalersTheme.inkMut)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(record.sentAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WholesalersTheme.inkMut)
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 16)
                    if record.id != recentActivity.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(WholesalersTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private func detailRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(WholesalersTheme.inkSoft)
                .frame(width: 30, height: 30)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WholesalersTheme.inkMut)
                Text(value)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(WholesalersTheme.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
    }

    private func contactAvatar(_ contact: WholesalerContact, index: Int) -> some View {
        let colors: [Color] = [WholesalersTheme.indigo, WholesalersTheme.green, Color(red: 0.145, green: 0.388, blue: 0.922), Color(red: 0.706, green: 0.325, blue: 0.035)]
        return Text(String(contact.name.prefix(1)).uppercased())
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(colors[index % colors.count])
            .clipShape(Circle())
    }

    private func openMail(contact: WholesalerContact) {
        let email = contact.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, let url = URL(string: "mailto:\(email)") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Organisation quote/order history (wholesaler profile)

private enum WholesalerHistoryTab: String, CaseIterable {
    case quotes = "Quotes"
    case orders = "Orders"
}

struct WholesalerSendHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore

    let wholesaler: Wholesaler
    let records: [MaterialSendRecord]
    let projects: [Project]

    @State private var selectedTab: WholesalerHistoryTab = .quotes
    @State private var jobFilter: String = "All jobs"
    @State private var orderedByFilter: String = "Anyone"
    @State private var dateFilter: Date = Date()
    @State private var useDateFilter = false
    @State private var materialSearch = ""
    @State private var expandedRecordIds: Set<UUID> = []

    private var wholesalerRecords: [MaterialSendRecord] {
        records.filter { $0.involves(wholesaler: wholesaler) }
    }

    private var jobOptions: [String] {
        let labels = projects.map { jobLabel(for: $0) }.sorted()
        return ["All jobs"] + labels
    }

    private var orderedByOptions: [String] {
        var names = Set(wholesalerRecords.map(\.sentBy))
        for user in userStore.organizationUsers where canPlaceMaterialOrders(user) {
            let label = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                names.insert(user.email)
            } else {
                names.insert(label)
            }
        }
        return ["Anyone"] + names.sorted()
    }

    private func canPlaceMaterialOrders(_ user: AppUser) -> Bool {
        guard user.isActive, !user.permissions.operativeMode else { return false }
        return user.isSuperAdmin || user.permissions.adminAccess || user.permissions.manager
    }

    private var filteredRecords: [MaterialSendRecord] {
        let calendar = Calendar.current
        return wholesalerRecords
            .filter { record in
                switch selectedTab {
                case .quotes: return record.requestType == .quote
                case .orders: return record.requestType == .order
                }
            }
            .filter { record in
                guard jobFilter != "All jobs" else { return true }
                return jobLabel(for: record.projectId) == jobFilter
            }
            .filter { record in
                guard orderedByFilter != "Anyone" else { return true }
                return record.sentBy == orderedByFilter
            }
            .filter { record in
                guard useDateFilter else { return true }
                return calendar.isDate(record.historyDay(calendar: calendar), inSameDayAs: calendar.startOfDay(for: dateFilter))
            }
            .filter { record in
                let q = materialSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !q.isEmpty else { return true }
                return record.lines.contains { line in
                    line.name.localizedCaseInsensitiveContains(q)
                        || (line.brand?.localizedCaseInsensitiveContains(q) ?? false)
                        || (line.productCode?.localizedCaseInsensitiveContains(q) ?? false)
                }
            }
            .sorted { $0.sentAt > $1.sentAt }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Type", selection: $selectedTab) {
                    ForEach(WholesalerHistoryTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                filtersPanel

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if filteredRecords.isEmpty {
                            Text("No \(selectedTab.rawValue.lowercased()) match your filters")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(WholesalersTheme.inkMut)
                                .padding(.top, 40)
                        } else {
                            ForEach(filteredRecords) { record in
                                wholesalerHistoryCard(record)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(WholesalersTheme.pageBackground)
            .navigationTitle("\(wholesaler.name) history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if userStore.organizationUsers.isEmpty {
                await userStore.loadOrganizationUsers()
            }
        }
    }

    private var filtersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Filters")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(WholesalersTheme.inkMut)
                Spacer()
                if useDateFilter || jobFilter != "All jobs" || orderedByFilter != "Anyone" || !materialSearch.isEmpty {
                    Button("Clear") {
                        jobFilter = "All jobs"
                        orderedByFilter = "Anyone"
                        useDateFilter = false
                        materialSearch = ""
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(jobOptions, id: \.self) { job in
                        Button(job) { jobFilter = job }
                    }
                } label: {
                    filterChip(title: "Job", value: jobFilter)
                }
                Menu {
                    ForEach(orderedByOptions, id: \.self) { name in
                        Button(name) { orderedByFilter = name }
                    }
                } label: {
                    filterChip(title: "Ordered by", value: orderedByFilter)
                }
            }
            HStack(spacing: 8) {
                Toggle("Filter by materials day", isOn: $useDateFilter)
                    .font(.system(size: 12, weight: .medium))
                if useDateFilter {
                    DatePicker("", selection: $dateFilter, displayedComponents: .date)
                        .labelsHidden()
                }
            }
            TextField("Search materials (name, brand, code)", text: $materialSearch)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func filterChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(WholesalersTheme.inkMut)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(WholesalersTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WholesalersTheme.border, lineWidth: 0.8))
    }

    @ViewBuilder
    private func wholesalerHistoryCard(_ record: MaterialSendRecord) -> some View {
        let isExpanded = expandedRecordIds.contains(record.id)
        let isQuote = record.requestType == .quote
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expandedRecordIds.remove(record.id) }
                else { expandedRecordIds.insert(record.id) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(isQuote ? "QUOTE" : "ORDER")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isQuote ? WholesalersTheme.green : Color(red: 0.145, green: 0.388, blue: 0.922))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isQuote ? WholesalersTheme.chipGreenBg : WholesalersTheme.chipBlueBg)
                            .clipShape(Capsule())
                        Spacer()
                        Text(record.sentAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(WholesalersTheme.inkMut)
                    }
                    if let job = jobLabel(for: record.projectId) {
                        Text(job)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(WholesalersTheme.ink)
                    }
                    Text("Materials day: \(record.historyDay().formatted(date: .abbreviated, time: .omitted)) · by \(record.sentBy)")
                        .font(.system(size: 12))
                        .foregroundStyle(WholesalersTheme.inkMut)
                    if !isExpanded, !record.lines.isEmpty {
                        Text(record.lines.map(\.name).joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(WholesalersTheme.inkSoft)
                            .lineLimit(2)
                    }
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.lines, id: \.materialId) { line in
                        Text("· \(line.name) × \(line.quantity) \(line.unit.rawValue)")
                            .font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(WholesalersTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func jobLabel(for project: Project) -> String {
        "\(project.jobNumber) · \(project.siteName)"
    }

    private func jobLabel(for projectId: UUID) -> String? {
        guard let p = projects.first(where: { $0.id == projectId }) else { return nil }
        return jobLabel(for: p)
    }
}

enum WholesalerActivity {
    static func stats(for wholesaler: Wholesaler, records: [MaterialSendRecord]) -> (orders: Int, lastOrder: Date?) {
        let matching = records.filter { $0.involves(wholesaler: wholesaler) && $0.requestType == .order }
        let last = matching.map(\.sentAt).max()
        return (matching.count, last)
    }

    static func recent(for wholesaler: Wholesaler, records: [MaterialSendRecord], limit: Int) -> [MaterialSendRecord] {
        records
            .filter { $0.involves(wholesaler: wholesaler) }
            .sorted { $0.sentAt > $1.sentAt }
            .prefix(limit)
            .map { $0 }
    }

    static func relativeLastOrder(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Editor (add / edit)

enum WholesalerEditorMode {
    case create
    case edit(Wholesaler)
}

struct WholesalerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let mode: WholesalerEditorMode
    let wholesaler: Wholesaler?
    @Binding var isPresented: Bool
    var onSaved: () -> Void

    @State private var name = ""
    @State private var trade = ""
    @State private var address = ""
    @State private var accountNumber = ""
    @State private var contacts: [WholesalerContact] = []
    @State private var isSaving = false
    @State private var showingDeleteConfirmation = false

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("WHOLESALER DETAILS")
                    VStack(spacing: 0) {
                        editorField(icon: "building.2.fill", tint: WholesalersTheme.chipIndigoBg, label: "Name", text: $name, required: true)
                        editorField(icon: "star.fill", tint: WholesalersTheme.chipAmberBg, label: "Trade / category", text: $trade, required: false)
                        editorField(icon: "mappin.and.ellipse", tint: WholesalersTheme.chipBlueBg, label: "Address · optional", text: $address, required: false)
                        editorField(icon: "archivebox.fill", tint: WholesalersTheme.chipGreenBg, label: "Account number · optional", text: $accountNumber, required: false)
                    }
                    .background(WholesalersTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    sectionHeader("STAFF / CONTACTS · \(contacts.count)")
                    VStack(spacing: 8) {
                        if contacts.isEmpty {
                            Text("Add at least one contact with name and email.")
                                .font(.system(size: 13))
                                .foregroundStyle(WholesalersTheme.inkMut)
                                .padding(12)
                        }
                        ForEach(Array(contacts.enumerated()), id: \.element.id) { index, contact in
                            contactEditRow(contact, index: index)
                        }
                        Button { addContact() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .frame(width: 28, height: 28)
                                    .background(WholesalersTheme.chipBlueBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("Add contact")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(WholesalersTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    if isEdit {
                        Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Wholesaler")
                            }
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(WholesalersTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.35), lineWidth: 1))
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .background(WholesalersTheme.pageBackground)
            .navigationTitle(isEdit ? "Edit Wholesaler" : "Add Wholesaler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.bold)
                        .disabled(!canSave || isSaving)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(canSave ? Color(red: 0.145, green: 0.388, blue: 0.922) : Color.gray.opacity(0.35))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .onAppear(perform: loadInitial)
            .alert("Delete Wholesaler", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await deleteWholesaler() } }
            } message: {
                Text("Are you sure you want to delete \(name)? This cannot be undone.")
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && contacts.contains { !$0.name.isEmpty && !$0.email.isEmpty }
    }

    private func loadInitial() {
        if case .edit(let w) = mode {
            name = w.name
            trade = w.trade ?? ""
            address = w.address ?? ""
            accountNumber = w.accountNumber ?? ""
            contacts = w.contacts
        } else if contacts.isEmpty {
            contacts = [WholesalerContact(name: "", email: "", isPrimary: true)]
        }
    }

    @ViewBuilder
    private func contactEditRow(_ contact: WholesalerContact, index: Int) -> some View {
        let nameBinding = Binding(
            get: { contacts.indices.contains(index) ? contacts[index].name : "" },
            set: { if contacts.indices.contains(index) { contacts[index].name = $0 } }
        )
        let emailBinding = Binding(
            get: { contacts.indices.contains(index) ? contacts[index].email : "" },
            set: { if contacts.indices.contains(index) { contacts[index].email = $0 } }
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(String((contacts.indices.contains(index) ? contacts[index].name : "?").prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(WholesalersTheme.indigo)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: nameBinding)
                        .font(.system(size: 14, weight: .bold))
                    TextField("Email", text: emailBinding)
                        .font(.system(size: 12))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    if contact.isPrimary {
                        Text("PRIMARY · order & quote emails go here")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(WholesalersTheme.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(WholesalersTheme.chipGreenBg)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Button("Make primary") {
                            setPrimary(contactId: contact.id)
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                    }
                }
                Menu {
                    if contacts.count > 1 {
                        Button(role: .destructive) {
                            contacts.removeAll { $0.id == contact.id }
                            ensurePrimary()
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.969, green: 0.976, blue: 0.988))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func setPrimary(contactId: UUID) {
        for i in contacts.indices {
            contacts[i].isPrimary = contacts[i].id == contactId
        }
    }

    private func ensurePrimary() {
        guard !contacts.isEmpty else { return }
        if !contacts.contains(where: \.isPrimary) {
            contacts[0].isPrimary = true
        }
    }

    private func addContact() {
        contacts.append(WholesalerContact(name: "", email: "", isPrimary: contacts.isEmpty))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(WholesalersTheme.inkMut)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func editorField(icon: String, tint: Color, label: String, text: Binding<String>, required: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(WholesalersTheme.inkSoft)
                .frame(width: 30, height: 30)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WholesalersTheme.inkMut)
                TextField(required ? "Required" : "Optional", text: text)
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .padding(.vertical, 13)
        }
        .padding(.horizontal, 16)
        .overlay(Divider(), alignment: .bottom)
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        ensurePrimary()
        let trimmedContacts = contacts.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let primaryId = trimmedContacts.first(where: \.isPrimary)?.id ?? trimmedContacts.first?.id
        var item = wholesaler ?? Wholesaler(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            primaryContactId: primaryId,
            contacts: trimmedContacts
        )
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tradeTrimmed = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        item.trade = tradeTrimmed.isEmpty ? nil : tradeTrimmed
        let addressTrimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        item.address = addressTrimmed.isEmpty ? nil : addressTrimmed
        let accountTrimmed = accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        item.accountNumber = accountTrimmed.isEmpty ? nil : accountTrimmed
        item.contacts = trimmedContacts
        item.primaryContactId = primaryId
        item.updatedAt = Date()

        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            await MainActor.run { isSaving = false }
            return
        }
        do {
            try await firebaseBackend.saveWholesaler(item, organizationId: organizationId)
            await MainActor.run {
                isSaving = false
                isPresented = false
                onSaved()
                NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
            }
        } catch {
            await MainActor.run { isSaving = false }
        }
    }

    private func deleteWholesaler() async {
        guard case .edit(let w) = mode else { return }
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            try await firebaseBackend.deleteWholesaler(wholesalerId: w.id, organizationId: organizationId)
            await MainActor.run {
                isPresented = false
                onSaved()
                NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
            }
        } catch {
            print("Delete wholesaler failed: \(error)")
        }
    }
}
