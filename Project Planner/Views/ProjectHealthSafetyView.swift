import SwiftUI
import PencilKit
import Combine
import UIKit
import PDFKit
import UniformTypeIdentifiers
import FirebaseAuth

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
            // PR 46/49: fill an empty library once. Do not merge/rewrite stored talks on every open
            // (later 51–55 rewrites fought uploads and wiped custom titles).
            if loaded.talks.isEmpty {
                loaded.talks = ToolboxTalkLibrary.bundledTalks()
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
        // Date on the issue sheet is the talk date, not a hidden schedule. Issued talks
        // must appear in Tracking immediately — matching how managers expect the flow.
        let issueId = UUID().uuidString
        let issue = HSToolboxIssue(
            id: issueId,
            projectId: project.id,
            talkId: talk.id,
            weekCommencing: weekCommencing,
            issuedByUserId: issuedByUserId,
            issuedAt: Date(),
            publishAt: nil,
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
        localFileURL: URL?,
        originalFileName: String?,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        let normalizedTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneral = normalizedTrade.caseInsensitiveCompare("General") == .orderedSame
        var uploadedURL: String?
        let persisted = localFileURL.flatMap { HSImportedFile.persist($0) }
        let fileURL = persisted?.url ?? localFileURL
        let fileName = persisted?.name ?? originalFileName ?? localFileURL?.lastPathComponent
        if let fileURL,
           let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) {
            uploadedURL = try? await firebaseBackend.uploadHealthSafetyFile(
                fileURL,
                organizationId: orgId,
                projectId: project.id,
                category: "toolboxTalks",
                fileName: fileName ?? fileURL.lastPathComponent
            )
        }
        if localFileURL != nil && uploadedURL == nil {
            errorMessage = "Couldn’t upload the toolbox talk file. Check your connection and try again."
            return
        }
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
            fileURL: uploadedURL
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

    func sendReminder(issueId: String, firebaseBackend: FirebaseBackend, userStore: UserStore) async -> Int {
        guard let issue = data.issues.first(where: { $0.id == issueId }) else { return 0 }
        let pendingUserIds = data.signatures
            .filter { $0.issueId == issueId && $0.status == .pending }
            .map(\.userId)
        guard !pendingUserIds.isEmpty else { return 0 }
        for idx in data.signatures.indices where data.signatures[idx].issueId == issueId && data.signatures[idx].status == .pending {
            data.signatures[idx].reminderSentAt = Date()
        }
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
        guard let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) else { return pendingUserIds.count }
        let talkTitle = data.talks.first(where: { $0.id == issue.talkId })?.title
            ?? data.ramsDocuments.first(where: { $0.id == issue.ramsDocumentId })?.title
            ?? "H&S sign-off"
        for userId in pendingUserIds {
            let notification = AppNotification(
                organizationId: orgId,
                type: .taskCreated,
                title: "Toolbox Talk Reminder",
                message: "\(talkTitle) is still awaiting your signature.",
                userId: userId,
                relatedId: nil,
                isRead: false,
                createdAt: Date(),
                requiresPermission: nil
            )
            try? await firebaseBackend.saveNotification(notification, organizationId: orgId)
        }
        return pendingUserIds.count
    }

    func removeIssue(issueId: String, firebaseBackend: FirebaseBackend, userStore: UserStore) async {
        data.issues.removeAll { $0.id == issueId }
        data.signatures.removeAll { $0.issueId == issueId }
        recalculateIssueStatuses()
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func isIssueScheduled(_ issue: HSToolboxIssue, now: Date = Date()) -> Bool {
        guard let publishAt = issue.publishAt else { return false }
        return publishAt > now
    }

    func scheduledIssues(now: Date = Date()) -> [HSToolboxIssue] {
        data.issues
            .filter { isIssueScheduled($0, now: now) }
            .sorted { ($0.publishAt ?? .distantFuture) < ($1.publishAt ?? .distantFuture) }
    }

    func visibleIssues(now: Date = Date()) -> [HSToolboxIssue] {
        data.issues
            .filter { !isIssueScheduled($0, now: now) }
    }

    func addRecipients(
        issueId: String,
        recipientIds: [String],
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        guard let issueIdx = data.issues.firstIndex(where: { $0.id == issueId }) else { return }
        var issue = data.issues[issueIdx]
        var allRecipients = Set(issue.recipientUserIds)
        var didAdd = false
        for userId in recipientIds where !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if allRecipients.insert(userId).inserted {
                let alreadyHasSignature = data.signatures.contains { $0.issueId == issueId && $0.userId == userId }
                if !alreadyHasSignature {
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
                didAdd = true
            }
        }
        guard didAdd else { return }
        issue.recipientUserIds = Array(allRecipients)
        data.issues[issueIdx] = issue
        recalculateIssueStatuses()
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func removeRecipient(
        issueId: String,
        recipientId: String,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        guard let issueIdx = data.issues.firstIndex(where: { $0.id == issueId }) else { return }
        data.issues[issueIdx].recipientUserIds.removeAll { $0 == recipientId }
        data.signatures.removeAll { $0.issueId == issueId && $0.userId == recipientId }
        recalculateIssueStatuses()
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func addRams(
        title: String,
        trade: String,
        reviewDate: Date?,
        attachedDocTitles: [String],
        localFileURL: URL?,
        originalFileName: String?,
        recipientUserIds: [String],
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        var uploadedURL: String?
        let persisted = localFileURL.flatMap { HSImportedFile.persist($0) }
        let fileURL = persisted?.url ?? localFileURL
        let fileName = persisted?.name ?? originalFileName ?? localFileURL?.lastPathComponent
        if let fileURL,
           let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) {
            uploadedURL = try? await firebaseBackend.uploadHealthSafetyFile(
                fileURL,
                organizationId: orgId,
                projectId: project.id,
                category: "rams",
                fileName: fileName ?? fileURL.lastPathComponent
            )
        }
        if localFileURL != nil && uploadedURL == nil {
            errorMessage = "Couldn’t upload the RAMS file. Check your connection and try again."
            return
        }
        let doc = HSRamsDocument(
            id: UUID().uuidString,
            title: title,
            trade: trade,
            version: 1,
            status: "live",
            uploadedAt: Date(),
            fileURL: uploadedURL,
            fileName: originalFileName,
            reviewDate: reviewDate,
            attachedDocTitles: attachedDocTitles
        )
        data.ramsDocuments.insert(doc, at: 0)
        await issueRams(
            document: doc,
            recipients: recipientUserIds,
            issuedByUserId: userStore.currentUser?.id ?? firebaseBackend.currentUser?.uid ?? "",
            firebaseBackend: firebaseBackend,
            userStore: userStore
        )
    }

    func issueRams(
        document: HSRamsDocument,
        recipients: [String],
        issuedByUserId: String,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        let uniqueRecipients = Array(Set(recipients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        if let existing = data.issues.first(where: { $0.ramsDocumentId == document.id }) {
            await addRecipients(
                issueId: existing.id,
                recipientIds: uniqueRecipients,
                firebaseBackend: firebaseBackend,
                userStore: userStore
            )
            return
        }
        let issueId = UUID().uuidString
        let issue = HSToolboxIssue(
            id: issueId,
            projectId: project.id,
            talkId: "",
            weekCommencing: Date(),
            issuedByUserId: issuedByUserId,
            issuedAt: Date(),
            publishAt: nil,
            recipientUserIds: uniqueRecipients,
            status: .awaiting,
            ramsDocumentId: document.id
        )
        data.issues.insert(issue, at: 0)
        for userId in uniqueRecipients {
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

    func addOtherDoc(
        title: String,
        trade: String?,
        category: String,
        issuableToClient: Bool,
        localFileURL: URL?,
        originalFileName: String?,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        var uploadedURL: String?
        let persisted = localFileURL.flatMap { HSImportedFile.persist($0) }
        let fileURL = persisted?.url ?? localFileURL
        let fileName = persisted?.name ?? originalFileName ?? localFileURL?.lastPathComponent
        if let fileURL,
           let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) {
            uploadedURL = try? await firebaseBackend.uploadHealthSafetyFile(
                fileURL,
                organizationId: orgId,
                projectId: project.id,
                category: "otherDocuments",
                fileName: fileName ?? fileURL.lastPathComponent
            )
        }
        if localFileURL != nil && uploadedURL == nil {
            errorMessage = "Couldn’t upload the H&S document. Check your connection and try again."
            return
        }
        data.otherDocuments.insert(
            HSOtherDocument(
                id: UUID().uuidString,
                title: title,
                trade: trade,
                category: category,
                uploadedAt: Date(),
                fileURL: uploadedURL,
                fileName: originalFileName,
                issuableToClient: issuableToClient
            ),
            at: 0
        )
        await persist(firebaseBackend: firebaseBackend, userStore: userStore)
    }

    func signatures(for issueId: String) -> [HSToolboxSignature] {
        data.signatures.filter { $0.issueId == issueId }
    }

    func trackingSignOffTotals(now: Date = Date()) -> (signed: Int, total: Int) {
        let allSigs = visibleIssues(now: now).flatMap { signatures(for: $0.id) }
        let signed = allSigs.filter { $0.status == .signed }.count
        return (signed, allSigs.count)
    }

    func issueDisplayTitle(_ issue: HSToolboxIssue) -> String {
        if let ramsId = issue.ramsDocumentId,
           let rams = data.ramsDocuments.first(where: { $0.id == ramsId }) {
            return rams.title
        }
        return ToolboxTalkLibrary.resolvedTitle(talkId: issue.talkId, storedTalks: data.talks)
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

}

struct ProjectHealthSafetyView: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @StateObject private var vm: ProjectHealthSafetyViewModel

    @State private var managerTab: HSManagerTab = .hub
    @State private var operativeTab: HSOperativeTab = .toolbox
    @State private var selectedTradeFilter: String = "All"
    @State private var talkSearchText = ""
    @State private var ramsSearchText = ""
    @State private var otherSearchText = ""
    @State private var showingIssueSheet = false
    @State private var showingUploadTalkSheet = false
    @State private var selectedTalkForIssue: HSToolboxTalk?
    @State private var selectedTalkForPreview: HSToolboxTalk?
    @State private var selectedIssueToTrack: HSToolboxIssue?
    @State private var selectedIssueToSign: HSToolboxIssue?
    @State private var selectedIssueToView: HSToolboxIssue?
    @State private var showingAddRams = false
    @State private var showingAddOtherDoc = false
    @State private var operativeWeekFilter: Date?
    @State private var talkShareItem: HSShareItem?
    @State private var signedShareItem: HSShareItem?
    @State private var showingScheduledTalks = false
    @State private var selectedIssueToAddRecipients: HSToolboxIssue?
    @State private var reminderSuccessMessage: String?
    @State private var showAllAssignedInHub = false
    @State private var showAllAssignedInTracking = false
    @State private var documentPreview: HSDocumentPreviewItem?
    @State private var selectedRamsDocument: HSRamsDocument?
    @State private var selectedRamsToSend: HSRamsDocument?
    @State private var selectedOtherDocument: HSOtherDocument?
    @State private var selectedCustomSignedIssue: HSToolboxIssue?

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
                || talk.displayTitle.localizedCaseInsensitiveContains(talkSearchText)
                || talk.purpose.localizedCaseInsensitiveContains(talkSearchText)
                || talk.id.localizedCaseInsensitiveContains(talkSearchText)
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

    private var filteredRamsDocuments: [HSRamsDocument] {
        let search = ramsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return vm.data.ramsDocuments }
        return vm.data.ramsDocuments.filter { doc in
            doc.title.localizedCaseInsensitiveContains(search)
                || doc.trade.localizedCaseInsensitiveContains(search)
                || doc.status.localizedCaseInsensitiveContains(search)
                || (doc.fileName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredOtherDocuments: [HSOtherDocument] {
        let search = otherSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return vm.data.otherDocuments }
        return vm.data.otherDocuments.filter { doc in
            doc.title.localizedCaseInsensitiveContains(search)
                || (doc.trade ?? "").localizedCaseInsensitiveContains(search)
                || doc.category.localizedCaseInsensitiveContains(search)
                || (doc.fileName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func hsUploadedOnLabel(_ date: Date) -> String {
        "Uploaded \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var groupedLibraryTalks: [(title: String, talks: [HSToolboxTalk])] {
        if selectedTradeFilter != "All" {
            return [(selectedTradeFilter, filteredLibraryTalks)]
        }
        let preferredOrder = [
            "General",
            "Electrical",
            "Groundworks",
            "Joinery",
            "Mechanical / HVAC",
            "Plumbing & Gas",
            "Scaffolding",
            "Brick & Block",
            "Drylining",
            "Painting",
            "Roofing",
            "Demolition",
            "Steel Fixing",
            "Plant"
        ]
        var grouped: [String: [HSToolboxTalk]] = [:]
        for talk in filteredLibraryTalks {
            if talk.source == .uploaded {
                grouped["My uploads", default: []].append(talk)
                continue
            }
            if talk.isGeneral {
                grouped["General", default: []].append(talk)
            } else if !talk.trades.isEmpty {
                for trade in talk.trades {
                    let key = trade.trimmingCharacters(in: .whitespacesAndNewlines)
                    grouped[key, default: []].append(talk)
                }
            } else {
                grouped["Other", default: []].append(talk)
            }
        }
        let ordered = preferredOrder + grouped.keys.filter { !preferredOrder.contains($0) && $0 != "My uploads" }.sorted() + ["My uploads"]
        return ordered.compactMap { name in
            let talks = grouped[name] ?? []
            return talks.isEmpty ? nil : (name, talks)
        }
    }

    private var availableOperativeWeeks: [Date] {
        let myId = userStore.currentUser?.id ?? ""
        let calendar = Calendar.current
        let weeks = Set(vm.visibleIssues().compactMap { issue -> Date? in
            guard vm.signatures(for: issue.id).contains(where: { $0.userId == myId }) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: issue.weekCommencing)?.start
        })
        return weeks.sorted(by: >)
    }

    private var liveRecipientUserIds: Set<String> {
        var ids = Set<String>()
        for booking in managerScheduleStore.managerSiteBookings
        where (booking.locationType == .project || booking.locationType == .smallWork) && booking.locationId == project.id {
            ids.insert(booking.userId)
        }
        let operativeById = Dictionary(operativeStore.operatives.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let userByEmail = Dictionary(
            userStore.organizationUsers.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { _, last in last }
        )
        for booking in bookingStore.bookings where booking.projectId == project.id {
            guard let operative = operativeById[booking.operativeId] else { continue }
            if let user = userByEmail[operative.email.lowercased()] {
                ids.insert(user.id)
            }
        }
        return ids
    }

    private var contextKind: String {
        project.jobType == .smallWorks ? "Small Work" : "Project"
    }

    private var pendingSignatureCount: Int {
        vm.data.signatures.filter { $0.status == .pending }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HSNavBar(
                title: "Health & Safety",
                subtitle: "\(project.jobNumber) · \(project.siteName)",
                onBack: { dismiss() }
            )

            if isOperative {
                HSSegmented(items: operativeSegments, selection: $operativeTab)
                    .padding(.bottom, 6)
            } else {
                HSSegmented(items: managerSegments, selection: $managerTab)
                    .padding(.bottom, 6)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HSContextHero(
                        title: project.siteName,
                        reference: project.jobNumber,
                        kind: contextKind
                    )
                    .padding(.top, 6)

                    if isOperative {
                        operativeContent
                    } else {
                        managerContent
                    }
                }
                .hsGutter()
                .padding(.bottom, 28)
            }
        }
        .hsScreen()
        .toolbar(.hidden, for: .navigationBar)
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
            get: { vm.errorMessage != nil || reminderSuccessMessage != nil },
            set: { _ in
                vm.errorMessage = nil
                reminderSuccessMessage = nil
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? reminderSuccessMessage ?? "")
        }
        .sheet(isPresented: $showingIssueSheet) {
            HSIssueTalkSheet(
                talks: vm.data.talks,
                preselectedTalkId: selectedTalkForIssue?.id,
                liveRecipientUserIds: liveRecipientUserIds
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
            HSTrackIssueView(
                issue: issue,
                talk: vm.data.talks.first(where: { $0.id == issue.talkId }),
                displayTitle: vm.issueDisplayTitle(issue),
                signatures: vm.signatures(for: issue.id)
            ) {
                Task {
                    let reminded = await vm.sendReminder(issueId: issue.id, firebaseBackend: firebaseBackend, userStore: userStore)
                    await MainActor.run {
                        reminderSuccessMessage = reminded > 0 ? "Toolbox Reminder Sent." : "No pending recipients to remind."
                    }
                }
            } onViewSignedTalk: {
                let issueCopy = issue
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    openSignedTalkFromTracking(issueCopy)
                }
            } onRemoveIssue: {
                Task { await vm.removeIssue(issueId: issue.id, firebaseBackend: firebaseBackend, userStore: userStore) }
                selectedIssueToTrack = nil
            } onSendToFurtherOperatives: {
                selectedIssueToAddRecipients = issue
            }
            .environmentObject(userStore)
        }
        .sheet(item: $selectedIssueToAddRecipients) { issue in
            HSAddRecipientsSheet(
                heading: "Send to further operatives",
                intro: "Select additional recipients for this toolbox talk. Existing recipients are excluded.",
                currentRecipientUserIds: Set(issue.recipientUserIds),
                liveRecipientUserIds: liveRecipientUserIds
            ) { selectedUserIds in
                Task {
                    await vm.addRecipients(
                        issueId: issue.id,
                        recipientIds: selectedUserIds,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
            .environmentObject(userStore)
        }
        .sheet(item: $selectedIssueToSign) { issue in
            HSSignTalkView(
                issue: issue,
                talk: vm.data.talks.first(where: { $0.id == issue.talkId }),
                rams: vm.data.ramsDocuments.first(where: { $0.id == issue.ramsDocumentId })
            ) { base64Signature in
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
                rams: vm.data.ramsDocuments.first(where: { $0.id == issue.ramsDocumentId }),
                signature: vm.signatures(for: issue.id).first(where: { $0.userId == (userStore.currentUser?.id ?? "") })
            )
        }
        .sheet(item: $selectedTalkForPreview) { talk in
            HSToolboxTalkDetailView(talk: talk) {
                selectedTalkForIssue = talk
                selectedTalkForPreview = nil
                showingIssueSheet = true
            } onDownload: {
                downloadTalkFromLibrary(talk)
            }
        }
        .sheet(item: $talkShareItem) { item in
            HSDocumentShareSheet(activityItems: [item.url])
        }
        .sheet(item: $signedShareItem) { item in
            HSDocumentShareSheet(activityItems: [item.url])
        }
        .sheet(item: $documentPreview) { item in
            InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
        }
        .sheet(item: $selectedRamsDocument) { doc in
            HSRamsDocumentDetailView(document: doc) {
                selectedRamsDocument = nil
                selectedRamsToSend = doc
            }
        }
        .sheet(item: $selectedRamsToSend) { doc in
            HSAddRecipientsSheet(
                heading: "Send RAMS for signatures",
                intro: "Choose everyone who must sign this RAMS. Tracking uses signed signatures out of everyone it was sent to.",
                currentRecipientUserIds: Set(vm.data.issues.first(where: { $0.ramsDocumentId == doc.id })?.recipientUserIds ?? []),
                liveRecipientUserIds: liveRecipientUserIds
            ) { selectedUserIds in
                Task {
                    await vm.issueRams(
                        document: doc,
                        recipients: selectedUserIds,
                        issuedByUserId: userStore.currentUser?.id ?? "unknown",
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
            .environmentObject(userStore)
        }
        .sheet(item: $selectedOtherDocument) { doc in
            HSOtherDocumentDetailView(document: doc)
        }
        .sheet(item: $selectedCustomSignedIssue) { issue in
            if let talk = vm.data.talks.first(where: { $0.id == issue.talkId }) {
                HSCustomSignedTalkView(
                    talk: talk,
                    issue: issue,
                    signatures: vm.signatures(for: issue.id),
                    users: userStore.organizationUsers
                )
            }
        }
        .sheet(isPresented: $showingScheduledTalks) {
            HSScheduledTalksView(
                issues: vm.scheduledIssues(),
                talksById: Dictionary(vm.data.talks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }),
                usersById: Dictionary(userStore.organizationUsers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }),
                onCancelIssue: { issue in
                    Task { await vm.removeIssue(issueId: issue.id, firebaseBackend: firebaseBackend, userStore: userStore) }
                },
                onAddRecipients: { issue, newRecipientIds in
                    Task { await vm.addRecipients(issueId: issue.id, recipientIds: newRecipientIds, firebaseBackend: firebaseBackend, userStore: userStore) }
                },
                onRemoveRecipient: { issue, recipientId in
                    Task { await vm.removeRecipient(issueId: issue.id, recipientId: recipientId, firebaseBackend: firebaseBackend, userStore: userStore) }
                },
                liveRecipientUserIds: liveRecipientUserIds
            )
            .environmentObject(userStore)
        }
        .sheet(isPresented: $showingUploadTalkSheet) {
            HSUploadTalkSheet { title, trade, purpose, keyPoints, localFileURL, originalFileName in
                Task {
                    await vm.addUploadedTalk(
                        title: title,
                        trade: trade,
                        purpose: purpose,
                        keyPoints: keyPoints,
                        localFileURL: localFileURL,
                        originalFileName: originalFileName,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddRams) {
            HSRamsUploadSheet { title, trade, reviewDate, attachedDocTitles, localFileURL, originalFileName in
                Task {
                    await vm.addRams(
                        title: title,
                        trade: trade ?? "General",
                        reviewDate: reviewDate,
                        attachedDocTitles: attachedDocTitles,
                        localFileURL: localFileURL,
                        originalFileName: originalFileName,
                        recipientUserIds: Array(liveRecipientUserIds),
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddOtherDoc) {
            HSOtherDocumentUploadSheet { title, trade, category, issuableToClient, localFileURL, originalFileName in
                Task {
                    await vm.addOtherDoc(
                        title: title,
                        trade: trade,
                        category: category ?? "trade",
                        issuableToClient: issuableToClient,
                        localFileURL: localFileURL,
                        originalFileName: originalFileName,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
    }

    private var managerSegments: [HSSegmented<HSManagerTab>.Item] {
        [
            .init(id: .hub, title: "Hub", icon: "square.grid.2x2.fill"),
            .init(id: .library, title: "Library", icon: "books.vertical.fill"),
            .init(id: .tracking, title: "Tracking", icon: "checkmark.seal.fill", count: pendingSignatureCount),
            .init(id: .rams, title: "RAMS", icon: "doc.richtext.fill", count: vm.data.ramsDocuments.count),
            .init(id: .other, title: "Other", icon: "folder.fill", count: vm.data.otherDocuments.count)
        ]
    }

    private var operativeSegments: [HSSegmented<HSOperativeTab>.Item] {
        let myId = userStore.currentUser?.id ?? ""
        let pendingMine = vm.data.signatures.filter { $0.userId == myId && $0.status == .pending }.count
        return [
            .init(id: .toolbox, title: "Toolbox", icon: "checkmark.seal.fill", count: pendingMine),
            .init(id: .rams, title: "RAMS", icon: "doc.richtext.fill", count: vm.data.ramsDocuments.count),
            .init(id: .other, title: "Other", icon: "folder.fill", count: vm.data.otherDocuments.count)
        ]
    }

    private func openSignedTalkFromTracking(_ issue: HSToolboxIssue) {
        if let talk = vm.data.talks.first(where: { $0.id == issue.talkId }), talk.isCustomUpload {
            selectedCustomSignedIssue = issue
        } else {
            Task { await generateSignedIssuePDF(issue: issue) }
        }
    }

    private func downloadTalkFromLibrary(_ talk: HSToolboxTalk) {
        if talk.isCustomUpload, let remote = talk.storedFileURL {
            presentDocumentPreview(HSDocumentPreviewItem(title: talk.displayTitle, remoteURL: remote, noun: "toolbox talk"))
            return
        }
        guard let generated = HSTalkPDFBuilder.makePDF(for: talk) else { return }
        presentTalkShareSheet(with: generated)
    }

    private func downloadBlankTalkTemplate() {
        let blank = HSToolboxTalk(
            id: "TBT-BLANK",
            title: "Toolbox Talk — blank template",
            category: .general,
            isGeneral: true,
            trades: [],
            purpose: "Write the purpose of this talk here.",
            keyPoints: [
                "Key control point 1",
                "Key control point 2",
                "Key control point 3"
            ],
            source: .library,
            ownerOrganizationId: nil,
            status: .draft,
            version: 1,
            updatedAt: Date(),
            fileURL: nil
        )
        guard let generated = HSTalkPDFBuilder.makePDF(for: blank) else { return }
        presentTalkShareSheet(with: generated)
    }

    private func presentDocumentPreview(_ item: HSDocumentPreviewItem) {
        dismissActiveSheetsThen {
            documentPreview = item
        }
    }

    private func isIssueOverdue(_ issue: HSToolboxIssue) -> Bool {
        guard issue.status != .completed else { return false }
        let weekStart = Calendar.current.startOfDay(for: issue.weekCommencing)
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        return weekEnd < Date()
    }

    private func myAssignedIssueEntries() -> [(issue: HSToolboxIssue, signature: HSToolboxSignature)] {
        let myUserId = userStore.currentUser?.id ?? ""
        guard !myUserId.isEmpty else { return [] }
        return vm.visibleIssues().compactMap { issue in
            guard let signature = vm.signatures(for: issue.id).first(where: { $0.userId == myUserId }) else { return nil }
            return (issue, signature)
        }
        .sorted { $0.issue.issuedAt > $1.issue.issuedAt }
    }

    private func generateSignedIssuePDF(issue: HSToolboxIssue) async {
        guard let talk = vm.data.talks.first(where: { $0.id == issue.talkId }) else { return }
        let signatures = vm.signatures(for: issue.id)
        let generated = await HSSignedTalkPDFBuilder.makePDF(
            talk: talk,
            issue: issue,
            signatures: signatures,
            userLookup: userStore.organizationUsers
        )
        await MainActor.run {
            guard let generated else { return }
            presentSignedShareSheet(with: generated)
        }
    }

    private func presentTalkShareSheet(with url: URL) {
        dismissActiveSheetsThen {
            talkShareItem = HSShareItem(url: url)
        }
    }

    private func presentSignedShareSheet(with url: URL) {
        dismissActiveSheetsThen {
            signedShareItem = HSShareItem(url: url)
        }
    }

    private func dismissActiveSheetsThen(_ action: @escaping () -> Void) {
        let hasPresentedSheet =
            selectedTalkForPreview != nil ||
            selectedIssueToTrack != nil ||
            selectedIssueToSign != nil ||
            selectedIssueToView != nil ||
            selectedRamsDocument != nil ||
            selectedOtherDocument != nil ||
            selectedCustomSignedIssue != nil ||
            documentPreview != nil

        if hasPresentedSheet {
            selectedTalkForPreview = nil
            selectedIssueToTrack = nil
            selectedIssueToSign = nil
            selectedIssueToView = nil
            selectedRamsDocument = nil
            selectedOtherDocument = nil
            selectedCustomSignedIssue = nil
            documentPreview = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                action()
            }
            return
        }
        action()
    }

    private var managerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        VStack(alignment: .leading, spacing: 0) {
            if !isOperative {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Manager access")
                            .font(HSFont.cardTitle)
                            .foregroundStyle(.white)
                            .hsNoClip(1)
                        Text("Add, edit, issue & track all H&S records")
                            .font(HSFont.meta)
                            .foregroundStyle(.white.opacity(0.88))
                            .hsNoClip(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HS.heroBlue)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: HS.blue.opacity(0.28), radius: 16, y: 8)
                .padding(.top, 16)
            }

            let mine = myAssignedIssueEntries()
            HSSectionHeader(
                title: "My toolbox talks",
                trailing: mine.count > 3 ? "See all" : nil,
                trailingAction: {
                    showAllAssignedInHub = true
                    managerTab = .tracking
                }
            )

            if mine.isEmpty {
                HSEmptyState(
                    icon: "checkmark.seal",
                    title: "Nothing to sign",
                    message: "Toolbox talks issued to you will appear here for sign-off.",
                    actionTitle: isOperative ? nil : "Issue a talk",
                    action: isOperative ? nil : {
                        managerTab = .library
                        showingIssueSheet = true
                    }
                )
            } else {
                let visibleMine = showAllAssignedInHub ? mine : Array(mine.prefix(3))
                VStack(spacing: HSMetric.rowGap) {
                    ForEach(visibleMine, id: \.issue.id) { entry in
                        assignedTalkCard(entry)
                    }
                }
            }

            HSSectionHeader(title: "This \(contextKind.lowercased())")

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: HSMetric.rowGap), GridItem(.flexible(), spacing: HSMetric.rowGap)],
                spacing: HSMetric.rowGap
            ) {
                HSStatTile(value: "\(vm.visibleIssues().count)", label: "Talks issued", accent: HS.ink, icon: "paperplane.fill") {
                    managerTab = .tracking
                }
                HSStatTile(value: "\(pendingSignatureCount)", label: "Awaiting signatures", accent: HS.amber, icon: "clock.fill") {
                    managerTab = .tracking
                }
                HSStatTile(value: "\(vm.data.ramsDocuments.count)", label: "RAMS documents", accent: HS.blue, icon: "doc.richtext.fill") {
                    managerTab = .rams
                }
                HSStatTile(value: "\(vm.scheduledIssues().count)", label: "Scheduled talks", accent: HS.violet, icon: "calendar") {
                    showingScheduledTalks = true
                }
            }

            HSSectionHeader(title: "Quick actions")

            VStack(spacing: HSMetric.rowGap) {
                HSActionRow(icon: "paperplane.fill", tint: HS.teal, title: "Issue a toolbox talk", subtitle: "Pick a talk and send it to operatives for sign-off") {
                    managerTab = .library
                    showingIssueSheet = true
                }
                HSActionRow(icon: "arrow.up.doc.fill", tint: HS.violet, title: "Upload a toolbox talk", subtitle: "Add your own talk to the library") {
                    showingUploadTalkSheet = true
                }
                HSActionRow(icon: "doc.richtext.fill", tint: HS.blue, title: "Upload RAMS", subtitle: "Add a risk assessment and method statement") {
                    showingAddRams = true
                }
                HSActionRow(icon: "folder.fill", tint: HS.navy, title: "Add H&S document", subtitle: "Safe isolation, COSHH, permits and more") {
                    showingAddOtherDoc = true
                }
                HSActionRow(
                    icon: "calendar.badge.clock",
                    tint: HS.violet,
                    title: "Scheduled toolbox talks",
                    subtitle: "Manage future talks and recipients",
                    badge: vm.scheduledIssues().isEmpty ? nil : "\(vm.scheduledIssues().count)"
                ) {
                    showingScheduledTalks = true
                }
            }
        }
    }

    @ViewBuilder
    private func assignedTalkCard(_ entry: (issue: HSToolboxIssue, signature: HSToolboxSignature)) -> some View {
        let talk = vm.data.talks.first(where: { $0.id == entry.issue.talkId })
        let signatures = vm.signatures(for: entry.issue.id)
        let signedCount = signatures.filter { $0.status == .signed }.count
        let isPending = entry.signature.status != .signed
        let overdue = isPending && isIssueOverdue(entry.issue)
        HSTalkCard(
            title: vm.issueDisplayTitle(entry.issue),
            reference: talk?.id ?? entry.issue.ramsDocumentId,
            trade: talk?.tradeLabel ?? vm.data.ramsDocuments.first(where: { $0.id == entry.issue.ramsDocumentId })?.trade,
            weekCommencing: entry.issue.ramsDocumentId == nil
                ? "W/C \(entry.issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))"
                : "Sent \(entry.issue.issuedAt.formatted(date: .abbreviated, time: .omitted))",
            status: isPending ? (overdue ? .overdue : .awaiting) : .signed,
            signedProgress: (signedCount, signatures.count),
            primaryTitle: isPending ? "Sign now" : "View signed",
            primaryTone: isPending ? .green : .blue,
            primaryAction: {
                if isPending { selectedIssueToSign = entry.issue } else { selectedIssueToView = entry.issue }
            },
            secondaryTitle: "Details",
            secondaryAction: { selectedIssueToTrack = entry.issue },
            onOpen: {
                if isPending { selectedIssueToSign = entry.issue } else { selectedIssueToView = entry.issue }
            }
        )
    }

    private var managerLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HSSearchField(placeholder: "Search \(max(vm.data.talks.count, 100))+ talks…", text: $talkSearchText)
                .padding(.top, 16)

            HSChipRow(
                chips: tradeFilters.map { HSChipRow<String>.Chip(id: $0, title: $0) },
                selection: $selectedTradeFilter
            )
            .padding(.top, 10)

            HStack(spacing: 10) {
                Button {
                    HSHaptic.tap()
                    downloadBlankTalkTemplate()
                } label: {
                    Label("Download blank template", systemImage: "arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HSGhostButton(tint: HS.blue))

                Button {
                    HSHaptic.tap()
                    showingUploadTalkSheet = true
                } label: {
                    Label("Upload your own", systemImage: "arrow.up.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HSGhostButton(tint: HS.violet))
            }
            .padding(.top, 12)

            if groupedLibraryTalks.isEmpty {
                HSEmptyState(
                    icon: "books.vertical",
                    title: "No talks found",
                    message: "Try another search or trade filter, or upload your own talk.",
                    actionTitle: "Upload a talk",
                    action: { showingUploadTalkSheet = true }
                )
                .padding(.top, 16)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedLibraryTalks, id: \.title) { group in
                        HSSectionHeader(title: groupHeaderTitle(group.title))
                        ForEach(group.talks, id: \.id) { talk in
                            HSLibraryRow(
                                title: talk.displayTitle,
                                reference: talk.id,
                                purpose: talk.purpose,
                                trade: talk.tradeLabel,
                                approved: talk.status == .approved,
                                isCustom: talk.isCustomUpload,
                                onOpen: { selectedTalkForPreview = talk },
                                onIssue: {
                                    selectedTalkForIssue = talk
                                    showingIssueSheet = true
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func groupHeaderTitle(_ title: String) -> String {
        title
    }

    private var managerTracking: some View {
        VStack(alignment: .leading, spacing: 0) {
            let visible = vm.visibleIssues()
            let totals = vm.trackingSignOffTotals()
            HSSignOffHero(signed: totals.signed, total: totals.total, talkTitle: "All sent RAMS & talks")
                .padding(.top, 16)

            let mine = myAssignedIssueEntries()
            if !mine.isEmpty {
                HSSectionHeader(
                    title: "Assigned to me",
                    trailing: mine.count > 3 ? (showAllAssignedInTracking ? "Show less" : "See all") : nil,
                    trailingAction: { showAllAssignedInTracking.toggle() }
                )
                let visibleMine = showAllAssignedInTracking ? mine : Array(mine.prefix(3))
                VStack(spacing: HSMetric.rowGap) {
                    ForEach(visibleMine, id: \.issue.id) { entry in
                        assignedTalkCard(entry)
                    }
                }
            }

            HSSectionHeader(title: "Issued talks")
            if visible.isEmpty {
                HSEmptyState(
                    icon: "paperplane",
                    title: "Nothing sent yet",
                    message: "Send RAMS or issue a toolbox talk so signatures can be tracked. The percentage is signed signatures out of everyone those documents were sent to.",
                    actionTitle: "Issue a talk",
                    action: {
                        managerTab = .library
                        showingIssueSheet = true
                    }
                )
            } else {
                LazyVStack(spacing: HSMetric.rowGap) {
                    ForEach(visible, id: \.id) { issue in
                        let talk = vm.data.talks.first(where: { $0.id == issue.talkId })
                        let signatures = vm.signatures(for: issue.id)
                        let signedCount = signatures.filter { $0.status == .signed }.count
                        let overdue = isIssueOverdue(issue)
                        HSTalkCard(
                            title: vm.issueDisplayTitle(issue),
                            reference: talk?.id ?? issue.ramsDocumentId,
                            trade: talk?.tradeLabel ?? vm.data.ramsDocuments.first(where: { $0.id == issue.ramsDocumentId })?.trade,
                            weekCommencing: issue.ramsDocumentId == nil
                                ? "W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))"
                                : "Sent \(issue.issuedAt.formatted(date: .abbreviated, time: .omitted))",
                            status: issue.status == .completed ? .signed : (overdue ? .overdue : .awaiting),
                            signedProgress: (signedCount, signatures.count),
                            primaryTitle: "Open",
                            primaryTone: .teal,
                            primaryAction: { selectedIssueToTrack = issue },
                            onOpen: { selectedIssueToTrack = issue }
                        )
                    }
                }
            }
        }
    }

    private var managerRams: some View {
        VStack(alignment: .leading, spacing: 0) {
            HSSearchField(placeholder: "Search RAMS…", text: $ramsSearchText)
                .padding(.top, 16)
                .padding(.bottom, 12)
            HSSectionHeader(title: "RAMS")
            if !isOperative {
                Button {
                    HSHaptic.tap()
                    showingAddRams = true
                } label: {
                    Label("Upload RAMS", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HSFilledButton(tone: .blue))
                .padding(.bottom, 12)
            }
            if vm.data.ramsDocuments.isEmpty {
                HSEmptyState(
                    icon: "doc.richtext",
                    title: "No RAMS yet",
                    message: "Upload a risk assessment and method statement so the team can preview and share it.",
                    actionTitle: isOperative ? nil : "Upload RAMS",
                    action: isOperative ? nil : { showingAddRams = true }
                )
            } else if filteredRamsDocuments.isEmpty {
                HSEmptyState(
                    icon: "magnifyingglass",
                    title: "No matching RAMS",
                    message: "Try a different title, trade, or file name."
                )
            } else {
                LazyVStack(spacing: HSMetric.rowGap) {
                    ForEach(filteredRamsDocuments, id: \.id) { doc in
                        Button {
                            HSHaptic.tap()
                            selectedRamsDocument = doc
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                HSIconTile(systemName: "doc.richtext.fill", tint: HS.blue, size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(doc.title)
                                        .font(HSFont.cardTitle)
                                        .foregroundStyle(HS.ink)
                                        .hsNoClip(2)
                                    Text("\(doc.trade) · v\(doc.version)")
                                        .font(HSFont.meta)
                                        .foregroundStyle(HS.slate)
                                        .hsNoClip(1)
                                    Text(hsUploadedOnLabel(doc.uploadedAt))
                                        .font(HSFont.meta)
                                        .foregroundStyle(HS.slate2)
                                        .hsNoClip(1)
                                }
                                Spacer(minLength: 6)
                                HSBadge(text: doc.status.capitalized, tone: .ok)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(HS.slate2)
                            }
                        }
                        .buttonStyle(HSPressStyle())
                        .hsTappableCard(padding: 14)
                    }
                }
            }
        }
    }

    private var managerOtherDocs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HSSearchField(placeholder: "Search other documents…", text: $otherSearchText)
                .padding(.top, 16)
                .padding(.bottom, 12)
            HSSectionHeader(title: "Other H&S documents")
            if !isOperative {
                Button {
                    HSHaptic.tap()
                    showingAddOtherDoc = true
                } label: {
                    Label("Add trade / site doc", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HSFilledButton(tone: .blue))
                .padding(.bottom, 12)
            }
            if vm.data.otherDocuments.isEmpty {
                HSEmptyState(
                    icon: "folder",
                    title: "No documents yet",
                    message: "Add Safe Isolation, COSHH, permits and other trade-specific files here.",
                    actionTitle: isOperative ? nil : "Add document",
                    action: isOperative ? nil : { showingAddOtherDoc = true }
                )
            } else if filteredOtherDocuments.isEmpty {
                HSEmptyState(
                    icon: "magnifyingglass",
                    title: "No matching documents",
                    message: "Try a different title, trade, or file name."
                )
            } else {
                LazyVStack(spacing: HSMetric.rowGap) {
                    ForEach(filteredOtherDocuments, id: \.id) { doc in
                        Button {
                            HSHaptic.tap()
                            selectedOtherDocument = doc
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                HSIconTile(systemName: "folder.fill", tint: HS.navy, size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(doc.title)
                                        .font(HSFont.cardTitle)
                                        .foregroundStyle(HS.ink)
                                        .hsNoClip(2)
                                    Text((doc.trade ?? "General") + " · " + doc.category.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(HSFont.meta)
                                        .foregroundStyle(HS.slate)
                                        .hsNoClip(1)
                                    Text(hsUploadedOnLabel(doc.uploadedAt))
                                        .font(HSFont.meta)
                                        .foregroundStyle(HS.slate2)
                                        .hsNoClip(1)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(HS.slate2)
                            }
                        }
                        .buttonStyle(HSPressStyle())
                        .hsTappableCard(padding: 14)
                    }
                }
            }
        }
    }

    private var operativeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            let myId = userStore.currentUser?.id ?? ""
            let pendingCount = vm.data.signatures.filter { $0.userId == myId && $0.status == .pending }.count
            if pendingCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(HS.amber)
                    Text("\(pendingCount) toolbox talk\(pendingCount == 1 ? "" : "s") to sign")
                        .font(HSFont.cardTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                }
                .hsCard()
                .padding(.top, 12)
            }

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
        VStack(alignment: .leading, spacing: 0) {
            if !availableOperativeWeeks.isEmpty {
                HSChipRow(
                    chips: availableOperativeWeeks.map { week in
                        HSChipRow<Date>.Chip(id: week, title: week.formatted(date: .abbreviated, time: .omitted))
                    },
                    selection: Binding(
                        get: { operativeWeekFilter ?? availableOperativeWeeks.first ?? Date() },
                        set: { operativeWeekFilter = $0 }
                    )
                )
                .padding(.top, 12)
            }

            let myId = userStore.currentUser?.id ?? ""
            let filteredIssues = vm.visibleIssues().filter { issue in
                let assigned = vm.signatures(for: issue.id).contains(where: { $0.userId == myId })
                guard assigned else { return false }
                guard let week = operativeWeekFilter else { return true }
                let issueWeek = Calendar.current.dateInterval(of: .weekOfYear, for: issue.weekCommencing)?.start
                return issueWeek == week
            }

            HSSectionHeader(title: "Your talks")
            if filteredIssues.isEmpty {
                HSEmptyState(
                    icon: "checkmark.seal",
                    title: "No talks this week",
                    message: "When a toolbox talk is issued to you, it will show here to preview, download and sign."
                )
            } else {
                VStack(spacing: HSMetric.rowGap) {
                    ForEach(filteredIssues, id: \.id) { issue in
                        let talk = vm.data.talks.first(where: { $0.id == issue.talkId })
                        let mySignature = vm.signatures(for: issue.id).first(where: { $0.userId == myId })
                        let isPending = mySignature?.status != .signed
                        let overdue = isPending && isIssueOverdue(issue)
                        HSTalkCard(
                            title: vm.issueDisplayTitle(issue),
                            reference: talk?.id ?? issue.ramsDocumentId,
                            trade: talk?.tradeLabel ?? vm.data.ramsDocuments.first(where: { $0.id == issue.ramsDocumentId })?.trade,
                            weekCommencing: issue.ramsDocumentId == nil
                                ? "W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))"
                                : "Sent \(issue.issuedAt.formatted(date: .abbreviated, time: .omitted))",
                            status: isPending ? (overdue ? .overdue : .awaiting) : .signed,
                            primaryTitle: isPending ? "Open to sign" : "View signed",
                            primaryTone: isPending ? .green : .blue,
                            primaryAction: {
                                if isPending { selectedIssueToSign = issue } else { selectedIssueToView = issue }
                            },
                            onOpen: {
                                if isPending { selectedIssueToSign = issue } else { selectedIssueToView = issue }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct HSIssueTalkSheet: View {
    let talks: [HSToolboxTalk]
    let preselectedTalkId: String?
    let liveRecipientUserIds: Set<String>
    let onIssue: (HSToolboxTalk, Date, [String]) -> Void
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTalkId: String?
    @State private var issueDate = Date()
    @State private var recipientSearch = ""
    @State private var talkSearch = ""
    @State private var selectedTalkTrade = "All"
    @State private var showLibraryPicker = false
    @State private var showDatePicker = false
    @State private var selectedTrade = "All"
    @State private var selectedRecipientIds: Set<String> = []

    private var talkTradeFilters: [String] {
        var set = Set<String>(["All", "General"])
        for talk in talks where !talk.isGeneral {
            for trade in talk.trades where !trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                set.insert(trade)
            }
        }
        return ["All", "General"] + set.filter { $0 != "All" && $0 != "General" }.sorted()
    }

    private var filteredTalks: [HSToolboxTalk] {
        talks.filter { talk in
            let search = talkSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = search.isEmpty
                || talk.displayTitle.localizedCaseInsensitiveContains(search)
                || talk.purpose.localizedCaseInsensitiveContains(search)
            guard matchesSearch else { return false }
            switch selectedTalkTrade {
            case "All":
                return true
            case "General":
                return talk.isGeneral
            default:
                return talk.trades.contains(where: { $0.caseInsensitiveCompare(selectedTalkTrade) == .orderedSame })
            }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var availableTrades: [String] {
        let set = Set(
            userStore.organizationUsers
                .filter { $0.isActive && isEligibleRecipient($0) }
                .map { StaffTradeType.displayLabel(presetRaw: $0.tradeTypePreset, custom: $0.tradeTypeCustom) }
        )
        return ["All", "Live"] + set.sorted()
    }

    private var filteredRecipients: [AppUser] {
        userStore.organizationUsers.filter { user in
            guard user.isActive && isEligibleRecipient(user) else { return false }
            let trade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
            let tradeMatch: Bool
            if selectedTrade == "All" {
                tradeMatch = true
            } else if selectedTrade == "Live" {
                tradeMatch = liveRecipientUserIds.contains(user.id)
            } else {
                tradeMatch = trade.caseInsensitiveCompare(selectedTrade) == .orderedSame
            }
            let searchText = recipientSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatch = searchText.isEmpty || user.fullName.localizedCaseInsensitiveContains(searchText)
            return tradeMatch && searchMatch
        }
    }

    private func isEligibleRecipient(_ user: AppUser) -> Bool {
        user.permissions.operativeMode || user.permissions.manager || user.permissions.adminAccess || user.role == .admin || user.isSuperAdmin
    }

    private var selectedTalk: HSToolboxTalk? {
        guard let selectedTalkId else { return nil }
        return talks.first(where: { $0.id == selectedTalkId })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected toolbox talk")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        if let selectedTalk {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedTalk.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(HS.ink)
                                Text(selectedTalk.isGeneral ? "General" : selectedTalk.trades.joined(separator: ", "))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(HS.blue)
                                Text(selectedTalk.purpose)
                                    .font(.system(size: 12))
                                    .foregroundStyle(HS.slate)
                                    .lineLimit(2)
                            }
                            .hsCard(padding: 12)
                        } else {
                            Text("Select a toolbox talk from the library to continue.")
                                .font(.system(size: 12))
                                .foregroundStyle(HS.slate)
                                .hsCard(padding: 12)
                        }

                        Button("View Library") {
                            showLibraryPicker.toggle()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HS.blue)

                        if showLibraryPicker {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search toolbox talks", text: $talkSearch)
                                    .textInputAutocapitalization(.never)
                            }
                            .hsCard(padding: 10)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(talkTradeFilters, id: \.self) { filter in
                                        Button(filter) { selectedTalkTrade = filter }
                                            .font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(selectedTalkTrade == filter ? HS.teal : HS.card)
                                            .foregroundStyle(selectedTalkTrade == filter ? .white : HS.slate)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(filteredTalks, id: \.id) { talk in
                                        Button {
                                            selectedTalkId = talk.id
                                            showLibraryPicker = false
                                        } label: {
                                            HStack(alignment: .top, spacing: 10) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(talk.displayTitle)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(HS.ink)
                                                        .multilineTextAlignment(.leading)
                                                    Text(talk.isGeneral ? "General" : talk.trades.joined(separator: ", "))
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(HS.blue)
                                                    Text(talk.purpose)
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(HS.slate)
                                                        .lineLimit(2)
                                                }
                                                Spacer(minLength: 0)
                                                Image(systemName: selectedTalkId == talk.id ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedTalkId == talk.id ? HS.teal : HS.slate2)
                                            }
                                            .padding(12)
                                            .hsCard(padding: 12)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 220)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Date")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Button {
                            showDatePicker.toggle()
                        } label: {
                            HStack {
                                Text(issueDate.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(HS.ink)
                                Spacer()
                                Image(systemName: showDatePicker ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(HS.slate2)
                            }
                            .padding(12)
                            .background(HS.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        if showDatePicker {
                            DatePicker("Date", selection: $issueDate, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.graphical)
                                .padding(8)
                                .background(HS.card)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose recipients")
                            .font(.system(size: 12, weight: .semibold))
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
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search operative", text: $recipientSearch)
                                .textInputAutocapitalization(.never)
                        }
                        .hsCard(padding: 10)
                        Button("Select all in trade") {
                            selectedRecipientIds.formUnion(filteredRecipients.map(\.id))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HS.teal)
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(filteredRecipients, id: \.id) { user in
                                    let isSelected = selectedRecipientIds.contains(user.id)
                                    Button {
                                        if isSelected {
                                            selectedRecipientIds.remove(user.id)
                                        } else {
                                            selectedRecipientIds.insert(user.id)
                                        }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(user.fullName)
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(HS.ink)
                                                Text(StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(HS.slate)
                                            }
                                            Spacer()
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isSelected ? HS.teal : HS.slate2)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(HS.card)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                        if !selectedRecipientIds.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Names Selected Recipients")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(HS.slate2)
                                ForEach(userStore.organizationUsers.filter { selectedRecipientIds.contains($0.id) }, id: \.id) { user in
                                    HStack(spacing: 8) {
                                        Text(user.fullName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(HS.ink)
                                        Spacer()
                                        Button {
                                            selectedRecipientIds.remove(user.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(HS.red)
                                                .font(.system(size: 17, weight: .bold))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(HS.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                            .hsCard(padding: 10)
                        }
                    }

                    Button {
                        guard let selectedTalkId, let talk = talks.first(where: { $0.id == selectedTalkId }) else { return }
                        HSHaptic.success()
                        onIssue(talk, issueDate, Array(selectedRecipientIds))
                        dismiss()
                    } label: {
                        Text("Issue to \(selectedRecipientIds.count) operative\(selectedRecipientIds.count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HSFilledButton(tone: .teal))
                    .disabled(selectedTalkId == nil || selectedRecipientIds.isEmpty)
                    .opacity((selectedTalkId == nil || selectedRecipientIds.isEmpty) ? 0.45 : 1)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Issue Toolbox Talk")
            .onAppear {
                if selectedTalkId == nil {
                    selectedTalkId = preselectedTalkId ?? filteredTalks.first?.id ?? talks.first?.id
                }
                showLibraryPicker = false
                if selectedTalkTrade == "All",
                   let selectedTalkId,
                   let talk = talks.first(where: { $0.id == selectedTalkId }),
                   !talk.isGeneral,
                   let firstTrade = talk.trades.first,
                   !firstTrade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedTalkTrade = firstTrade
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct HSToolboxTalkDetailView: View {
    let talk: HSToolboxTalk
    let onIssue: () -> Void
    let onDownload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remotePreview: HSDocumentPreviewItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HSMetric.rowGap) {
                    VStack(alignment: .leading, spacing: 8) {
                        HSBadge(
                            text: talk.isCustomUpload ? "Your upload · \(talk.id)" : "Library · \(talk.id)",
                            tone: talk.isCustomUpload ? .scheduled : .ok
                        )
                        Text(talk.displayTitle)
                            .font(HSFont.heroTitle)
                            .foregroundStyle(HS.ink)
                            .hsNoClip(3)
                        Text(talk.tradeLabel)
                            .font(HSFont.meta)
                            .foregroundStyle(HS.blue)
                    }
                    .hsCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(talk.isCustomUpload ? "About this talk" : "Purpose")
                            .font(HSFont.sectionLabel)
                            .tracking(0.9)
                            .foregroundStyle(HS.slate2)
                        Text(talk.purpose)
                            .font(HSFont.body)
                            .foregroundStyle(HS.ink)
                            .hsNoClip(8)
                    }
                    .hsCard()

                    if !talk.isCustomUpload, !talk.keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Key points")
                                .font(HSFont.sectionLabel)
                                .tracking(0.9)
                                .foregroundStyle(HS.slate2)
                            ForEach(Array(talk.keyPoints.enumerated()), id: \.offset) { index, point in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(HS.teal)
                                    Text(point)
                                        .font(HSFont.body)
                                        .foregroundStyle(HS.ink)
                                        .hsNoClip(4)
                                }
                            }
                        }
                        .hsCard()
                    }

                    if talk.isCustomUpload {
                        Text("The file you uploaded is the talk that will be issued, previewed, downloaded and signed against.")
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate)
                            .hsNoClip(3)
                    }

                    VStack(spacing: 10) {
                        Button(action: onIssue) {
                            Label("Issue", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HSFilledButton(tone: .teal))

                        Button {
                            HSHaptic.tap()
                            if talk.isCustomUpload, let remote = talk.storedFileURL {
                                remotePreview = HSDocumentPreviewItem(title: talk.displayTitle, remoteURL: remote, noun: "toolbox talk")
                            } else {
                                onDownload()
                            }
                        } label: {
                            Label(talk.isCustomUpload ? "Preview / download original file" : "Download", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HSGhostButton(tint: HS.blue))
                    }
                }
                .padding(16)
            }
            .hsScreen()
            .navigationTitle("Toolbox Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $remotePreview) { item in
                InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
            }
        }
    }
}

private struct HSScheduledTalksView: View {
    let issues: [HSToolboxIssue]
    let talksById: [String: HSToolboxTalk]
    let usersById: [String: AppUser]
    let onCancelIssue: (HSToolboxIssue) -> Void
    let onAddRecipients: (HSToolboxIssue, [String]) -> Void
    let onRemoveRecipient: (HSToolboxIssue, String) -> Void
    let liveRecipientUserIds: Set<String>

    var body: some View {
        NavigationStack {
            List {
                if issues.isEmpty {
                    Section {
                        Text("No scheduled toolbox talks.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(issues, id: \.id) { issue in
                        NavigationLink {
                            HSScheduledTalkDetailView(
                                issue: issue,
                                talk: talksById[issue.talkId],
                                usersById: usersById,
                                onCancelIssue: { onCancelIssue(issue) },
                                onAddRecipients: { onAddRecipients(issue, $0) },
                                onRemoveRecipient: { onRemoveRecipient(issue, $0) },
                                liveRecipientUserIds: liveRecipientUserIds
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(talksById[issue.talkId]?.title ?? "Toolbox talk")
                                    .font(.system(size: 14, weight: .semibold))
                                if let publishAt = issue.publishAt {
                                    Text("Scheduled for \(publishAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(issue.recipientUserIds.count) recipient\(issue.recipientUserIds.count == 1 ? "" : "s")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scheduled Toolbox Talks")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct HSScheduledTalkDetailView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    let usersById: [String: AppUser]
    let onCancelIssue: () -> Void
    let onAddRecipients: ([String]) -> Void
    let onRemoveRecipient: (String) -> Void
    let liveRecipientUserIds: Set<String>

    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipientSearch = ""
    @State private var selectedTrade = "All"
    @State private var pendingAdds: Set<String> = []

    private var availableTrades: [String] {
        let set = Set(
            userStore.organizationUsers
                .filter { $0.isActive }
                .map { StaffTradeType.displayLabel(presetRaw: $0.tradeTypePreset, custom: $0.tradeTypeCustom) }
        )
        return ["All", "Live"] + set.sorted()
    }

    private var candidateUsers: [AppUser] {
        userStore.organizationUsers
            .filter { $0.isActive }
            .filter { !issue.recipientUserIds.contains($0.id) }
            .filter { user in
                if selectedTrade == "All" { return true }
                if selectedTrade == "Live" { return liveRecipientUserIds.contains(user.id) }
                let trade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
                return trade.caseInsensitiveCompare(selectedTrade) == .orderedSame
            }
            .filter { user in
                let q = recipientSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                return q.isEmpty || user.fullName.localizedCaseInsensitiveContains(q)
            }
    }

    var body: some View {
        List {
            Section("Summary") {
                Text(talk?.title ?? "Toolbox talk")
                Text(talk?.purpose ?? "No summary available.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let publishAt = issue.publishAt {
                    Text("Scheduled for \(publishAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12, weight: .semibold))
                }
            }

            Section("Recipients") {
                ForEach(issue.recipientUserIds, id: \.self) { userId in
                    let user = usersById[userId]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user?.fullName ?? user?.email ?? userId)
                            Text(StaffTradeType.displayLabel(presetRaw: user?.tradeTypePreset ?? "", custom: user?.tradeTypeCustom))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            onRemoveRecipient(userId)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Add Recipients") {
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
                TextField("Search users in organization", text: $recipientSearch)
                    .textInputAutocapitalization(.never)
                ForEach(candidateUsers, id: \.id) { user in
                    let selected = pendingAdds.contains(user.id)
                    Button {
                        if selected { pendingAdds.remove(user.id) } else { pendingAdds.insert(user.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.fullName)
                                Text(StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? HS.teal : HS.slate2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("Add Selected Recipients") {
                    onAddRecipients(Array(pendingAdds))
                    pendingAdds.removeAll()
                }
                .disabled(pendingAdds.isEmpty)
            }

            Section("Actions") {
                Button("Cancel Toolbox Talk", role: .destructive) {
                    onCancelIssue()
                    dismiss()
                }
            }
        }
        .navigationTitle("Scheduled Talk")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HSAddRecipientsSheet: View {
    var heading: String = "Send to further operatives"
    var intro: String = "Select additional recipients for this toolbox talk. Existing recipients are excluded."
    let currentRecipientUserIds: Set<String>
    let liveRecipientUserIds: Set<String>
    let onSave: ([String]) -> Void

    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTrade = "All"
    @State private var searchText = ""
    @State private var selectedRecipientIds: Set<String> = []

    private var availableTrades: [String] {
        let set = Set(
            userStore.organizationUsers
                .filter { $0.isActive }
                .map { StaffTradeType.displayLabel(presetRaw: $0.tradeTypePreset, custom: $0.tradeTypeCustom) }
        )
        return ["All", "Live"] + set.sorted()
    }

    private var candidates: [AppUser] {
        userStore.organizationUsers.filter { user in
            guard user.isActive else { return false }
            guard !currentRecipientUserIds.contains(user.id) else { return false }
            let searchMatch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || user.fullName.localizedCaseInsensitiveContains(searchText)
            guard searchMatch else { return false }
            if selectedTrade == "All" { return true }
            if selectedTrade == "Live" { return liveRecipientUserIds.contains(user.id) }
            let trade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
            return trade.caseInsensitiveCompare(selectedTrade) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(heading)
                        .font(.system(size: 22, weight: .bold))
                    Text(intro)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text("Filter recipients by trade")
                        .font(.system(size: 12, weight: .semibold))
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
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search operative", text: $searchText)
                            .textInputAutocapitalization(.never)
                    }
                    .hsCard(padding: 10)

                    Button("Select all in trade") {
                        selectedRecipientIds.formUnion(candidates.map(\.id))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HS.teal)

                    VStack(spacing: 8) {
                        ForEach(candidates, id: \.id) { user in
                            let isSelected = selectedRecipientIds.contains(user.id)
                            Button {
                                if isSelected { selectedRecipientIds.remove(user.id) } else { selectedRecipientIds.insert(user.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.fullName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(HS.ink)
                                        Text(StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom))
                                            .font(.system(size: 11))
                                            .foregroundStyle(HS.slate)
                                    }
                                    Spacer()
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? HS.teal : HS.slate2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(HS.card)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        onSave(Array(selectedRecipientIds))
                        dismiss()
                    } label: {
                        Text("Add \(selectedRecipientIds.count) recipient\(selectedRecipientIds.count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(FilledButtonStyle(tone: .teal))
                    .disabled(selectedRecipientIds.isEmpty)
                    .opacity(selectedRecipientIds.isEmpty ? 0.5 : 1)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Add Recipients")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct HSShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct HSDocumentShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct HSTrackIssueView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    var displayTitle: String? = nil
    let signatures: [HSToolboxSignature]
    let onSendReminder: () -> Void
    let onViewSignedTalk: () -> Void
    let onRemoveIssue: () -> Void
    let onSendToFurtherOperatives: () -> Void
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    private var signed: [HSToolboxSignature] { signatures.filter { $0.status == .signed } }
    private var pending: [HSToolboxSignature] { signatures.filter { $0.status != .signed } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HSSignOffHero(
                        signed: signed.count,
                        total: signatures.count,
                        talkTitle: displayTitle ?? talk?.title ?? "RAMS"
                    )
                    .padding(.top, 8)

                    HSSectionHeader(title: "Signed", trailing: signed.isEmpty ? nil : "\(signed.count)")
                    if signed.isEmpty {
                        Text("No signatures yet.")
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate)
                            .hsCard()
                    } else {
                        HSRowGroup {
                            ForEach(Array(signed.enumerated()), id: \.element.id) { index, signature in
                                let user = userStore.organizationUsers.first(where: { $0.id == signature.userId })
                                HSOperativeRow(
                                    name: user?.fullName.isEmpty == false ? (user?.fullName ?? signature.userId) : (user?.email ?? signature.userId),
                                    trade: user?.displayTradeType ?? "",
                                    detail: signature.signedAt.map { "Signed \($0.formatted(date: .abbreviated, time: .shortened))" },
                                    state: .signed
                                )
                                if index < signed.count - 1 { HSDivider() }
                            }
                        }
                    }

                    if !pending.isEmpty {
                        HSSectionHeader(title: "Awaiting", trailing: "\(pending.count)")
                        HSRowGroup {
                            ForEach(Array(pending.enumerated()), id: \.element.id) { index, signature in
                                let user = userStore.organizationUsers.first(where: { $0.id == signature.userId })
                                HSOperativeRow(
                                    name: user?.fullName.isEmpty == false ? (user?.fullName ?? signature.userId) : (user?.email ?? signature.userId),
                                    trade: user?.displayTradeType ?? "",
                                    state: .pending
                                )
                                if index < pending.count - 1 { HSDivider() }
                            }
                        }
                    }

                    HSSectionHeader(title: "Actions")
                    VStack(spacing: HSMetric.rowGap) {
                        HSActionRow(
                            icon: talk?.isCustomUpload == true ? "signature" : "doc.richtext.fill",
                            tint: HS.blue,
                            title: "View signed toolbox talk",
                            subtitle: talk?.isCustomUpload == true
                                ? "Open the custom talk signature sheet"
                                : "Preview or download the signed talk PDF",
                            action: { dismissThenPerform(onViewSignedTalk) }
                        )
                        HSActionRow(
                            icon: "person.badge.plus",
                            tint: HS.teal,
                            title: "Send to further operatives",
                            subtitle: "Add more people to this issue",
                            action: { dismissThenPerform(onSendToFurtherOperatives) }
                        )
                        HSActionRow(
                            icon: "bell.fill",
                            tint: HS.amber,
                            title: "Remind pending",
                            subtitle: "Notify people who have not signed yet",
                            action: onSendReminder
                        )
                    }
                }
                .padding(.horizontal, HSMetric.screenPad)
                .padding(.bottom, 24)
            }
            .hsScreen()
            .navigationTitle("Sign-off tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Remove", role: .destructive) {
                        onRemoveIssue()
                        dismiss()
                    }
                }
            }
        }
    }

    private func dismissThenPerform(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
        }
    }
}

private struct HSSignTalkView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    var rams: HSRamsDocument? = nil
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var readConfirmed = false
    @State private var signatureImageData: Data?
    @State private var documentPreview: HSDocumentPreviewItem?
    @State private var shareURL: IdentifiableURL?

    private var canSubmit: Bool { readConfirmed && signatureImageData != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HSMetric.rowGap) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(talk?.title ?? rams?.title ?? "Sign-off")
                            .font(HSFont.heroTitle)
                            .foregroundStyle(HS.ink)
                            .hsNoClip(3)
                        Text(rams == nil
                             ? "W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))"
                             : "Sent \(issue.issuedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate)
                        if talk?.isCustomUpload == true {
                            HSBadge(text: "Custom uploaded talk", tone: .scheduled)
                        }
                    }
                    .hsCard()

                    if let purpose = talk?.purpose, !purpose.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(talk?.isCustomUpload == true ? "About this talk" : "Purpose")
                                .font(HSFont.sectionLabel)
                                .tracking(0.9)
                                .foregroundStyle(HS.slate2)
                            Text(purpose)
                                .font(HSFont.body)
                                .foregroundStyle(HS.ink)
                                .hsNoClip(8)
                        }
                        .hsCard()
                    }

                    if talk?.isCustomUpload != true, let points = talk?.keyPoints, !points.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Key control points")
                                .font(HSFont.sectionLabel)
                                .tracking(0.9)
                                .foregroundStyle(HS.slate2)
                            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(HS.teal)
                                    Text(point)
                                        .font(HSFont.body)
                                        .foregroundStyle(HS.ink)
                                        .hsNoClip(4)
                                }
                            }
                        }
                        .hsCard()
                    }

                    Button {
                        HSHaptic.tap()
                        previewTalk()
                    } label: {
                        Label(
                            talk?.isCustomUpload == true ? "Preview / download original file" : (rams == nil ? "Preview / download talk" : "Preview RAMS"),
                            systemImage: "eye.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HSGhostButton(tint: HS.blue))

                    Button {
                        HSHaptic.select()
                        readConfirmed.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: readConfirmed ? "checkmark.square.fill" : "square")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(readConfirmed ? HS.teal : HS.slate2)
                            Text(rams == nil ? "I have read and understood this toolbox talk" : "I have read and understood this RAMS")
                                .font(HSFont.body)
                                .foregroundStyle(HS.ink)
                                .hsNoClip(3)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(readConfirmed ? HS.teal : HS.line, lineWidth: readConfirmed ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .hsCard(padding: 0)

                    HSSignaturePad(imageData: $signatureImageData)

                    if !canSubmit {
                        Text(submitHint)
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate2)
                            .hsNoClip(2)
                    }

                    Button {
                        guard let signatureImageData else { return }
                        HSHaptic.success()
                        onSubmit(signatureImageData.base64EncodedString())
                        dismiss()
                    } label: {
                        Label("Submit signature", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HSFilledButton(tone: .teal))
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.45)
                }
                .padding(16)
            }
            .hsScreen()
            .navigationTitle("Sign Toolbox Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $documentPreview) { item in
                InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
            }
            .sheet(item: $shareURL) { item in
                HSDocumentActivityView(activityItems: [item.url])
            }
        }
    }

    private var submitHint: String {
        if !readConfirmed && signatureImageData == nil {
            return "Confirm you have read the talk and add your signature to submit."
        }
        if !readConfirmed { return "Tick the declaration before submitting." }
        return "Add your signature before submitting."
    }

    private func previewTalk() {
        if let rams, let remote = rams.storedFileURL {
            documentPreview = HSDocumentPreviewItem(title: rams.title, remoteURL: remote, noun: "RAMS")
            return
        }
        if let talk, talk.isCustomUpload, let remote = talk.storedFileURL {
            documentPreview = HSDocumentPreviewItem(title: talk.displayTitle, remoteURL: remote, noun: "toolbox talk")
            return
        }
        if let talk, let generated = HSTalkPDFBuilder.makePDF(for: talk) {
            documentPreview = HSDocumentPreviewItem(title: talk.displayTitle, localURL: generated, noun: "toolbox talk")
        }
    }
}

private struct HSSignedTalkView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    var rams: HSRamsDocument? = nil
    let signature: HSToolboxSignature?
    @EnvironmentObject var userStore: UserStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(talk?.title ?? rams?.title ?? "Sign-off")
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
                            .background(HS.bgDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(HS.line, lineWidth: 1)
                            )
                    }
                    if let signedAt = signature?.signedAt {
                        let signer = userStore.organizationUsers.first(where: { $0.id == signature?.userId })
                        let signerName = signer?.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? signer?.fullName : signer?.email
                        Text("Signed by \(signerName ?? "User") at \(signedAt.formatted(date: .abbreviated, time: .shortened))")
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
    let onSave: (String, String, String, [String], URL?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var trade = "General"
    @State private var purpose = ""
    @State private var showFileImporter = false
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    private let trades = ["General"] + StaffTradeType.pickerCases.map(\.rawValue)

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedFileURL != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upload Toolbox Talk")
                        .font(HSFont.heroTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Text("The PDF you upload is the talk that gets issued, previewed, downloaded and signed against.")
                        .font(HSFont.body)
                        .foregroundStyle(HS.slate)
                        .hsNoClip(4)

                    HSUploadDropZone(
                        title: selectedFileName ?? "Upload talk (PDF)",
                        subtitle: selectedFileName == nil ? "PDF required — this is the file people will sign against" : "Ready to save",
                        isFilled: selectedFileName != nil
                    ) { showFileImporter = true }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Please fill this in when uploading your TBT.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HS.ink)
                            .hsNoClip(3)
                        HSFormField(label: "Talk title", text: $title, placeholder: "e.g. Site-specific working rules")
                        HSFormMenuField(label: "Trade", value: trade) {
                            ForEach(trades, id: \.self) { t in
                                Button(t) { trade = t }
                            }
                        }
                        HSFormMultilineField(label: "Small description about the talk", text: $purpose, placeholder: "What this talk is about")
                    }
                    .hsCard()

                    if !canSave {
                        Text("Add the PDF, talk title, trade and a short description to enable Save.")
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate2)
                            .hsNoClip(3)
                    }

                    Button {
                        guard canSave else { return }
                        HSHaptic.success()
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            trade.trimmingCharacters(in: .whitespacesAndNewlines),
                            purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                            [],
                            selectedFileURL,
                            selectedFileName
                        )
                        dismiss()
                    } label: {
                        Label("Save to library", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HSFilledButton(tone: .teal))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
                }
                .padding(16)
            }
            .hsScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if let persisted = HSImportedFile.persist(url) {
                        selectedFileURL = persisted.url
                        selectedFileName = persisted.name
                    } else {
                        selectedFileURL = url
                        selectedFileName = url.lastPathComponent
                    }
                }
            }
        }
    }
}

private struct HSRamsUploadSheet: View {
    let onSave: (String, String?, Date?, [String], URL?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var docTitle = ""
    @State private var trade: String = ""
    @State private var reviewDate = Date()
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    @State private var showFileImporter = false
    private let trades = [""] + ["General"] + StaffTradeType.pickerCases.map(\.rawValue)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upload RAMS")
                        .font(HSFont.heroTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Text("Upload a Risk Assessment & Method Statement. Operatives can view it and managers can share with clients.")
                        .font(HSFont.body)
                        .foregroundStyle(HS.slate)
                        .hsNoClip(4)

                    HSUploadDropZone(
                        title: selectedFileName ?? "Upload RAMS document",
                        subtitle: selectedFileName == nil ? "PDF or Word up to 25MB" : "Ready to publish",
                        isFilled: selectedFileName != nil
                    ) { showFileImporter = true }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details")
                            .font(HSFont.sectionLabel)
                            .tracking(0.9)
                            .foregroundStyle(HS.slate2)
                        HSFormField(label: "Document title", text: $docTitle, placeholder: "e.g. CAT A Fit-Out — Master RAMS")
                        HSFormMenuField(label: "Trade / area", value: trade.isEmpty ? "Select trade (optional)" : trade) {
                            ForEach(trades, id: \.self) { t in
                                Button(t.isEmpty ? "Unassigned" : t) { trade = t }
                            }
                        }
                        DatePicker("Review date", selection: $reviewDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .hsCard()

                    Button {
                        let cleanTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
                        HSHaptic.success()
                        onSave(
                            docTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            cleanTrade.isEmpty ? nil : cleanTrade,
                            reviewDate,
                            [],
                            selectedFileURL,
                            selectedFileName
                        )
                        dismiss()
                    } label: {
                        Label("Publish RAMS", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HSFilledButton(tone: .blue))
                    .disabled(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                }
                .padding(16)
            }
            .hsScreen()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if let persisted = HSImportedFile.persist(url) {
                        selectedFileURL = persisted.url
                        selectedFileName = persisted.name
                    } else {
                        selectedFileURL = url
                        selectedFileName = url.lastPathComponent
                    }
                }
            }
        }
    }
}

private struct HSOtherDocumentUploadSheet: View {
    let onSave: (String, String?, String?, Bool, URL?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var docTitle = ""
    @State private var trade = ""
    @State private var category = "trade"
    @State private var issuableToClient = true
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add H&S Document")
                        .font(HSFont.heroTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Text("Add a Safe Isolation procedure, COSHH sheet, permit, or site-wide H&S document.")
                        .font(HSFont.body)
                        .foregroundStyle(HS.slate)
                        .hsNoClip(4)

                    HSUploadDropZone(
                        title: selectedFileName ?? "Upload document",
                        subtitle: selectedFileName == nil ? "PDF, Word or image up to 25MB" : "Ready to save",
                        isFilled: selectedFileName != nil
                    ) { showFileImporter = true }

                    VStack(alignment: .leading, spacing: 8) {
                        HSFormField(label: "Document title", text: $docTitle, placeholder: "e.g. Safe Isolation Procedure")
                        HSFormField(label: "Trade", text: $trade, placeholder: "Optional")
                        HSFormMenuField(label: "Category", value: category) {
                            Button("trade") { category = "trade" }
                            Button("site_wide") { category = "site_wide" }
                        }
                        Toggle("Issuable to client", isOn: $issuableToClient)
                    }
                    .hsCard()

                    Button {
                        let cleanTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
                        HSHaptic.success()
                        onSave(
                            docTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            cleanTrade.isEmpty ? nil : cleanTrade,
                            cleanCategory.isEmpty ? nil : cleanCategory,
                            issuableToClient,
                            selectedFileURL,
                            selectedFileName
                        )
                        dismiss()
                    } label: {
                        Label("Save document", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HSFilledButton(tone: .blue))
                    .disabled(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                }
                .padding(16)
            }
            .hsScreen()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if let persisted = HSImportedFile.persist(url) {
                        selectedFileURL = persisted.url
                        selectedFileName = persisted.name
                    } else {
                        selectedFileURL = url
                        selectedFileName = url.lastPathComponent
                    }
                }
            }
        }
    }
}

private struct HSUploadDropZone: View {
    let title: String
    let subtitle: String
    let isFilled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: isFilled ? "checkmark.circle.fill" : "arrow.up.doc.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isFilled ? HS.green : HS.blue)
                    .frame(width: 56, height: 56)
                    .background((isFilled ? HS.green.opacity(0.15) : HS.blue.opacity(0.12)))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HS.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(HS.slate)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(HS.card)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(isFilled ? HS.green.opacity(0.6) : HS.blue.opacity(0.4))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct HSFormField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HS.slate2)
                .textCase(.uppercase)
            TextField(placeholder, text: $text)
                .font(.system(size: 15, weight: .medium))
                .textInputAutocapitalization(.sentences)
        }
    }
}

private struct HSFormMultilineField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HS.slate2)
                .textCase(.uppercase)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(4...8)
                .font(.system(size: 15, weight: .medium))
        }
    }
}

private struct HSFormMenuField<MenuContent: View>: View {
    let label: String
    let value: String
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HS.slate2)
                    .textCase(.uppercase)
                HStack {
                    Text(value)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(value.contains("Select") ? HS.slate2 : HS.ink)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HS.slate2)
                }
            }
        }
    }
}

private enum HSTalkPDFBuilder {
    static func makePDF(for talk: HSToolboxTalk) -> URL? {
        makeStyledPDF(talk: talk, issue: nil, signatures: [], userLookup: [])
    }

    static func makeStyledPDF(
        talk: HSToolboxTalk,
        issue: HSToolboxIssue?,
        signatures: [HSToolboxSignature],
        userLookup: [AppUser]
    ) -> URL? {
        let safeName = talk.displayTitle.replacingOccurrences(of: " ", with: "_")
        let fileName = "ToolboxTalk-\(safeName)-\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let orgBadge = HSDocumentOrgBadge.currentDisplay

        let navy = UIColor(red: 0.055, green: 0.122, blue: 0.2, alpha: 1)
        let cyan = UIColor(red: 0.169, green: 0.733, blue: 0.937, alpha: 1)
        let amber = UIColor(red: 0.902, green: 0.624, blue: 0.161, alpha: 1)
        let ink = UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1)
        let slate = UIColor(red: 0.357, green: 0.42, blue: 0.5, alpha: 1)
        let line = UIColor(red: 0.902, green: 0.933, blue: 0.961, alpha: 1)

        func drawPill(_ text: String, x: CGFloat, y: CGFloat, fill: UIColor, textColor: UIColor) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: textColor
            ]
            let w = (text as NSString).size(withAttributes: attrs).width + 20
            let h: CGFloat = 18
            fill.setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 7).fill()
            (text as NSString).draw(at: CGPoint(x: x + 10, y: y + 4), withAttributes: attrs)
            return w
        }

        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()

                // Header band
                let bandRect = CGRect(x: 0, y: 0, width: pageRect.width, height: 92)
                navy.setFill()
                UIRectFill(bandRect)
                amber.setFill()
                UIRectFill(CGRect(x: 0, y: 92, width: pageRect.width, height: 4))
                ("PROJECT " as NSString).draw(at: CGPoint(x: 26, y: 28), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor.white
                ])
                ("PLANNER" as NSString).draw(at: CGPoint(x: 88, y: 28), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: cyan
                ])
                drawOrganizationDocumentBadgePDF(text: orgBadge, in: CGRect(x: 168, y: 24, width: 50, height: 36))
                ("TOOLBOX TALK" as NSString).draw(at: CGPoint(x: 26, y: 48), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor(red: 0.62, green: 0.70, blue: 0.81, alpha: 1)
                ])
                ("REF" as NSString).draw(at: CGPoint(x: pageRect.width - 126, y: 24), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: UIColor(red: 0.5, green: 0.6, blue: 0.72, alpha: 1)
                ])
                (talk.id as NSString).draw(at: CGPoint(x: pageRect.width - 126, y: 40), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 18, weight: .bold),
                    .foregroundColor: UIColor.white
                ])

                // Body
                let margin: CGFloat = 26
                var y: CGFloat = 114
                (talk.displayTitle as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                    .foregroundColor: ink
                ])
                y += 40

                let tradeLine = talk.isGeneral ? "General H&S" : talk.trades.joined(separator: ", ")
                var x = margin
                x += drawPill(talk.id, x: x, y: y, fill: UIColor(red: 0.91, green: 0.94, blue: 1, alpha: 1), textColor: UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)) + 8
                x += drawPill(tradeLine, x: x, y: y, fill: UIColor(red: 0.933, green: 0.953, blue: 0.976, alpha: 1), textColor: slate) + 8
                x += drawPill("v\(talk.version)", x: x, y: y, fill: UIColor(red: 0.933, green: 0.953, blue: 0.976, alpha: 1), textColor: slate) + 8
                _ = drawPill(talk.status.rawValue.capitalized, x: x, y: y, fill: UIColor(red: 0.894, green: 0.969, blue: 0.933, alpha: 1), textColor: UIColor(red: 0.102, green: 0.647, blue: 0.392, alpha: 1))
                y += 34

                // Info cards
                let cardW = (pageRect.width - margin * 2 - 24) / 3
                let info: [(String, String)] = [
                    ("Project", issue?.projectId.uuidString.prefix(8).uppercased() ?? "Library talk"),
                    ("Week commencing", issue.map { "W/C " + $0.weekCommencing.formatted(date: .abbreviated, time: .omitted) } ?? "W/C —"),
                    ("Presented by", "Project Planner")
                ]
                for idx in 0..<3 {
                    let r = CGRect(x: margin + CGFloat(idx) * (cardW + 12), y: y, width: cardW, height: 58)
                    UIColor(red: 0.965, green: 0.976, blue: 0.988, alpha: 1).setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: 10).fill()
                    line.setStroke()
                    UIBezierPath(roundedRect: r, cornerRadius: 10).stroke()
                    (info[idx].0.uppercased() as NSString).draw(at: CGPoint(x: r.minX + 10, y: r.minY + 8), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 9.5, weight: .bold),
                        .foregroundColor: UIColor(red: 0.604, green: 0.651, blue: 0.706, alpha: 1)
                    ])
                    (String(info[idx].1) as NSString).draw(at: CGPoint(x: r.minX + 10, y: r.minY + 25), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 12.5, weight: .semibold),
                        .foregroundColor: ink
                    ])
                }
                y += 74

                func sectionTitle(_ title: String) {
                    (title.uppercased() as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: cyan
                    ])
                    y += 16
                    line.setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: 2))
                    y += 8
                }

                sectionTitle("Purpose")
                let purposeRect = CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: 48)
                (talk.purpose as NSString).draw(with: purposeRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                    .font: UIFont.systemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: UIColor(red: 0.184, green: 0.243, blue: 0.314, alpha: 1)
                ], context: nil)
                y += 60

                sectionTitle("Key control points")
                for point in talk.keyPoints {
                    cyan.setFill()
                    UIBezierPath(ovalIn: CGRect(x: margin + 4, y: y + 6, width: 8, height: 8)).fill()
                    let pointRect = CGRect(x: margin + 18, y: y, width: pageRect.width - margin * 2 - 20, height: 34)
                    (point as NSString).draw(with: pointRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                        .font: UIFont.systemFont(ofSize: 12.5, weight: .regular),
                        .foregroundColor: UIColor(red: 0.184, green: 0.243, blue: 0.314, alpha: 1)
                    ], context: nil)
                    y += 20
                }
                y += 8

                sectionTitle("References")
                let refBox = CGRect(x: margin, y: y, width: pageRect.width - margin * 2, height: 34)
                UIColor(red: 0.965, green: 0.976, blue: 0.988, alpha: 1).setFill()
                UIBezierPath(roundedRect: refBox, cornerRadius: 8).fill()
                amber.setFill()
                UIRectFill(CGRect(x: refBox.minX, y: refBox.minY, width: 3, height: refBox.height))
                ("Master RAMS · Relevant legislation · Permit to Work (where applicable)" as NSString).draw(in: CGRect(x: refBox.minX + 10, y: refBox.minY + 9, width: refBox.width - 14, height: 20), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: slate
                ])
                y += 46

                // Sign-off table
                ("ATTENDEE SIGN-OFF" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: ink
                ])
                y += 18

                let tableX = margin
                let tableW = pageRect.width - margin * 2
                let rowH: CGFloat = 32
                let colW: [CGFloat] = [tableW * 0.26, tableW * 0.20, tableW * 0.34, tableW * 0.20]

                navy.setFill()
                UIBezierPath(roundedRect: CGRect(x: tableX, y: y, width: tableW, height: rowH), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 8, height: 8)).fill()
                let headers = ["Name", "Trade", "Signature", "Date & time"]
                var hx = tableX + 12
                for i in 0..<headers.count {
                    (headers[i].uppercased() as NSString).draw(at: CGPoint(x: hx, y: y + 10), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 9.5, weight: .bold),
                        .foregroundColor: UIColor.white
                    ])
                    hx += colW[i]
                }
                y += rowH

                let sorted = signatures.sorted { ($0.signedAt ?? .distantPast) > ($1.signedAt ?? .distantPast) }
                let rows = max(sorted.count, 2)
                for idx in 0..<rows {
                    let rowRect = CGRect(x: tableX, y: y, width: tableW, height: rowH)
                    if idx % 2 == 1 {
                        UIColor(red: 0.98, green: 0.988, blue: 0.996, alpha: 1).setFill()
                        UIRectFill(rowRect)
                    }
                    line.setStroke()
                    UIBezierPath(rect: rowRect).stroke()
                    var cx = tableX
                    for w in colW.dropLast() {
                        cx += w
                        line.setFill()
                        UIRectFill(CGRect(x: cx, y: y, width: 1, height: rowH))
                    }

                    if idx < sorted.count {
                        let sig = sorted[idx]
                        let user = userLookup.first(where: { $0.id == sig.userId })
                        let name = (user?.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user?.fullName : user?.email) ?? sig.userId
                        let trade = user?.displayTradeType == "—" ? "" : (user?.displayTradeType ?? "")
                        let signedAt = sig.signedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Awaiting"

                        (name as NSString).draw(in: CGRect(x: tableX + 12, y: y + 9, width: colW[0] - 14, height: 16), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 11.5, weight: .semibold),
                            .foregroundColor: ink
                        ])
                        (trade as NSString).draw(in: CGRect(x: tableX + colW[0] + 12, y: y + 9, width: colW[1] - 14, height: 16), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 11),
                            .foregroundColor: slate
                        ])

                        if sig.status == .signed,
                           let b64 = sig.signatureImageBase64,
                           let data = Data(base64Encoded: b64),
                           let img = UIImage(data: data) {
                            img.draw(in: CGRect(x: tableX + colW[0] + colW[1] + 12, y: y + 4, width: colW[2] - 24, height: rowH - 8))
                        } else {
                            UIColor(red: 0.79, green: 0.84, blue: 0.89, alpha: 1).setFill()
                            UIRectFill(CGRect(x: tableX + colW[0] + colW[1] + 12, y: y + rowH / 2, width: colW[2] - 24, height: 1))
                        }

                        let dateColor = sig.status == .signed ? slate : UIColor(red: 0.79, green: 0.635, blue: 0.29, alpha: 1)
                        (signedAt as NSString).draw(in: CGRect(x: tableX + colW[0] + colW[1] + colW[2] + 12, y: y + 9, width: colW[3] - 16, height: 16), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 10.5, weight: .medium),
                            .foregroundColor: dateColor
                        ])
                    }
                    y += rowH
                }

                let signedCount = sorted.filter { $0.status == .signed }.count
                ("\(signedCount) of \(max(sorted.count, 1)) operatives signed." as NSString).draw(at: CGPoint(x: margin, y: y + 6), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: slate
                ])

                // Footer
                let footerY = pageRect.height - 26
                line.setFill()
                UIRectFill(CGRect(x: margin, y: footerY - 8, width: pageRect.width - margin * 2, height: 1))
                ("Generated by Project Planner · \(talk.id) · v\(talk.version)" as NSString).draw(at: CGPoint(x: margin, y: footerY), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: UIColor(red: 0.604, green: 0.651, blue: 0.706, alpha: 1)
                ])
            }
            return url
        } catch {
            return nil
        }
    }
}

private enum HSSignedTalkPDFBuilder {
    static func makePDF(
        talk: HSToolboxTalk,
        issue: HSToolboxIssue,
        signatures: [HSToolboxSignature],
        userLookup: [AppUser]
    ) async -> URL? {
        HSTalkPDFBuilder.makeStyledPDF(talk: talk, issue: issue, signatures: signatures, userLookup: userLookup)
    }
}

private struct HSSignaturePad: View {
    @Binding var imageData: Data?
    @State private var canvas = PKCanvasView()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIGNATURE")
                    .font(HSFont.sectionLabel)
                    .tracking(0.9)
                    .foregroundStyle(HS.slate2)
                Spacer()
                Button("Clear") {
                    canvas.drawing = PKDrawing()
                    imageData = nil
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(imageData == nil ? HS.slate2.opacity(0.5) : HS.red)
                .disabled(imageData == nil)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HS.bgDeep.opacity(0.6))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(imageData == nil ? HS.slate2.opacity(0.45) : HS.teal.opacity(0.5))
                HSCanvasRepresentable(canvas: $canvas) { exportSignaturePNG() }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if imageData == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "signature")
                            .font(.system(size: 22))
                            .foregroundStyle(HS.slate2.opacity(0.7))
                        Text("Sign with your finger")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HS.slate2)
                    }
                    .allowsHitTesting(false)
                }
                VStack {
                    Spacer()
                    Rectangle().fill(HS.slate2.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 22)
                }
                .allowsHitTesting(false)
            }
            .frame(height: 170)
        }
        .hsCard()
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
        canvas.backgroundColor = .clear
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
