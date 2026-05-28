import SwiftUI
import PencilKit
import Combine

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

            VStack(spacing: 8) {
                ForEach(filteredLibraryTalks, id: \.id) { talk in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(talk.title)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            HSStatusBadge(text: talk.source == .uploaded ? "Uploaded" : "Library", tone: talk.source == .uploaded ? .info : .ok)
                        }
                        Text(talk.purpose)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(talk.isGeneral ? "General" : talk.trades.joined(separator: ", "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HS.blue)

                        Button {
                            selectedTalkForIssue = talk
                            showingIssueSheet = true
                        } label: {
                            Text("Issue")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(HS.teal)
                    }
                    .hsCard(padding: 12)
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
            Button {
                showingAddRams = true
            } label: {
                Label("Upload RAMS", systemImage: "plus")
            }
            .buttonStyle(FilledButtonStyle(tone: .blue))

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
            Button {
                showingAddOtherDoc = true
            } label: {
                Label("Add trade / site doc", systemImage: "plus")
            }
            .buttonStyle(FilledButtonStyle(tone: .blue))

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
            Form {
                Picker("Talk", selection: $selectedTalkId) {
                    Text("Select talk").tag(Optional<String>.none)
                    ForEach(talks, id: \.id) { talk in
                        Text(talk.title).tag(Optional(talk.id))
                    }
                }
                DatePicker("Week commencing", selection: $weekCommencing, displayedComponents: .date)
                Picker("Filter by trade", selection: $selectedTrade) {
                    ForEach(availableTrades, id: \.self) { trade in
                        Text(trade).tag(trade)
                    }
                }
                TextField("Search operative", text: $recipientSearch)
                Button("Select all in trade") {
                    selectedRecipientIds.formUnion(filteredRecipients.map(\.id))
                }
                Section("Recipients") {
                    ForEach(filteredRecipients, id: \.id) { user in
                        let isSelected = selectedRecipientIds.contains(user.id)
                        Button {
                            if isSelected { selectedRecipientIds.remove(user.id) } else { selectedRecipientIds.insert(user.id) }
                        } label: {
                            HStack {
                                Text(user.fullName)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Issue Toolbox Talk")
            .onAppear {
                if selectedTalkId == nil {
                    selectedTalkId = preselectedTalkId ?? talks.first?.id
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Issue") {
                        guard let selectedTalkId, let talk = talks.first(where: { $0.id == selectedTalkId }) else { return }
                        onIssue(talk, weekCommencing, Array(selectedRecipientIds))
                        dismiss()
                    }
                    .disabled(selectedTalkId == nil || selectedRecipientIds.isEmpty)
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
            List {
                Section {
                    Text(talk?.title ?? "Toolbox talk")
                    let signedCount = signatures.filter { $0.status == .signed }.count
                    ProgressView(value: Double(signedCount), total: Double(max(signatures.count, 1)))
                    Text("\(signedCount) of \(max(signatures.count, 1)) signed")
                }
                Section("Recipients") {
                    ForEach(signatures, id: \.id) { signature in
                        let name = userStore.organizationUsers.first(where: { $0.id == signature.userId })?.fullName ?? signature.userId
                        HStack {
                            Text(name)
                            Spacer()
                            Text(signature.status == .signed ? "Signed" : "Pending")
                                .foregroundStyle(signature.status == .signed ? .green : .orange)
                        }
                    }
                }
            }
            .navigationTitle("Sign-off tracking")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remind pending", action: onSendReminder)
                }
            }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(talk?.title ?? "Toolbox talk")
                        .font(.system(size: 20, weight: .bold))
                    Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(talk?.purpose ?? "Read full talk before signing.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Toggle("I have read and understood this toolbox talk", isOn: $readConfirmed)
                    HSSignaturePad(imageData: $signatureImageData)
                }
                .padding(16)
            }
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

    var body: some View {
        NavigationStack {
            ScrollView {
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
