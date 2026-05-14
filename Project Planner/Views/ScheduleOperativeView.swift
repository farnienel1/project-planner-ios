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
    
    let project: Project
    /// When opening from a project week booking row, pre-selects operative/date/hours and replaces that booking after confirm.
    var editingBooking: Booking? = nil

    @State private var selectedOperatives: Set<UUID> = []
    @State private var showingSelectOperatives = false
    @State private var selectedDates: Set<Date> = []
    @State private var dateSlotChoices: [String: OperativeDayBookingChoice] = [:]
    /// Default hours applied to every selected date (bulk). Kept in sync when dates are added.
    @State private var sharedBulkChoice: OperativeDayBookingChoice = OperativeDayBookingChoice(
        timeSlot: .customHours,
        workStartTime: OrgPayrollTimePolicy.default.standardDayStart,
        workEndTime: OrgPayrollTimePolicy.default.standardDayEnd,
        isBreakRemoved: false,
        otMultiplierOverride: nil
    )
    /// Per-operative, per-day overrides on top of `dateSlotChoices` (key: `operativeUUID|yyyy-m-d`).
    @State private var operativeSlotOverrides: [String: OperativeDayBookingChoice] = [:]
    /// Hours template per operative when no dates selected yet (applied when dates are first chosen).
    @State private var operativeDefaultChoice: [UUID: OperativeDayBookingChoice] = [:]
    @State private var operativeCustomHoursPick: OperativeCustomHoursPick?
    @State private var currentMonth: Date = Date()
    @State private var quickSelectDays: Int? = nil
    @State private var showingBookingConfirmation = false
    @State private var isBooking = false
    @State private var showingClashWarning = false
    @State private var detectedClashes: [BookingClash] = []
    @State private var didApplyOrgDefaultHours = false
    @State private var didApplyEditingBookingPrefill = false
    /// `operativeOverrideKey` → booking id to delete before creating the replacement on confirm.
    @State private var replaceBookingOnConfirmByOverrideKey: [String: UUID] = [:]
    @EnvironmentObject var notificationService: NotificationService
    
    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var canBookStandardDayWindow: Bool {
        let p = payrollTimePolicy
        guard let s = ManagerScheduleInterval.parseMinutes(p.standardDayStart),
              let e = ManagerScheduleInterval.parseMinutes(p.standardDayEnd) else { return false }
        return e > s
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
        NavigationView {
            ZStack {
                ProjectWorksRevampColors.canvas
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 12) {
                        scheduleBookingProjectCard
                        scheduleBookingOperativesSection
                        if !selectedOperatives.isEmpty {
                            scheduleBookingBulkHoursCard
                        }
                        scheduleBookingCalendarCardCompact
                        quickSelectSectionCompact
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 100)
                }
            }
            .navigationTitle("Schedule booking")
            .navigationBarTitleDisplayMode(.inline)
            .appChromeNavigationBarSurface()
            .sheet(isPresented: $showingClashWarning) {
                BookingClashWarningView(
                    clashes: $detectedClashes,
                    isPresented: $showingClashWarning,
                    onCancel: {
                        showingClashWarning = false
                    },
                    onContinue: {
                        showingClashWarning = false
                        proceedWithBooking()
                    }
                )
                .environmentObject(projectStore)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(firebaseBackend)
            }
            .sheet(item: $operativeCustomHoursPick) { pick in
                OperativeCustomHoursSheet(
                    policy: payrollTimePolicy,
                    title: pick.operativeId == nil ? "Hours" : "Edit booking",
                    subtitle: pick.operativeId == nil ? "Applies to all selected operatives and dates" : pick.operativeDisplaySubtitle,
                    allowsOtMultiplierOverride: pick.operativeId != nil,
                    initialChoice: pick.initialChoice,
                    onSave: { start, end, breakRemoved, otMultiplierOverride in
                        operativeCustomHoursPick = nil
                        let newChoice = OperativeDayBookingChoice(
                            timeSlot: .customHours,
                            workStartTime: start,
                            workEndTime: end,
                            isBreakRemoved: breakRemoved,
                            otMultiplierOverride: pick.operativeId == nil ? nil : otMultiplierOverride
                        )
                        if let opId = pick.operativeId {
                            applyOperativeOverride(operativeId: opId, choice: newChoice)
                            if newChoice.timeSlot == sharedBulkChoice.timeSlot,
                               newChoice.workStartTime == sharedBulkChoice.workStartTime,
                               newChoice.workEndTime == sharedBulkChoice.workEndTime,
                               newChoice.isBreakRemoved == sharedBulkChoice.isBreakRemoved,
                               newChoice.otMultiplierOverride == nil {
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
                                otMultiplierOverride: nil
                            )
                            syncSharedBulkToAllSelectedDates()
                            operativeSlotOverrides.removeAll()
                        }
                    },
                    onCancel: { operativeCustomHoursPick = nil }
                )
            }
            .sheet(isPresented: $showingBookingConfirmation, onDismiss: {
                // After showing "Booking Confirmed", return to the scheduling overview page.
                dismiss()
            }) {
                BookingConfirmationView(isPresented: $showingBookingConfirmation)
                    .presentationDetents([.fraction(0.35)])
                    .interactiveDismissDisabled(true)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .fontWeight(.medium)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .sheet(isPresented: $showingSelectOperatives) {
                SelectOperativesView(
                    selectedOperatives: $selectedOperatives,
                    unavailableOperativeIds: unavailableOperativeIdsForSelectedDates
                )
                    .environmentObject(operativeStore)
            }
            .onChange(of: selectedDates) { oldSet, newSet in
                removeUnavailableSelectedOperatives()
                if oldSet.isEmpty && !newSet.isEmpty {
                    for opId in selectedOperatives {
                        if let d = operativeDefaultChoice[opId] {
                            applyOperativeOverride(operativeId: opId, choice: d)
                        }
                    }
                }
            }
            .onAppear {
                Task { await holidayStore.loadData() }
                if !didApplyOrgDefaultHours {
                    let p = payrollTimePolicy
                    sharedBulkChoice = OperativeDayBookingChoice(
                        timeSlot: .customHours,
                        workStartTime: p.standardDayStart,
                        workEndTime: p.standardDayEnd,
                        isBreakRemoved: false,
                        otMultiplierOverride: nil
                    )
                    didApplyOrgDefaultHours = true
                }
                if let b = editingBooking, !didApplyEditingBookingPrefill {
                    didApplyEditingBookingPrefill = true
                    applyPrefillFromEditingBooking(b)
                }
            }
        }
    }
    
    // MARK: - Project Header Card
    private var selectableOperatives: [Operative] {
        let active = operativeStore.activeOperatives
        return active.isEmpty ? operativeStore.allOperatives : active
    }
    
    private func applyPrefillFromEditingBooking(_ booking: Booking) {
        guard booking.projectId == project.id else { return }
        let cal = Calendar.current
        let day = cal.startOfDay(for: booking.date)
        selectedOperatives = [booking.operativeId]
        selectedDates = [day]
        let choice = OperativeDayBookingChoice(from: booking)
        let k = operativeOverrideKey(booking.operativeId, day)
        operativeSlotOverrides[k] = choice
        operativeDefaultChoice[booking.operativeId] = choice
        replaceBookingOnConfirmByOverrideKey[k] = booking.id
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

    private func clearOverrides(for operativeId: UUID) {
        let prefix = "\(operativeId.uuidString)|"
        operativeSlotOverrides = operativeSlotOverrides.filter { !$0.key.hasPrefix(prefix) }
        operativeDefaultChoice.removeValue(forKey: operativeId)
    }

    private var isBulkStandardDay: Bool {
        let p = payrollTimePolicy
        return sharedBulkChoice.timeSlot == .customHours &&
            sharedBulkChoice.workStartTime == p.standardDayStart &&
            sharedBulkChoice.workEndTime == p.standardDayEnd &&
            !sharedBulkChoice.isBreakRemoved &&
            sharedBulkChoice.otMultiplierOverride == nil
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

    private func operativeLineForChoice(_ c: OperativeDayBookingChoice) -> String {
        let p = payrollTimePolicy
        if c.timeSlot == .customHours,
           c.workStartTime == p.standardDayStart,
           c.workEndTime == p.standardDayEnd,
           !c.isBreakRemoved,
           c.otMultiplierOverride == nil {
            return "Standard · \(p.standardDayStart)–\(p.standardDayEnd)"
        }
        if c.timeSlot == .customHours, let s = c.workStartTime, let e = c.workEndTime {
            var line = "\(s)–\(e)"
            if c.isBreakRemoved { line += " · no break" }
            if let m = c.otMultiplierOverride {
                let ms = abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m)
                line += " · OT \(ms)×"
            }
            return line
        }
        return c.scheduleLabel(policy: p)
    }

    private var totalPlannedHours: Double {
        let dates = selectedDates.sorted()
        guard !selectedOperatives.isEmpty, !dates.isEmpty else { return 0 }
        let ops = selectableOperatives.filter { selectedOperatives.contains($0.id) }
        var sum = 0.0
        let p = payrollTimePolicy
        for op in ops {
            for d in dates {
                let choice = resolvedChoice(operativeId: op.id, date: d)
                let probe = choice.bookingProbe(operativeId: op.id, projectId: project.id, date: d, bookedBy: loggedInUserName)
                sum += probe.paidBookedHours(policy: p)
            }
        }
        return sum
    }

    private var bottomBarHoursCaption: String {
        let dates = selectedDates.sorted()
        guard !selectedOperatives.isEmpty, !dates.isEmpty else { return "" }
        let ops = selectedOperatives.count
        let dCount = dates.count
        let h = totalPlannedHours
        let hStr = formatHoursOneDecimal(h)
        return "\(ops) ops × \(dCount) date\(dCount == 1 ? "" : "s") · \(hStr)h total"
    }

    private var bottomBarStandardCaption: String {
        if hasAnyOperativeOverrides { return "Mixed / custom" }
        if isBulkStandardDay { return "All standard" }
        return "Custom hours"
    }

    private func formatHoursOneDecimal(_ h: Double) -> String {
        let r = (h * 2).rounded() / 2
        if abs(r - r.rounded(.towardZero)) < 0.01 { return String(format: "%.0f", r) }
        return String(format: "%.1f", r)
    }

    private var scheduleBookingProjectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(project.jobNumber)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(project.jobType == .smallWorks ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.blue)
                        Text(project.siteName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .lineLimit(2)
                    }
                    Text(project.client.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink.opacity(0.85))
                    Text(project.jobType == .smallWorks ? "Small works" : (project.customJobType ?? "Project"))
                        .font(.system(size: 10))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                Spacer(minLength: 0)
                if project.jobType == .smallWorks {
                    Text("SMALL WORKS")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            Text(project.siteAddress)
                .font(.system(size: 10))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var scheduleBookingOperativesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OPERATIVES")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
                .padding(.leading, 4)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                if selectedOperatives.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose who is on this job. You can set hours per person after they’re selected.")
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showingSelectOperatives = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 15, weight: .medium))
                                Text("Add operatives")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.902, green: 0.945, blue: 0.984))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(ProjectWorksRevampColors.blue.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                } else {
                    let ordered = selectableOperatives.filter { selectedOperatives.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, op in
                        if idx > 0 {
                            Divider().overlay(ProjectWorksRevampColors.border)
                        }
                        HStack(spacing: 10) {
                            Button {
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
                            } label: {
                                HStack(spacing: 10) {
                                    Text(PlannerUIInitials.from(op.name))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(
                                            LinearGradient(
                                                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(op.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(ProjectWorksRevampColors.ink)
                                        Text(operativeHoursSubtitle(for: op.id))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                clearOverrides(for: op.id)
                                selectedOperatives.remove(op.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 10)
                    }
                    Divider().overlay(ProjectWorksRevampColors.border)
                    Button { showingSelectOperatives = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16, weight: .medium))
                            Text(selectedOperatives.count <= 1 ? "Add operative" : "Add another operative")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var scheduleBookingBulkHoursCard: some View {
        let p = payrollTimePolicy
        let start = sharedBulkChoice.workStartTime ?? p.standardDayStart
        let end = sharedBulkChoice.workEndTime ?? p.standardDayEnd
        let probe = OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: sharedBulkChoice.isBreakRemoved,
            otMultiplierOverride: nil
        ).bookingProbe(
            operativeId: UUID(),
            projectId: project.id,
            date: Date(),
            bookedBy: ""
        )
        let paidH = probe.paidBookedHours(policy: p)
        let otH = probe.overtimeHoursBeyondPaidStandard(policy: p)
        return VStack(alignment: .leading, spacing: 10) {
            Text("HOURS · APPLIES TO ALL SELECTED")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        guard canBookStandardDayWindow else { return }
                        sharedBulkChoice = OperativeDayBookingChoice(
                            timeSlot: .customHours,
                            workStartTime: p.standardDayStart,
                            workEndTime: p.standardDayEnd,
                            isBreakRemoved: false,
                            otMultiplierOverride: nil
                        )
                        syncSharedBulkToAllSelectedDates()
                        operativeSlotOverrides.removeAll()
                    } label: {
                        Text("Standard day")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(isBulkStandardDay ? Color(red: 0.902, green: 0.945, blue: 0.984) : Color.white)
                            .foregroundStyle(isBulkStandardDay ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.ink)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(isBulkStandardDay ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.searchBorder, lineWidth: isBulkStandardDay ? 1.5 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canBookStandardDayWindow)
                    Button {
                        operativeCustomHoursPick = OperativeCustomHoursPick(
                            operativeId: nil,
                            operativeName: nil,
                            initialChoice: sharedBulkChoice
                        )
                    } label: {
                        Text("Custom")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(!isBulkStandardDay ? Color(red: 0.902, green: 0.945, blue: 0.984) : Color.white)
                            .foregroundStyle(!isBulkStandardDay ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.ink)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(!isBulkStandardDay ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.searchBorder, lineWidth: !isBulkStandardDay ? 1.5 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("START")
                            .font(.system(size: 9))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        Text(start)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    .background(ProjectWorksRevampColors.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("END")
                            .font(.system(size: 9))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        Text(end)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    .background(ProjectWorksRevampColors.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                scheduleHoursTimelineBarWithStandardWindow(policy: p, workStart: start, workEnd: end, centerLabel: formatHoursOneDecimal(paidH) + "h")
                HStack {
                    ForEach(["6", "9", "12", "15", "18", "21"], id: \.self) { t in
                        Text(t)
                            .font(.system(size: 7))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(otH < 0.05 ? ProjectWorksRevampColors.activeGreen : ProjectWorksRevampColors.upcomingAmber)
                Group {
                    if otH < 0.05 {
                        Text("\(formatHoursOneDecimal(paidH))h within standard window · \(formatHoursOneDecimal(p.weekdayOutsideStandardMultiplier))× OT if extended")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                    } else {
                        Text("\(formatHoursOneDecimal(paidH))h booked · ")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        + Text("\(formatHoursOneDecimal(otH))h outside standard (\(formatHoursOneDecimal(p.weekdayOutsideStandardMultiplier))×)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                    }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(otH < 0.05 ? Color(red: 0.882, green: 0.961, blue: 0.933) : Color(red: 0.98, green: 0.933, blue: 0.855))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Timeline 06:00–21:00: org standard window in blue, work outside that window in orange (before/after).
    private func scheduleHoursTimelineBarWithStandardWindow(policy: OrgPayrollTimePolicy, workStart: String, workEnd: String, centerLabel: String) -> some View {
        let clipLo = 6 * 60
        let clipHi = 21 * 60
        let sm = ManagerScheduleInterval.parseMinutes(workStart) ?? clipLo
        let em = ManagerScheduleInterval.parseMinutes(workEnd) ?? (clipLo + 1)
        let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart) ?? (7 * 60 + 30)
        let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd) ?? (16 * 60)
        let orange = Color(red: 0.95, green: 0.55, blue: 0.2)
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let xPos: (Int) -> CGFloat = { minutes in
                let clipped = min(clipHi, max(clipLo, minutes))
                return CGFloat(clipped - clipLo) / CGFloat(clipHi - clipLo) * w
            }
            let w0 = max(sm, clipLo)
            let w1 = min(em, clipHi)
            let s0 = max(ds, clipLo)
            let s1 = min(de, clipHi)
            let midLeft = max(w0, s0)
            let midRight = min(w1, s1)
            let leftOt0 = w0
            let leftOt1 = min(w1, s0)
            let rightOt0 = max(w0, s1)
            let rightOt1 = w1
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.949, green: 0.953, blue: 0.961))
                if leftOt1 > leftOt0 {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(orange.opacity(0.92))
                        .frame(width: max(4, xPos(leftOt1) - xPos(leftOt0)), height: h)
                        .offset(x: xPos(leftOt0))
                }
                if midRight > midLeft {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, xPos(midRight) - xPos(midLeft)), height: h)
                        .offset(x: xPos(midLeft))
                }
                if rightOt1 > rightOt0 {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(orange.opacity(0.92))
                        .frame(width: max(4, xPos(rightOt1) - xPos(rightOt0)), height: h)
                        .offset(x: xPos(rightOt0))
                }
                Text(centerLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 22)
    }

    private var scheduleBookingCalendarCardCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DATES · \(selectedDates.count) selected")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
                .padding(.leading, 4)
            VStack(spacing: 8) {
                HStack {
                    Button(action: { changeMonth(by: -1) }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(monthYearString)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Spacer()
                    Button(action: { changeMonth(by: 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    .buttonStyle(.plain)
                }
                calendarGridCompact
            }
            .padding(8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        }
    }

    private var quickSelectSectionCompact: some View {
        HStack(spacing: 8) {
            quickSelectChip(days: 1, label: "Today")
            quickSelectChip(days: 3, label: "3d")
            quickSelectChip(days: 5, label: "5d")
        }
    }

    private func quickSelectChip(days: Int, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                quickSelectDays(days: days)
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(quickSelectDays == days ? .white : ProjectWorksRevampColors.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(quickSelectDays == days ? ProjectWorksRevampColors.blue : Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
    
    private var calendarGridCompact: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            let calendar = Calendar.current
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth))!
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
            let startDate = calendar.date(byAdding: DateComponents(day: -calendar.component(.weekday, from: monthStart) + 1), to: monthStart)!
            let endDate = calendar.date(byAdding: DateComponents(day: 6 - calendar.component(.weekday, from: monthEnd) + calendar.range(of: .day, in: .month, for: monthEnd)!.count), to: monthStart)!
            let days = generateDaysInMonth(start: startDate, end: endDate)
            let weeks = days.chunked(into: 7)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(week, id: \.self) { date in
                        calendarDayButtonCompact(for: date, isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month))
                    }
                }
            }
        }
    }

    private func calendarDayButtonCompact(for date: Date, isCurrentMonth: Bool) -> some View {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(normalizedDate)
        let isToday = calendar.isDateInToday(date)
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                toggleDateSelection(date)
            }
        }) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 11, weight: isSelected ? .bold : (isToday ? .semibold : .regular)))
                .foregroundColor(
                    isSelected ? .white :
                        (isCurrentMonth ? (isToday ? ProjectWorksRevampColors.blue : Color.primary) : Color.secondary)
                )
                .frame(width: 28, height: 28)
                .background(
                    Group {
                        if isSelected {
                            Circle()
                                .fill(ProjectWorksRevampColors.blue)
                        } else if isToday {
                            Circle()
                                .stroke(ProjectWorksRevampColors.blue, lineWidth: 1.5)
                                .background(Circle().fill(ProjectWorksRevampColors.blue.opacity(0.08)))
                        } else {
                            Circle().fill(Color.clear)
                        }
                    }
                )
        }
        .frame(maxWidth: .infinity)
        .opacity(isCurrentMonth ? 1.0 : 0.35)
    }
    
    // MARK: - Bottom Action Bar
    
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if !bottomBarHoursCaption.isEmpty {
                            Text(bottomBarHoursCaption)
                                .font(.system(size: 10))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                            Text(bottomBarStandardCaption)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                        } else {
                            Text("Select operatives and dates")
                                .font(.system(size: 12))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(ProjectWorksRevampColors.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                Button(action: { bookOperatives() }) {
                    HStack(spacing: 6) {
                        if isBooking {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(isBooking ? "Booking…" : "Confirm booking")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selectedOperatives.isEmpty || selectedDates.isEmpty || isBooking ? ProjectWorksRevampColors.muted.opacity(0.45) : ProjectWorksRevampColors.blue)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedOperatives.isEmpty || selectedDates.isEmpty || isBooking)
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 12)
            .background(Color.white)
        }
    }
    
    // MARK: - Helper Methods
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentMonth)
    }
    
    private func changeMonth(by months: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: months, to: currentMonth) {
            currentMonth = newMonth
        }
    }
    
    private func toggleDateSelection(_ date: Date) {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let key = slotKey(for: normalizedDate)
        
        if selectedDates.contains(normalizedDate) {
            selectedDates.remove(normalizedDate)
            dateSlotChoices.removeValue(forKey: key)
        } else {
            selectedDates.insert(normalizedDate)
            dateSlotChoices[key] = sharedBulkChoice
        }
        
        quickSelectDays = nil
    }
    
    private func quickSelectDays(days: Int) {
        quickSelectDays = days
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        selectedDates.removeAll()
        dateSlotChoices.removeAll()
        
        for i in 0..<days {
            if let date = calendar.date(byAdding: .day, value: i, to: today) {
                let normalizedDate = calendar.startOfDay(for: date)
                selectedDates.insert(normalizedDate)
                dateSlotChoices[slotKey(for: normalizedDate)] = sharedBulkChoice
            }
        }
    }
    
    private func generateDaysInMonth(start: Date, end: Date) -> [Date] {
        var days: [Date] = []
        var currentDate = start
        let calendar = Calendar.current
        
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
    
    private func bookOperatives() {
        guard !selectedOperatives.isEmpty, !selectedDates.isEmpty else { return }
        
        // Check for clashes before booking
        let clashes = detectClashes()
        
        if !clashes.isEmpty {
            detectedClashes = clashes
            showingClashWarning = true
        } else {
            proceedWithBooking()
        }
    }
    
    private func detectClashes() -> [BookingClash] {
        var clashes: [BookingClash] = []
        let operatives = selectableOperatives.filter { selectedOperatives.contains($0.id) }
        let dates = Array(selectedDates.sorted())
        
        let policy = payrollTimePolicy
        for operative in operatives {
            for date in dates {
                let choice = resolvedChoice(operativeId: operative.id, date: date)
                let probeNew = choice.bookingProbe(
                    operativeId: operative.id,
                    projectId: project.id,
                    date: date,
                    bookedBy: loggedInUserName
                )
                let existingBookings = bookingStore.bookings.filter { booking in
                    booking.operativeId == operative.id &&
                        Calendar.current.isDate(booking.date, inSameDayAs: date) &&
                        (booking.status == .confirmed || booking.status == .tentative)
                }

                for existingBooking in existingBookings {
                    if existingBooking.projectId == project.id {
                        continue
                    }
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
        }

        return clashes
    }

    private func slotKey(for date: Date) -> String {
        let calendar = Calendar.current
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
        let linkedUser = userStore.organizationUsers.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
        }
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
            let dates = Array(selectedDates.sorted())
            var createdBookingCount = 0
            var createdDatesByOperative: [UUID: Set<Date>] = [:]
            
            // Cancelled clashes are explicitly skipped from booking creation.
            let cancelledClashKeys = Set(
                detectedClashes
                    .filter(\.cancelled)
                    .map(\.bookingKey)
            )
            
            // Create bookings for each operative on each selected date
            for operative in operatives {
                for date in dates {
                    let ovKey = operativeOverrideKey(operative.id, date)
                    if let rid = replaceBookingOnConfirmByOverrideKey[ovKey],
                       let existing = bookingStore.bookings.first(where: { $0.id == rid }) {
                        await bookingStore.deleteBooking(existing)
                        replaceBookingOnConfirmByOverrideKey.removeValue(forKey: ovKey)
                    }

                    let choice = resolvedChoice(operativeId: operative.id, date: date)
                    let bookingKey = BookingKey(
                        operativeId: operative.id,
                        dateKey: slotKey(for: date),
                        timeSlot: choice.timeSlot,
                        workStart: choice.workStartTime,
                        workEnd: choice.workEndTime,
                        isBreakRemoved: choice.isBreakRemoved,
                        otMultiplierOverride: choice.otMultiplierOverride
                    )

                    if cancelledClashKeys.contains(bookingKey) {
                        continue
                    }

                    let duplicateExists = bookingStore.bookings.contains { booking in
                        booking.projectId == project.id &&
                            booking.operativeId == operative.id &&
                            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
                            booking.timeSlot == choice.timeSlot &&
                            booking.workStartTime == choice.workStartTime &&
                            booking.workEndTime == choice.workEndTime &&
                            booking.isBreakRemoved == choice.isBreakRemoved &&
                            booking.otMultiplierOverride == choice.otMultiplierOverride &&
                            (booking.status == .confirmed || booking.status == .tentative)
                    }

                    if !duplicateExists && !isOperativeOnApprovedHoliday(operative: operative, date: date) {
                        await bookingStore.bookOperative(
                            operative,
                            on: date,
                            timeSlot: choice.timeSlot,
                            for: project,
                            bookedBy: loggedInUserName,
                            workStartTime: choice.workStartTime,
                            workEndTime: choice.workEndTime,
                            isBreakRemoved: choice.isBreakRemoved,
                            otMultiplierOverride: choice.otMultiplierOverride
                        )
                        createdBookingCount += 1
                        createdDatesByOperative[operative.id, default: []].insert(Calendar.current.startOfDay(for: date))
                    }
                }
            }
            
            if createdBookingCount > 0 {
                await notificationService.notifyBookingBatchCreated(
                    projectName: project.siteName,
                    bookingCount: createdBookingCount,
                    createdBy: loggedInUserName
                )
                let bookedRecipients = createdDatesByOperative.map { (operativeId, dates) in
                    NotificationService.BookedUserRecipient(
                        operativeId: operativeId,
                        dates: Array(dates)
                    )
                }
                await notificationService.notifyBookedUsers(
                    projectName: project.siteName,
                    bookedBy: loggedInUserName,
                    recipients: bookedRecipients
                )
            }
            
            await MainActor.run {
                isBooking = false
                showingBookingConfirmation = true
                detectedClashes = []
                // Stay on Schedule Operative page; reset selections so user can continue booking quickly.
                selectedDates.removeAll()
                selectedOperatives.removeAll()
                dateSlotChoices.removeAll()
                operativeSlotOverrides.removeAll()
                operativeDefaultChoice.removeAll()
                replaceBookingOnConfirmByOverrideKey.removeAll()
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
            let calendar = Calendar.current
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

/// Edit / custom hours sheet aligned with `project_planner_break_toggle_and_grouped_overview.html`.
private struct OperativeCustomHoursSheet: View {
    let policy: OrgPayrollTimePolicy
    var title: String
    var subtitle: String?
    var allowsOtMultiplierOverride: Bool
    let initialChoice: OperativeDayBookingChoice?
    let onSave: (String, String, Bool, Double?) -> Void
    let onCancel: () -> Void

    @State private var startText: String
    @State private var endText: String
    @State private var breakRemoved = false
    @State private var otMultText: String
    @State private var errorMessage: String?

    init(
        policy: OrgPayrollTimePolicy,
        title: String = "Edit booking",
        subtitle: String? = nil,
        allowsOtMultiplierOverride: Bool = false,
        initialChoice: OperativeDayBookingChoice?,
        onSave: @escaping (String, String, Bool, Double?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.policy = policy
        self.title = title
        self.subtitle = subtitle
        self.allowsOtMultiplierOverride = allowsOtMultiplierOverride
        self.initialChoice = initialChoice
        self.onSave = onSave
        self.onCancel = onCancel
        let ic = initialChoice
        let start: String
        let end: String
        let br: Bool
        let otm: String
        if let ic, ic.timeSlot == .customHours, let s = ic.workStartTime, let e = ic.workEndTime, !s.isEmpty, !e.isEmpty {
            start = s
            end = e
            br = ic.isBreakRemoved
            if let m = ic.otMultiplierOverride {
                otm = abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m)
            } else {
                otm = ""
            }
        } else {
            start = policy.standardDayStart
            end = policy.standardDayEnd
            br = false
            otm = ""
        }
        _startText = State(initialValue: start)
        _endText = State(initialValue: end)
        _breakRemoved = State(initialValue: br)
        _otMultText = State(initialValue: otm)
    }

    private var resolvedOtMultiplierOverride: Double? {
        guard allowsOtMultiplierOverride else { return nil }
        let t = otMultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let normalized = t.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    private var probeBooking: Booking {
        OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: startText.trimmingCharacters(in: .whitespacesAndNewlines),
            workEndTime: endText.trimmingCharacters(in: .whitespacesAndNewlines),
            isBreakRemoved: breakRemoved,
            otMultiplierOverride: resolvedOtMultiplierOverride
        ).bookingProbe(operativeId: UUID(), projectId: UUID(), date: Date(), bookedBy: "")
    }

    private var breakdownPaidHours: Double {
        probeBooking.paidBookedHours(policy: policy)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.horizontal, 4)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("HOURS")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .tracking(0.4)
                            .padding(.leading, 4)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("START")
                                    .font(.system(size: 9))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                                TextField("HH:mm", text: $startText)
                                    .font(.system(size: 16, weight: .medium))
                                    .keyboardType(.numbersAndPunctuation)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(ProjectWorksRevampColors.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("END")
                                    .font(.system(size: 9))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                                TextField("HH:mm", text: $endText)
                                    .font(.system(size: 16, weight: .medium))
                                    .keyboardType(.numbersAndPunctuation)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(ProjectWorksRevampColors.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )

                    if allowsOtMultiplierOverride {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OVERTIME MULTIPLIER")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                                .tracking(0.4)
                                .padding(.leading, 4)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Optional — e.g. \(String(format: "%.1f", policy.weekdayOutsideStandardMultiplier))", text: $otMultText)
                                    .font(.system(size: 15, weight: .medium))
                                    .keyboardType(.decimalPad)
                                Text("Applies to hours outside \(policy.standardDayStart)–\(policy.standardDayEnd). Leave empty for organisation default.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                            }
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(breakRemoved ? Color(red: 0.949, green: 0.953, blue: 0.961) : Color(red: 0.98, green: 0.933, blue: 0.855))
                                    .frame(width: 32, height: 32)
                                Image(systemName: breakRemoved ? "cup.and.saucer.fill" : "cup.and.saucer.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(breakRemoved ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.upcomingAmber)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unpaid break")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                Text(breakRemoved ? "Removed · full elapsed hours paid" : "Deducted around midday (org default)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(breakRemoved ? ProjectWorksRevampColors.endDateFg : ProjectWorksRevampColors.muted)
                            }
                            Spacer()
                            Toggle("", isOn: $breakRemoved)
                                .labelsHidden()
                        }
                    }
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Breakdown")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1f", breakdownPaidHours) + "h paid")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        HStack {
                            Text("Elapsed")
                                .font(.system(size: 11))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                            Spacer()
                            Text(String(format: "%.1f", probeBooking.totalBookedHours(policy: policy)) + "h · 1×")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                        }
                        if !breakRemoved, policy.standardUnpaidBreakHours > 0.05 {
                            HStack {
                                Label("Less unpaid break", systemImage: "cup.and.saucer.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                Spacer()
                                Text("−\(String(format: "%.1f", policy.standardUnpaidBreakHours))h")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                            }
                        }
                        let otH = probeBooking.overtimeHoursBeyondPaidStandard(policy: policy)
                        if otH > 0.05 {
                            let mult = probeBooking.effectiveWeekdayOtMultiplier(policy: policy)
                            let multStr = abs(mult - mult.rounded()) < 0.05 ? String(format: "%.0f", mult) : String(format: "%.1f", mult)
                            HStack {
                                Text("Outside standard window")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                Spacer()
                                Text("\(String(format: "%.1f", otH))h × \(multStr)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )

                    if breakRemoved {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                            Text("Operative will be paid for the full elapsed hours. Make sure this is agreed.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.98, green: 0.933, blue: 0.855))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                            Text("Toggle break off for a working lunch or short shift.")
                                .font(.system(size: 10))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ProjectWorksRevampColors.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func validateAndSave() {
        errorMessage = nil
        let s = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = endText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sm = ManagerScheduleInterval.parseMinutes(s),
              let em = ManagerScheduleInterval.parseMinutes(e),
              em > sm else {
            errorMessage = "Enter valid times (HH:mm) with end after start."
            return
        }
        var otOut: Double? = nil
        if allowsOtMultiplierOverride {
            let raw = otMultText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                let normalized = raw.replacingOccurrences(of: ",", with: ".")
                guard let v = Double(normalized), v >= 1.0, v <= 10.0 else {
                    errorMessage = "OT multiplier must be a number between 1 and 10 (or leave blank for org default)."
                    return
                }
                otOut = v
            }
        }
        onSave(s, e, breakRemoved, otOut)
    }
}

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

