import SwiftUI
import PencilKit
import Combine
import UIKit
import PDFKit
import UniformTypeIdentifiers

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
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: weekCommencing)
        let today = calendar.startOfDay(for: Date())
        let publishAt: Date? = selectedDay > today ? calendar.date(bySettingHour: 7, minute: 0, second: 0, of: selectedDay) : nil
        let issueId = UUID().uuidString
        let issue = HSToolboxIssue(
            id: issueId,
            projectId: project.id,
            talkId: talk.id,
            weekCommencing: weekCommencing,
            issuedByUserId: issuedByUserId,
            issuedAt: Date(),
            publishAt: publishAt,
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
        if let publishAt {
            _ = await LocalNotificationService.shared.requestAuthorization()
            await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                identifier: "hs-toolbox-scheduled-\(issueId)",
                title: "Scheduled Toolbox Talk",
                body: "\(talk.title) is now due.",
                fireAt: publishAt
            )
        }
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
        if let localFileURL,
           let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) {
            uploadedURL = try? await firebaseBackend.uploadHealthSafetyFile(
                localFileURL,
                organizationId: orgId,
                projectId: project.id,
                category: "toolboxTalks",
                fileName: originalFileName ?? localFileURL.lastPathComponent
            )
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
        let talkTitle = data.talks.first(where: { $0.id == issue.talkId })?.title ?? "Toolbox Talk"
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
        firebaseBackend: FirebaseBackend,
        userStore: UserStore
    ) async {
        var uploadedURL: String?
        if let localFileURL,
           let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) {
            uploadedURL = try? await firebaseBackend.uploadHealthSafetyFile(
                localFileURL,
                organizationId: orgId,
                projectId: project.id,
                category: "rams",
                fileName: originalFileName ?? localFileURL.lastPathComponent
            )
        }
        data.ramsDocuments.insert(
            HSRamsDocument(
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
            ),
            at: 0
        )
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
        if let localFileURL,
           let orgId = organizationId(firebaseBackend: firebaseBackend, userStore: userStore) {
            uploadedURL = try? await firebaseBackend.uploadHealthSafetyFile(
                localFileURL,
                organizationId: orgId,
                projectId: project.id,
                category: "otherDocuments",
                fileName: originalFileName ?? localFileURL.lastPathComponent
            )
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

    private static let defaultLibraryTalks: [HSToolboxTalk] = {
        let now = Date()

        func parseExternalLibrary(from path: String) -> [HSToolboxTalk] {
            guard let markdown = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            let regexPattern = #"\*\*(TBT-[A-Z]+-[0-9]{3}) · ([^\*]+)\*\*"#
            guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return [] }
            let ns = markdown as NSString
            let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return [] }

            func tradeMeta(for id: String) -> (isGeneral: Bool, trades: [String]) {
                if id.hasPrefix("TBT-GEN-") { return (true, []) }
                if id.hasPrefix("TBT-ELE-") { return (false, ["Electrical"]) }
                if id.hasPrefix("TBT-MEC-") { return (false, ["Mechanical / HVAC"]) }
                if id.hasPrefix("TBT-PLG-") { return (false, ["Plumbing & Gas"]) }
                if id.hasPrefix("TBT-GRD-") { return (false, ["Groundworks"]) }
                if id.hasPrefix("TBT-SCA-") { return (false, ["Scaffolding"]) }
                if id.hasPrefix("TBT-BRK-") { return (false, ["Brick & Block"]) }
                if id.hasPrefix("TBT-JOI-") { return (false, ["Joinery"]) }
                if id.hasPrefix("TBT-DRY-") { return (false, ["Drylining"]) }
                if id.hasPrefix("TBT-PNT-") { return (false, ["Painting"]) }
                if id.hasPrefix("TBT-ROO-") { return (false, ["Roofing"]) }
                if id.hasPrefix("TBT-DEM-") { return (false, ["Demolition"]) }
                if id.hasPrefix("TBT-STL-") { return (false, ["Steel Fixing"]) }
                if id.hasPrefix("TBT-PLA-") { return (false, ["Plant"]) }
                return (false, ["General"])
            }

            return matches.compactMap { match in
                guard match.numberOfRanges >= 3 else { return nil }
                let id = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let meta = tradeMeta(for: id)
                return HSToolboxTalk(
                    id: id,
                    title: title,
                    category: meta.isGeneral ? .general : .trade,
                    isGeneral: meta.isGeneral,
                    trades: meta.trades,
                    purpose: "Review controls and safe method of work for \(title.lowercased()) before starting the task.",
                    keyPoints: [
                        "Brief the team on hazards and controls for this task.",
                        "Confirm competence, permits, and PPE requirements before work starts.",
                        "Stop work and escalate if site conditions change or controls fail."
                    ],
                    source: .library,
                    ownerOrganizationId: nil,
                    status: .approved,
                    version: 1,
                    updatedAt: now,
                    fileURL: nil
                )
            }
        }

        let externalPaths = [
            "/Users/farnienel/Downloads/TBT and Dash/TOOLBOX-TALK-LIBRARY.md",
            "/Users/farnienel/Downloads/Toolbox t/TOOLBOX-TALK-LIBRARY.md"
        ]
        for path in externalPaths {
            let parsed = parseExternalLibrary(from: path)
            if !parsed.isEmpty {
                return parsed
            }
        }

        let general = [
            "Working at Height", "Manual Handling", "PPE Selection and Use", "Slips Trips and Falls", "Fire Prevention and Emergency Routes",
            "Housekeeping and Waste Segregation", "Working Around Mobile Plant", "Noise and Vibration Awareness", "Site Induction and Welfare Rules", "Accident and Near-Miss Reporting"
        ]
        let electrical = [
            "Safe Isolation Procedure", "Temporary Electrical Installations", "Cable Management and Trip Prevention", "Testing and Verification Records",
            "Live Services Avoidance", "Portable Appliance Safety", "RCD and Circuit Protection", "Lockout Tagout for Electrical Works"
        ]
        let groundworks = [
            "Excavations and Services Avoidance", "Trench Support and Edge Protection", "Ground Stability and Weather Risk", "Plant Banksman Controls",
            "Manual Handling in Groundworks", "Confined Spaces Entry Control", "Buried Services Permit to Dig", "Backfilling and Compaction Safety"
        ]
        let joinery = [
            "Wood Dust and Extraction", "Bench and Portable Saw Safety", "Hand Tool Maintenance", "Ladder and Podium Use for Joiners",
            "Adhesives and Solvent Ventilation", "Fire Door Installation Controls", "Manual Handling of Sheet Materials", "Workshop Housekeeping Standards"
        ]
        let mechanical = [
            "Hot Works Permit Controls", "Lifting and Rigging Awareness", "Ductwork Installation Safety", "Pressurised Systems Isolation",
            "Plant Room Access Controls", "Working at Height for Mechanical Install", "Hand Arm Vibration in Mechanical Works", "Temporary Supports and Bracing"
        ]
        let plumbing = [
            "Gas Safe Working and Purging", "Legionella and Water Hygiene", "Pressure Testing Water Systems", "Soldering and Fire Watch",
            "Working in Service Voids", "Asbestos Awareness for Plumbing Works", "Safe Use of Pipe Press Tools", "Draining Down and Refill Controls"
        ]

        func makeTalk(id: String, title: String, trade: String?) -> HSToolboxTalk {
            let isGeneral = trade == nil
            return HSToolboxTalk(
                id: id,
                title: title,
                category: isGeneral ? .general : .trade,
                isGeneral: isGeneral,
                trades: trade.map { [$0] } ?? [],
                purpose: "Ensure safe planning, communication, and execution for \(title.lowercased()).",
                keyPoints: [
                    "Review hazards and controls before work starts.",
                    "Confirm competence, permits, and required PPE for the task.",
                    "Stop and report immediately if site conditions change."
                ],
                source: .library,
                ownerOrganizationId: nil,
                status: .approved,
                version: 1,
                updatedAt: now,
                fileURL: nil
            )
        }

        var output: [HSToolboxTalk] = []
        output += general.enumerated().map { makeTalk(id: String(format: "TBT-GEN-%03d", $0.offset + 1), title: $0.element, trade: nil) }
        output += electrical.enumerated().map { makeTalk(id: String(format: "TBT-ELE-%03d", $0.offset + 1), title: $0.element, trade: "Electrical") }
        output += groundworks.enumerated().map { makeTalk(id: String(format: "TBT-GRD-%03d", $0.offset + 1), title: $0.element, trade: "Groundworks") }
        output += joinery.enumerated().map { makeTalk(id: String(format: "TBT-JOI-%03d", $0.offset + 1), title: $0.element, trade: "Joinery") }
        output += mechanical.enumerated().map { makeTalk(id: String(format: "TBT-MEC-%03d", $0.offset + 1), title: $0.element, trade: "Mechanical / HVAC") }
        output += plumbing.enumerated().map { makeTalk(id: String(format: "TBT-PLG-%03d", $0.offset + 1), title: $0.element, trade: "Plumbing & Gas") }
        return output
    }()
}

struct ProjectHealthSafetyView: View {
    let project: Project
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
        let ordered = preferredOrder + grouped.keys.filter { !preferredOrder.contains($0) }.sorted()
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
        let operativeById = Dictionary(uniqueKeysWithValues: operativeStore.operatives.map { ($0.id, $0) })
        for booking in bookingStore.bookings where booking.projectId == project.id {
            guard let operative = operativeById[booking.operativeId] else { continue }
            if let user = userStore.organizationUsers.first(where: { $0.email.caseInsensitiveCompare(operative.email) == .orderedSame }) {
                ids.insert(user.id)
            }
        }
        return ids
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
                talks: filteredLibraryTalks,
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
                signatures: vm.signatures(for: issue.id)
            ) {
                Task {
                    let reminded = await vm.sendReminder(issueId: issue.id, firebaseBackend: firebaseBackend, userStore: userStore)
                    await MainActor.run {
                        reminderSuccessMessage = reminded > 0 ? "Toolbox Reminder Sent." : "No pending recipients to remind."
                    }
                }
            } onViewSignedTalk: {
                Task { await generateSignedIssuePDF(issue: issue) }
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
                issue: issue,
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
        .sheet(isPresented: $showingScheduledTalks) {
            HSScheduledTalksView(
                issues: vm.scheduledIssues(),
                talksById: Dictionary(uniqueKeysWithValues: vm.data.talks.map { ($0.id, $0) }),
                usersById: Dictionary(uniqueKeysWithValues: userStore.organizationUsers.map { ($0.id, $0) }),
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

    private func downloadTalkFromLibrary(_ talk: HSToolboxTalk) {
        guard let generated = HSTalkPDFBuilder.makePDF(for: talk) else { return }
        presentTalkShareSheet(with: generated)
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
            selectedIssueToView != nil

        if hasPresentedSheet {
            selectedTalkForPreview = nil
            selectedIssueToTrack = nil
            selectedIssueToSign = nil
            selectedIssueToView = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                action()
            }
            return
        }
        action()
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
        VStack(alignment: .leading, spacing: 12) {
            let mine = myAssignedIssueEntries()
            if !mine.isEmpty {
                let visibleMine = showAllAssignedInHub ? mine : Array(mine.prefix(2))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("My Toolbox Talks")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Spacer()
                        let pendingMine = mine.filter { $0.signature.status != .signed }.count
                        if pendingMine > 0 {
                            Text("\(pendingMine)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(HS.amber)
                                .clipShape(Capsule())
                        }
                        if mine.count > 2 {
                            Button {
                                showAllAssignedInHub.toggle()
                            } label: {
                                Image(systemName: showAllAssignedInHub ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(HS.slate2)
                                    .frame(width: 28, height: 28)
                                    .background(HS.card)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    VStack(spacing: 8) {
                        ForEach(visibleMine, id: \.issue.id) { entry in
                            let talkTitle = vm.data.talks.first(where: { $0.id == entry.issue.talkId })?.title ?? "Toolbox talk"
                            let isPending = entry.signature.status != .signed
                            HStack(spacing: 10) {
                                Image(systemName: isPending ? "doc.text.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(isPending ? HS.amber : HS.green)
                                    .frame(width: 34, height: 34)
                                    .background((isPending ? HS.amberBg : HS.greenBg))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(talkTitle)
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .layoutPriority(1)
                                    Text("W/C \(entry.issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(isPending ? "Sign Now" : "View Signature") {
                                    if isPending { selectedIssueToSign = entry.issue } else { selectedIssueToView = entry.issue }
                                }
                                .buttonStyle(FilledButtonStyle(tone: isPending ? .teal : .blue, fixedWidth: 188))
                                .layoutPriority(2)
                            }
                            .hsCard(padding: 12)
                        }
                    }
                }
            }

            Text("This project")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HS.slate2)
                .textCase(.uppercase)
            HStack(spacing: 10) {
                hsMetricCard(title: "Talks issued", value: "\(vm.visibleIssues().count)")
                hsMetricCard(title: "Awaiting signatures", value: "\(vm.data.signatures.filter { $0.status == .pending }.count)")
                hsMetricCard(title: "RAMS docs", value: "\(vm.data.ramsDocuments.count)")
            }

            Text("Quick actions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HS.slate2)
                .textCase(.uppercase)
            VStack(spacing: 8) {
                hsActionCard(title: "Issue a Toolbox Talk", subtitle: "Pick a talk and send to operatives", icon: "paperplane.fill") {
                    managerTab = .library
                    showingIssueSheet = true
                }
                hsActionCard(title: "Upload a Toolbox Talk", subtitle: "Add your own talk to the library", icon: "square.and.arrow.up.fill") {
                    showingUploadTalkSheet = true
                }
                hsActionCard(title: "Upload RAMS", subtitle: "Add risk assessment and method statement", icon: "doc.text.fill") {
                    showingAddRams = true
                }
                hsActionCard(title: "Add H&S document", subtitle: "Safe isolation, COSHH, permits and more", icon: "plus.circle.fill") {
                    showingAddOtherDoc = true
                }
                hsActionCard(title: "Scheduled Toolbox Talks", subtitle: "Manage future talks and recipients", icon: "calendar.badge.clock") {
                    showingScheduledTalks = true
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
                    showingUploadTalkSheet = true
                } label: {
                    Label("Upload custom talk", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()
            }

            VStack(spacing: 10) {
                ForEach(groupedLibraryTalks, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        ForEach(group.talks, id: \.id) { talk in
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

                                HStack(spacing: 8) {
                                    Button {
                                        selectedTalkForPreview = talk
                                    } label: {
                                        Text("View Toolbox Talk")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(HS.blue)

                                    Button {
                                        selectedTalkForIssue = talk
                                        showingIssueSheet = true
                                    } label: {
                                        Text("Issue Toolbox Talk")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(HS.teal)
                                }
                            }
                            .hsCard(padding: 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedTalkForPreview = talk
                            }
                        }
                    }
                }
            }
        }
    }

    private var managerTracking: some View {
        VStack(spacing: 8) {
            let myEntries = myAssignedIssueEntries()
            if !myEntries.isEmpty {
                let visibleMyEntries = showAllAssignedInTracking ? myEntries : Array(myEntries.prefix(2))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Assigned to me")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Spacer()
                        if myEntries.count > 2 {
                            Button {
                                showAllAssignedInTracking.toggle()
                            } label: {
                                Image(systemName: showAllAssignedInTracking ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(HS.slate2)
                                    .frame(width: 28, height: 28)
                                    .background(HS.card)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(visibleMyEntries, id: \.issue.id) { entry in
                        let talk = vm.data.talks.first(where: { $0.id == entry.issue.talkId })
                        let isPending = entry.signature.status != .signed
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(talk?.title ?? "Toolbox talk")
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(1)
                                Text("Date \(entry.issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(isPending ? "Sign Now" : "View Signature") {
                                if isPending { selectedIssueToSign = entry.issue } else { selectedIssueToView = entry.issue }
                            }
                            .buttonStyle(FilledButtonStyle(tone: isPending ? .teal : .blue, fixedWidth: 188))
                            .layoutPriority(2)
                        }
                        .hsCard(padding: 12)
                    }
                }
                .hsCard()
            }
            ForEach(vm.visibleIssues(), id: \.id) { issue in
                let signatures = vm.signatures(for: issue.id)
                let signedCount = signatures.filter { $0.status == .signed }.count
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(vm.data.talks.first(where: { $0.id == issue.talkId })?.title ?? "Toolbox talk")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
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
            let filteredIssues = vm.visibleIssues().filter { issue in
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
                || talk.title.localizedCaseInsensitiveContains(search)
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
                                VStack(spacing: 8) {
                                    ForEach(filteredTalks, id: \.id) { talk in
                                        Button {
                                            selectedTalkId = talk.id
                                            showLibraryPicker = false
                                        } label: {
                                            HStack(alignment: .top, spacing: 10) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(talk.title)
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
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        if showDatePicker {
                            DatePicker("Date", selection: $issueDate, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.graphical)
                                .padding(8)
                                .background(.white)
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
                        onIssue(talk, issueDate, Array(selectedRecipientIds))
                        dismiss()
                    } label: {
                        Text("Issue to \(selectedRecipientIds.count) recipient\(selectedRecipientIds.count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HSStatusBadge(text: "\(talk.source == .uploaded ? "Uploaded" : "Library") · \(talk.id)", tone: talk.source == .uploaded ? .info : .ok)
                        Text(talk.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(HS.ink)
                        Text(talk.isGeneral ? "General" : talk.trades.joined(separator: ", "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HS.blue)
                    }
                    .hsCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purpose")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Text(talk.purpose)
                            .font(.system(size: 14))
                            .foregroundStyle(HS.ink)
                    }
                    .hsCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key points")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        ForEach(Array(talk.keyPoints.enumerated()), id: \.offset) { _, point in
                            Text("• \(point)")
                                .font(.system(size: 13))
                                .foregroundStyle(HS.ink)
                        }
                    }
                    .hsCard()

                    HStack(spacing: 10) {
                        Button(action: onIssue) {
                            Label("Issue", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(FilledButtonStyle(tone: .teal))

                        Button(action: onDownload) {
                            Label("Download", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Toolbox Talk")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
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
    let issue: HSToolboxIssue
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
                    Text("Send to further operatives")
                        .font(.system(size: 22, weight: .bold))
                    Text("Select additional recipients for this toolbox talk. Existing recipients are excluded.")
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
    let signatures: [HSToolboxSignature]
    let onSendReminder: () -> Void
    let onViewSignedTalk: () -> Void
    let onRemoveIssue: () -> Void
    let onSendToFurtherOperatives: () -> Void
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
                let signed = signatures.filter { $0.status == .signed }
                let pending = signatures.filter { $0.status != .signed }
                Section("Signed") {
                    ForEach(signed, id: \.id) { signature in
                        let name = userStore.organizationUsers.first(where: { $0.id == signature.userId })?.fullName ?? signature.userId
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                if let signedAt = signature.signedAt {
                                    Text(signedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("Signed")
                                .foregroundStyle(.green)
                        }
                    }
                }
                if !pending.isEmpty {
                    Section("Awaiting") {
                        ForEach(pending, id: \.id) { signature in
                            let name = userStore.organizationUsers.first(where: { $0.id == signature.userId })?.fullName ?? signature.userId
                            HStack {
                                Text(name)
                                Spacer()
                                Text("Pending")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Section("Actions") {
                    Button("View Signed Toolbox Talk") {
                        dismissThenPerform(onViewSignedTalk)
                    }
                    Button("Send to further operatives") {
                        dismissThenPerform(onSendToFurtherOperatives)
                    }
                    Button("Remind pending", action: onSendReminder)
                }
            }
            .navigationTitle("Sign-off tracking")
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
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var readConfirmed = false
    @State private var signatureImageData: Data?
    @State private var showPreviewShare = false
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(talk?.title ?? "Toolbox talk")
                        .font(.system(size: 20, weight: .bold))
                    Text("Date \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let purpose = talk?.purpose, !purpose.isEmpty {
                        Text(purpose)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if let points = talk?.keyPoints, !points.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Key control points")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(HS.slate2)
                                .textCase(.uppercase)
                            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                Text("• \(point)")
                                    .font(.system(size: 13))
                            }
                        }
                        .hsCard()
                    }
                    Button {
                        let generated = talk.flatMap { HSTalkPDFBuilder.makePDF(for: $0) }
                        if let generated {
                            previewURL = generated
                            showPreviewShare = true
                        }
                    } label: {
                        Label("Preview / download talk", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(GhostButtonStyle())
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
            .sheet(isPresented: $showPreviewShare) {
                if let previewURL {
                    HSDocumentShareSheet(activityItems: [previewURL])
                }
            }
        }
    }
}

private struct HSSignedTalkView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    let signature: HSToolboxSignature?
    @EnvironmentObject var userStore: UserStore

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
    @State private var keyPointsRaw = ""
    @State private var showFileImporter = false
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    private let trades = ["General"] + StaffTradeType.pickerCases.map(\.rawValue)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upload Toolbox Talk")
                        .font(.system(size: 26, weight: .bold))
                    Text("Add your own talk to the library. It can then be issued and signed like standard templates.")
                        .font(.system(size: 13))
                        .foregroundStyle(HS.slate)

                    HSUploadDropZone(
                        title: selectedFileName ?? "Upload talk (PDF)",
                        subtitle: selectedFileName == nil ? "or fill in the fields below" : "Ready to save",
                        isFilled: selectedFileName != nil
                    ) { showFileImporter = true }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or write the talk")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        HSFormField(label: "Talk title", text: $title, placeholder: "e.g. Site-specific working rules")
                        HSFormMenuField(label: "Trade", value: trade) {
                            ForEach(trades, id: \.self) { t in
                                Button(t) { trade = t }
                            }
                        }
                        HSFormField(label: "Purpose", text: $purpose, placeholder: "One line — why this matters")
                        HSFormMultilineField(label: "Key control points", text: $keyPointsRaw, placeholder: "One point per line…")
                    }
                    .hsCard()

                    Button {
                        let points = keyPointsRaw
                            .split(separator: "\n")
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            trade.trimmingCharacters(in: .whitespacesAndNewlines),
                            purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                            points,
                            selectedFileURL,
                            selectedFileName
                        )
                        dismiss()
                    } label: {
                        Label("Save to library", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(FilledButtonStyle(tone: .teal))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
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
                    selectedFileURL = url
                    selectedFileName = url.lastPathComponent
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
    @State private var attachedDocTitles: Set<String> = ["Safe Isolation"]
    private let trades = [""] + ["General"] + StaffTradeType.pickerCases.map(\.rawValue)
    private let availableAttachables = ["Safe Isolation", "COSHH", "Permit to Work"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upload RAMS")
                        .font(.system(size: 26, weight: .bold))
                    Text("Upload a Risk Assessment & Method Statement. Operatives can view it and managers can share with clients.")
                        .font(.system(size: 13))
                        .foregroundStyle(HS.slate)

                    HSUploadDropZone(
                        title: selectedFileName ?? "Upload RAMS document",
                        subtitle: selectedFileName == nil ? "PDF or Word up to 25MB" : "Ready to publish",
                        isFilled: selectedFileName != nil
                    ) { showFileImporter = true }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
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

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Attach trade-specific docs")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        HStack(spacing: 8) {
                            ForEach(availableAttachables, id: \.self) { item in
                                Button(item) {
                                    if attachedDocTitles.contains(item) { attachedDocTitles.remove(item) } else { attachedDocTitles.insert(item) }
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(attachedDocTitles.contains(item) ? HS.blue : HS.card)
                                .foregroundStyle(attachedDocTitles.contains(item) ? .white : HS.slate)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .hsCard()

                    Button {
                        let cleanTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            docTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            cleanTrade.isEmpty ? nil : cleanTrade,
                            reviewDate,
                            attachedDocTitles.sorted(),
                            selectedFileURL,
                            selectedFileName
                        )
                        dismiss()
                    } label: {
                        Label("Publish RAMS", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(FilledButtonStyle(tone: .blue))
                    .disabled(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    selectedFileURL = url
                    selectedFileName = url.lastPathComponent
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
                        .font(.system(size: 26, weight: .bold))
                    Text("Add a Safe Isolation procedure, COSHH sheet, permit, or site-wide H&S document.")
                        .font(.system(size: 13))
                        .foregroundStyle(HS.slate)

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
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(FilledButtonStyle(tone: .blue))
                    .disabled(docTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    selectedFileURL = url
                    selectedFileName = url.lastPathComponent
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
            .background(.white)
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
        let safeName = talk.title.replacingOccurrences(of: " ", with: "_")
        let fileName = "ToolboxTalk-\(safeName)-\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

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
                (talk.title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
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
