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
            let mergedTalks = mergeLibraryTalks(into: loaded.talks)
            let mergedIds = Set(mergedTalks.map(\.id))
            let loadedIds = Set(loaded.talks.map(\.id))
            if loaded.talks.isEmpty || mergedIds != loadedIds {
                loaded.talks = mergedTalks
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
        fileURL: String?,
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
            fileURL: fileURL
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

    private func mergeLibraryTalks(into existing: [HSToolboxTalk]) -> [HSToolboxTalk] {
        let uploaded = existing.filter { $0.source == .uploaded }
        let existingLibraryById = Dictionary(uniqueKeysWithValues: existing.filter { $0.source == .library }.map { ($0.id, $0) })
        let baseLibrary = Self.defaultLibraryTalks.map { talk in
            if let existingTalk = existingLibraryById[talk.id] {
                var merged = talk
                merged.updatedAt = existingTalk.updatedAt
                merged.version = max(existingTalk.version, talk.version)
                return merged
            }
            return talk
        }
        let defaultIds = Set(Self.defaultLibraryTalks.map(\.id))
        let extraLibrary = existing.filter { talk in
            talk.source == .library && !defaultIds.contains(talk.id)
        }
        return (baseLibrary + extraLibrary + uploaded)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func makeTalk(
        id: String,
        title: String,
        trade: String? = nil,
        purpose: String,
        keyPoints: [String]
    ) -> HSToolboxTalk {
        let isGeneral = trade == nil
        return HSToolboxTalk(
            id: id,
            title: title,
            category: isGeneral ? .general : .trade,
            isGeneral: isGeneral,
            trades: trade.map { [$0] } ?? [],
            purpose: purpose,
            keyPoints: keyPoints,
            source: .library,
            ownerOrganizationId: nil,
            status: .approved,
            version: 1,
            updatedAt: Date(),
            fileURL: nil
        )
    }

    private static let defaultLibraryTalks: [HSToolboxTalk] = [
        makeTalk(id: "TBT-GEN-001", title: "Working at Height", purpose: "Plan and control all work at height to prevent falls.", keyPoints: ["Use suitable access equipment", "Inspect edge protection", "Use exclusion zones below"]),
        makeTalk(id: "TBT-GEN-002", title: "Working Near Openings, Voids & Risers", purpose: "Prevent falls into openings and risers.", keyPoints: ["Cover and barrier openings", "Use load-rated fixed covers", "Reinstate protection immediately"]),
        makeTalk(id: "TBT-GEN-003", title: "Manual Handling", purpose: "Reduce injuries from lifting and carrying.", keyPoints: ["Assess load and route", "Use mechanical aids", "Team-lift where needed"]),
        makeTalk(id: "TBT-GEN-004", title: "Slips, Trips & Falls", purpose: "Keep site access routes safe and clear.", keyPoints: ["Maintain housekeeping", "Manage cables and spills", "Wear suitable footwear"]),
        makeTalk(id: "TBT-GEN-005", title: "PPE — Selection, Use & Care", purpose: "Ensure PPE is task-appropriate and maintained.", keyPoints: ["Wear site minimum PPE", "Inspect before use", "Replace damaged PPE"]),
        makeTalk(id: "TBT-GEN-006", title: "COSHH — General Awareness", purpose: "Control exposure to hazardous substances.", keyPoints: ["Read COSHH/SDS first", "Use ventilation controls", "Never mix chemicals"]),
        makeTalk(id: "TBT-GEN-007", title: "Dust & Silica (RCS) Control", purpose: "Limit harmful dust exposure on site.", keyPoints: ["Use extraction/water suppression", "Avoid dry sweeping", "Use suitable RPE"]),
        makeTalk(id: "TBT-GEN-008", title: "Noise & Hand-Arm Vibration (HAVS)", purpose: "Reduce long-term hearing and vibration injury.", keyPoints: ["Wear hearing protection", "Control trigger time", "Report symptoms early"]),
        makeTalk(id: "TBT-GEN-009", title: "Fire Safety & Emergency Procedures", purpose: "Ensure everyone understands fire response.", keyPoints: ["Know exits and assembly points", "Keep routes clear", "Use correct extinguisher type"]),
        makeTalk(id: "TBT-GEN-010", title: "First Aid, Welfare & Reporting (RIDDOR)", purpose: "Promote immediate reporting and correct response.", keyPoints: ["Report all incidents", "Know first aid points", "Use correct emergency address"]),
        makeTalk(id: "TBT-GEN-011", title: "Site Induction & Rules Refresh", purpose: "Reinforce project-specific safety rules.", keyPoints: ["Review key site rules", "Sign in/out correctly", "Confirm permit-controlled zones"]),
        makeTalk(id: "TBT-GEN-012", title: "Plant & Pedestrian Segregation", purpose: "Prevent plant-person interface incidents.", keyPoints: ["Use designated walkways", "Follow banksman signals", "Never walk behind moving plant"]),
        makeTalk(id: "TBT-GEN-013", title: "Hand & Power Tools (Safe Use)", purpose: "Use tools safely and isolate defects.", keyPoints: ["Use the right tool", "Check guards and condition", "Quarantine defective tools"]),
        makeTalk(id: "TBT-GEN-014", title: "Adverse Weather (Heat, Cold, Wind)", purpose: "Adjust working practices for weather risk.", keyPoints: ["Stop unsafe height work", "Hydrate and take breaks", "Secure loose materials"]),

        makeTalk(id: "TBT-ELE-001", title: "Safe Isolation Procedure", trade: "Electrical", purpose: "Prove circuits are dead before intervention.", keyPoints: ["Prove-test-prove", "Use lock-off/tag", "Record isolation points"]),
        makeTalk(id: "TBT-ELE-002", title: "Cable Strike / Working Near Live Services", trade: "Electrical", purpose: "Prevent contact with hidden live services.", keyPoints: ["Review drawings", "Use CAT and Genny", "Use permit to break-in"]),
        makeTalk(id: "TBT-ELE-003", title: "Temporary Electrical Installations", trade: "Electrical", purpose: "Control temporary electrical hazards.", keyPoints: ["Use 110V/RCD protection", "Inspect leads and connectors", "Protect outdoor equipment"]),
        makeTalk(id: "TBT-ELE-004", title: "Working in Risers & Confined Electrical Spaces", trade: "Electrical", purpose: "Work safely in constrained electrical areas.", keyPoints: ["Protect riser openings", "Isolate before work", "Maintain safe egress"]),
        makeTalk(id: "TBT-ELE-005", title: "Live Working (Prohibited / Exceptional)", trade: "Electrical", purpose: "Avoid live work unless formally authorised.", keyPoints: ["Avoid live work by default", "Use documented controls", "Only competent persons"]),
        makeTalk(id: "TBT-ELE-006", title: "Test Instruments (GS38)", trade: "Electrical", purpose: "Use testing equipment safely and correctly.", keyPoints: ["Check calibration", "Use GS38-compliant leads", "Use correct CAT rating"]),
        makeTalk(id: "TBT-ELE-007", title: "Containment & Tray at Height", trade: "Electrical", purpose: "Install containment safely at height.", keyPoints: ["Use suitable access", "Control dropped objects", "Handle long lengths safely"]),
        makeTalk(id: "TBT-ELE-008", title: "Battery, Solar PV & Stored Energy", trade: "Electrical", purpose: "Manage DC and stored-energy electrical risks.", keyPoints: ["Apply DC isolation controls", "Account for arc risk", "Use competent personnel"]),

        makeTalk(id: "TBT-MEC-001", title: "Hot Works (Welding, Brazing, Cutting)", trade: "Mechanical / HVAC", purpose: "Control fire and fume risks in hot works.", keyPoints: ["Use permit to work", "Protect combustibles", "Fire watch and post-watch"]),
        makeTalk(id: "TBT-MEC-002", title: "Pressure Testing of Pipework", trade: "Mechanical / HVAC", purpose: "Pressure test systems safely.", keyPoints: ["Follow test procedure", "Use exclusion zones", "Increase pressure gradually"]),
        makeTalk(id: "TBT-MEC-003", title: "Ductwork Install at Height", trade: "Mechanical / HVAC", purpose: "Install ductwork safely above ground level.", keyPoints: ["Use suitable access platform", "Control dropped objects", "Coordinate with trades below"]),
        makeTalk(id: "TBT-MEC-004", title: "Lifting & Rigging Plant (AHUs, Chillers)", trade: "Mechanical / HVAC", purpose: "Lift plant safely under a controlled lift plan.", keyPoints: ["Use appointed person plan", "Check lifting gear", "Maintain exclusion zone"]),
        makeTalk(id: "TBT-MEC-005", title: "Refrigerants & F-Gas Handling", trade: "Mechanical / HVAC", purpose: "Handle refrigerants safely and compliantly.", keyPoints: ["Use F-Gas competence", "Ventilate working area", "Detect and recover leaks safely"]),
        makeTalk(id: "TBT-MEC-006", title: "Commissioning Rotating Plant", trade: "Mechanical / HVAC", purpose: "Commission rotating equipment safely.", keyPoints: ["Check guards in place", "Isolate before access", "Use controlled test-runs"]),
        makeTalk(id: "TBT-MEC-007", title: "Insulation & Lagging", trade: "Mechanical / HVAC", purpose: "Control fibre and dust exposure during lagging.", keyPoints: ["Use suitable RPE", "Protect skin and eyes", "Report possible asbestos immediately"]),
        makeTalk(id: "TBT-MEC-008", title: "Plantroom Working", trade: "Mechanical / HVAC", purpose: "Manage plantroom-specific hazards.", keyPoints: ["Control noise and heat risk", "Follow isolation rules", "Maintain safe housekeeping"]),

        makeTalk(id: "TBT-PLG-001", title: "Gas Safe Working & Purging", trade: "Plumbing & Gas", purpose: "Control gas risks during purge and commissioning.", keyPoints: ["Use Gas Safe competence", "Perform tightness tests", "Control ignition sources"]),
        makeTalk(id: "TBT-PLG-002", title: "Hot Works on Pipework (Solder/Braze)", trade: "Plumbing & Gas", purpose: "Control heat-related hazards in pipework works.", keyPoints: ["Use permit controls", "Apply heat protection mats", "Perform fire watch"]),
        makeTalk(id: "TBT-PLG-003", title: "Legionella & Water Hygiene", trade: "Plumbing & Gas", purpose: "Maintain water hygiene and reduce legionella risk.", keyPoints: ["Avoid dead legs", "Flush and disinfect correctly", "Record hygiene actions"]),
        makeTalk(id: "TBT-PLG-004", title: "Below-Ground Drainage Connections", trade: "Plumbing & Gas", purpose: "Install drainage safely in below-ground conditions.", keyPoints: ["Manage excavation safety", "Use hygiene controls", "Handle pipe sections safely"]),
        makeTalk(id: "TBT-PLG-005", title: "Soil & Waste at Height", trade: "Plumbing & Gas", purpose: "Install soil and waste systems safely at height.", keyPoints: ["Use proper access", "Control dropped materials", "Manage solvent fumes"]),
        makeTalk(id: "TBT-PLG-006", title: "Solvent Cements & Adhesives", trade: "Plumbing & Gas", purpose: "Use cements and adhesives without exposure incidents.", keyPoints: ["Ventilate work area", "Use PPE and RPE", "Store away from ignition sources"]),
        makeTalk(id: "TBT-PLG-007", title: "Carbon Monoxide Awareness", trade: "Plumbing & Gas", purpose: "Prevent and detect CO exposure hazards.", keyPoints: ["Check flues and ventilation", "Recognize CO symptoms", "Use functional CO alarms"]),
        makeTalk(id: "TBT-PLG-008", title: "Water Bursts & Flooding Control", trade: "Plumbing & Gas", purpose: "Respond quickly to burst and flooding events.", keyPoints: ["Know isolation points", "Protect finishes and equipment", "Escalate and report quickly"]),

        makeTalk(id: "TBT-GRD-001", title: "Excavations — Collapse & Access", trade: "Groundworks", purpose: "Prevent excavation collapse and access incidents.", keyPoints: ["Support or batter excavations", "Inspect daily", "Maintain spoil set-back"]),
        makeTalk(id: "TBT-GRD-002", title: "Underground Services Avoidance", trade: "Groundworks", purpose: "Avoid utility strikes during groundworks.", keyPoints: ["Use utility drawings", "Use CAT and Genny", "Use trial holes/hand dig"]),
        makeTalk(id: "TBT-GRD-003", title: "Confined Spaces (Chambers, Manholes)", trade: "Groundworks", purpose: "Control confined-space entry hazards.", keyPoints: ["Use permit controls", "Perform gas testing", "Have rescue plan ready"]),
        makeTalk(id: "TBT-GRD-004", title: "Plant on Groundworks (Excavators, Dumpers)", trade: "Groundworks", purpose: "Operate groundworks plant safely.", keyPoints: ["Use segregation and banksman", "Check quick-hitch safety", "Control refuelling safely"]),
        makeTalk(id: "TBT-GRD-005", title: "Concrete & Wet Pours", trade: "Groundworks", purpose: "Control burns and placement hazards during pours.", keyPoints: ["Use skin protection", "Control pump-line whip", "Provide wash facilities"]),
        makeTalk(id: "TBT-GRD-006", title: "Working Near Water / Flooding", trade: "Groundworks", purpose: "Reduce drowning and contamination risks.", keyPoints: ["Use edge protection", "Keep rescue equipment ready", "Monitor weather and pumping"]),

        makeTalk(id: "TBT-JOI-001", title: "Woodworking Machinery & Saws", trade: "Joinery", purpose: "Operate woodworking machinery without injury.", keyPoints: ["Keep guards/riving knife fitted", "Use push sticks", "Use extraction controls"]),
        makeTalk(id: "TBT-JOI-002", title: "Wood Dust (Carcinogen)", trade: "Joinery", purpose: "Control carcinogenic wood dust exposure.", keyPoints: ["Use on-tool extraction", "Use suitable RPE", "Avoid dry sweeping"]),
        makeTalk(id: "TBT-JOI-003", title: "Nail Guns & Cartridge Tools", trade: "Joinery", purpose: "Prevent inadvertent discharge injuries.", keyPoints: ["Never bypass safety tip", "Keep hands clear of firing line", "Disconnect when idle"]),
        makeTalk(id: "TBT-JOI-004", title: "1st Fix at Height & Access", trade: "Joinery", purpose: "Deliver first-fix works safely at height.", keyPoints: ["Use podium/tower access", "Control timber handling", "Control dropped objects"]),
        makeTalk(id: "TBT-JOI-005", title: "Adhesives, Sealants & Solvents", trade: "Joinery", purpose: "Use adhesives safely and limit exposure.", keyPoints: ["Ventilate enclosed areas", "Use eye/skin protection", "Control flammability risk"]),
        makeTalk(id: "TBT-JOI-006", title: "Manual Handling of Sheet Materials", trade: "Joinery", purpose: "Handle sheet materials without strain injury.", keyPoints: ["Use team-lifts/board lifters", "Protect from sharp edges", "Plan clear routes"]),

        makeTalk(id: "TBT-SCA-001", title: "Scaffold Erection & Dismantle (SG4)", trade: "Scaffolding", purpose: "Erect and dismantle scaffolds with controlled fall protection.", keyPoints: ["Work to SG4 methods", "Use advance guardrails", "Maintain exclusion zones below"]),
        makeTalk(id: "TBT-SCA-002", title: "Scaffold Inspection & Tagging", trade: "Scaffolding", purpose: "Ensure only safe tagged scaffolds are used.", keyPoints: ["Check tags before use", "Inspect after weather/events", "Report alterations or damage"]),

        makeTalk(id: "TBT-BRK-001", title: "Silica Dust from Cutting Blocks & Bricks", trade: "Brick & Block", purpose: "Control silica exposure during brick and block cutting.", keyPoints: ["Use water suppression or extraction", "Wear face-fit-tested FFP3", "Vacuum dust instead of dry sweeping"]),
        makeTalk(id: "TBT-BRK-002", title: "Manual Handling of Blocks", trade: "Brick & Block", purpose: "Reduce musculoskeletal injuries in block laying.", keyPoints: ["Use mechanical aids where possible", "Use team-lifts for heavy blocks", "Set work at suitable height"]),

        makeTalk(id: "TBT-DRY-001", title: "Board Handling & Working at Height", trade: "Drylining", purpose: "Install plasterboard safely at height.", keyPoints: ["Use board lifters or 2-person lift", "Use suitable podium/tower access", "Control dropped materials"]),
        makeTalk(id: "TBT-DRY-002", title: "Dust from Sanding & Mixing", trade: "Drylining", purpose: "Minimise dust exposure from drylining and finishing.", keyPoints: ["Use extraction-compatible sanding", "Wear RPE", "Vacuum dust, do not sweep"]),

        makeTalk(id: "TBT-PNT-001", title: "Solvents & Isocyanates (COSHH)", trade: "Painting & Decorating", purpose: "Control chemical exposure from coatings and thinners.", keyPoints: ["Check COSHH/SDS", "Ventilate work area", "Use suitable RPE/PPE"]),
        makeTalk(id: "TBT-PNT-002", title: "Access for Decorating", trade: "Painting & Decorating", purpose: "Use safe access methods for decorating tasks.", keyPoints: ["Use podiums/towers over overreaching ladders", "Keep access routes clear", "Beware wet/slippery surfaces"]),

        makeTalk(id: "TBT-ROO-001", title: "Roof Edge Protection & Fragile Surfaces", trade: "Roofing", purpose: "Prevent falls from roofs and through fragile surfaces.", keyPoints: ["Provide edge protection", "Cover/barrier rooflights", "Use collective protection first"]),
        makeTalk(id: "TBT-ROO-002", title: "Hot Works on Roofs (Torch-On)", trade: "Roofing", purpose: "Control fire risk during torch-on roofing works.", keyPoints: ["Use permit system", "Control combustibles", "Provide fire watch during and after"]),

        makeTalk(id: "TBT-DEM-001", title: "Asbestos & Unexpected Discovery", trade: "Demolition", purpose: "Prevent exposure during demolition and strip-out.", keyPoints: ["Check surveys before work", "Stop immediately if suspected ACM is found", "Escalate to licensed removal process"]),
        makeTalk(id: "TBT-DEM-002", title: "Structural Stability During Demolition", trade: "Demolition", purpose: "Follow safe sequence to avoid collapse.", keyPoints: ["Follow demolition method statement", "Maintain exclusion zones", "Do not deviate sequence"]),

        makeTalk(id: "TBT-STL-001", title: "Rebar Handling & Protruding Bar", trade: "Steel Fixing", purpose: "Control impalement and handling hazards in steel fixing.", keyPoints: ["Cap protruding bars", "Use handling aids", "Control sharp cut ends"]),
        makeTalk(id: "TBT-STL-002", title: "Concrete Pours & Pump Lines", trade: "Steel Fixing", purpose: "Control whip, splash and burn risk during pours.", keyPoints: ["Establish exclusion zones", "Control pump-line movement", "Wear wet-concrete PPE"]),

        makeTalk(id: "TBT-PLA-001", title: "Operator Competence & Daily Checks", trade: "Plant", purpose: "Ensure only competent operators use inspected plant.", keyPoints: ["Use CPCS/NPORS competence", "Complete daily checks", "Quarantine defective plant"]),
        makeTalk(id: "TBT-PLA-002", title: "MEWP Safe Use & Rescue", trade: "Plant", purpose: "Operate MEWPs with rescue readiness.", keyPoints: ["Confirm IPAF competence", "Assess ground/stability", "Have rescue plan in place"])
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

    private var groupedLibraryTalks: [(title: String, talks: [HSToolboxTalk])] {
        let order = [
            "General",
            "Electrical",
            "Groundworks",
            "Joinery",
            "Mechanical / HVAC",
            "Plumbing & Gas",
            "Scaffolding",
            "Brick & Block",
            "Drylining",
            "Painting & Decorating",
            "Roofing",
            "Demolition",
            "Steel Fixing",
            "Plant"
        ]
        var buckets: [String: [HSToolboxTalk]] = [:]
        for talk in filteredLibraryTalks {
            let key: String
            if talk.isGeneral {
                key = "General"
            } else {
                key = talk.trades.first ?? "General"
            }
            buckets[key, default: []].append(talk)
        }
        return order.compactMap { title in
            guard let talks = buckets[title], !talks.isEmpty else { return nil }
            return (title, talks.sorted { $0.title < $1.title })
        }
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
            HSTrackIssueView(
                issue: issue,
                talk: vm.data.talks.first(where: { $0.id == issue.talkId }),
                signatures: vm.signatures(for: issue.id),
                projectName: project.siteName
            ) {
                Task { await vm.sendReminder(issueId: issue.id, firebaseBackend: firebaseBackend, userStore: userStore) }
            }
            .environmentObject(userStore)
        }
        .sheet(item: $selectedIssueToSign) { issue in
            HSSignTalkView(
                issue: issue,
                talk: vm.data.talks.first(where: { $0.id == issue.talkId }),
                signatures: vm.signatures(for: issue.id),
                users: userStore.organizationUsers,
                projectName: project.siteName
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
                signature: vm.signatures(for: issue.id).first(where: { $0.userId == (userStore.currentUser?.id ?? "") }),
                signatures: vm.signatures(for: issue.id),
                users: userStore.organizationUsers,
                projectName: project.siteName
            )
        }
        .sheet(isPresented: $showingUploadTalkSheet) {
            HSUploadTalkSheet { title, trade, purpose, keyPoints, fileURL in
                Task {
                    await vm.addUploadedTalk(
                        title: title,
                        trade: trade,
                        purpose: purpose,
                        keyPoints: keyPoints,
                        fileURL: fileURL,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddRams) {
            HSUploadRAMSSheet { title, trade in
                Task {
                    await vm.addRams(
                        title: title,
                        trade: trade,
                        firebaseBackend: firebaseBackend,
                        userStore: userStore
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddOtherDoc) {
            HSUploadSiteDocumentSheet { title, trade, category in
                Task {
                    await vm.addOtherDoc(
                        title: title,
                        trade: trade,
                        category: category,
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
        let myId = userStore.currentUser?.id ?? ""
        let myIssues = vm.data.issues.filter { issue in
            vm.signatures(for: issue.id).contains(where: { $0.userId == myId })
        }
        let pendingMyIssues = myIssues.filter { issue in
            vm.signatures(for: issue.id).first(where: { $0.userId == myId })?.status != .signed
        }

        return VStack(alignment: .leading, spacing: 12) {
            if !myIssues.isEmpty {
                HStack {
                    Text("My Toolbox Talks")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HS.slate2)
                        .textCase(.uppercase)
                    Spacer()
                    if !pendingMyIssues.isEmpty {
                        Text("\(pendingMyIssues.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(HS.amber)
                            .clipShape(Capsule())
                    }
                }
                VStack(spacing: 0) {
                    ForEach(myIssues, id: \.id) { issue in
                        let mySignature = vm.signatures(for: issue.id).first(where: { $0.userId == myId })
                        let isPending = mySignature?.status != .signed
                        let title = vm.data.talks.first(where: { $0.id == issue.talkId })?.title ?? "Toolbox talk"
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isPending ? HS.amberBg : HS.greenBg)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Image(systemName: isPending ? "doc.text" : "checkmark")
                                        .foregroundStyle(isPending ? HS.amber : HS.green)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(HS.ink)
                                    .lineLimit(1)
                                Text("W/C \(issue.weekCommencing.formatted(date: .abbreviated, time: .omitted)) · assigned to you")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(HS.slate)
                            }
                            Spacer()
                            Button(isPending ? "Sign" : "Signed") {
                                if isPending { selectedIssueToSign = issue } else { selectedIssueToView = issue }
                            }
                            .buttonStyle(FilledButtonStyle(tone: isPending ? .teal : .blue))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        if issue.id != myIssues.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 6)
            }

            Text("This project")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HS.slate2)
                .textCase(.uppercase)

            HStack(spacing: 10) {
                hsMetricCard(title: "Talks issued", value: "\(vm.data.issues.count)")
                hsMetricCard(title: "Awaiting signatures", value: "\(vm.data.signatures.filter { $0.status == .pending }.count)")
                hsMetricCard(title: "RAMS docs", value: "\(vm.data.ramsDocuments.count)")
            }

            Text("Quick actions")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HS.slate2)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                hsActionRow(title: "Issue a Toolbox Talk", subtitle: "Pick a talk and send to operatives", icon: "paperplane.fill", tone: HS.teal) {
                    selectedTalkForIssue = nil
                    showingIssueSheet = true
                }
                hsActionRow(title: "Upload a Toolbox Talk", subtitle: "Add your own talk to the library", icon: "square.and.arrow.up", tone: HS.teal) {
                    showingUploadTalkSheet = true
                }
                hsActionRow(title: "Upload RAMS", subtitle: "Add a risk assessment / method statement", icon: "doc.text.fill", tone: HS.blue) {
                    showingAddRams = true
                }
                hsActionRow(title: "Add H&S document", subtitle: "Safe isolation, COSHH, permits", icon: "plus", tone: HS.amber, isLast: true) {
                    showingAddOtherDoc = true
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 6)
        }
    }

    private func hsActionRow(title: String, subtitle: String, icon: String, tone: Color, isLast: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tone.opacity(0.13))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tone)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(HS.ink)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(HS.slate)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HS.slate2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 68)
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

            VStack(spacing: 12) {
                ForEach(groupedLibraryTalks, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)

                        ForEach(group.talks, id: \.id) { talk in
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
    let projectName: String
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

                    if !pending.isEmpty {
                        Text("Awaiting (\(pending.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                        recipientListCard(signatures: pending, pending: true)
                    }

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
        guard let talk else { return nil }
        return HSToolboxTalkDocumentBuilder.makeIssuedTalkDocument(
            issue: issue,
            talk: talk,
            signatures: signatures,
            users: userStore.organizationUsers,
            projectName: projectName
        )
    }
}

private struct HSSignTalkView: View {
    let issue: HSToolboxIssue
    let talk: HSToolboxTalk?
    let signatures: [HSToolboxSignature]
    let users: [AppUser]
    let projectName: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var readConfirmed = false
    @State private var signatureImageData: Data?
    
    private var talkDocumentURL: URL? {
        guard let talk else { return nil }
        return HSToolboxTalkDocumentBuilder.makeIssuedTalkDocument(
            issue: issue,
            talk: talk,
            signatures: signatures,
            users: users,
            projectName: projectName
        )
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
    let signatures: [HSToolboxSignature]
    let users: [AppUser]
    let projectName: String
    
    private var talkDocumentURL: URL? {
        guard let talk else { return nil }
        return HSToolboxTalkDocumentBuilder.makeIssuedTalkDocument(
            issue: issue,
            talk: talk,
            signatures: signatures,
            users: users,
            projectName: projectName
        )
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
    let onSave: (String, String, String, [String], String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var trade = "General"
    @State private var purpose = ""
    @State private var keyPointsRaw = ""
    @State private var pickedFileName: String?
    @State private var copiedFilePath: String?
    @State private var showImporter = false

    private let trades = ["General", "Electrical", "Mechanical / HVAC", "Plumbing & Gas", "Groundworks", "Joinery"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Upload Toolbox Talk")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(HS.ink)
                    Text("Add your own talk to the library. Upload a PDF or complete details below.")
                        .font(.system(size: 13))
                        .foregroundStyle(HS.slate)

                    Button {
                        showImporter = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: copiedFilePath == nil ? "square.and.arrow.up" : "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(copiedFilePath == nil ? HS.blue : HS.green)
                            Text(pickedFileName ?? "Upload talk (PDF)")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(HS.ink)
                            Text(copiedFilePath == nil ? "Tap to choose a PDF" : "Ready to save")
                                .font(.system(size: 12))
                                .foregroundStyle(HS.slate)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.plain)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(copiedFilePath == nil ? HS.line : HS.green, style: StrokeStyle(lineWidth: 1.6, dash: copiedFilePath == nil ? [5] : []))
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Talk title")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        TextField("e.g. Site-specific working rules", text: $title)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        Picker("Category", selection: $trade) {
                            ForEach(trades, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purpose")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        TextField("One line - why this matters", text: $purpose)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key control points")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HS.slate2)
                            .textCase(.uppercase)
                        TextField("One point per line", text: $keyPointsRaw, axis: .vertical)
                            .lineLimit(5, reservesSpace: true)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .hsCard(padding: 14)

                    Text("Saved as approved and ready to issue.")
                        .font(.system(size: 12))
                        .foregroundStyle(HS.slate)

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
                            copiedFilePath
                        )
                        dismiss()
                    } label: {
                        Label("Save to library", systemImage: "checkmark")
                    }
                    .buttonStyle(FilledButtonStyle(tone: .blue))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Upload Toolbox Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                pickedFileName = url.lastPathComponent
                copiedFilePath = HSToolboxTalkDocumentBuilder.copyImportedTalkFile(url)
            }
        }
    }
}

private struct HSUploadRAMSSheet: View {
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var trade = "General"
    @State private var showImporter = false
    @State private var pickedFileName: String?
    private let trades = ["General", "Electrical", "Mechanical / HVAC", "Plumbing & Gas", "Groundworks", "Joinery"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Upload RAMS")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(HS.ink)
                    Text("Upload a RAMS document for this project and tag the relevant trade.")
                        .font(.system(size: 13))
                        .foregroundStyle(HS.slate)
                    Button { showImporter = true } label: {
                        HStack {
                            Image(systemName: pickedFileName == nil ? "doc.badge.plus" : "checkmark.circle.fill")
                            Text(pickedFileName ?? "Upload RAMS document")
                            Spacer()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HS.ink)
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HS.line, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Document title").font(.system(size: 11, weight: .bold)).foregroundStyle(HS.slate2).textCase(.uppercase)
                        TextField("e.g. CAT A fit-out master RAMS", text: $title)
                            .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trade / area").font(.system(size: 11, weight: .bold)).foregroundStyle(HS.slate2).textCase(.uppercase)
                        Picker("Trade", selection: $trade) { ForEach(trades, id: \.self) { Text($0).tag($0) } }
                            .pickerStyle(.menu)
                    }.hsCard(padding: 14)

                    Button {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), trade)
                        dismiss()
                    } label: {
                        Label("Publish RAMS", systemImage: "checkmark")
                    }
                    .buttonStyle(FilledButtonStyle(tone: .blue))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Upload RAMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .rtf, .plainText]) { result in
            if case .success(let url) = result { pickedFileName = url.lastPathComponent }
        }
    }
}

private struct HSUploadSiteDocumentSheet: View {
    let onSave: (String, String?, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var trade = ""
    @State private var category = "trade"
    @State private var showImporter = false
    @State private var pickedFileName: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Add H&S Document")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(HS.ink)
                    Text("Add a trade or site-wide H&S document to this project.")
                        .font(.system(size: 13))
                        .foregroundStyle(HS.slate)

                    Button { showImporter = true } label: {
                        HStack {
                            Image(systemName: pickedFileName == nil ? "doc.badge.plus" : "checkmark.circle.fill")
                            Text(pickedFileName ?? "Upload document")
                            Spacer()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HS.ink)
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HS.line, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Document title").font(.system(size: 11, weight: .bold)).foregroundStyle(HS.slate2).textCase(.uppercase)
                        TextField("e.g. Safe isolation procedure", text: $title)
                            .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trade (optional)").font(.system(size: 11, weight: .bold)).foregroundStyle(HS.slate2).textCase(.uppercase)
                        TextField("Electrical / Mechanical / etc", text: $trade)
                            .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.hsCard(padding: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category").font(.system(size: 11, weight: .bold)).foregroundStyle(HS.slate2).textCase(.uppercase)
                        Picker("Category", selection: $category) {
                            Text("Trade").tag("trade")
                            Text("Site wide").tag("site_wide")
                        }
                        .pickerStyle(.segmented)
                    }.hsCard(padding: 14)

                    Button {
                        let cleanTrade = trade.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            cleanTrade.isEmpty ? nil : cleanTrade,
                            category
                        )
                        dismiss()
                    } label: {
                        Label("Save document", systemImage: "checkmark")
                    }
                    .buttonStyle(FilledButtonStyle(tone: .blue))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(HS.bg.ignoresSafeArea())
            .navigationTitle("Add H&S Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image, .plainText]) { result in
            if case .success(let url) = result { pickedFileName = url.lastPathComponent }
        }
    }
}

private enum HSToolboxTalkDocumentBuilder {
    private struct SignoffRow {
        let name: String
        let trade: String
        let signatureImage: UIImage?
        let signedAtText: String
    }

    static func copyImportedTalkFile(_ sourceURL: URL) -> String? {
        let destination = libraryRootDirectory().appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
        let target = destination.appendingPathComponent("\(UUID().uuidString)-\(safeFilename(sourceURL.lastPathComponent)).pdf")
        do {
            let access = sourceURL.startAccessingSecurityScopedResource()
            defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: sourceURL, to: target)
            return target.path
        } catch {
            return nil
        }
    }

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
        return buildTalkPDF(
            to: outputURL,
            reference: talk.id,
            title: talk.title,
            subtitle: "\(talk.id) · \(talk.isGeneral ? "General H&S" : talk.trades.joined(separator: ", "))",
            purpose: talk.purpose,
            keyPoints: talk.keyPoints,
            footer: "Project Planner Toolbox Library · v\(talk.version) · \(talk.status.rawValue.capitalized)",
            projectName: "Library",
            weekCommencing: nil,
            presentedBy: "Project Planner",
            signoffRows: [],
            expectedSignoffCount: 0
        )
    }

    static func makeIssuedTalkDocument(
        issue: HSToolboxIssue,
        talk: HSToolboxTalk,
        signatures: [HSToolboxSignature],
        users: [AppUser],
        projectName: String
    ) -> URL? {
        let rows = signatures.map { signature in
            let user = users.first(where: { $0.id == signature.userId })
            let displayName = user?.fullName.isEmpty == false ? (user?.fullName ?? signature.userId) : (user?.email ?? signature.userId)
            let trade = StaffTradeType.displayLabel(presetRaw: user?.tradeTypePreset, custom: user?.tradeTypeCustom)
            let image: UIImage? = signature.signatureImageBase64.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
            let signedAtText = signature.signedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Awaiting"
            return SignoffRow(name: displayName, trade: trade, signatureImage: image, signedAtText: signedAtText)
        }

        let issuedURL = issuePDFURL(issueId: issue.id, title: talk.title)
        let presentedBy = users.first(where: { $0.id == issue.issuedByUserId })?.fullName ?? issue.issuedByUserId

        if talk.source == .uploaded, let sourceURL = resolveTalkFileURL(talk.fileURL) {
            let signoffURL = issueSignaturePageURL(issueId: issue.id)
            guard buildTalkPDF(
                to: signoffURL,
                reference: talk.id,
                title: talk.title,
                subtitle: "\(talk.id) · \(talk.isGeneral ? "General H&S" : talk.trades.joined(separator: ", "))",
                purpose: talk.purpose,
                keyPoints: talk.keyPoints,
                footer: "Project Planner issued toolbox talk",
                projectName: projectName,
                weekCommencing: issue.weekCommencing,
                presentedBy: presentedBy,
                signoffRows: rows,
                expectedSignoffCount: max(issue.recipientUserIds.count, rows.count)
            ) != nil else {
                return nil
            }
            return appendPDF(source: sourceURL, appendix: signoffURL, output: issuedURL)
        }

        return buildTalkPDF(
            to: issuedURL,
            reference: talk.id,
            title: talk.title,
            subtitle: "\(talk.id) · \(talk.isGeneral ? "General H&S" : talk.trades.joined(separator: ", "))",
            purpose: talk.purpose,
            keyPoints: talk.keyPoints,
            footer: "Generated by Project Planner",
            projectName: projectName,
            weekCommencing: issue.weekCommencing,
            presentedBy: presentedBy,
            signoffRows: rows,
            expectedSignoffCount: max(issue.recipientUserIds.count, rows.count)
        )
    }

    static func makeBlankTemplate() -> URL? {
        let url = libraryRootDirectory().appendingPathComponent("Project-Planner-Toolbox-Talk-Template.pdf")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return buildTalkPDF(
            to: url,
            reference: "TBT-XXX-000",
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
            footer: "Project Planner",
            projectName: "Project",
            weekCommencing: nil,
            presentedBy: "Presenter",
            signoffRows: [],
            expectedSignoffCount: 6
        )
    }

    @discardableResult
    private static func buildTalkPDF(
        to url: URL,
        reference: String,
        title: String,
        subtitle: String,
        purpose: String,
        keyPoints: [String],
        footer: String,
        projectName: String,
        weekCommencing: Date?,
        presentedBy: String,
        signoffRows: [SignoffRow],
        expectedSignoffCount: Int
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

                UIColor(red: 0.13, green: 0.4, blue: 0.93, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: margin, y: y, width: contentWidth, height: 44), cornerRadius: 8).fill()
                ("PROJECT PLANNER TOOLBOX TALK" as NSString).draw(
                    in: CGRect(x: margin + 14, y: y + 12, width: contentWidth - 28, height: 20),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 13, weight: .heavy),
                        .foregroundColor: UIColor.white
                    ]
                )
                y += 58

                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor(red: 0.086, green: 0.125, blue: 0.18, alpha: 1)
                ]
                (title as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 90), withAttributes: titleAttrs)
                y += 40

                let metaAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: UIColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1)
                ]
                let weekString = weekCommencing?.formatted(date: .abbreviated, time: .omitted) ?? "-"
                let meta = "REF \(reference)    PROJECT \(projectName)    W/C \(weekString)    PRESENTED BY \(presentedBy)"
                (meta as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 20), withAttributes: metaAttrs)
                y += 26

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

                y += 12
                ("REFERENCES" as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 18), withAttributes: sectionAttrs)
                y += 20
                let references = "Master RAMS · Working at Height Regulations 2005 · Permit to Work (where applicable)"
                (references as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 30), withAttributes: bodyAttrs)
                y += 36

                ("ATTENDEE SIGN-OFF" as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: 18), withAttributes: sectionAttrs)
                y += 22

                let totalRows = max(expectedSignoffCount, signoffRows.count, 1)
                let rowHeight: CGFloat = 28
                let headerRect = CGRect(x: margin, y: y, width: contentWidth, height: rowHeight)
                UIColor(red: 0.95, green: 0.97, blue: 0.99, alpha: 1).setFill()
                UIBezierPath(rect: headerRect).fill()
                let tableHeader = "NAME                        TRADE               SIGNATURE               DATE & TIME"
                (tableHeader as NSString).draw(in: CGRect(x: margin + 8, y: y + 7, width: contentWidth - 16, height: 20), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: UIColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1)
                ])
                y += rowHeight

                for index in 0..<totalRows {
                    if y > pageRect.height - 80 {
                        context.beginPage()
                        y = margin
                    }
                    let rowRect = CGRect(x: margin, y: y, width: contentWidth, height: rowHeight)
                    UIColor(red: 0.9, green: 0.93, blue: 0.97, alpha: 1).setStroke()
                    UIBezierPath(rect: rowRect).stroke()
                    if index < signoffRows.count {
                        let row = signoffRows[index]
                        (row.name as NSString).draw(in: CGRect(x: margin + 8, y: y + 6, width: 170, height: 18), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
                        (row.trade as NSString).draw(in: CGRect(x: margin + 180, y: y + 6, width: 90, height: 18), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
                        if let signatureImage = row.signatureImage {
                            signatureImage.draw(in: CGRect(x: margin + 282, y: y + 4, width: 90, height: 20))
                        } else {
                            ("Awaiting" as NSString).draw(in: CGRect(x: margin + 282, y: y + 6, width: 90, height: 18), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray])
                        }
                        (row.signedAtText as NSString).draw(in: CGRect(x: margin + 386, y: y + 6, width: 120, height: 18), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
                    }
                    y += rowHeight
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

    private static func issuePDFURL(issueId: String, title: String) -> URL {
        libraryRootDirectory().appendingPathComponent("Issued-\(safeFilename(title))-\(safeFilename(issueId)).pdf")
    }

    private static func issueSignaturePageURL(issueId: String) -> URL {
        libraryRootDirectory().appendingPathComponent("Issued-Signatures-\(safeFilename(issueId)).pdf")
    }

    private static func resolveTalkFileURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return URL(string: trimmed)
    }

    private static func appendPDF(source: URL, appendix: URL, output: URL) -> URL? {
        guard let sourceDoc = PDFDocument(url: source),
              let appendixDoc = PDFDocument(url: appendix) else {
            return nil
        }
        let combined = PDFDocument()
        var insertIndex = 0
        for pageIndex in 0..<sourceDoc.pageCount {
            if let page = sourceDoc.page(at: pageIndex) {
                combined.insert(page, at: insertIndex)
                insertIndex += 1
            }
        }
        for pageIndex in 0..<appendixDoc.pageCount {
            if let page = appendixDoc.page(at: pageIndex) {
                combined.insert(page, at: insertIndex)
                insertIndex += 1
            }
        }
        return combined.write(to: output) ? output : nil
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
