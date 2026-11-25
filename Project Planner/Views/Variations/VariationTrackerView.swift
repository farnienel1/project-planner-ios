//
//  VariationTrackerView.swift
//  Project Planner
//
//  RULEBOOK 1.52.0 / 1.63.0 §22, owner decision 23 Nov (reverses 15 Nov "iOS tracker read-only"): admins and this
//  job's managers (`canRenumberVariations`) drag open variations into a new order, the numbers follow live
//  (`variationRenumberPlan`, the plan the save uses) and the order is saved on drop with the same write as web
//  (`FirebaseBackend.applyVariationOrder`). Submitted and Closed are pinned (`variationIsPinned`); a locked order
//  (`orderLocked`) cannot be changed. Online only. Everyone else sees the tracker read-only.
//

import SwiftUI
import UniformTypeIdentifiers

struct VariationTrackerView: View {
    @ObservedObject var store: VariationStore
    let parentName: String
    /// The job; nil (a preview or snapshot) shows the tracker read-only.
    var project: Project? = nil

    @EnvironmentObject private var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var smartCache: SmartCacheService
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var operativeStore: OperativeStore

    /// The open order on screen while dragging (nil = the stored order).
    @State private var order: [String]?
    @State private var dragId: String?
    /// The variations as loaded when the drag started (web `baseRows`), so a change meanwhile refuses the save.
    @State private var baseRows: [Variation]?
    @State private var busy = false
    @State private var message: TrackerMessage?

    private struct TrackerMessage: Equatable {
        enum Tone { case ok, warn, locked }
        let text: String
        let tone: Tone
        /// A pinned variation the person may reopen from the message (owner 23 Nov: "you can still unlock it").
        var reopenId: String? = nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                trackerNavyHeader

                VStack(alignment: .leading, spacing: 0) {
                    infoCard
                        .padding(.top, 16)

                    if let message {
                        messageBanner(message)
                            .padding(.top, 10)
                    }

                    PPGroupLabel(text: "Variations")

                    PPGroupedCard {
                        ForEach(planRows, id: \.id) { row in
                            if let variation = byId[row.id.lowercased()] {
                                trackerRow(variation, row: row)
                                    .onDrop(of: [UTType.text], delegate: TrackerRowDropDelegate(
                                        targetId: variation.id,
                                        onEnter: { moveDragged(onto: variation.id) },
                                        onDrop: { finishDrag() }
                                    ))
                            }
                        }
                    }
                    .onDrop(of: [UTType.text], delegate: TrackerRowDropDelegate(
                        targetId: nil,
                        onEnter: {},
                        onDrop: { finishDrag() }
                    ))
                }
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            // A drag that ended outside the list leaves its order on screen, not saved: Save or Undo it here.
            if order != nil, !busy {
                pendingOrderBar
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("Tracker")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
    }

    // MARK: - Who and when

    /// `canRenumberVariations(role, { managesJob })` for this job.
    private var canReorder: Bool {
        guard let project else { return false }
        return userStore.canRenumberVariations(on: project)
    }

    /// Who may change a variation's status (the status control's rule, `canSeeVariations` via
    /// `WorkAccess.canAccessVariations`): they get Reopen on a pinned variation.
    private var canEditVariation: Bool {
        guard let project else { return false }
        return WorkAccess.canAccessVariations(project: project, userStore: userStore, operativeStore: operativeStore)
    }

    private var isOnline: Bool {
        OfflinePolicy.isEnabled(.renumberVariations, isOnline: smartCache.isOnline)
    }

    /// Web `canDrag`: the tracker is on, the order is not locked, nothing is saving, and online.
    private var canDrag: Bool {
        canReorder && store.tracker.enabled && !store.tracker.orderLocked && !busy && isOnline
    }

    // MARK: - Order and plan

    private var liveVariations: [Variation] { store.variations.filter { !$0.isDeleted } }

    private var byId: [String: Variation] {
        var out: [String: Variation] = [:]
        for variation in liveVariations { out[variation.id.lowercased()] = variation }
        return out
    }

    private func isPinned(_ variation: Variation) -> Bool {
        CanonicalBusinessEngine.variationIsPinned(status: variation.status.rawValue, voNumberLocked: variation.voNumberLocked)
    }

    /// RULEBOOK 1.63.0 `variationTrackerOrder`: the stored order `variationRenumberPlan` reads, so opening the tracker
    /// plans no number change.
    private var storedOrder: [String] {
        CanonicalBusinessEngine.variationTrackerOrder(rows: liveVariations.map(\.rulebookInput)) ?? store.visibleVariations.map(\.id)
    }

    /// The OPEN variations in their order on screen; pinned ones keep their places (`variationRenumberPlan`).
    private var storedOpenIds: [String] {
        storedOrder.filter { id in byId[id.lowercased()].map { !isPinned($0) } ?? false }
    }

    private var openIds: [String] { order ?? storedOpenIds }

    /// RULEBOOK 1.52.0 §22 `variationRenumberPlan` over every stored variation (deleted ones included, which keep their
    /// numbers reserved) and the open order on screen: the tracker's order and numbers, pinned rows in their places.
    private var planRows: [RulebookVariationPlanRow] {
        let plan = CanonicalBusinessEngine.variationRenumberPlan(
            rows: store.variations.map(\.rulebookInput),
            order: order ?? [],
            prefix: store.tracker.prefix,
            padding: store.tracker.padding,
            orderLocked: store.tracker.orderLocked
        )
        return plan?.rows ?? store.visibleVariations.map {
            RulebookVariationPlanRow(id: $0.id, from: $0.voNumber, to: $0.voNumber, changed: false, pinned: false, sequence: $0.sequence)
        }
    }

    // MARK: - Drag

    private func startDrag(_ id: String) -> NSItemProvider {
        // A drag that ended outside every drop target left its order on screen: start again from the stored order.
        if dragId != nil || order == nil {
            order = nil
            baseRows = store.variations
        }
        dragId = id
        return NSItemProvider(object: id as NSString)
    }

    /// The dragged row is over `targetId`: move it there (web `trackerOrderAfterMove`; a pinned row is never a target).
    private func moveDragged(onto targetId: String) {
        guard let dragId, dragId != targetId else { return }
        var next = openIds
        guard let from = next.firstIndex(of: dragId), let to = next.firstIndex(of: targetId) else { return }
        let item = next.remove(at: from)
        next.insert(item, at: to)
        withAnimation(.easeInOut(duration: 0.15)) { order = next }
    }

    /// Finger lifted: save the order on screen, or nothing when the row never moved.
    private func finishDrag() {
        guard dragId != nil else { return }
        dragId = nil
        guard !busy else { return }
        guard let next = order, next != storedOpenIds else {
            order = nil
            baseRows = nil
            return
        }
        startSave(next)
    }

    /// ↑ / ↓ (and VoiceOver): swap with the next open variation and save, as web does.
    private func moveBy(_ id: String, _ delta: Int) {
        guard !busy else { return }
        var current = openIds
        guard let from = current.firstIndex(of: id) else { return }
        let to = from + delta
        guard to >= 0, to < current.count else { return }
        let item = current.remove(at: from)
        current.insert(item, at: to)
        baseRows = store.variations
        message = nil
        startSave(current)
    }

    /// Owner 23 Nov: the locked message says how to unlock it — reopen (status back to Open) — and offers Reopen to
    /// people who may change the status.
    private func showPinned(_ variation: Variation) {
        let locked = CanonicalBusinessEngine.variationPinnedMoveText(voNumber: variation.voNumber, status: variation.status.rawValue)
        let hint = canEditVariation
            ? "To move it, reopen it: change its status back to Open."
            : "An admin or a manager assigned to this job can reopen it."
        message = TrackerMessage(text: "\(locked) \(hint)", tone: .locked, reopenId: canEditVariation ? variation.id : nil)
    }

    /// Reopen: the status control's write (`Variation.withStatus(.open)`, RULEBOOK 1.63.0 `variationStatusWriteFields`:
    /// the number lock cleared in the same write), so the variation can then be dragged.
    private func reopen(_ variationId: String) async {
        guard !busy, let opened = store.variations.first(where: { $0.id == variationId && !$0.isDeleted }) else { return }
        let orgId = (await firebaseBackend.resolveOrganizationIdForFirebaseWrites(
            preferredFallback: firebaseBackend.currentOrganization?.firestoreDocumentId
        )) ?? ""
        guard !orgId.isEmpty else { return }
        let user = userStore.displayUser
        let uid = user?.id ?? ""
        let name = user?.fullName.isEmpty == false ? (user?.fullName ?? "") : (user?.email ?? "")
        let next = opened.withStatus(.open, byUid: uid, byName: name)
        busy = true
        defer { busy = false }
        do {
            try await firebaseBackend.saveVariation(next, opened: opened, organizationId: orgId)
            store.upsert(next)
            message = TrackerMessage(text: "\(opened.voNumber) is open again. Drag it to its new place.", tone: .ok)
        } catch {
            message = TrackerMessage(text: error.localizedDescription, tone: .warn)
        }
    }

    /// Unlock order (web Lock order switch off): `variationTrackerWriteFields` `unlockOrder`. Admins and the job's
    /// managers (`canReorder`); online only.
    private func unlockOrder() async {
        guard !busy, canReorder, isOnline, let project,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId, !orgId.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await firebaseBackend.unlockVariationTrackerOrder(parentId: project.documentId, organizationId: orgId)
            message = TrackerMessage(text: "Order unlocked. You can drag open variations again.", tone: .ok)
        } catch {
            message = TrackerMessage(text: error.localizedDescription, tone: .warn)
        }
    }

    // MARK: - Save

    /// One save at a time (review of #273): `busy` is set before the save's task starts, so a second drop or a tap on
    /// ↑ / ↓ while it runs is ignored.
    private func startSave(_ nextOrder: [String]) {
        guard !busy else { return }
        busy = true
        Task { await save(nextOrder) }
    }

    private func save(_ nextOrder: [String]) async {
        defer {
            order = nil
            baseRows = nil
            busy = false
        }
        guard let project,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId, !orgId.isEmpty else { return }
        guard isOnline else {
            message = TrackerMessage(text: OnlineOnlyActionError(actionId: UnlistedOfflineAction.renumberVariations.rawValue).localizedDescription, tone: .warn)
            return
        }
        let snapshot = baseRows ?? store.variations
        do {
            let result = try await firebaseBackend.applyVariationOrder(
                parentId: project.documentId,
                parentType: project.isSmallWorksDocument ? .smallWork : .project,
                order: nextOrder,
                baseRows: snapshot,
                organizationId: orgId
            )
            if result.changed.isEmpty {
                message = TrackerMessage(text: "Order saved. No numbers changed.", tone: .ok)
            } else {
                let moves = result.changed.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")
                let copies = result.copiesFailed.isEmpty ? "" : " The copy older iPhone builds read did not all update — save again."
                message = TrackerMessage(text: "Saved: \(moves).\(copies)", tone: result.copiesFailed.isEmpty ? .ok : .warn)
                let actorName = (userStore.currentUser?.fullName).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone"
                // Web: the job name stored on the variations (`baseRows[0].parentName`), else "this job".
                let storedParentName = snapshot.first(where: { !$0.parentName.isEmpty })?.parentName ?? ""
                Task {
                    await notificationService.notifyVariationRenumbered(
                        parentDocumentId: project.documentId,
                        parentName: storedParentName,
                        isSmallWorks: project.isSmallWorksDocument,
                        actorName: actorName,
                        jobManagerIds: project.managerIds
                    )
                }
            }
        } catch {
            logAndReportError("⚠️ [Variations] tracker save failed: \(error.localizedDescription)")
            message = Self.failureMessage(error)
        }
    }

    /// Web's wording: the stale and pinned messages alone, anything else "Nothing was renumbered: …".
    private static func failureMessage(_ error: Error) -> TrackerMessage {
        let text = (error as? VariationOrderSaveError)?.message ?? error.localizedDescription
        if text == CanonicalBusinessEngine.variationPinnedMessage {
            return TrackerMessage(text: text, tone: .locked)
        }
        if text == CanonicalBusinessEngine.variationRenumberStaleMessage {
            return TrackerMessage(text: text, tone: .warn)
        }
        return TrackerMessage(text: text.isEmpty ? "Nothing was renumbered." : "Nothing was renumbered: \(text)", tone: .warn)
    }

    // MARK: - Views

    private var infoText: String {
        guard project != nil else { return "Read-only tracker. The order and numbering can be managed on the web app." }
        guard canReorder else { return "Admins and this job's managers change the order of the variations." }
        if !isOnline { return OfflinePolicy.onlineOnlyMessage.isEmpty ? "Connect to the internet to change this" : OfflinePolicy.onlineOnlyMessage }
        return "Drag an open variation to change the order. The numbers follow; Submitted and Closed keep theirs."
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            PPIconTile(symbol: canDrag ? "arrow.up.arrow.down" : "lock.fill", family: .trade)
            VStack(alignment: .leading, spacing: 4) {
                Text(infoText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("variationTracker.info")
                // RULEBOOK 1.52.0 §22: the tracker's order lock (`orderLocked`), set on web.
                if store.tracker.orderLocked {
                    Text(lockedText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("variationTracker.locked")
                    if canReorder {
                        Button("Unlock order") { Task { await unlockOrder() } }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .foregroundStyle(PPColor.brand)
                            .disabled(busy || !isOnline)
                            .accessibilityIdentifier("variationTracker.unlockOrder")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func messageBanner(_ message: TrackerMessage) -> some View {
        let color: Color = message.tone == .ok ? .green : (message.tone == .locked ? .secondary : .orange)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.tone == .ok ? "checkmark.circle.fill" : (message.tone == .locked ? "lock.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(color)
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let reopenId = message.reopenId {
                Button("Reopen") { Task { await reopen(reopenId) } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(PPColor.brand)
                    .disabled(busy)
                    .accessibilityIdentifier("variationTracker.reopen")
            }
            Button {
                self.message = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("variationTracker.message")
    }

    /// Shown only when a drag ended outside the list and its order was not saved.
    private var pendingOrderBar: some View {
        HStack(spacing: 10) {
            Text("This order is not saved yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Undo") {
                order = nil
                baseRows = nil
                dragId = nil
            }
            .font(.footnote.weight(.semibold))
            Button("Save order") {
                dragId = nil
                if let next = order { startSave(next) }
            }
            .font(.footnote.weight(.semibold))
            .disabled(!canDrag)
        }
        .padding(12)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .accessibilityIdentifier("variationTracker.pendingOrder")
    }

    /// Navy header: the parent this tracker belongs to and how many variations it lists.
    private var trackerNavyHeader: some View {
        // RULEBOOK 1.52.0 §22 `variationListTotals`.
        let totals = CanonicalBusinessEngine.variationListTotals(store.variations.map(\.rulebookInput)) ?? .zero
        let count = totals.count
        return VStack(alignment: .leading, spacing: 8) {
            PPOverviewTitle(
                eyebrow: parentName,
                count: "\(count)",
                countLabel: count == 1 ? "variation" : "variations"
            )
            Text("\(String(format: "%g", totals.labourHours)) hrs · \(totals.materialsCount) materials · \(totals.evidenceCount) evidence")
                .font(.footnote)
                .foregroundStyle(PPColor.onNavySecondary)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    /// "Locked by Sam · 15 Nov 2026" and `VARIATION_ORDER_LOCKED_MESSAGE`.
    private var lockedText: String {
        var parts = ["Locked"]
        if let name = store.tracker.orderLockedByName, !name.isEmpty { parts.append("by \(name)") }
        var line = parts.joined(separator: " ")
        let date = CanonicalBusinessEngine.variationDateText(store.tracker.orderLockedAt, timeZone: OrganizationRulebookContext.timeZoneIdentifier)
        if !date.isEmpty { line += " · \(date)" }
        let message = CanonicalBusinessEngine.variationOrderLockedMessage
        return message.isEmpty ? line : "\(line). \(message)"
    }

    @ViewBuilder
    private func trackerRow(_ variation: Variation, row: RulebookVariationPlanRow) -> some View {
        let pinned = isPinned(variation)
        let movable = canDrag && !pinned
        let content = rowContent(variation, row: row, pinned: pinned, movable: movable)
        if movable {
            content
                .contentShape(Rectangle())
                .onDrag { startDrag(variation.id) }
                // Dimmed only while a drag has moved something (a long press that never moved, or a drop outside, leaves
                // `dragId` set with no order on screen).
                .opacity(order != nil && dragId == variation.id ? 0.5 : 1)
                .accessibilityAction(named: "Move up") { moveBy(variation.id, -1) }
                .accessibilityAction(named: "Move down") { moveBy(variation.id, 1) }
        } else if pinned && canReorder {
            content
                .contentShape(Rectangle())
                .onTapGesture { showPinned(variation) }
                .accessibilityHint("Submitted and closed variations keep their numbers.")
        } else {
            content
        }
    }

    private func rowContent(_ variation: Variation, row: RulebookVariationPlanRow, pinned: Bool, movable: Bool) -> some View {
        let openIndex = openIds.firstIndex(of: variation.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if movable {
                    Image(systemName: "line.3.horizontal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Circle()
                    .fill(dot(variation.status))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.to.isEmpty ? variation.voNumber : row.to)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .accessibilityIdentifier("variationTracker.number.\(variation.id)")
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Keeps its number")
                        }
                    }
                    // Owner 23 Nov: no "was VO-003" on the iPhone tracker — it just renumbers (display only; the number
                    // history is stored and exported as before).
                }
                .frame(width: 96, alignment: .leading)
                Text(variation.heading.isEmpty ? "Untitled" : variation.heading)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(variation.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dot(variation.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(dot(variation.status).opacity(0.14), in: Capsule())
                if movable, let openIndex {
                    VStack(spacing: 2) {
                        Button { moveBy(variation.id, -1) } label: {
                            Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                        }
                        .disabled(openIndex == 0)
                        .accessibilityLabel("Move \(variation.voNumber) up")
                        Button { moveBy(variation.id, 1) } label: {
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .disabled(openIndex >= openIds.count - 1)
                        .accessibilityLabel("Move \(variation.voNumber) down")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PPColor.brand)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            Divider()
                .padding(.leading, 14)
        }
    }

    private func dot(_ status: VariationStatus) -> Color {
        switch status {
        case .open: return .orange
        case .submitted: return .green
        case .closed: return .red
        }
    }
}

/// Drop target for one tracker row (or the whole list): entering moves the dragged row there, dropping saves.
private struct TrackerRowDropDelegate: DropDelegate {
    let targetId: String?
    let onEnter: () -> Void
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) { onEnter() }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        onDrop()
        return true
    }
}
