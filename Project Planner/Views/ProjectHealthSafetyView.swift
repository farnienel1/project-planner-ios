import SwiftUI
import PencilKit
import Combine
import UIKit

private enum HSManagerTab: String, CaseIterable, Identifiable {
    case hub = "Hub"
    case library = "Library"
    case tracking = "Tracking"
    case rams = "RAMS"
    case other = "Other"
    var id: String { rawValue }
}

private enum HSOperativeTab: String, CaseIterable, Identifiable {
    case toolbox = "Toolbox"
    case rams = "RAMS"
    case other = "Other"
    var id: String { rawValue }
}

@MainActor
private final class ProjectHealthSafetyViewModel: ObservableObject {
    @Published var data: HSProjectSafetyData = .empty
    @Published var isLoading = false
    @Published var errorMessage: String?

    let project: Project
    private var didInitialLoad = false

    init(project: Project) {
        self.project = project
    }

    func loadIfNeeded(firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await load(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func load(firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        guard let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) else {
            errorMessage = "Organization is unavailable."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            var loaded = try await firebaseBackend.loadHealthSafetyData(project: project, organizationId: orgId)
            if loaded.talks.isEmpty {
                loaded.talks = Self.defaultLibraryTalks
                loaded.updatedAt = Date()
                try await firebaseBackend.saveHealthSafetyData(loaded, project: project, organizationId: orgId)
            }
            data = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func issueTalk(
        talk: HSToolboxTalk,
        weekCommencing: Date,
        recipients: [String],
        issuedByUserId: String,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        guard !recipients.isEmpty else { return }
        let issueId = UUID().uuidString
        let issue = HSToolboxIssue(
            id: issueId,
            projectId: project.id,
            talkId: talk.id,
            weekCommencing: weekCommencing,
            issuedByUserId: issuedByUserId,
            issuedAt: Date(),
            recipientUserIds: recipients,
            status: .awaiting
        )
        data.issues.insert(issue, at: 0)
        for userId in recipients {
            data.signatures.insert(
                HSToolboxSignature(
                    id: UUID().uuidString,
                    issueId: issueId,
                    userId: userId,
                    status: .pending,
                    readConfirmed: false,
                    signatureImageBase64: nil,
                    signedAt: nil,
                    reminderSentAt: nil
                ),
                at: 0
            )
        }
        recalculateIssueStatuses()
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func addUploadedTalk(
        title: String,
        trade: String,
        purpose: String,
        keyPoints: [String],
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        let normalizedTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneral = normalizedTrade.caseInsensitiveCompare("General") == .orderedSame
        let talk = HSToolboxTalk(
            id: "TBT-UP-\(UUID().uuidString.prefix(8))",
            title: title,
            category: isGeneral ? .general : .trade,
            isGeneral: isGeneral,
            trades: isGeneral ? [] : [normalizedTrade],
            purpose: purpose,
            keyPoints: keyPoints,
            source: .uploaded,
            ownerOrganizationId: organizationId(firebaseBackend: firebaseBackend, userStore: userStore),
            status: .approved,
            version: 1,
            updatedAt: Date(),
            fileURL: nil
        )
        data.talks.insert(talk, at: 0)
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func signTalk(
        issueId: String,
        userId: String,
        readConfirmed: Bool,
        signatureImageBase64: String,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        if let idx = data.signatures.firstIndex(where: { $0.issueId == issueId && $0.userId == userId }) {
            data.signatures[idx].readConfirmed = readConfirmed
            data.signatures[idx].status = .signed
            data.signatures[idx].signatureImageBase64 = signatureImageBase64
            data.signatures[idx].signedAt = Date()
        } else {
            data.signatures.insert(
                HSToolboxSignature(
                    id: UUID().uuidString,
                    issueId: issueId,
                    userId: userId,
                    status: .signed,
                    readConfirmed: readConfirmed,
                    signatureImageBase64: signatureImageBase64,
                    signedAt: Date(),
                    reminderSentAt: nil
                ),
                at: 0
            )
        }
        recalculateIssueStatuses()
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func sendReminder(issueId: String, firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        for idx in data.signatures.indices where data.signatures[idx].issueId == issueId && data.signatures[idx].status == .pending {
            data.signatures[idx].reminderSentAt = Date()
        }
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func addRams(title: String, trade: String, firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        data.ramsDocuments.insert(
            HSRamsDocument(
                id: UUID().uuidString,
                title: title,
                trade: trade,
                version: 1,
                status: "live",
                uploadedAt: Date()
            ),
            at: 0
        )
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func addOtherDoc(title: String, trade: String?, category: String, firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        data.otherDocuments.insert(
            HSOtherDocument(
                id: UUID().uuidString,
                title: title,
                trade: trade,
                category: category,
                uploadedAt: Date()
            ),
            at: 0
        )
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func signatures(for issueId: String) -> [HSToolboxSignature] {
        data.signatures.filter { $0.issueId == issueId }
    }

    private func recalculateIssueStatuses() {
        data.issues = data.issues.map { issue in
            let issueSignatures = data.signatures.filter { $0.issueId == issue.id }
            var updated = issue
            updated.status = (!issueSignatures.isEmpty && issueSignatures.allSatisfy { $0.status == .signed }) ? .completed : .awaiting
            return updated
        }
    }

    private func persist(firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        guard let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) else {
            errorMessage = "Cannot save without organization."
            return
        }
        data.updatedAt = Date()
        do {
            try await firebaseBackend.saveHealthSafetyData(data, project: project, organizationId: orgId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func organizationId(firebaseBackend: FirebaseBackend, userStore: UserStore) -> String? {
        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId ?? userStore.currentUser?.organizationId
        guard let orgId else { return nil }
        let trimmed = orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let defaultLibraryTalks: [HSToolboxTalk] = [
        HSToolboxTalk(id: "TBT-GEN-001", title: "Working at Height", category: .general, isGeneral: true, trades: [], purpose: "Prevent falls and dropped-object incidents.", keyPoints: ["Use suitable access equipment", "Inspect edge protection", "Keep exclusion zones below"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-GEN-002", title: "Manual Handling", category: .general, isGeneral: true, trades: [], purpose: "Reduce musculoskeletal injuries while lifting and carrying.", keyPoints: ["Assess load and route first", "Use mechanical aids where possible", "Team lift when needed"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-GEN-003", title: "PPE Selection and Use", category: .general, isGeneral: true, trades: [], purpose: "Ensure mandatory PPE is selected and used correctly.", keyPoints: ["Task-specific PPE checks", "Inspect damaged PPE", "Replace defective PPE immediately"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-ELE-001", title: "Safe Isolation Procedure", category: .trade, isGeneral: false, trades: ["Electrical"], purpose: "Prove circuits are dead before any electrical intervention.", keyPoints: ["Lock off and tag", "Prove-test-prove sequence", "Record isolation point"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-ELE-002", title: "Temporary Electrical Installations", category: .trade, isGeneral: false, trades: ["Electrical"], purpose: "Control electrical risk on temporary power systems.", keyPoints: ["RCD protection", "Lead routing and inspection", "No damaged connectors"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-PLG-001", title: "Gas Safe Working and Purging", category: .trade, isGeneral: false, trades: ["Plumbing & Gas"], purpose: "Manage purge and ignition risks during gas works.", keyPoints: ["Gas Safe competence", "Tightness testing", "Control ignition sources"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-PLG-002", title: "Legionella and Water Hygiene", category: .trade, isGeneral: false, trades: ["Plumbing & Gas"], purpose: "Maintain hygienic control of water systems.", keyPoints: ["Avoid dead legs", "Flush correctly", "Record disinfection"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-MEC-001", title: "Hot Works Permit Controls", category: .trade, isGeneral: false, trades: ["Mechanical / HVAC"], purpose: "Reduce fire and fume hazards during hot works.", keyPoints: ["Permit before start", "Fire watch and post-watch", "Protect nearby combustibles"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-GRD-001", title: "Excavations and Services Avoidance", category: .trade, isGeneral: false, trades: ["Groundworks"], purpose: "Prevent collapse and service strikes in excavations.", keyPoints: ["CAT and Genny checks", "Edge barriers and access", "Daily inspections"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil),
        HSToolboxTalk(id: "TBT-JOI-001", title: "Wood Dust and Extraction", category: .trade, isGeneral: false, trades: ["Joinery"], purpose: "Control carcinogenic wood dust exposure.", keyPoints: ["On-tool extraction", "RPE where needed", "Never dry sweep"], source: .library, ownerOrganizationId: nil, status: .approved, version: 1, updatedAt: Date(), fileURL: nil)
    ]
}

struct ProjectHealthSafetyView: View {
    let project: Project
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @StateObject private var vm: ProjectHealthSafetyViewModel

    @State private var managerTab: HSManagerTab = .hub
    @State private var operativeTab: HSOperativeTab = .toolbox
    @State private var selectedTradeFilter: String = "All"
    @State private var talkSearchText = ""
    @State private var selectedLibraryTalk: HSToolboxTalk?
    @State private var showingIssueSheet = false
    @State private var showingUploadTalkSheet = false
    @State private var selectedTalkForIssue: HSToolboxTalk?
    @State private var selectedIssueToTrack: HSToolboxIssue?
    @State private var selectedIssueToSign: HSToolboxIssue?
    @State private var selectedIssueToView: HSToolboxIssue?
    @State private var showingAddRams = false
    @State private var showingAddOtherDoc = false
    @State private var operativeWeekFilter: Date?

    init(project: Project) {
        self.project = project
        _vm = StateObject(wrappedValue: ProjectHealthSafetyViewModel(project: project))
    }

    private var isOperative: Bool {
        userStore.isOperativeMode()
    }

    private var tradeFilters: [String] {
        var trades = Set<String>(["All", "General", "My uploads"])
        for talk in vm.data.talks where !talk.isGeneral {
            for trade in talk.trades where !trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trades.insert(trade)
            }
        }
        return ["All", "General"] + trades.filter { $0 != "All" && $0 != "General" && $0 != "My uploads" }.sorted() + ["My uploads"]
    }

    private var filteredLibraryTalks: [HSToolboxTalk] {
        vm.data.talks.filter { talk in
            let matchesSearch: Bool = talkSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || talk.title.localizedCaseInsensitiveContains(talkSearchText)
                || talk.purpose.localizedCaseInsensitiveContains(talkSearchText)
            guard matchesSearch else { return false }
            switch selectedTradeFilter {
            case "All":
                return true
            case "General":
                return talk.isGeneral
            case "My uploads":
                return talk.source == .uploaded
            default:
                return talk.trades.contains(where: { $0.caseInsensitiveCompare(selectedTradeFilter) == .orderedSame })
            }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var blankToolboxTemplateURL: URL? {
        HSToolboxTalkDocumentBuilder.makeBlankTemplate()
    }

    private var availableOperativeWeeks: [Date] {
        let myId = userStore.currentUser?.id ?? ""
        let calendar = Calendar.current
        let weeks = Set(vm.data.issues.compactMap { issue -> Date? in
            guard vm.signatures(for: issue.id).contains(where: { $0.userId == myId }) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: issue.weekCommencing)?.start
        })
        return weeks.sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                if isOperative {
                    operativeContent
                } else {
                    managerContent
                }
            }
            .padding(16)
        }
        .background(HS.bg.ignoresSafeArea())
        .navigationTitle("Health & Safety")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.isLoading {
                ProgressView("Loading H&S...")
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task {
            await vm.loadIfNeeded(firebaseBackend: firebaseBackend, userStore: userStore)
            if operativeWeekFilter == nil {
                operativeWeekFilter = availableOperativeWeeks.first
            }
        }
        .alert("Health & Safety", isPresented: Binding<Bool>(
            get: { vm.errorMessage != nil },
            set: { _ in vm.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: $showingIssueSheet) {
            HSIssueTalkSheet(
                talks: filteredLibraryTalks,
                preselectedTalkId: selectedTalkForIssue?.id
            ) { selectedTalk, weekCommencing, recipients in
                Task {
                    await vm.issueTalk(
                        talk: selectedTalk,
                        weekCommencing: weekCommencing,
                        recipients: recipients,
                        issuedByUserId: userStore.currentUser?.id ?? "unknown",
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
            .environmentObject(userStore)
        }
        .sheet(item: $selectedIssueToTrack) { issue in
            HSTrackIssueView(issue: issue, talk: vm.data.talks.first(where: { $0.id == issue.talkId }), signatures: vm.signatures(for: issue.id)) {
                Task { await vm.sendReminder(issueId: issue.id, firebaseBackend: firebaseBackend, userStore: userStore) }
            }
            .environmentObject(userStore)
        }
        .sheet(item: $selectedIssueToSign) { issue in
            HSSignTalkView(issue: issue, talk: vm.data.talks.first(where: { $0.id == issue.talkId })) { base64Signature in
                Task {
                    await vm.signTalk(
                        issueId: issue.id,
                        userId: userStore.currentUser?.id ?? "",
                        readConfirmed: true,
                        signatureImageBase64: base64Signature,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(item: $selectedLibraryTalk) { talk in
            HSToolboxTalkDetailView(talk: talk) {
                selectedLibraryTalk = nil
                selectedTalkForIssue = talk
                showingIssueSheet = true
            }
        }
        .sheet(item: $selectedIssueToView) { issue in
            HSSignedTalkView(
                issue: issue,
                talk: vm.data.talks.first(where: { $0.id == issue.talkId }),
                signature: vm.signatures(for: issue.id).first(where: { $0.userId == (userStore.currentUser?.id ?? "") })
            )
        }
        .sheet(isPresented: $showingUploadTalkSheet) {
            HSUploadTalkSheet { title, trade, purpose, keyPoints in
                Task {
                    await vm.addUploadedTalk(
                        title: title,
                        trade: trade,
                        purpose: purpose,
                        keyPoints: keyPoints,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddRams) {
            HSAddDocSheet(title: "Upload RAMS") { title, trade, category in
                Task {
                    await vm.addRams(
                        title: title,
                        trade: trade ?? "General",
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddOtherDoc) {
            HSAddDocSheet(title: "Add H&S Document") { title, trade, category in
                Task {
                    await vm.addOtherDoc(
                        title: title,
                        trade: trade,
                        category: category ?? "trade",
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.siteName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(project.jobType == .smallWorks ? "\(project.jobNumber) · Small Works" : "\(project.jobNumber) · Project")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(hex: "#3f86ff"), Color(hex: "#2563eb"), Color(hex: "#1e54cf")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: HS.blue2.opacity(0.34), radius: 18, x: 0, y: 10)
    }

    private var managerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $managerTab) {
                ForEach(HSManagerTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch managerTab {
            case .hub:
                managerHub
            case .library:
                managerLibrary
            case .tracking:
                managerTracking
            case .rams:
                managerRams
            case .other:
                managerOtherDocs
            }
        }
    }

    private var managerHub: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                hsMetricCard(title: "Talks issued", value: "\(vm.data.issues.count)")
                hsMetricCard(title: "Awaiting signatures", value: "\(vm.data.signatures.filter { $0.status == .pending }.count)")
                hsMetricCard(title: "RAMS docs", value: "\(vm.data.ramsDocuments.count)")
            }
            HStack(spacing: 10) {
                hsActionCard(title: "Toolbox Library", subtitle: "Search talks, filter by trade, issue immediately", icon: "books.vertical.fill") {
                    managerTab = .library
                }
                hsActionCard(title: "Track Sign-off", subtitle: "See progress and remind pending operatives", icon: "checkmark.shield.fill") {
                    managerTab = .tracking
                }
            }
        }
    }

    private var managerLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search toolbox talks", text: $talkSearchText)
                    .textInputAutocapitalization(.never)
            }
            .hsCard(padding: 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tradeFilters, id: \.self) { filter in
                        Button(filter) { selectedTradeFilter = filter }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedTradeFilter == filter ? HS.teal : HS.card)
                            .foregroundStyle(selectedTradeFilter == filter ? .white : HS.slate)
                            .clipShape(Capsule())
                    }
                }
            }

            HStack {
                Button {
                    selectedTalkForIssue = nil
                    showingIssueSheet = true
                } label: {
                    Label("Issue selected talk", systemImage: "paperplane.fill")
                }
                .buttonStyle(FilledButtonStyle(tone: .teal))

                Button {
                    showingUploadTalkSheet = true
                } label: {
                    Label("Upload custom talk", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(GhostButtonStyle())
            }

            if let blankToolboxTemplateURL {
                ShareLink(item: blankToolboxTemplateURL) {
                    Label("Download blank template", systemImage: "arrow.down.doc")
                }
                .buttonStyle(GhostButtonStyle())
            }

            VStack(spacing: 8) {
                ForEach(filteredLibraryTalks, id: \.id) { talk in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill((talk.isGeneral ? HS.teal : HS.blue).opacity(0.13))
                                .frame(width: 42, height: 42)
                                .overlay(
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(talk.isGeneral ? HS.teal : HS.blue)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(talk.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(HS.ink)
                                Text(talk.purpose)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(HS.slate)
                                    .lineLimit(1)
                                Text(talk.isGeneral ? "General" : talk.trades.joined(separator: ", "))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(HS.blue)
                                    .lineLimit(1)
                            }
                            Spacer()
                            HSStatusBadge(
                                text: talk.source == .uploaded ? "Uploaded" : "Library",
                                tone: talk.source == .uploaded ? .info : .ok
                            )
                        }

                        HStack {
                            Spacer()
                            Button {
                                selectedTalkForIssue = talk
                                showingIssueSheet = true
                            } label: {
                                Text("Issue")
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(HS.teal.opacity(0.12))
                                    .foregroundStyle(HS.teal)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .hsCard(padding: 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedLibraryTalk = talk
                    }
                }
            }
        }
    }

    private var managerTracking: some View {
        VStack(spacing: 8) {
            ForEach(vm.data.issues, id: \.id) { issue in
                let signatures = vm.signatures(for: issue.id)
                let signedCount = signatures.filter { $0.status == .signed }.count
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(vm.data.talks.first(where: { $0.id == issue.talkId })?.title ?? "Toolbox talk")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(signedCount)/\(max(signatures.count, 1))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    ProgressView(value: Double(signedCount), total: Double(max(signatures.count, 1)))
                        .tint(issue.status == .completed ? .green : .orange)
                    HStack {
                        Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { selectedIssueToTrack = issue }
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .padding(12)
                .hsCard(padding: 12)
            }
        }
    }

    private var managerRams: some View {
        VStack(spacing: 8) {
            if !isOperative {
                Button {
                    showingAddRams = true
                } label: {
                    Label("Upload RAMS", systemImage: "plus")
                }
                .buttonStyle(FilledButtonStyle(tone: .blue))
            }

            ForEach(vm.data.ramsDocuments, id: \.id) { doc in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(doc.title).font(.system(size: 13, weight: .semibold))
                        Text("\(doc.trade) · v\(doc.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(doc.status.capitalized).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                }
                .hsCard(padding: 12)
            }
        }
    }

    private var managerOtherDocs: some View {
        VStack(spacing: 8) {
            if !isOperative {
                Button {
                    showingAddOtherDoc = true
                } label: {
                    Label("Add trade / site doc", systemImage: "plus")
                }
                .buttonStyle(FilledButtonStyle(tone: .blue))
            }

            ForEach(vm.data.otherDocuments, id: \.id) { doc in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(doc.title).font(.system(size: 13, weight: .semibold))
                        Text((doc.trade ?? "General") + " · " + doc.category.capitalized)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .hsCard(padding: 12)
            }
        }
    }

    private var operativeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            let myId = userStore.currentUser?.id ?? ""
            let pendingCount = vm.data.signatures.filter { $0.userId == myId && $0.status == .pending }.count
            if pendingCount > 0 {
                Text("\(pendingCount) toolbox talks to sign")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HS.amberBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Picker("", selection: $operativeTab) {
                ForEach(HSOperativeTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch operativeTab {
            case .toolbox:
                operativeToolboxList
            case .rams:
                managerRams
            case .other:
                managerOtherDocs
            }
        }
    }

    private var operativeToolboxList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !availableOperativeWeeks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableOperativeWeeks, id: \.self) { week in
                            Button(week.formatted(date: .abbreviated, time: .omitted)) {
                                operativeWeekFilter = week
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(operativeWeekFilter == week ? HS.teal : HS.card)
                            .foregroundStyle(operativeWeekFilter == week ? .white : HS.slate)
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            let myId = userStore.currentUser?.id ?? ""
            let filteredIssues = vm.data.issues.filter { issue in
                let assigned = vm.signatures(for: issue.id).contains(where: { $0.userId == myId })
                guard assigned else { return false }
                guard let week = operativeWeekFilter else { return true }
                let issueWeek = Calendar.current.dateInterval(of: .weekOfYear, for: issue.weekCommencing)?.start
                return issueWeek == week
            }

            ForEach(filteredIssues, id: \.id) { issue in
                let mySignature = vm.signatures(for: issue.id).first(where: { $0.userId == myId })
                let isPending = mySignature?.status != .signed
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.data.talks.first(where: { $0.id == issue.talkId })?.title ?? "Toolbox talk")
                        .font(.system(size: 14, weight: .semibold))
                    Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(isPending ? "Open to sign" : "Signed") {
                        if isPending {
                            selectedIssueToSign = issue
                        } else {
                            selectedIssueToView = issue
                        }
                    }
                    .buttonStyle(FilledButtonStyle(tone: isPending ? .teal : .blue))
                }
                .hsCard(padding: 12)
            }
        }
    }

    private func hsMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hsCard(padding: 14)
    }

    private func hsActionCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(.blue)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .hsCard(padding: 14)
        }
        .buttonStyle(.plain)
    }
}

private struct HSIssueTalkSheet: View {
    let talks: [HSToolboxTalk]
    let preselectedTalkId: String?
    let onIssue: (HSToolboxTalk, Date, [String]) -> Void
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTalkId: String?
    @State private var weekCommencing = Date()
    @State private var recipientSearch = ""
    @State private var selectedTrade = "All"
    @State private var selectedRecipientIds: Set<String> = []

    private var availableTrades: [String] {
        let set = Set(
            userStore.organizationUsers
                .filter { $0.isActive && isEligibleRecipient($0) }
                .map { StaffTradeType.displayLabel(presetRaw: $0.tradeTypePreset, custom: $0.tradeTypeCustom) }
        )
        return ["All"] + set.sorted()
    }

    private var filteredRecipients: [AppUser] {
        userStore.organizationUsers.filter { user in
            guard user.isActive && isEligibleRecipient(user) else { return false }
            let trade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
            let tradeMatch = selectedTrade == "All" || trade.caseInsensitiveCompare(selectedTrade) == .orderedSame
            let searchText = recipientSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatch = searchText.isEmpty || user.fullName.localizedCaseInsensitiveContains(searchText)
            return tradeMatch && searchMatch
        }
    }

    private func isEligibleRecipient(_ user: AppUser) -> Bool {
        user.permissions.operativeMode || user.permissions.manager || user.permissions.adminAccess || user.role == .admin || user.isSuperAdmin
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Issue toolbox talk")
                            .font(.system(size: 18, weight: .bold))
                        Text("Pick a talk from library/uploads, choose week commencing, then select recipients by trade.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(HS.slate)
                    }
                    .hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Talk")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Picker("Talk", selection: $selectedTalkId) {
                            Text("Select talk").tag(Optional<String>.none)
                            ForEach(talks, id: \.id) { talk in
                                Text(talk.title).tag(Optional(talk.id))
                            }
                        }
                    }
                    .hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Week commencing")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        DatePicker("Week commencing", selection: $weekCommencing, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filter recipients by trade")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(availableTrades, id: \.self) { trade in
                                    Button(trade) { selectedTrade = trade }
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(selectedTrade == trade ? HS.teal : HS.card)
                                        .foregroundStyle(selectedTrade == trade ? .white : HS.slate)
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search operative by name", text: $recipientSearch)
                        }
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(HS.line, lineWidth: 1)
                        )

                        HStack {
                            Text("Recipients (\(filteredRecipients.count))")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(HS.slate)
                            Spacer()
                            Button("Select all in filter") {
                                selectedRecipientIds.formUnion(filteredRecipients.map(\.id))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.teal)
                        }

                        VStack(spacing: 0) {
                            ForEach(filteredRecipients, id: \.id) { user in
                                let isSelected = selectedRecipientIds.contains(user.id)
                                let trade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
                                Button {
                                    if isSelected { selectedRecipientIds.remove(user.id) } else { selectedRecipientIds.insert(user.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(HS.blue.opacity(0.14))
                                            .frame(width: 34, height: 34)
                                            .overlay(
                                                Text(initials(for: user))
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(HS.blue)
                                            )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(user.fullName.isEmpty ? user.email : user.fullName)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(HS.ink)
                                            Text(trade)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(HS.slate)
                                        }
                                        Spacer()
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(isSelected ? HS.teal : HS.slate2)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                if user.id != filteredRecipients.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                            if filteredRecipients.isEmpty {
                                Text("No recipients for this filter.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(HS.slate2)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 18)
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 6)
                    }
                    .hsCard(padding: 14)

                    Button {
                        guard let selectedTalkId, let talk = talks.first(where: { $0.id == selectedTalkId }) else { return }
                        onIssue(talk, weekCommencing, Array(selectedRecipientIds))
                        dismiss()
                    } label: {
                        Label("Issue to \(selectedRecipientIds.count) operatives", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(FilledButtonStyle(tone: .teal))
                    .disabled(selectedTalkId == nil || selectedRecipientIds.isEmpty)
                    .opacity((selectedTalkId == nil || selectedRecipientIds.isEmpty) ? 0.5 : 1)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Issue Toolbox Talk")
            .onAppear {
                if selectedTalkId == nil {
                    selectedTalkId = preselectedTalkId ?? talks.first?.id
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func initials(for user: AppUser) -> String {
        let name = user.fullName.isEmpty ? user.email : user.fullName
        let chunks = name.split(separator: " ").prefix(2)
        let letters = chunks.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "U" : letters.uppercased()
    }
}

private struct HSToolboxTalkDetailView: View {
    let talk: HSToolboxTalk
    let onIssue: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var talkDocumentURL: URL? {
        HSToolboxTalkDocumentBuilder.makeDocument(for: talk)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HSStatusBadge(
                            text: "\(talk.status == .approved ? "Approved" : "Draft") · \(talk.id)",
                            tone: talk.status == .approved ? .ok : .warn
                        )
                        Text(talk.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(HS.ink)
                        Text(talk.isGeneral ? "General H&S" : talk.trades.joined(separator: ", "))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(HS.blue)
                    }
                    .hsCard(padding: 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purpose")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Text(talk.purpose.isEmpty ? "No purpose text saved for this talk yet." : talk.purpose)
                            .font(.system(size: 14))
                            .foregroundStyle(HS.ink)
                    }
                    .hsCard(padding: 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key control points")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        if talk.keyPoints.isEmpty {
                            Text("No key points saved.")
                                .font(.system(size: 13))
                                .foregroundStyle(HS.slate)
                        } else {
                            ForEach(Array(talk.keyPoints.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(HS.teal)
                                        .padding(.top, 1)
                                    Text(point)
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(HS.ink)
                                }
                            }
                        }
                    }
                    .hsCard(padding: 16)

                    if let talkDocumentURL {
                        ShareLink(item: talkDocumentURL) {
                            Label("Download talk", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    Button {
                        dismiss()
                        onIssue()
                    } label: {
                        Label("Issue this talk", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(FilledButtonStyle(tone: .teal))
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Toolbox Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct HSTrackIssueView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    let signatures: [HSToolboxSignature]
    let onSendReminder: () -> Void
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let signed = signatures.filter { $0.status == .signed }
                let pending = signatures.filter { $0.status != .signed }
                let total = max(signatures.count, 1)
                let percent = Int((Double(signed.count) / Double(total) * 100).rounded())

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SIGN-OFF PROGRESS")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(.white.opacity(0.9))
                                Text("\(percent)%")
                                    .font(.system(size: 40, weight: .heavy))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(signed.count)/\(total)")
                                    .font(.system(size: 26, weight: .heavy))
                                    .foregroundStyle(.white)
                                Text("signed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        ProgressView(value: Double(signed.count), total: Double(total))
                            .tint(.white)
                            .background(Color.white.opacity(0.28))
                    }
                    .padding(18)
                    .background(
                        LinearGradient(colors: [Color(hex: "#19c4b3"), Color(hex: "#0fae9e")], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: HS.teal.opacity(0.3), radius: 11, x: 0, y: 8)

                    if let documentURL = signoffSheetURL() {
                        ShareLink(item: documentURL) {
                            Label("Download operative signatures", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(FilledButtonStyle(tone: .blue))
                    }

                    Text("Signed (\(signed.count))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HS.slate2)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                    recipientListCard(signatures: signed, pending: false)

                    Text("Awaiting (\(pending.count))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HS.slate2)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                    recipientListCard(signatures: pending, pending: true)

                    Button("Send reminder to pending", action: onSendReminder)
                        .buttonStyle(GhostButtonStyle(tint: HS.blue))
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Sign-off tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func recipientListCard(signatures: [HSToolboxSignature], pending: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(signatures, id: \.id) { signature in
                let user = userStore.organizationUsers.first(where: { $0.id == signature.userId })
                let displayName = user?.fullName.isEmpty == false ? user?.fullName ?? signature.userId : (user?.email ?? signature.userId)
                let trade = StaffTradeType.displayLabel(presetRaw: user?.tradeTypePreset, custom: user?.tradeTypeCustom)
                HStack(spacing: 11) {
                    Circle()
                        .fill((pending ? HS.amberBg : HS.greenBg))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Text(initials(from: displayName))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(pending ? HS.amber : HS.green)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HS.ink)
                        if pending {
                            let reminderText = signature.reminderSentAt.map { "reminder sent \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "awaiting signature"
                            Text("\(trade) · \(reminderText)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(HS.slate)
                        } else {
                            Text("\(trade) · signed \(signature.signedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                                .font(.system(size: 11.5))
                                .foregroundStyle(HS.slate)
                        }
                    }
                    Spacer()
                    if pending {
                        HSStatusBadge(text: "Pending", tone: .warn)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(HS.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                if signature.id != signatures.last?.id {
                    Divider().padding(.leading, 58)
                }
            }
            if signatures.isEmpty {
                Text("No records")
                    .font(.system(size: 12))
                    .foregroundStyle(HS.slate2)
                    .padding(.vertical, 18)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 6)
    }

    private func initials(from name: String) -> String {
        let chunks = name.split(separator: " ").prefix(2)
        let letters = chunks.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "U" : letters.uppercased()
    }

    private func signoffSheetURL() -> URL? {
        let title = talk?.title ?? "Toolbox talk"
        var lines: [String] = []
        lines.append("Toolbox Talk Sign-off Sheet")
        lines.append("Talk: \(title)")
        lines.append("Week commencing: \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
        lines.append("")
        lines.append("Name | Trade | Status | Signed At")
        lines.append("---")
        for signature in signatures {
            let user = userStore.organizationUsers.first(where: { $0.id == signature.userId })
            let displayName = user?.fullName.isEmpty == false ? user?.fullName ?? signature.userId : (user?.email ?? signature.userId)
            let trade = StaffTradeType.displayLabel(presetRaw: user?.tradeTypePreset, custom: user?.tradeTypeCustom)
            let status = signature.status == .signed ? "Signed" : "Pending"
            let signedAt = signature.signedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-"
            lines.append("\(displayName) | \(trade) | \(status) | \(signedAt)")
        }
        let filename = "Toolbox-Signoff-\(title.replacingOccurrences(of: " ", with: "-"))-\(Int(issue.weekCommencing.timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

private struct HSSignTalkView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var readConfirmed = false
    @State private var signatureImageData: Data?
    
    private var talkDocumentURL: URL? {
        guard let talk else { return nil }
        return HSToolboxTalkDocumentBuilder.makeDocument(for: talk)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(talk?.title ?? "Toolbox talk")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(HS.ink)
                        Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 12))
                            .foregroundStyle(HS.slate)
                        Text(talk?.purpose ?? "Read full talk before signing.")
                            .font(.system(size: 13))
                            .foregroundStyle(HS.slate)
                    }
                    .hsCard(padding: 16)

                    if let talkDocumentURL {
                        ShareLink(item: talkDocumentURL) {
                            Label("Download toolbox talk", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("I have read and understood this toolbox talk", isOn: $readConfirmed)
                            .tint(HS.teal)
                        HSSignaturePad(imageData: $signatureImageData)
                    }
                    .hsCard(padding: 16)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Sign Toolbox Talk")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        guard let signatureImageData else { return }
                        onSubmit(signatureImageData.base64EncodedString())
                        dismiss()
                    }
                    .foregroundStyle(HS.blue)
                    .disabled(!readConfirmed || signatureImageData == nil)
                }
            }
        }
    }
}

private struct HSSignedTalkView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    let signature: HSToolboxSignature?
    
    private var talkDocumentURL: URL? {
        guard let talk else { return nil }
        return HSToolboxTalkDocumentBuilder.makeDocument(for: talk)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text(talk?.title ?? "Toolbox talk")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(HS.ink)
                    Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundStyle(HS.slate)
                    HSStatusBadge(text: "Signed", tone: .ok)
                    if let purpose = talk?.purpose, !purpose.isEmpty {
                        Text(purpose)
                            .font(.system(size: 13))
                            .foregroundStyle(HS.slate)
                    }
                    if let signatureBase64 = signature?.signatureImageBase64,
                       let data = Data(base64Encoded: signatureBase64),
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 170)
                            .background(Color(hex: "#fbfcfd"))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(HS.line, lineWidth: 1)
                            )
                    }
                    if let signedAt = signature?.signedAt {
                        Text("Signed at \(signedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(HS.slate2)
                    }
                }
                    .hsCard()
                    if let talkDocumentURL {
                        ShareLink(item: talkDocumentURL) {
                            Label("Download toolbox talk", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Signed Talk")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct HSUploadTalkSheet: View {
    let onSave: (String, String, String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var trade = "General"
    @State private var purpose = ""
    @State private var keyPointsRaw = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Talk title", text: $title)
                TextField("Trade (or General)", text: $trade)
                TextField("Purpose", text: $purpose, axis: .vertical)
                TextField("Key points (one per line)", text: $keyPointsRaw, axis: .vertical)
            }
            .navigationTitle("Upload Toolbox Talk")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let points = keyPointsRaw
                            .split(separator: "\n")
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            trade.trimmingCharacters(in: .whitespacesAndNewlines),
                            purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                            points
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct HSAddDocSheet: View {
    let title: String
    let onSave: (String, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var docTitle = ""
    @State private var trade = ""
    @State private var category = "trade"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Document title", text: $docTitle)
                TextField("Trade (optional)", text: $trade)
                TextField("Category (trade/site_wide)", text: $category)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleanTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            docTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            cleanTrade.isEmpty ? nil : cleanTrade,
                            cleanCategory.isEmpty ? nil : cleanCategory
                        )
                        dismiss()
                    }
                    .disabled(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private enum HSToolboxTalkDocumentBuilder {
    static func makeDocument(for talk: HSToolboxTalk) -> URL? {
        if let fileURL = talk.fileURL {
            let trimmed = fileURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.hasPrefix("/") {
                    return URL(fileURLWithPath: trimmed)
                }
                if let url = URL(string: trimmed) {
                    return url
                }
            }
        }
        let outputURL = libraryPDFURL(for: talk)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }
        return buildTalkPDF(
            to: outputURL,
            title: talk.title,
            subtitle: "\(talk.id) · \(talk.isGeneral ? "General H&S" : talk.trades.joined(separator: ", "))",
            purpose: talk.purpose,
            keyPoints: talk.keyPoints,
            footer: "Project Planner Toolbox Library · v\(talk.version) · \(talk.status.rawValue.capitalized)"
        )
    }

    static func makeBlankTemplate() -> URL? {
        let url = libraryRootDirectory().appendingPathComponent("Project-Planner-Toolbox-Talk-Template.pdf")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return buildTalkPDF(
            to: url,
            title: "Project Planner Toolbox Talk Template",
            subtitle: "Blank template",
            purpose: "Use this template to author a site-specific toolbox talk before uploading it back into the library.",
            keyPoints: [
                "Title:",
                "Ref / Trade:",
                "Date / W/C:",
                "Presented by:",
                "Purpose:",
                "Key control points:",
                "References:",
                "Attendee sign-off: Name | Trade | Signature | Date/Time"
            ],
            footer: "Project Planner"
        )
    }

    @discardableResult
    private static func buildTalkPDF(
        to url: URL,
        title: String,
        subtitle: String,
        purpose: String,
        keyPoints: [String],
        footer: String
    ) -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let margin: CGFloat = 44
        let contentWidth = pageRect.width - margin * 2
        let lines = keyPoints.isEmpty ? ["No key control points saved."] : keyPoints

        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                var y = margin

                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1)
                ]
                (title as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 90), withAttributes: titleAttrs)
                y += 40

                let subtitleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: UIColor(red: 0.42, green: 0.47, blue: 0.55, alpha: 1)
                ]
                (subtitle as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 24), withAttributes: subtitleAttrs)
                y += 30

                let sectionAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: UIColor(red: 0.19, green: 0.45, blue: 0.94, alpha: 1)
                ]
                ("PURPOSE" as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 18), withAttributes: sectionAttrs)
                y += 20

                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13),
                    .foregroundColor: UIColor(red: 0.14, green: 0.17, blue: 0.21, alpha: 1)
                ]
                let purposeText = purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No purpose text saved for this talk."
                    : purpose
                let purposeRect = CGRect(x: margin, y: y, width: contentWidth, height: 120)
                (purposeText as NSString).draw(in: purposeRect, withAttributes: bodyAttrs)
                let purposeHeight = (purposeText as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: 1000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bodyAttrs,
                    context: nil
                ).height
                y += max(50, ceil(purposeHeight) + 14)

                ("KEY CONTROL POINTS" as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 18), withAttributes: sectionAttrs)
                y += 22

                for point in lines {
                    let bullet = "• \(point)"
                    let bulletRect = CGRect(x: margin, y: y, width: contentWidth, height: 80)
                    (bullet as NSString).draw(in: bulletRect, withAttributes: bodyAttrs)
                    let bulletHeight = (bullet as NSString).boundingRect(
                        with: CGSize(width: contentWidth, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: bodyAttrs,
                        context: nil
                    ).height
                    y += max(22, ceil(bulletHeight) + 6)
                    if y > pageRect.height - 110 {
                        context.beginPage()
                        y = margin
                    }
                }

                let footerAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: UIColor(red: 0.55, green: 0.59, blue: 0.66, alpha: 1)
                ]
                (footer as NSString).draw(in: CGRect(x: margin, y: pageRect.height - 36, width: contentWidth, height: 20), withAttributes: footerAttrs)
            }
            return url
        } catch {
            return nil
        }
    }

    private static func libraryPDFURL(for talk: HSToolboxTalk) -> URL {
        libraryRootDirectory().appendingPathComponent("\(safeFilename(talk.id))-\(safeFilename(talk.title)).pdf")
    }

    private static func libraryRootDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let directory = base.appendingPathComponent("ProjectPlanner-ToolboxTalkLibrary", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory
    }

    private static func safeFilename(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .prefix(50)
            .description
    }
}

private struct HSSignaturePad: View {
    @Binding var imageData: Data?
    @State private var canvas = PKCanvasView()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Signature")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    canvas.drawing = PKDrawing()
                    imageData = nil
                }
                .font(.system(size: 12, weight: .semibold))
            }
            HSCanvasRepresentable(canvas: $canvas) { exportSignaturePNG() }
                .frame(height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [5]))
                        .foregroundStyle(Color(red: 0.8, green: 0.84, blue: 0.88))
                )
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func exportSignaturePNG() {
        let bounds = canvas.drawing.bounds
        guard !bounds.isEmpty else {
            imageData = nil
            return
        }
        imageData = canvas.drawing.image(from: bounds, scale: UIScreen.main.scale).pngData()
    }
}

private struct HSCanvasRepresentable: UIViewRepresentable {
    @Binding var canvas: PKCanvasView
    let onChange: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1), width: 3)
        canvas.delegate = context.coordinator
        canvas.backgroundColor = UIColor(red: 0.98, green: 0.985, blue: 0.992, alpha: 1)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange()
        }
    }
}
