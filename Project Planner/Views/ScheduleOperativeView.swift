//
//  ScheduleOperativeView.swift
//  Project Planner
//
//  Created by Assistant on 22/10/2025.
//

import SwiftUI
import MapKit
import FirebaseAuth

struct ScheduleOperativeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    
    let project: Project
    /// When opening from a project week booking row, pre-selects operative/date/hours and replaces that booking after confirm.
    var editingBooking: Booking? = nil
    /// When set, pre-selects all operatives/dates in this group for batch edit.
    var editingGroupId: String? = nil

    @State private var selectedOperatives: Set<UUID> = []
    @State private var showingSelectOperatives = false
    @State private var selectedDates: Set<Date> = []
    @State private var dateSlotChoices: [String: OperativeDayBookingChoice] = [:]
    /// Default hours applied to every selected date (bulk). Kept in sync when dates are added.
    @State private var sharedBulkChoice: OperativeDayBookingChoice = .legacy(.fullDay)
    /// Per-operative, per-day overrides on top of `dateSlotChoices` (key: `operativeUUID|yyyy-m-d`).
    @State private var operativeSlotOverrides: [String: OperativeDayBookingChoice] = [:]
    /// Hours template per operative when no dates selected yet (applied when dates are first chosen).
    @State private var operativeDefaultChoice: [UUID: OperativeDayBookingChoice] = [:]
    @State private var operativeCustomHoursPick: OperativeCustomHoursPick?
    @State private var currentMonth: Date = Date()
    @State private var quickSelectDays: Int? = nil
    @State private var showingBookingConfirmation = false
    /// 1.33.1: what Confirm left when it was not a clean save (a refusal, "saved locally", nothing new to save).
    @State private var saveOutcomeAlert: ScheduleBookingSaveAlert?
    @State private var isBooking = false
    /// Operatives with a time overlap awaiting ✓ (add to list) or ✕ (remove).
    @State private var clashReviewOperativeIds: Set<UUID> = []
    @State private var operativeClashSummaries: [UUID: [BookingClash]] = [:]
    /// User approved overlap for these operatives (✓ on warning panel).
    @State private var approvedOverlapOperativeIds: Set<UUID> = []
    /// People ✕-dropped in the double-booking review (1.33.1 owner report: ✕ on the only person left Confirm grey).
    @State private var droppedClashOperativeIds: Set<UUID> = []
    @State private var didApplyOrgDefaultHours = false
    @State private var didApplyEditingBookingPrefill = false
    @State private var didApplyEditingGroupPrefill = false
    /// `operativeOverrideKey` → booking id to delete before creating the replacement on confirm.
    @State private var replaceBookingOnConfirmByOverrideKey: [String: UUID] = [:]
    @State private var acknowledgedConflictIds: Set<String> = []
    @State private var struckConflictIds: Set<String> = []
    /// RULEBOOK 1.41.0 §5: conflict rows where Replace was chosen (also in `acknowledgedConflictIds`).
    @State private var replacedConflictIds: Set<String> = []
    @State private var expandedMainConflictPersonIds: Set<UUID> = []
    @State private var expandedPickerPersonIds: Set<UUID> = []
    @State private var showingSelectDatesFirstAlert = false
    @State private var showingHoursClashAlert = false
    @State private var showingDateSelectionAlert = false
    @State private var dateSelectionAlertMessage = ""
    @State private var didShowHoursClashAlertThisSession = false
    /// RULEBOOK 1.18.0 `customHoursPrefillForDays`: the selection kind the shared hours were last reset for.
    @State private var customHoursKind = CustomHoursKindTracker()
    /// Steps folded into a summary card while the booking is in progress (1 Dates, 2 Hours). Display only.
    @State private var collapsedBookingSteps: Set<Int> = []
    @EnvironmentObject var notificationService: NotificationService
    
    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private func payrollPolicy(for day: Date) -> OrgPayrollTimePolicy {
        firebaseBackend.payrollPolicy(for: day)
    }

    private var primarySelectedDatePolicy: OrgPayrollTimePolicy {
        if let first = selectedDates.sorted().first {
            return payrollPolicy(for: first)
        }
        return payrollTimePolicy
    }

    private var canBookStandardDayWindow: Bool {
        guard let refDay = selectedDates.sorted().first else { return false }
        let p = payrollPolicy(for: refDay)
        if PayrollTimePolicyCatalog.isWeekend(refDay) {
            let weekend = PayrollTimePolicyCatalog.weekendSettings(for: refDay, policy: p)
            if weekend.allHoursAtMultiplierMode { return true }
            guard let s = weekend.customStandardStart,
                  let e = weekend.customStandardEnd,
                  let sm = ManagerScheduleInterval.parseMinutes(s),
                  let em = ManagerScheduleInterval.parseMinutes(e) else { return false }
            return em > sm
        }
        guard let s = ManagerScheduleInterval.parseMinutes(p.standardDayStart),
              let e = ManagerScheduleInterval.parseMinutes(p.standardDayEnd) else { return false }
        return e > s
    }

    private func defaultChoiceForDay(_ day: Date, policy: OrgPayrollTimePolicy) -> OperativeDayBookingChoice {
        if PayrollTimePolicyCatalog.isWeekend(day) {
            return .weekendCustomHours(on: day, policy: policy)
        }
        return .legacy(.fullDay)
    }

    private func applyBulkTimeSlot(_ slot: TimeSlot) {
        // One pair of times for every selected day opens on the first selected Saturday's (RULEBOOK 1.17.0).
        let refDay = CanonicalBusinessEngine.singlePairPrefillDay(Array(selectedDates)) ?? Date()
        let p = payrollPolicy(for: refDay)
        let next: OperativeDayBookingChoice
        switch slot {
        case .morning, .afternoon:
            next = .legacy(slot)
        case .fullDay:
            if PayrollTimePolicyCatalog.isWeekend(refDay) {
                next = defaultChoiceForDay(refDay, policy: p)
            } else {
                next = .legacy(.fullDay)
            }
        default:
            return
        }
        sharedBulkChoice = next
        syncSharedBulkToAllSelectedDates()
        operativeSlotOverrides.removeAll()
    }

    private func currentBulkChoice() -> OperativeDayBookingChoice {
        if let refDay = selectedDates.sorted().first {
            return baseChoice(for: refDay)
        }
        return sharedBulkChoice
    }

    private func isBulkSelectedSlot(_ slot: TimeSlot) -> Bool {
        let choice = currentBulkChoice()
        switch slot {
        case .morning, .afternoon:
            return choice.timeSlot == slot
        case .fullDay:
            if choice.timeSlot == .morning || choice.timeSlot == .afternoon { return false }
            if choice.timeSlot == .fullDay { return true }
            return isBulkStandardDay
        case .customHours:
            if choice.timeSlot == .morning || choice.timeSlot == .afternoon || choice.timeSlot == .fullDay {
                return false
            }
            return !isBulkStandardDay
        default:
            return choice.timeSlot == slot
        }
    }

    private func displayClockWindow(for choice: OperativeDayBookingChoice, day: Date, policy: OrgPayrollTimePolicy) -> (start: String, end: String) {
        if choice.timeSlot == .morning || choice.timeSlot == .afternoon {
            let probe = choice.bookingProbe(operativeId: UUID(), projectId: project.id, date: day, bookedBy: "")
            if let iv = OperativeBookingInterval.clashInterval(for: probe, policy: policy) {
                return (ManagerScheduleInterval.formatMinutes(iv.0), ManagerScheduleInterval.formatMinutes(iv.1))
            }
        }
        if let s = choice.workStartTime, let e = choice.workEndTime, !s.isEmpty, !e.isEmpty {
            return (s, e)
        }
        let probe = choice.bookingProbe(operativeId: UUID(), projectId: project.id, date: day, bookedBy: "")
        if let iv = OperativeBookingInterval.clashInterval(for: probe, policy: policy) {
            return (ManagerScheduleInterval.formatMinutes(iv.0), ManagerScheduleInterval.formatMinutes(iv.1))
        }
        return (policy.standardDayStart, policy.standardDayEnd)
    }

    private func isStandardChoiceForDay(_ choice: OperativeDayBookingChoice, day: Date, policy: OrgPayrollTimePolicy) -> Bool {
        choice == defaultChoiceForDay(day, policy: policy)
    }

    // Get logged-in user name
    private var loggedInUserName: String {
        if let user = userStore.currentUser {
            if !user.firstName.isEmpty || !user.surname.isEmpty {
                return "\(user.firstName) \(user.surname)".trimmingCharacters(in: .whitespaces)
            }
            return user.email
        }
        // Fallback to Firebase user email if available
        if let firebaseUser = firebaseBackend.currentUser {
            return firebaseUser.email ?? "Unknown User"
        }
        return "Unknown User"
    }
    
    var body: some View {
        baseNavigationView
            .sheet(item: $operativeCustomHoursPick) { pick in
                operativeCustomHoursSheet(for: pick)
            }
            .sheet(isPresented: $showingBookingConfirmation, onDismiss: {
                dismiss()
            }) {
                BookingConfirmationView(isPresented: $showingBookingConfirmation)
                    .presentationDetents([.fraction(0.35)])
                    .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: $showingSelectOperatives) {
                selectOperativesSheet
            }
            .alert("Select dates first", isPresented: $showingSelectDatesFirstAlert) {
                Button("OK", role: .cancel) { }
                    .accessibilityIdentifier("scheduleOperative.ok")
            } message: {
                Text("Select a day or days below first, then you will be able to add users to the booking.")
            }
            .alert("Hours caused clashes", isPresented: $showingHoursClashAlert) {
                Button("OK", role: .cancel) { }
                    .accessibilityIdentifier("scheduleOperative.ok2")
            } message: {
                Text("New hours have been selected, which has caused clashes with other bookings. Make your final change and then acknowledge each clash above before being able to Confirm booking.")
            }
            .alert(item: $saveOutcomeAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK")) {
                        if alert.outcome.closesScreen { dismiss() }
                    }
                )
            }
            .alert("Date selection", isPresented: $showingDateSelectionAlert) {
                Button("OK", role: .cancel) { }
                    .accessibilityIdentifier("scheduleOperative.ok3")
            } message: {
                Text(dateSelectionAlertMessage)
            }
            .onChange(of: selectedDates) { oldSet, newSet in
                if oldSet != newSet {
                    acknowledgedConflictIds.removeAll()
                    struckConflictIds.removeAll()
                    replacedConflictIds.removeAll()
                }
                if newSet.count == 1, let only = newSet.sorted().first {
                    sharedBulkChoice = baseChoice(for: only)
                }
                reconcileMainConflictExpansion()
            }
            .onChange(of: selectedOperatives) { _, _ in
                reconcileMainConflictExpansion()
            }
            .onChange(of: operativeSlotOverrides.count) { _, _ in
                handleHoursOrDatesChanged()
            }
            .onChange(of: sharedBulkChoice) { _, _ in
                handleHoursOrDatesChanged()
            }
            .onAppear {
                scheduleBookingOnAppear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .organizationDidLoad)) { _ in
                refreshDefaultHoursFromOrgPolicy()
            }
    }

    private func refreshDefaultHoursFromOrgPolicy() {
        guard !didApplyEditingBookingPrefill, !didApplyEditingGroupPrefill else { return }
        // One pair of times for every selected day opens on the first selected Saturday's (RULEBOOK 1.17.0), under the
        // rules in effect on that day.
        let refDay = CanonicalBusinessEngine.singlePairPrefillDay(Array(selectedDates)) ?? Date()
        let p = payrollPolicy(for: refDay)
        sharedBulkChoice = defaultChoiceForDay(refDay, policy: p)
        customHoursKind = CustomHoursKindTracker(
            seed: CanonicalBusinessEngine.customHoursPrefill(on: selectedDates.isEmpty ? [refDay] : selectedDates.sorted(), fallbackPolicy: p)
        )
        didApplyOrgDefaultHours = true
        if !selectedDates.isEmpty {
            syncSharedBulkToAllSelectedDates()
        }
    }

    private var baseNavigationView: some View {
        NavigationView {
            ZStack(alignment: .top) {
                PPColor.page
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        scheduleBookingHeader
                        VStack(alignment: .leading, spacing: 4) {
                            scheduleBookingDatesSection
                            scheduleBookingHoursSection
                            scheduleBookingOperativesSection
                        }
                        .padding(.bottom, 24)
                        .ppContentSheet()
                    }
                }

                if mainScreenHasUnactionedConflicts {
                    scheduleMainClashNotice
                }
            }
            .navigationTitle("Schedule booking")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .fontWeight(.semibold)
                        .fixedSize()
                    }
                        .accessibilityIdentifier("scheduleOperative.back")
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
        }
    }

    private var selectOperativesSheet: some View {
        SelectOperativesView(
            selectedOperatives: $selectedOperatives,
            people: bookablePeople,
            selectedDates: selectedDates,
            bulkChoice: sharedBulkChoice,
            projectId: project.id,
            excludingBookingIds: excludingBookingIds,
            acknowledgedConflictIds: $acknowledgedConflictIds,
            struckConflictIds: $struckConflictIds,
            expandedPersonIds: $expandedPickerPersonIds,
            replacedConflictIds: $replacedConflictIds
        )
        .environmentObject(operativeStore)
        .environmentObject(userStore)
        .environmentObject(bookingStore)
        .environmentObject(projectStore)
        .environmentObject(managerScheduleStore)
        .environmentObject(holidayStore)
        .environmentObject(firebaseBackend)
    }

    private func operativeCustomHoursSheet(for pick: OperativeCustomHoursPick) -> some View {
        let refDay = selectedDates.sorted().first ?? Date()
        let dayPolicy = payrollPolicy(for: refDay)
        return OperativeCustomHoursSheet(
            policy: dayPolicy,
            referenceDay: refDay,
            noteDays: selectedDates.sorted(),
            title: pick.operativeId == nil ? "Hours" : "Edit booking",
            subtitle: pick.operativeId == nil ? "Applies to all selected operatives and dates" : pick.operativeDisplaySubtitle,
            // RULEBOOK 1.32.0 §25 (decision A): the custom-hours create screen shows the rate pre-filled with the
            // organisation's for the day — one rate for every selected operative and date ("Hours"), or one person's.
            allowsOtMultiplierOverride: true,
            createsBooking: true,
            initialChoice: pick.initialChoice,
            onSave: { start, end, breakRemoved, otMultiplierOverride in
                operativeCustomHoursPick = nil
                let newChoice = OperativeDayBookingChoice(
                    timeSlot: .customHours,
                    workStartTime: start,
                    workEndTime: end,
                    isBreakRemoved: breakRemoved,
                    otMultiplierOverride: otMultiplierOverride
                )
                if let opId = pick.operativeId {
                    applyOperativeOverride(operativeId: opId, choice: newChoice)
                    if newChoice.timeSlot == sharedBulkChoice.timeSlot,
                       newChoice.workStartTime == sharedBulkChoice.workStartTime,
                       newChoice.workEndTime == sharedBulkChoice.workEndTime,
                       newChoice.isBreakRemoved == sharedBulkChoice.isBreakRemoved,
                       newChoice.otMultiplierOverride == sharedBulkChoice.otMultiplierOverride {
                        operativeDefaultChoice.removeValue(forKey: opId)
                    } else {
                        operativeDefaultChoice[opId] = newChoice
                    }
                } else {
                    sharedBulkChoice = OperativeDayBookingChoice(
                        timeSlot: .customHours,
                        workStartTime: start,
                        workEndTime: end,
                        isBreakRemoved: breakRemoved,
                        otMultiplierOverride: otMultiplierOverride
                    )
                    syncSharedBulkToAllSelectedDates()
                    operativeSlotOverrides.removeAll()
                }
            },
            onCancel: { operativeCustomHoursPick = nil }
        )
    }

    private func scheduleBookingOnAppear() {
        Task {
            await holidayStore.loadData()
            managerScheduleStore.loadData()
        }
        if !didApplyOrgDefaultHours {
            refreshDefaultHoursFromOrgPolicy()
        }
        if let b = editingBooking, !didApplyEditingBookingPrefill {
            didApplyEditingBookingPrefill = true
            applyPrefillFromEditingBooking(b)
        }
        if let gid = editingGroupId, !didApplyEditingGroupPrefill {
            didApplyEditingGroupPrefill = true
            applyPrefillFromEditingGroup(gid)
        }
    }
    
    // MARK: - Project Header Card
    private var bookablePeople: [ScheduleBookablePerson] {
        ScheduleBookablePersonBuilder.build(
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers,
            projectId: project.id,
            bookings: bookingStore.bookings
        )
    }

    private var excludingBookingIds: Set<UUID> {
        Set(replaceBookingOnConfirmByOverrideKey.values)
    }

    private var canOpenPeoplePicker: Bool {
        !selectedDates.isEmpty
    }

    private var mainScreenHasUnactionedConflicts: Bool {
        !selectedOperatives.isEmpty && selectedOperatives.contains { opId in
            guard let person = bookablePeople.first(where: { $0.operativeId == opId }) else { return false }
            let summary = personConflictSummary(person)
            return summary?.hasUnactionedRows == true
        }
    }

    private var canConfirmBooking: Bool {
        guard !selectedOperatives.isEmpty, !selectedDates.isEmpty, !isBooking else { return false }
        guard ScheduleDateSelectionPolicy.saturdaySundaySelectionAllowed(
            selected: selectedDates,
            policy: primarySelectedDatePolicy
        ) else { return false }
        return ScheduleBookingConflictEngine.allActionableRowsResolved(
            people: bookablePeople,
            selectedOperativeIds: selectedOperatives,
            selectedDates: selectedDates,
            choice: sharedBulkChoice,
            projectId: project.id,
            projectStore: projectStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            policy: primarySelectedDatePolicy,
            excludingBookingIds: excludingBookingIds,
            manuallyExcludedDaysByOperative: autoExcludedDaysByOperative,
            acknowledgedRowIds: acknowledgedConflictIds,
            struckRowIds: struckConflictIds
        )
    }

    /// RULEBOOK 1.16.0 §5, §9: no day is dropped without asking. Approved leave is a purple row (`bookingLeaveConflicts`)
    /// the booker ticks or drops like every other conflict, so nothing is excluded up front.
    private var autoExcludedDaysByOperative: [UUID: Set<Date>] {
        [:]
    }

    private func personConflictSummary(_ person: ScheduleBookablePerson) -> SchedulePersonConflictSummary? {
        ScheduleBookingConflictEngine.summarizePerson(
            person: person,
            selectedDates: selectedDates,
            isSelected: selectedOperatives.contains(person.operativeId),
            choice: sharedBulkChoice,
            projectId: project.id,
            projectStore: projectStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            policy: primarySelectedDatePolicy,
            excludingBookingIds: excludingBookingIds,
            manuallyExcludedDays: autoExcludedDaysByOperative[person.operativeId] ?? [],
            acknowledgedRowIds: acknowledgedConflictIds,
            struckRowIds: struckConflictIds
        )
    }

    private func effectiveDates(for operativeId: UUID) -> [Date] {
        guard let person = bookablePeople.first(where: { $0.operativeId == operativeId }) else {
            return selectedDates.sorted()
        }
        return personConflictSummary(person)?.effectiveSelectedDates ?? []
    }

    private func handleHoursOrDatesChanged() {
        acknowledgedConflictIds.removeAll()
        struckConflictIds.removeAll()
        replacedConflictIds.removeAll()
        droppedClashOperativeIds.removeAll()
        if mainScreenHasUnactionedConflicts && !didShowHoursClashAlertThisSession {
            didShowHoursClashAlertThisSession = true
            showingHoursClashAlert = true
        }
        reconcileMainConflictExpansion()
    }

    private func reconcileMainConflictExpansion() {
        for opId in selectedOperatives {
            guard let person = bookablePeople.first(where: { $0.operativeId == opId }),
                  let summary = personConflictSummary(person),
                  summary.triangle != .none else { continue }
            expandedMainConflictPersonIds.insert(opId)
        }
    }

    private func openPeoplePicker() {
        guard canOpenPeoplePicker else {
            showingSelectDatesFirstAlert = true
            return
        }
        showingSelectOperatives = true
    }

    private var selectableOperatives: [Operative] {
        let current = ScheduleBookablePersonBuilder.operativesForScheduling(
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers
        )
        let active = current.filter(\.isActive)
        return active.isEmpty ? current : active
    }
    
    private func applyPrefillFromEditingBooking(_ booking: Booking) {
        guard booking.projectId == project.id else { return }
        let cal = OrganizationRulebookContext.calendar
        let day = cal.startOfDay(for: booking.date)
        selectedOperatives = [booking.operativeId]
        selectedDates = [day]
        let choice = OperativeDayBookingChoice(from: booking)
        let k = operativeOverrideKey(booking.operativeId, day)
        operativeSlotOverrides[k] = choice
        operativeDefaultChoice[booking.operativeId] = choice
        replaceBookingOnConfirmByOverrideKey[k] = booking.id
        // The booking keeps its stored hours; only a later change of selection kind resets the shared hours (1.18.0).
        customHoursKind = CustomHoursKindTracker(
            seed: CanonicalBusinessEngine.customHoursPrefill(on: [day], fallbackPolicy: payrollPolicy(for: day))
        )
    }

    private func applyPrefillFromEditingGroup(_ groupId: String) {
        let cal = OrganizationRulebookContext.calendar
        let inGroup = bookingStore.bookings.filter {
            $0.projectId == project.id &&
                $0.bookingGroupId == groupId &&
                ($0.status == .confirmed || $0.status == .tentative)
        }
        guard !inGroup.isEmpty else { return }
        selectedOperatives = Set(inGroup.map(\.operativeId))
        selectedDates = Set(inGroup.map { cal.startOfDay(for: $0.date) })
        for b in inGroup {
            let day = cal.startOfDay(for: b.date)
            let choice = OperativeDayBookingChoice(from: b)
            let k = operativeOverrideKey(b.operativeId, day)
            operativeSlotOverrides[k] = choice
            operativeDefaultChoice[b.operativeId] = choice
            replaceBookingOnConfirmByOverrideKey[k] = b.id
        }
        customHoursKind = CustomHoursKindTracker(
            seed: CanonicalBusinessEngine.customHoursPrefill(on: selectedDates.sorted(), fallbackPolicy: primarySelectedDatePolicy)
        )
    }

    // MARK: - Schedule booking (project_planner_scheduling_with_overtime.html)

    private func operativeOverrideKey(_ operativeId: UUID, _ date: Date) -> String {
        "\(operativeId.uuidString)|\(slotKey(for: date))"
    }

    private func baseChoice(for date: Date) -> OperativeDayBookingChoice {
        dateSlotChoices[slotKey(for: date)] ?? sharedBulkChoice
    }

    private func resolvedChoice(operativeId: UUID, date: Date) -> OperativeDayBookingChoice {
        let k = operativeOverrideKey(operativeId, date)
        if let o = operativeSlotOverrides[k] { return o }
        return baseChoice(for: date)
    }

    private func applyOperativeOverride(operativeId: UUID, choice: OperativeDayBookingChoice) {
        for d in selectedDates.sorted() {
            let k = operativeOverrideKey(operativeId, d)
            let base = baseChoice(for: d)
            if choice == base {
                operativeSlotOverrides.removeValue(forKey: k)
            } else {
                operativeSlotOverrides[k] = choice
            }
        }
    }

    private func syncSharedBulkToAllSelectedDates() {
        for d in selectedDates {
            dateSlotChoices[slotKey(for: d)] = sharedBulkChoice
        }
    }

    /// RULEBOOK 1.18.0 §4.3 `customHoursPrefillForDays` (web `useCustomHoursPrefillOnKindChange`): when the selection
    /// turns weekend-only or weekday-only, every selected day's hours reset to that kind's default straight away —
    /// weekend → the returned custom start/finish, weekday → the standard day (FULL DAY, the `halfDayWindows` day the
    /// call returns). Within the same kind nothing is reset, so a manual edit survives adding another day.
    private func applyCustomHoursPrefillOnKindChange() {
        let dates = selectedDates.sorted()
        let prefill = CanonicalBusinessEngine.customHoursPrefill(on: dates, fallbackPolicy: primarySelectedDatePolicy)
        guard let apply = customHoursKind.prefillToApply(prefill) else { return }
        switch apply.kind {
        case .weekday:
            let first = dates.first ?? Date()
            sharedBulkChoice = defaultChoiceForDay(first, policy: payrollPolicy(for: first))
        case .weekend:
            sharedBulkChoice = OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: apply.start,
                workEndTime: apply.end,
                isBreakRemoved: false,
                otMultiplierOverride: nil
            )
        case .mixed:
            return
        }
        syncSharedBulkToAllSelectedDates()
    }

    private func clearOverrides(for operativeId: UUID) {
        let prefix = "\(operativeId.uuidString)|"
        operativeSlotOverrides = operativeSlotOverrides.filter { !$0.key.hasPrefix(prefix) }
        operativeDefaultChoice.removeValue(forKey: operativeId)
    }

    private var isBulkStandardDay: Bool {
        let choice = currentBulkChoice()
        if choice.timeSlot == .fullDay { return true }
        guard let refDay = selectedDates.sorted().first else { return false }
        let p = payrollPolicy(for: refDay)
        return isStandardChoiceForDay(choice, day: refDay, policy: p)
    }

    private var hasAnyOperativeOverrides: Bool {
        !operativeSlotOverrides.isEmpty
    }

    private func operativeHoursSubtitle(for opId: UUID) -> String {
        if selectedDates.isEmpty {
            let c = operativeDefaultChoice[opId] ?? sharedBulkChoice
            return operativeLineForChoice(c)
        }
        let dates = selectedDates.sorted()
        let choices = dates.map { resolvedChoice(operativeId: opId, date: $0) }
        if let first = choices.first, choices.allSatisfy({ $0 == first }) {
            return operativeLineForChoice(first)
        }
        return "Varies by day · tap to edit"
    }

    private func operativeLineForChoice(_ c: OperativeDayBookingChoice, day: Date? = nil) -> String {
        let refDay = day ?? selectedDates.sorted().first ?? Date()
        let p = payrollPolicy(for: refDay)
        if c.timeSlot == .morning { return "AM" }
        if c.timeSlot == .afternoon { return "PM" }
        if c.timeSlot == .fullDay {
            return "FULL DAY · \(p.standardDayStart)–\(p.standardDayEnd)"
        }
        // RULEBOOK 1.18/1.19: Saturday and Sunday are custom hours priced per day (`weekendBookingBreakdown`), never a
        // "Standard" day — the subtitle shows the hours entered.
        let isWeekendDay = PayrollTimePolicyCatalog.isWeekend(refDay, calendar: OrganizationRulebookContext.calendar)
        if !isWeekendDay, isStandardChoiceForDay(c, day: refDay, policy: p) {
            return "Standard · \(p.standardDayStart)–\(p.standardDayEnd)"
        }
        if c.timeSlot == .customHours, let s = c.workStartTime, let e = c.workEndTime {
            var line = "\(s)–\(e)"
            // "No unpaid break" means something only on a day that takes an unpaid break off (`unpaidBreakAppliesOnDay`).
            if c.isBreakRemoved,
               CanonicalBusinessEngine.unpaidBreakAppliesOnDay(policy: p, dayKey: CanonicalBusinessEngine.bookingDayKey(refDay)) {
                line += " · no break"
            }
            if let m = c.otMultiplierOverride {
                // The rate as stored, to the hundredth (×1.25 stays "1.25", never "1.2").
                line += " · OT \(ScheduleCoverageFormat.hours(m))×"
            }
            return line
        }
        return c.scheduleLabel(policy: p)
    }

    private var totalPlannedHours: Double {
        guard !selectedOperatives.isEmpty, !selectedDates.isEmpty else { return 0 }
        let ops = selectableOperatives.filter { selectedOperatives.contains($0.id) }
        var sum = 0.0
        for op in ops {
            for d in effectiveDates(for: op.id) {
                let choice = resolvedChoice(operativeId: op.id, date: d)
                let dayPolicy = payrollPolicy(for: d)
                let probe = choice.bookingProbe(operativeId: op.id, projectId: project.id, date: d, bookedBy: loggedInUserName)
                sum += probe.paidBookedHours(policy: dayPolicy)
            }
        }
        return sum
    }

    private var totalEffectiveBookingDays: Int {
        selectedOperatives.reduce(0) { partial, opId in
            partial + effectiveDates(for: opId).count
        }
    }

    // MARK: - Layout (docs/design/booking-ui 3.3 in progress / 3.4 ready)

    /// Ready = there are dates and people, so the header shows the booking at a glance instead of the step tracker.
    private var isReadyToReview: Bool {
        !selectedDates.isEmpty && !selectedOperatives.isEmpty
    }

    /// Steps the booker folded into a summary card (1 Dates, 2 Hours). Only used while the booking is in progress.
    private func isStepCollapsed(_ step: Int) -> Bool {
        !isReadyToReview && !selectedDates.isEmpty && collapsedBookingSteps.contains(step)
    }

    private func setStep(_ step: Int, collapsed: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsed {
                collapsedBookingSteps.insert(step)
            } else {
                collapsedBookingSteps.remove(step)
            }
        }
    }

    private var bookingJobTypeLabel: String {
        project.isSmallWorksDocument ? "Small works" : (project.customJobType ?? "Project")
    }

    private var scheduleBookingHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            PPJobHeaderBlock(
                code: project.jobNumber,
                name: project.siteName,
                detail: "\(project.client.name) · \(bookingJobTypeLabel)",
                address: project.siteAddress,
                isSmallWorks: project.isSmallWorksDocument
            )
            if isReadyToReview {
                // Derived display arithmetic on existing values: total = `totalPlannedHours` (each person's
                // `paidBookedHours` per effective day), shifts = `totalEffectiveBookingDays`.
                PPGlanceHeadline(
                    eyebrow: "Booking at a glance",
                    primary: "\(ScheduleCoverageFormat.hours(totalPlannedHours))h paid",
                    secondary: "\(totalEffectiveBookingDays) shift\(totalEffectiveBookingDays == 1 ? "" : "s")"
                )
                PPStatRow(items: [
                    PPStatItem(id: "days", value: "\(selectedDates.count)", label: selectedDates.count == 1 ? "Day" : "Days"),
                    PPStatItem(id: "people", value: "\(selectedOperatives.count)", label: "People"),
                    PPStatItem(id: "perDay", value: paidHoursPerDayText, label: "Paid hrs / day"),
                ])
            } else {
                PPStepTracker(steps: bookingStepItems)
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var bookingStepItems: [PPStepTrackerItem] {
        let datesDone = !selectedDates.isEmpty
        let hoursDone = !selectedDates.isEmpty
        let peopleDone = !selectedOperatives.isEmpty
        let current = !datesDone ? 1 : (!peopleDone ? 3 : 0)
        return [
            PPStepTrackerItem(id: 1, title: "Dates", isDone: datesDone, isCurrent: current == 1),
            PPStepTrackerItem(id: 2, title: "Hours", isDone: hoursDone, isCurrent: current == 2),
            PPStepTrackerItem(id: 3, title: "Operatives", isDone: peopleDone, isCurrent: current == 3),
        ]
    }

    /// One paid-hours figure per day when every selected day books the same paid hours (each day's
    /// `paidBookedHours` under the rules in effect that day), else "Mixed / custom".
    private var paidHoursPerDay: Double? {
        guard !selectedDates.isEmpty, !hasAnyOperativeOverrides else { return nil }
        var values = Set<String>()
        var first: Double?
        for day in selectedDates {
            let probe = baseChoice(for: day).bookingProbe(operativeId: UUID(), projectId: project.id, date: day, bookedBy: "")
            let hours = probe.paidBookedHours(policy: payrollPolicy(for: day))
            values.insert(ScheduleCoverageFormat.hours(hours))
            if first == nil { first = hours }
        }
        return values.count == 1 ? first : nil
    }

    private var paidHoursPerDayText: String {
        if selectedDates.isEmpty { return "–" }
        if let hours = paidHoursPerDay { return ScheduleCoverageFormat.hours(hours) }
        return "Mixed / custom"
    }

    private static let bookingDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private func bookingDayText(_ date: Date) -> String {
        let f = Self.bookingDayFormatter
        f.timeZone = OrganizationRulebookContext.timeZone
        return f.string(from: date)
    }

    /// "Tue 17 Nov – Wed 18 Nov" for a run of days; "3 dates · Tue 17 Nov – Fri 20 Nov" when there are gaps.
    private var selectedDateRangeText: String {
        let dates = selectedDates.sorted()
        guard let first = dates.first, let last = dates.last else { return "No dates" }
        if dates.count == 1 { return bookingDayText(first) }
        let calendar = OrganizationRulebookContext.calendar
        let consecutive = zip(dates, dates.dropFirst()).allSatisfy { pair in
            calendar.dateComponents([.day], from: pair.0, to: pair.1).day == 1
        }
        let range = "\(bookingDayText(first)) – \(bookingDayText(last))"
        return consecutive ? range : "\(dates.count) dates · \(range)"
    }

    /// Every selected date (was the review's "Selected dates" row).
    private var selectedDatesListText: String {
        selectedDates.sorted()
            .map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: OrganizationRulebookContext.timeZone)) }
            .joined(separator: ", ")
    }

    private func stepDoneButton(_ step: Int) -> some View {
        Button("Done") { setStep(step, collapsed: true) }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.brand)
            .accessibilityIdentifier("scheduleOperative.step\(step).done")
            .accessibilityHint("Folds this step into a summary")
    }

    private func stepSummaryCard(step: Int, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(PPFamily.sites.top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Edit") { setStep(step, collapsed: false) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .accessibilityIdentifier("scheduleOperative.step\(step).edit")
        }
        .ppBookingCard(padding: 14)
        .padding(.top, 14)
    }

    // MARK: Dates

    @ViewBuilder
    private var scheduleBookingDatesSection: some View {
        if isStepCollapsed(1) {
            stepSummaryCard(
                step: 1,
                title: "Dates · \(selectedDates.count) day\(selectedDates.count == 1 ? "" : "s")",
                value: selectedDateRangeText
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PPSheetSectionTitle("Dates") {
                    HStack(spacing: 10) {
                        PPChip(text: "\(selectedDates.count) selected", tone: .blue)
                        if !isReadyToReview && !selectedDates.isEmpty {
                            stepDoneButton(1)
                        }
                    }
                }
                scheduleBookingCalendarCardCompact
                quickSelectSectionCompact
                if !selectedDates.isEmpty {
                    Text(selectedDatesListText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: Hours

    private var bulkHoursSegmentItems: [PPSegmentItem<TimeSlot>] {
        let refDay = selectedDates.sorted().first ?? Date()
        // RULEBOOK 1.13.1 §4.3 `allowedTimeSlotsOnDay`: Saturday and Sunday are custom hours only (AM / PM / FULL DAY
        // hidden). A stored weekend FULL DAY / AM / PM being edited still shows its own slot.
        let offered = RulebookBookingSlot.allCases.filter {
            CanonicalBusinessEngine.slotOffered($0, on: refDay, storedTimeSlot: editingBooking?.timeSlot.rawValue)
        }
        var items: [PPSegmentItem<TimeSlot>] = []
        if offered.contains(.am) {
            items.append(PPSegmentItem(id: .morning, title: "AM", isEnabled: canBookStandardDayWindow,
                                       accessibilityIdentifier: "scheduleOperative.\(AccessibilityID.token("AM"))"))
        }
        if offered.contains(.pm) {
            items.append(PPSegmentItem(id: .afternoon, title: "PM", isEnabled: canBookStandardDayWindow,
                                       accessibilityIdentifier: "scheduleOperative.\(AccessibilityID.token("PM"))"))
        }
        if offered.contains(.fullDay) {
            items.append(PPSegmentItem(id: .fullDay, title: "Full day", isEnabled: canBookStandardDayWindow,
                                       accessibilityIdentifier: "scheduleOperative.\(AccessibilityID.token("FULL DAY"))"))
        }
        items.append(PPSegmentItem(id: .customHours, title: "Custom", isEnabled: true,
                                   accessibilityIdentifier: "scheduleOperative.custom"))
        return items
    }

    /// Custom, a time tile, or the summary's hours open the existing Hours sheet for every selected person and date.
    private func openBulkHoursSheet() {
        operativeCustomHoursPick = OperativeCustomHoursPick(
            operativeId: nil,
            operativeName: nil,
            initialChoice: sharedBulkChoice
        )
    }

    private func bulkSlotSummary(_ choice: OperativeDayBookingChoice) -> String {
        switch choice.timeSlot {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "Full day"
        default: return isBulkStandardDay ? "Standard" : "Custom"
        }
    }

    @ViewBuilder
    private var scheduleBookingHoursSection: some View {
        let refDay = selectedDates.sorted().first ?? Date()
        let p = payrollPolicy(for: refDay)
        let choice = selectedDates.isEmpty ? sharedBulkChoice : baseChoice(for: refDay)
        let window = displayClockWindow(for: choice, day: refDay, policy: p)
        let start = window.start
        let end = window.end
        let probe = OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: choice.isBreakRemoved,
            otMultiplierOverride: choice.otMultiplierOverride
        ).bookingProbe(
            operativeId: UUID(),
            projectId: project.id,
            date: refDay,
            bookedBy: ""
        )
        let paidH = probe.paidBookedHours(policy: p)
        if isStepCollapsed(2) {
            stepSummaryCard(
                step: 2,
                title: "Hours · \(bulkSlotSummary(choice))",
                value: "\(start) – \(end) · \(ScheduleCoverageFormat.hours(paidH))h paid"
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PPSheetSectionTitle("Hours") {
                    if !isReadyToReview && !selectedDates.isEmpty {
                        stepDoneButton(2)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    PPSegmentedPills(
                        items: bulkHoursSegmentItems,
                        isSelected: { isBulkSelectedSlot($0) },
                        onSelect: { slot in
                            if slot == .customHours {
                                openBulkHoursSheet()
                            } else {
                                applyBulkTimeSlot(slot)
                            }
                        }
                    )
                    // RULEBOOK 1.17.0 `weekendBookingNotes`: the note covers every selected day.
                    WeekendBookingNoteView(days: selectedDates.isEmpty ? [refDay] : selectedDates.sorted(), policy: p)
                    HStack(spacing: 10) {
                        Button { openBulkHoursSheet() } label: {
                            PPTimeTileLabel(title: "Start", value: start)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scheduleOperative.startTile")
                        .accessibilityHint("Opens the hours for every selected person and date")
                        Button { openBulkHoursSheet() } label: {
                            PPTimeTileLabel(title: "End", value: end)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scheduleOperative.endTile")
                        .accessibilityHint("Opens the hours for every selected person and date")
                    }
                    PPDayTimelineBar(
                        day: refDay,
                        policy: p,
                        workStart: start,
                        workEnd: end,
                        breakIncluded: !choice.isBreakRemoved,
                        centerLabel: ScheduleCoverageFormat.hours(paidH) + "h"
                    )
                }
                .ppBookingCard(padding: 12)
                bulkHoursConfirmation(probe: probe, policy: p, start: start, end: end, isBreakRemoved: choice.isBreakRemoved, paidHours: paidH)
            }
        }
    }

    /// The green line "8.5h paid · 9h on site less 30m unpaid break" (amber with the overtime sum when the day has
    /// overtime). Paid = `paidBookedHours`, break = `payrollHoursResult.unpaidBreakHours`, overtime =
    /// `payrollMultipliedHours` text; on site = finish − start (owner decision 2). A weekend selection shows its
    /// per-day rows (`weekendBookingBreakdown`) instead, as before.
    @ViewBuilder
    private func bulkHoursConfirmation(
        probe: Booking,
        policy p: OrgPayrollTimePolicy,
        start: String,
        end: String,
        isBreakRemoved: Bool,
        paidHours paidH: Double
    ) -> some View {
        let weekendLines = weekendBreakdownLines(start: start, end: end, isBreakRemoved: isBreakRemoved)
        if !weekendLines.isEmpty {
            WeekendBookingBreakdownView(lines: weekendLines)
        } else {
            let otH = probe.overtimeHoursBeyondPaidStandard(policy: p)
            let result = probe.payrollHoursResult(policy: p)
            let tone: PPChipTone = otH < 0.05 ? .green : .amber
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tone.ink)
                Text(bulkHoursConfirmationText(result: result, start: start, end: end, paidHours: paidH, hasOvertime: otH >= 0.05))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func bulkHoursConfirmationText(
        result: PayrollHoursResult,
        start: String,
        end: String,
        paidHours: Double,
        hasOvertime: Bool
    ) -> String {
        var text = "\(ScheduleCoverageFormat.hours(paidHours))h paid"
        if let s = ManagerScheduleInterval.parseMinutes(start),
           let e = ManagerScheduleInterval.parseMinutes(end), e > s {
            text += " · \(ScheduleCoverageFormat.hours(Double(e - s) / 60))h on site"
        }
        let breakMinutes = Int((result.unpaidBreakHours * 60).rounded())
        if breakMinutes > 0 {
            text += " less \(breakMinutes)m unpaid break"
        }
        if hasOvertime, let multiplied = result.multipliedHours {
            text += " · OT \(multiplied.text)"
        }
        return text
    }

    // MARK: Operatives

    /// One person's paid hours over their effective days: the same `paidBookedHours` sum as `totalPlannedHours`.
    private func personPaidHours(_ operativeId: UUID) -> Double {
        var sum = 0.0
        for day in effectiveDates(for: operativeId) {
            let choice = resolvedChoice(operativeId: operativeId, date: day)
            let probe = choice.bookingProbe(operativeId: operativeId, projectId: project.id, date: day, bookedBy: loggedInUserName)
            sum += probe.paidBookedHours(policy: payrollPolicy(for: day))
        }
        return sum
    }

    private func openPersonHours(_ op: Operative) {
        let initial: OperativeDayBookingChoice
        if let d = selectedDates.sorted().first {
            initial = resolvedChoice(operativeId: op.id, date: d)
        } else {
            initial = operativeDefaultChoice[op.id] ?? sharedBulkChoice
        }
        operativeCustomHoursPick = OperativeCustomHoursPick(
            operativeId: op.id,
            operativeName: op.name,
            initialChoice: initial
        )
    }

    private var scheduleBookingOperativesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PPSheetSectionTitle("Operatives") {
                if !selectedOperatives.isEmpty {
                    Button { openPeoplePicker() } label: {
                        Label("Add people", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.brand)
                    }
                    .accessibilityIdentifier("scheduleOperative.plusCircleFill")
                    .buttonStyle(.plain)
                }
            }
            if selectedOperatives.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        PPIconTile(symbol: "person.2.fill", family: .people, size: 36)
                        Text("Choose who is on this job. You can set hours per person after they’re selected.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { openPeoplePicker() } label: {
                        Label("Add people", systemImage: "person.badge.plus")
                            .font(.headline)
                            .foregroundStyle(canOpenPeoplePicker ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                canOpenPeoplePicker ? AnyShapeStyle(PPBookingColor.primaryGradient) : AnyShapeStyle(PPColor.well),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    }
                    .accessibilityIdentifier("scheduleOperative.personBadgePlus")
                    .buttonStyle(PPPressableButtonStyle())
                    .disabled(!canOpenPeoplePicker)
                    if !canOpenPeoplePicker {
                        Text("Select dates first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .ppBookingCard(padding: 14)
            } else {
                let ordered = bookablePeople
                    .filter { selectedOperatives.contains($0.operativeId) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                VStack(spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, person in
                        if idx > 0 {
                            Divider().padding(.leading, 60)
                        }
                        scheduleBookingPersonRow(person)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5)
                )
            }
        }
    }

    private func scheduleBookingPersonRow(_ person: ScheduleBookablePerson) -> some View {
        let op = selectableOperatives.first(where: { $0.id == person.operativeId }) ?? Operative(
            firstName: person.name,
            lastName: "",
            email: person.email,
            startDate: Date()
        )
        let summary = personConflictSummary(person)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { openPersonHours(op) } label: {
                    HStack(spacing: 12) {
                        PPInitialsAvatar(initials: PlannerUIInitials.from(op.name), family: .plan, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(op.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let summary, summary.triangle != .none {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(summary.triangle == .red ? Color.red : Color.orange)
                                        .accessibilityLabel("Has a clash")
                                }
                            }
                            Text("\(person.roleLabel) · \(operativeHoursSubtitle(for: op.id))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let days = summary?.effectiveSelectedDates, !days.isEmpty {
                                Text(days.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: OrganizationRulebookContext.timeZone)) }.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(ScheduleCoverageFormat.hours(personPaidHours(op.id)))h")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("scheduleOperative.row.\(person.id)")
                .accessibilityHint("Sets hours for this person")
                .buttonStyle(.plain)
                Button {
                    clearOverrides(for: op.id)
                    selectedOperatives.remove(op.id)
                    expandedMainConflictPersonIds.remove(op.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(PPColor.well, in: Circle())
                }
                .accessibilityIdentifier("scheduleOperative.row.\(person.id).close")
                .accessibilityLabel("Remove \(op.name)")
                .buttonStyle(.plain)
            }
            if let summary, !summary.rows.isEmpty {
                ScheduleOperativeMainConflictBlock(
                    person: person,
                    summary: summary,
                    isExpanded: expandedMainConflictPersonIds.contains(person.operativeId),
                    acknowledgedIds: acknowledgedConflictIds,
                    struckIds: struckConflictIds,
                    onToggleExpand: {
                        if expandedMainConflictPersonIds.contains(person.operativeId) {
                            expandedMainConflictPersonIds.remove(person.operativeId)
                        } else {
                            expandedMainConflictPersonIds.insert(person.operativeId)
                        }
                    },
                    onAcknowledge: { acknowledgedConflictIds.insert($0); struckConflictIds.remove($0); replacedConflictIds.remove($0) },
                    onStrike: { struckConflictIds.insert($0); acknowledgedConflictIds.remove($0); replacedConflictIds.remove($0) },
                    replacedIds: replacedConflictIds,
                    onReplace: { replacedConflictIds.insert($0); acknowledgedConflictIds.insert($0); struckConflictIds.remove($0) }
                )
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var scheduleMainClashNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
            Text("Acknowledge each clash above before you can confirm booking.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// `weekendBookingBreakdown` lines for the selected days with one pair of times (`collapsedBreakdownLines`); empty
    /// for a weekday-only selection or no dates.
    private func weekendBreakdownLines(start: String, end: String, isBreakRemoved: Bool) -> [String] {
        guard !selectedDates.isEmpty else { return [] }
        return CanonicalBusinessEngine.collapsedBreakdownLines(
            CanonicalBusinessEngine.weekendBookingBreakdown(
                on: selectedDates.sorted(),
                start: start,
                end: end,
                isBreakRemoved: isBreakRemoved,
                fallbackPolicy: primarySelectedDatePolicy
            )
        )
    }

    private var scheduleBookingCalendarCardCompact: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(PPBookingColor.field, in: Circle())
                }
                .accessibilityIdentifier("scheduleOperative.back2")
                .accessibilityLabel("Previous month")
                .buttonStyle(.plain)
                Spacer()
                Text(monthYearString)
                    .font(.headline)
                Spacer()
                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(PPBookingColor.field, in: Circle())
                }
                .accessibilityIdentifier("scheduleOperative.chevronRight")
                .accessibilityLabel("Next month")
                .buttonStyle(.plain)
            }
            calendarGridCompact
        }
        .ppBookingCard(padding: 12)
    }

    /// Today / Next 3 working days / Next 5 working days: the existing Today / 3d / 5d actions (owner decision 7), with
    /// their old accessibility identifiers.
    private var quickSelectSectionCompact: some View {
        PPChipRow {
            quickSelectChip(days: 1, label: "Today", idLabel: "Today")
            quickSelectChip(days: 3, label: "Next 3 working days", idLabel: "3d")
            quickSelectChip(days: 5, label: "Next 5 working days", idLabel: "5d")
        }
    }

    private func quickSelectChip(days: Int, label: String, idLabel: String) -> some View {
        let selected = quickSelectDays == days
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                quickSelectDays(days: days)
            }
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : PPColor.brand)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? PPBookingColor.selected : PPColor.card, in: Capsule())
                .overlay(Capsule().strokeBorder(PPBookingColor.cardBorder, lineWidth: selected ? 0 : 0.5))
        }
        .accessibilityIdentifier("scheduleOperative.\(AccessibilityID.token(idLabel))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .buttonStyle(.plain)
    }

    private var calendarGridCompact: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(MondayFirstCalendarSupport.weekdayHeaderItems, id: \.id) { day in
                    Text(day.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            let calendar = OrganizationRulebookContext.calendar
            let range = MondayFirstCalendarSupport.gridRange(for: currentMonth, calendar: calendar)
            let days = MondayFirstCalendarSupport.days(from: range.start, through: range.end, calendar: calendar)
            let weeks = days.chunked(into: 7)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { date in
                        calendarDayButtonCompact(for: date, isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month))
                    }
                }
            }
        }
    }

    /// Today ringed, selected days filled, and a light band joining consecutive selected days.
    private func calendarDayButtonCompact(for date: Date, isCurrentMonth: Bool) -> some View {
        let calendar = OrganizationRulebookContext.calendar
        let normalizedDate = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(normalizedDate)
        let isToday = calendar.isDate(date, inSameDayAs: Date())
        let previousSelected = isSelected && (calendar.date(byAdding: .day, value: -1, to: normalizedDate)
            .map { selectedDates.contains(calendar.startOfDay(for: $0)) } ?? false)
        let nextSelected = isSelected && (calendar.date(byAdding: .day, value: 1, to: normalizedDate)
            .map { selectedDates.contains(calendar.startOfDay(for: $0)) } ?? false)
        let band = PPColor.brand.opacity(0.14)
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                toggleDateSelection(date)
            }
        }) {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline.weight(isSelected ? .bold : (isToday ? .semibold : .regular)))
                .monospacedDigit()
                .foregroundStyle(
                    isSelected ? Color.white :
                        (isCurrentMonth ? (isToday ? PPColor.brand : Color.primary) : Color.secondary)
                )
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(PPColor.brand)
                    } else if isToday {
                        Circle().strokeBorder(PPColor.brand, lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .background {
                    HStack(spacing: 0) {
                        Rectangle().fill(previousSelected ? band : Color.clear)
                        Rectangle().fill(nextSelected ? band : Color.clear)
                    }
                    .frame(height: 34)
                }
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("scheduleOperative.calendarDayButtonCompact")
        .accessibilityLabel(date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: OrganizationRulebookContext.timeZone)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .opacity(isCurrentMonth ? 1.0 : 0.35)
    }

    // MARK: - Bottom Action Bar

    /// Why Confirm is off, one line per check `canConfirmBooking` makes, in the order the booker meets them.
    private var confirmDisabledReason: String? {
        if selectedDates.isEmpty { return "Choose dates to confirm" }
        if selectedOperatives.isEmpty { return "Add operatives to confirm" }
        if isBooking { return "Booking…" }
        if !ScheduleDateSelectionPolicy.saturdaySundaySelectionAllowed(selected: selectedDates, policy: primarySelectedDatePolicy) {
            return "Book Saturday and Sunday separately to confirm"
        }
        if !canConfirmBooking { return "Acknowledge each clash to confirm" }
        return nil
    }

    /// The amber "still needed" chip.
    private var confirmMissingChip: String? {
        if selectedDates.isEmpty { return "No dates yet" }
        if selectedOperatives.isEmpty { return "No one added yet" }
        if isBooking { return nil }
        if !ScheduleDateSelectionPolicy.saturdaySundaySelectionAllowed(selected: selectedDates, policy: primarySelectedDatePolicy) {
            return "Saturday and Sunday rules differ"
        }
        if !canConfirmBooking { return "Clashes to acknowledge" }
        return nil
    }

    /// The hours chip: the shared hours line (was the review's "Hours" row), or "Mixed / custom" with per-person hours.
    private var bookingTimesChipText: String {
        if hasAnyOperativeOverrides { return "Mixed / custom" }
        return operativeLineForChoice(sharedBulkChoice)
    }

    private var confirmButtonTitle: String {
        let shifts = totalEffectiveBookingDays
        guard shifts > 0 else { return "Confirm booking" }
        return "Confirm \(shifts) shift\(shifts == 1 ? "" : "s")"
    }

    private var bottomActionBar: some View {
        PPBottomActionBar(
            title: confirmButtonTitle,
            trailingValue: totalEffectiveBookingDays > 0 ? "\(ScheduleCoverageFormat.hours(totalPlannedHours))h" : nil,
            isEnabled: canConfirmBooking,
            disabledTitle: confirmDisabledReason,
            isBusy: isBooking,
            accessibilityIdentifier: "scheduleOperative.checkmark",
            action: { bookOperatives() }
        ) {
            PPChipRow {
                if !selectedDates.isEmpty {
                    PPChip(
                        text: isReadyToReview ? selectedDateRangeText : "\(selectedDates.count) day\(selectedDates.count == 1 ? "" : "s")",
                        symbol: "checkmark",
                        tone: .blue
                    )
                    if isReadyToReview {
                        PPChip(text: bookingTimesChipText, symbol: "clock", tone: .blue)
                    } else if let perDay = paidHoursPerDay {
                        PPChip(text: "\(ScheduleCoverageFormat.hours(perDay))h / day", symbol: "checkmark", tone: .blue)
                    } else {
                        PPChip(text: "Mixed / custom", symbol: "checkmark", tone: .blue)
                    }
                }
                if !selectedOperatives.isEmpty {
                    PPChip(
                        text: "\(selectedOperatives.count) \(selectedOperatives.count == 1 ? "person" : "people")",
                        symbol: "person.2.fill",
                        tone: .blue
                    )
                }
                if let missing = confirmMissingChip {
                    PPChip(text: missing, symbol: "exclamationmark.circle", tone: .amber)
                }
                if hasAnyOperativeOverrides {
                    PPChip(text: "Some people have custom hours — tap a name above to review.", symbol: "slider.horizontal.3", tone: .amber)
                }
            }
        }
    }

    // MARK: - Helper Methods
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentMonth)
    }
    
    private func changeMonth(by months: Int) {
        if let newMonth = OrganizationRulebookContext.calendar.date(byAdding: .month, value: months, to: currentMonth) {
            currentMonth = newMonth
        }
    }
    
    private func toggleDateSelection(_ date: Date) {
        let calendar = OrganizationRulebookContext.calendar
        let normalizedDate = calendar.startOfDay(for: date)
        let key = slotKey(for: normalizedDate)

        if selectedDates.contains(normalizedDate) {
            selectedDates.remove(normalizedDate)
            dateSlotChoices.removeValue(forKey: key)
            quickSelectDays = nil
            return
        }

        var next = selectedDates
        if let message = ScheduleDateSelectionPolicy.toggle(
            date: date,
            selected: &next,
            policy: payrollPolicy(for: normalizedDate),
            calendar: calendar
        ) {
            dateSelectionAlertMessage = message
            showingDateSelectionAlert = true
            return
        }

        selectedDates = next
        // A new day takes the request's current hours; a change of selection kind resets them (1.18.0).
        dateSlotChoices[key] = sharedBulkChoice
        applyCustomHoursPrefillOnKindChange()
        quickSelectDays = nil
    }

    private func quickSelectDays(days: Int) {
        quickSelectDays = days
        var dates: Set<Date> = []
        ScheduleDateSelectionPolicy.quickSelect(count: days, into: &dates)
        selectedDates = dates
        dateSlotChoices.removeAll()
        for d in dates.sorted() {
            let key = slotKey(for: d)
            let policy = payrollPolicy(for: d)
            if PayrollTimePolicyCatalog.isWeekend(d) {
                dateSlotChoices[key] = .weekendCustomHours(on: d, policy: policy)
            } else {
                dateSlotChoices[key] = sharedBulkChoice
            }
        }
        if dates.count == 1, let only = dates.sorted().first, let choice = dateSlotChoices[slotKey(for: only)] {
            sharedBulkChoice = choice
        }
        applyCustomHoursPrefillOnKindChange()
    }
    
    private func generateDaysInMonth(start: Date, end: Date) -> [Date] {
        var days: [Date] = []
        var currentDate = start
        let calendar = OrganizationRulebookContext.calendar
        
        while currentDate <= end {
            days.append(currentDate)
            if let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) {
                currentDate = nextDate
            } else {
                break
            }
        }
        
        return days
    }
    
    private var operativeClashReviewBanner: some View {
        let groups: [(operative: Operative, clashes: [BookingClash])] = clashReviewOperativeIds.compactMap { id in
            guard let op = selectableOperatives.first(where: { $0.id == id }),
                  let clashes = operativeClashSummaries[id], !clashes.isEmpty else { return nil }
            return (op, clashes)
        }.sorted { $0.operative.name.localizedCaseInsensitiveCompare($1.operative.name) == .orderedAscending }

        return OperativeClashReviewPanel(
            clashesByOperative: groups,
            onApprove: { approveClashOperative($0) },
            onDismissOperative: { dismissClashOperative($0) },
            onCancelAll: {
                clashReviewOperativeIds.removeAll()
                operativeClashSummaries.removeAll()
                approvedOverlapOperativeIds.removeAll()
                droppedClashOperativeIds.removeAll()
            },
            onConfirmBooking: {
                guard !selectedOperatives.isEmpty else {
                    // Every clashing person was ✕-dropped: nothing is booked (web `droppedPersonDays`).
                    droppedClashOperativeIds.removeAll()
                    saveOutcomeAlert = ScheduleBookingSaveAlert(
                        outcome: .nothingToSave,
                        message: ScheduleBookingSaveOutcome.allDroppedMessage
                    )
                    return
                }
                droppedClashOperativeIds.removeAll()
                proceedWithBooking()
            },
            canConfirmBooking: ScheduleBookingSaveOutcome.clashReviewConfirmEnabled(
                selectedCount: selectedOperatives.count,
                droppedCount: droppedClashOperativeIds.count,
                awaitingDecisionCount: clashReviewOperativeIds.count,
                hasDates: !selectedDates.isEmpty,
                isBooking: isBooking
            ),
            approvedOperativeIds: approvedOverlapOperativeIds
        )
        .environmentObject(projectStore)
        .environmentObject(firebaseBackend)
    }

    private func approveClashOperative(_ operativeId: UUID) {
        droppedClashOperativeIds.remove(operativeId)
        approvedOverlapOperativeIds.insert(operativeId)
        reconcileOperativeClashState()
    }

    private func dismissClashOperative(_ operativeId: UUID) {
        droppedClashOperativeIds.insert(operativeId)
        clashReviewOperativeIds.remove(operativeId)
        operativeClashSummaries.removeValue(forKey: operativeId)
        approvedOverlapOperativeIds.remove(operativeId)
        selectedOperatives.remove(operativeId)
        clearOverrides(for: operativeId)
    }

    private func reconcileOperativeClashState() {
        guard !selectedDates.isEmpty else {
            clashReviewOperativeIds.removeAll()
            operativeClashSummaries.removeAll()
            return
        }
        let pool = selectedOperatives.union(clashReviewOperativeIds).union(approvedOverlapOperativeIds)
        var nextSelected: Set<UUID> = []
        var nextReview: Set<UUID> = []
        var summaries: [UUID: [BookingClash]] = [:]

        for opId in pool {
            guard selectableOperatives.contains(where: { $0.id == opId }) else { continue }
            let clashes = detectClashes(forOperativeId: opId)
            if clashes.isEmpty {
                nextSelected.insert(opId)
            } else if approvedOverlapOperativeIds.contains(opId) {
                nextSelected.insert(opId)
                summaries[opId] = clashes
            } else {
                nextReview.insert(opId)
                summaries[opId] = clashes
            }
        }

        selectedOperatives = nextSelected
        clashReviewOperativeIds = nextReview
        operativeClashSummaries = summaries
        approvedOverlapOperativeIds = approvedOverlapOperativeIds.intersection(nextSelected)
    }

    private func bookOperatives() {
        guard canConfirmBooking else { return }
        proceedWithBooking()
    }
    
    private func detectClashes(forOperativeId operativeId: UUID) -> [BookingClash] {
        guard let operative = selectableOperatives.first(where: { $0.id == operativeId }) else { return [] }
        var clashes: [BookingClash] = []
        let dates = Array(selectedDates.sorted())
        for date in dates {
            let policy = payrollPolicy(for: date)
            let choice = resolvedChoice(operativeId: operative.id, date: date)
            let probeNew = choice.bookingProbe(
                operativeId: operative.id,
                projectId: project.id,
                date: date,
                bookedBy: loggedInUserName
            )
            // Bookings under any id this person has had clash too (`resolveBookingPerson`, `bookingIdsForAccount`).
            let personIds = labourBookingIds(sameAs: operative.id, operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
            let existingBookings = bookingStore.bookings.filter { booking in
                personIds.contains(booking.operativeId) &&
                    OrganizationRulebookContext.calendar.isDate(booking.date, inSameDayAs: date) &&
                    booking.occupiesDay
            }

            for existingBooking in existingBookings {
                if OperativeBookingInterval.bookingsOverlap(probeNew, existingBooking, policy: policy) {
                    let existingProject = projectStore.projects.first(where: { $0.id == existingBooking.projectId }) ??
                        projectStore.smallWorks.first(where: { $0.id == existingBooking.projectId })
                    clashes.append(BookingClash(
                        operative: operative,
                        date: date,
                        newChoice: choice,
                        existingBooking: existingBooking,
                        existingProject: existingProject
                    ))
                }
            }
        }
        return clashes
    }

    private func slotKey(for date: Date) -> String {
        let calendar = OrganizationRulebookContext.calendar
        let normalizedDate = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: normalizedDate)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private var unavailableOperativeIdsForSelectedDates: Set<UUID> {
        guard !selectedDates.isEmpty else { return [] }
        return Set(
            selectableOperatives
                .filter { operative in
                    selectedDates.contains { isOperativeOnApprovedHoliday(operative: operative, date: $0) }
                }
                .map(\.id)
        )
    }
    
    private func isOperativeOnApprovedHoliday(operative: Operative, date: Date) -> Bool {
        let normalizedEmail = operative.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // RULEBOOK 1.34.0 §11: an empty email names nobody (ghosts have none); a converted ghost's row keeps its id.
        let linkedUser = userStore.organizationUsers.first {
            !normalizedEmail.isEmpty && $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
        } ?? userStore.organizationUsers.first { $0.id.caseInsensitiveCompare(operative.documentId) == .orderedSame }
        return holidayStore.approvedBookings(covering: date).contains { booking in
            if booking.operativeId == operative.id { return true }
            if let uid = booking.userId, let linkedUser, uid == linkedUser.id { return true }
            return false
        }
    }
    
    private func removeUnavailableSelectedOperatives() {
        let blocked = unavailableOperativeIdsForSelectedDates
        guard !blocked.isEmpty else { return }
        selectedOperatives = selectedOperatives.subtracting(blocked)
    }
    
    private func proceedWithBooking() {
        isBooking = true
        
        Task {
            let operatives = selectableOperatives.filter { selectedOperatives.contains($0.id) }
            var newBookings: [Booking] = []
            var createdDatesByOperative: [UUID: Set<Date>] = [:]
            /// 1.33.1 review item 4: each booking's own outcome (saved, queued as Pending sync, refused). A booking is
            /// counted, and its notice sent, only once its outcome says it was kept.
            var saveResults: [BookingSaveResult] = []
            let groupId: String? = operatives.count > 1 ? UUID().uuidString : nil
            // 1.33.1: the organisation open when Save was pressed. Every write and notice of this save goes there, and
            // nothing more is written if another organisation is opened meanwhile.
            let savingOrganizationId = firebaseBackend.resolvedOrganizationIdForOfflineWrites()
            // 1.33.1 review item 1: one save for the whole Confirm — the organisation is checked once, and after the
            // first wait that times out (a write, a read before an edit, or the organisation check) every later wait of
            // this Confirm is 1 s at most, so a dead link cannot add 15–38 s per booking.
            let writeSession = BookingWriteSession(organizationId: savingOrganizationId)
            // RULEBOOK 1.41.0 §5: per operative and day, the bookings Replace removes (read before any write changes the
            // stores). Those bookings are saved one by one, each in one batch with its replaced deletes (online only).
            var replacing: [(booking: Booking, refs: [RulebookBookingReplaceRef])] = []
            var refsByOperativeDay: [String: [RulebookBookingReplaceRef]] = [:]
            if !replacedConflictIds.isEmpty {
                for operative in operatives {
                    guard let person = bookablePeople.first(where: { $0.operativeId == operative.id }),
                          let rows = personConflictSummary(person)?.rows else { continue }
                    for row in rows where replacedConflictIds.contains(row.id) {
                        guard let ref = row.replaceRef else { continue }
                        refsByOperativeDay[operativeOverrideKey(operative.id, row.date), default: []].append(ref)
                    }
                }
            }

            for operative in operatives {
                let dates = effectiveDates(for: operative.id)
                guard !dates.isEmpty else { continue }
                for date in dates {
                    let ovKey = operativeOverrideKey(operative.id, date)
                    var choice = resolvedChoice(operativeId: operative.id, date: date)
                    // RULEBOOK 1.32.0 §25 (decision A): `otMultiplierOverride` is stored only when the rate differs
                    // from the organisation's for that date (`overtimeMultiplierCreateFields`); custom hours only.
                    choice.otMultiplierOverride = choice.timeSlot == .customHours
                        ? CanonicalBusinessEngine.createOtMultiplierOverride(chosen: choice.otMultiplierOverride, on: date)
                        : nil
                    // Replace = one partial update of the existing booking (same id) onto this job and slot — never a
                    // delete then a create, which offline left both bookings (each paid, RULEBOOK §8) and online could
                    // leave none when the create failed (launch data audit #7). An update also queues offline.
                    if let rid = replaceBookingOnConfirmByOverrideKey[ovKey],
                       let existing = bookingStore.bookings.first(where: { $0.id == rid }) {
                        // 1.33.1: the key is kept until the outcome is known, so a refused edit stays an edit when the
                        // booker tries again (the whole map is cleared once something saved).
                        var replaced = existing
                        if replaced.projectId != project.id {
                            replaced.projectId = project.id
                            replaced.projectKey = nil
                        }
                        replaced.date = BookingDay.organizationMidnight(for: date)
                        replaced.timeSlot = choice.timeSlot
                        replaced.workStartTime = choice.workStartTime
                        replaced.workEndTime = choice.workEndTime
                        replaced.isBreakRemoved = choice.isBreakRemoved
                        replaced.otMultiplierOverride = choice.otMultiplierOverride
                        replaced.bookingGroupId = groupId
                        replaced.status = .confirmed
                        replaced.updatedAt = Date()
                        // 1.33.1: judged on this save's own message, never one an earlier load or save left behind.
                        let result = await bookingStore.updateBookingReportingProblem(
                            replaced,
                            organizationId: savingOrganizationId,
                            session: writeSession
                        )
                        saveResults.append(result)
                        if result.keepsBooking {
                            createdDatesByOperative[operative.id, default: []].insert(replaced.date)
                        }
                        continue
                    }

                    let personIds = labourBookingIds(sameAs: operative.id, operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
                    let duplicateExists = bookingStore.bookings.contains { booking in
                        booking.projectId == project.id &&
                            personIds.contains(booking.operativeId) &&
                            OrganizationRulebookContext.calendar.isDate(booking.date, inSameDayAs: date) &&
                            booking.timeSlot == choice.timeSlot &&
                            booking.workStartTime == choice.workStartTime &&
                            booking.workEndTime == choice.workEndTime &&
                            booking.isBreakRemoved == choice.isBreakRemoved &&
                            booking.otMultiplierOverride == choice.otMultiplierOverride &&
                            (booking.status == .confirmed || booking.status == .tentative)
                    }

                    if !duplicateExists {
                        let normalizedDate = OrganizationRulebookContext.calendar.startOfDay(for: date)
                        var booking = Booking(
                            operativeId: operative.id,
                            projectId: project.id,
                            date: normalizedDate,
                            timeSlot: choice.timeSlot,
                            bookedBy: loggedInUserName,
                            workStartTime: choice.workStartTime,
                            workEndTime: choice.workEndTime,
                            isBreakRemoved: choice.isBreakRemoved,
                            otMultiplierOverride: choice.otMultiplierOverride,
                            bookingGroupId: groupId
                        )
                        booking.updatedAt = Date()
                        if let refs = refsByOperativeDay[ovKey], !refs.isEmpty {
                            replacing.append((booking, refs))
                        } else {
                            newBookings.append(booking)
                        }
                    }
                }
            }

            for entry in replacing {
                if let problem = await bookingStore.addBookingReplacing(entry.booking, replaces: entry.refs) {
                    saveResults.append(.refused(problem))
                } else {
                    saveResults.append(.saved)
                    createdDatesByOperative[entry.booking.operativeId, default: []].insert(entry.booking.date)
                }
            }

            if !newBookings.isEmpty {
                let results = await bookingStore.addBookingsReportingProblem(
                    newBookings,
                    organizationId: savingOrganizationId,
                    session: writeSession
                )
                for booking in newBookings {
                    // A booking the store never reported on was not written: treated as not saved.
                    let result = results[booking.id] ?? .refused("This booking could not be saved.")
                    saveResults.append(result)
                    if result.keepsBooking {
                        createdDatesByOperative[booking.operativeId, default: []].insert(booking.date)
                    }
                }
            }

            // 1.33.1: the screen finishes as soon as the bookings are saved on this phone. The "You've been booked"
            // notices follow on their own task: each one waits for the server, and awaiting them here left the
            // Confirm spinner turning for ever although the booking had saved.
            let outcome = ScheduleBookingSaveOutcome.decide(results: saveResults)
            await MainActor.run {
                isBooking = false
                switch outcome {
                case .confirmed:
                    showingBookingConfirmation = true
                case .pendingSync(let message), .savedWithProblem(let message), .notSaved(let message):
                    saveOutcomeAlert = ScheduleBookingSaveAlert(outcome: outcome, message: message)
                case .nothingToSave:
                    saveOutcomeAlert = ScheduleBookingSaveAlert(outcome: outcome, message: ScheduleBookingSaveOutcome.nothingToSaveMessage)
                }
                if outcome.clearsSelection {
                    acknowledgedConflictIds.removeAll()
                    struckConflictIds.removeAll()
                    replacedConflictIds.removeAll()
                    selectedDates.removeAll()
                    selectedOperatives.removeAll()
                    dateSlotChoices.removeAll()
                    operativeSlotOverrides.removeAll()
                    operativeDefaultChoice.removeAll()
                    replaceBookingOnConfirmByOverrideKey.removeAll()
                }
            }

            if !createdDatesByOperative.isEmpty {
                ScheduleChangeNotifier.postBookingStoreDidChange()
                let bookedRecipients = createdDatesByOperative.map { (operativeId, dates) in
                    NotificationService.BookedUserRecipient(
                        operativeId: operativeId,
                        dates: Array(dates)
                    )
                }
                let service = notificationService
                let projectName = project.siteName
                let bookedBy = loggedInUserName
                let projectId = project.id
                let catalogue = project.isSmallWorksDocument ? "smallWorks" : "projects"
                Task {
                    await service.notifyBookedUsers(
                        projectName: projectName,
                        bookedBy: bookedBy,
                        recipients: bookedRecipients,
                        projectId: projectId,
                        catalogue: catalogue,
                        organizationId: savingOrganizationId
                    )
                }
            }
        }
    }
    
    struct BookingClash: Identifiable {
        let id = UUID()
        let operative: Operative
        let date: Date
        let newChoice: OperativeDayBookingChoice
        let existingBooking: Booking
        let existingProject: Project?
        var cancelled: Bool = false
        
        var bookingKey: BookingKey {
            BookingKey(
                operativeId: operative.id,
                dateKey: Self.dateKey(from: date),
                timeSlot: newChoice.timeSlot,
                workStart: newChoice.workStartTime,
                workEnd: newChoice.workEndTime,
                isBreakRemoved: newChoice.isBreakRemoved,
                otMultiplierOverride: newChoice.otMultiplierOverride
            )
        }
        
        private static func dateKey(from date: Date) -> String {
            let calendar = OrganizationRulebookContext.calendar
            let normalizedDate = calendar.startOfDay(for: date)
            let components = calendar.dateComponents([.year, .month, .day], from: normalizedDate)
            return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        }
    }
    
    struct BookingKey: Hashable {
        let operativeId: UUID
        let dateKey: String
        let timeSlot: TimeSlot
        let workStart: String?
        let workEnd: String?
        let isBreakRemoved: Bool
        let otMultiplierOverride: Double?
    }
}

private struct OperativeCustomHoursPick: Identifiable {
    let id = UUID()
    var operativeId: UUID?
    var operativeName: String?
    var initialChoice: OperativeDayBookingChoice?

    var operativeDisplaySubtitle: String? {
        guard let operativeName, !operativeName.isEmpty else { return nil }
        return "\(operativeName) · tap hours below, then save"
    }
}

// OperativeCustomHoursSheet — see BookingHoursEditSheet.swift

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

#Preview {
    ScheduleOperativeView(project: Project(
        jobNumber: "C646",
        siteName: "Lancelot Place",
        siteAddress: "8 Lancelot Place, SW7 1DR, London",
        client: Client(name: "Test Client"),
        startDate: Date(),
        endDate: Date(),
        jobType: .catA,
        manager: .na
    ))
    .environmentObject(BookingStore())
    .environmentObject(OperativeStore())
    .environmentObject(ProjectStore())
    .environmentObject(UserStore())
    .environmentObject(HolidayStore())
    .environmentObject(FirebaseBackend())
}

