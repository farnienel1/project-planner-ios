//
//  OrganisationWorkingHoursView.swift
//  Project Planner
//
//  Edits organisations/{orgId}.payrollTimePolicy — weekday, Saturday, Sunday, save + schedule.
//

import SwiftUI

// MARK: - Palette (TSX reference)

private enum WorkingHoursPalette {
    static let canvas = PPColor.page
    static let cardBorder = ProjectWorksRevampColors.searchBorder
    static let ink = Color.primary
    static let muted = Color.secondary
    static let indigo = Color(red: 0.310, green: 0.275, blue: 0.898) // #4f46e5
    static let amber = Color(red: 0.851, green: 0.467, blue: 0.024) // #d97706
    static let rose = Color(red: 0.882, green: 0.114, blue: 0.282) // #e11d48
    static let indigoGradientTop = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.941, 0.992),
        dark: AppAdaptiveColor.rgb(0.145, 0.149, 0.259)
    )
    static let indigoGradientBottom = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.953, 0.910, 0.992),
        dark: AppAdaptiveColor.rgb(0.165, 0.133, 0.239)
    )
    static let amberGradientTop = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(1.0, 0.953, 0.878),
        dark: AppAdaptiveColor.rgb(0.239, 0.180, 0.090)
    )
    static let amberGradientBottom = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(1.0, 0.969, 0.929),
        dark: AppAdaptiveColor.rgb(0.220, 0.173, 0.110)
    )
    static let roseGradientTop = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(1.0, 0.894, 0.910),
        dark: AppAdaptiveColor.rgb(0.239, 0.125, 0.145)
    )
    static let roseGradientBottom = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(1.0, 0.941, 0.961),
        dark: AppAdaptiveColor.rgb(0.220, 0.133, 0.157)
    )
}

// MARK: - Main view

struct OrganisationWorkingHoursView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OrgPayrollTimePolicy.default
    @State private var baselineDraft = OrgPayrollTimePolicy.default
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingImmediateSaveWarning = false
    @State private var showingScheduleSheet = false
    @State private var showingCancelConfirm = false
    /// Date-picker value (device calendar, UI only); sent as that `YYYY-MM-DD` organisation day.
    @State private var scheduleEffectiveDate = Self.firstSchedulableDay
    @State private var saveSucceeded = false
    @State private var showingCancelScheduledConfirm = false
    /// RULEBOOK 1.19.0 §4.3 (two admins): the stored working-hours state this draft was taken from
    /// (`Organization.payrollPolicyStateJSON`). Every save is refused with `PAYROLL_POLICY_STALE_SAVE_MESSAGE` when the
    /// server's working hours moved since (`payrollTimePolicySaveConflict`).
    @State private var baseStateJSON: String?

    /// A scheduled change must start after today (`payrollTimePolicyScheduleDateError`).
    private static var firstSchedulableDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// `PAYROLL_POLICY_LIMITS` (break 0–120 min, paid and counts-as 1–12 h, multipliers ×1–×3).
    private var limits: CanonicalBusinessEngine.PayrollPolicyLimits? {
        CanonicalBusinessEngine.payrollPolicyLimits
    }

    /// RULEBOOK 1.20.0 §4.3: `validatePayrollTimePolicy(withDerivedWeekdayPaidHours(draft))` — the draft as it will be
    /// saved. Nil when the draft can be saved.
    private var validationMessage: String? {
        CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(draft, previous: baselineDraft)
    }

    /// RULEBOOK 1.20.0 §4.3 `weekdayPaidDayPreview(draft)` (memoised by the draft): the Monday–Friday paid day worked out
    /// from start, finish and the lunch break. Nil while the clock times are not valid.
    private var weekdayPreview: RulebookWeekdayPaidDayPreview? {
        guard dayTimelineValid else { return nil }
        return CanonicalBusinessEngine.weekdayPaidDayPreview(draft)
    }

    private var scheduledChange: OrgPayrollTimePolicyScheduledChange? {
        firebaseBackend.currentOrganization?.payrollTimePolicyScheduled
    }

    private var isDirty: Bool {
        draft != baselineDraft
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                introText
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if let scheduled = scheduledChange {
                    scheduledBanner(scheduled)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                if saveSucceeded {
                    successBanner
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                dayTimelineCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                weekAtAGlanceCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                weekdaySection
                    .padding(.horizontal, 16)
                    .padding(.top, 20)

                saturdaySection
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                sundaySection
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                } else if isDirty, let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .accessibilityIdentifier("organisationWorkingHours.validation")
                }

                Text("Changes apply to new timesheet entries from today. Existing approved timesheets aren't recalculated.")
                    .font(.caption)
                    .foregroundStyle(Color(.systemGray))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 100)
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if isDirty {
                        showingCancelConfirm = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                }
                    .accessibilityIdentifier("organisationWorkingHours.cancel")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Working hours")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Organisation default")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(PPColor.onNavySecondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .task { loadDraft() }
        .onChange(of: firebaseBackend.currentOrganization?.settings.payrollTimePolicy) { _, _ in
            // §4: keep an unsaved draft; follow the server only while nothing has been changed here.
            guard !isDirty, !isSaving else { return }
            loadDraft()
        }
        .onChange(of: firebaseBackend.currentOrganization?.payrollPolicyStateJSON) { _, _ in
            // 1.19.0: the base of the two-admin guard follows the server only while the draft is unchanged.
            guard !isDirty, !isSaving else { return }
            loadDraft()
        }
        .alert("Cancel scheduled change?", isPresented: $showingCancelScheduledConfirm) {
            Button("Keep", role: .cancel) {}
                .accessibilityIdentifier("organisationWorkingHours.keepScheduled")
            Button("Cancel change", role: .destructive) {
                Task { await cancelScheduledChange() }
            }
                .accessibilityIdentifier("organisationWorkingHours.confirmCancelScheduled")
        } message: {
            Text("The queued working hours will not take effect. The current working hours stay in place.")
        }
        .sheet(isPresented: $showingScheduleSheet) {
            scheduleChangeSheet
        }
        // RULEBOOK §4.3: apply from today (`payrollTimePolicyApplyNowWriteFields`) or schedule from a later
        // date (`payrollTimePolicyScheduleWriteFields`, the same sheet as the Schedule button).
        .alert("Apply changes today?", isPresented: $showingImmediateSaveWarning) {
            Button("Apply from today") {
                Task { await saveImmediately() }
            }
                .accessibilityIdentifier("organisationWorkingHours.applyFromToday")
            Button("Schedule for a later date") {
                // Open the sheet on the next turn, after the alert has gone.
                DispatchQueue.main.async {
                    showingScheduleSheet = true
                }
            }
                .accessibilityIdentifier("organisationWorkingHours.scheduleForLaterDate")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("organisationWorkingHours.cancelApply")
        } message: {
            Text("These hours will apply to today's bookings, timesheets, weekly report and invoices. To start on a later date, choose Schedule for a later date.")
        }
        .background(SettingsSwipeBackGuard(disabled: isDirty))
        .alert("Unsaved changes", isPresented: $showingCancelConfirm) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("organisationWorkingHours.keepEditing")
            Button("Continue") {
                draft = baselineDraft
                dismiss()
            }
                .accessibilityIdentifier("organisationWorkingHours.discard")
        } message: {
            Text("You have changes that have not been saved. Leave this page and discard them?")
        }
    }

    // MARK: - Intro & banners

    private var introText: some View {
        Text("These rules apply across the firm and decide how hours are costed on every timesheet — set the standard week, then how Saturday and Sunday are treated.")
            .font(.subheadline)
            .foregroundStyle(WorkingHoursPalette.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scheduledBanner(_ scheduled: OrgPayrollTimePolicyScheduledChange) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WorkingHoursPalette.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text("Scheduled change")
                    .font(.subheadline.weight(.semibold))
                Text("New working hours take effect on \(scheduled.effectiveFrom.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: OrganizationRulebookContext.timeZone))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel scheduled change") {
                    showingCancelScheduledConfirm = true
                }
                .accessibilityIdentifier("organisationWorkingHours.cancelScheduled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WorkingHoursPalette.rose)
                .disabled(isSaving)
                .onlineOnly(isOnline: smartCache.isOnline)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(WorkingHoursPalette.indigo.opacity(0.25), lineWidth: 1)
        )
    }

    private var successBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.063, green: 0.725, blue: 0.506))
            Text("Working hours saved. New bookings will use these rules.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ProjectWorksRevampColors.activeGreen)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProjectWorksRevampColors.successTint)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(red: 0.655, green: 0.949, blue: 0.839), lineWidth: 1)
        )
    }

    // MARK: - Week at a glance

    private var weekAtAGlanceCard: some View {
        workingHoursCard {
            Text("WEEK AT A GLANCE")
                .font(.caption.weight(.bold))
                .foregroundStyle(WorkingHoursPalette.muted)
                .tracking(1.2)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 10) {
                glanceRow(
                    label: "Mon–Fri",
                    color: WorkingHoursPalette.indigo,
                    text: "\(draft.standardDayStart)–\(draft.standardDayEnd)  ·  \(weekdayPreview.map { formatHoursDisplay($0.paidHours) } ?? "—") paid  ·  OT \(formatMultiplier(draft.weekdayOutsideStandardMultiplier))x"
                )
                glanceRow(
                    label: "Saturday",
                    color: WorkingHoursPalette.amber,
                    text: saturdayGlanceText
                )
                glanceRow(
                    label: "Sunday",
                    color: WorkingHoursPalette.rose,
                    text: sundayGlanceText
                )
            }
        }
    }

    private var saturdayGlanceText: String {
        let sat = draft.saturday
        if sat.allHoursAtMultiplierMode {
            return "Every hour worked  ·  \(formatMultiplier(sat.allHoursMultiplier))x\(lunchGlanceSuffix(sat))"
        }
        let start = sat.customStandardStart ?? draft.standardDayStart
        let end = sat.customStandardEnd ?? "13:00"
        let flat = sat.resolvedCountsAsHours(fallback: draft.standardPaidHours)
        return "\(start)–\(end)  ·  \(formatHoursDisplay(flat)) flat  ·  \(formatMultiplier(sat.outsideStandardWindowMultiplier))x\(lunchGlanceSuffix(sat))"
    }

    /// RULEBOOK 1.19.0: a weekend day whose own lunch break is unpaid (`breakPaid == false`).
    private func lunchGlanceSuffix(_ settings: OrgWeekendDayPayrollSettings) -> String {
        settings.breakPaid == false ? "  ·  unpaid lunch" : ""
    }

    private var sundayGlanceText: String {
        if draft.sundaySameAsSaturday {
            return "Same as Saturday"
        }
        let sun = draft.sunday
        if sun.allHoursAtMultiplierMode {
            return "Every hour worked  ·  \(formatMultiplier(sun.allHoursMultiplier))x\(lunchGlanceSuffix(sun))"
        }
        let start = sun.customStandardStart ?? draft.standardDayStart
        let end = sun.customStandardEnd ?? "13:00"
        let flat = sun.resolvedCountsAsHours(fallback: draft.standardPaidHours)
        return "\(start)–\(end)  ·  \(formatHoursDisplay(flat)) flat  ·  \(formatMultiplier(sun.outsideStandardWindowMultiplier))x\(lunchGlanceSuffix(sun))"
    }

    private func glanceRow(label: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(label)
                .font(.footnote.weight(.bold))
                .foregroundStyle(WorkingHoursPalette.ink)
                .frame(width: 64, alignment: .leading)
            Text(text)
                .font(.footnote)
                .foregroundStyle(WorkingHoursPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Weekday

    private var weekdaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(color: WorkingHoursPalette.indigo, title: "Monday – Friday · Standard day")

            workingHoursCard {
                HStack(spacing: 12) {
                    timeFieldColumn(label: "Day starts", text: $draft.standardDayStart)
                    timeFieldColumn(label: "Day ends", text: $draft.standardDayEnd)
                }

                cardDivider

                // RULEBOOK 1.20.0 §4.3: no paid-hours box Monday–Friday — the paid day is start, finish and the lunch break.
                weekdayPaidDayLine

                cardDivider

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lunch break")
                            .font(.body.weight(.semibold))
                        Text(draft.breakPaid
                             ? "Paid — counts toward hours worked"
                             : "Unpaid — deducted from paid hours")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    WorkingHoursSegmentedPicker(
                        selection: Binding(
                            get: { draft.breakPaid ? 1 : 0 },
                            set: { draft.breakPaid = $0 == 1 }
                        ),
                        options: [(0, "Unpaid"), (1, "Paid")]
                    )
                    .frame(maxWidth: 160)
                }

                breakLengthRow(label: "Break length", minutes: $draft.unpaidBreakMinutes)

                // The firm sets the break window; it is never moved for them (1.20.0).
                HStack(spacing: 12) {
                    timeFieldColumn(label: "Break starts", text: $draft.breakWindowStart, isBreakTime: true)
                    timeFieldColumn(label: "Break ends", text: $draft.breakWindowEnd, isBreakTime: true)
                }

                cardDivider

                multiplierRow(
                    title: "Overtime multiplier",
                    subtitle: "Any Mon–Fri time worked before \(draft.standardDayStart) or after \(draft.standardDayEnd)",
                    value: $draft.weekdayOutsideStandardMultiplier,
                    accent: WorkingHoursPalette.indigo
                )
            }
        }
    }

    /// RULEBOOK 1.20.0 §4.3 (web `WeekdayPaidDayLine`): "06:30–14:30 = 8h − 45 min unpaid break = 7h15m".
    private var weekdayPaidDayLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paid hours for a full day")
                .font(.body.weight(.semibold))
            Text(weekdayPreview?.line ?? "Enter valid 24h times to see the paid day.")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(WorkingHoursPalette.ink)
                .accessibilityIdentifier("weekday-paid-day")
            Text("Worked out from the start, finish and lunch break.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayTimelineValid: Bool {
        isValidHM(draft.standardDayStart)
            && isValidHM(draft.standardDayEnd)
            && isValidHM(draft.breakWindowStart)
            && isValidHM(draft.breakWindowEnd)
            && (ManagerScheduleInterval.parseMinutes(draft.standardDayEnd) ?? 0)
                > (ManagerScheduleInterval.parseMinutes(draft.standardDayStart) ?? 0)
    }

    private var dayTimelineCard: some View {
        workingHoursCard {
            if dayTimelineValid {
                WorkingHoursDayTimeline(
                    dayStart: draft.standardDayStart,
                    dayEnd: draft.standardDayEnd,
                    breakStart: draft.breakWindowStart,
                    breakEnd: draft.breakWindowEnd
                )
                HStack {
                    Text("05:00")
                    Spacer(minLength: 0)
                    Text("09:00")
                    Spacer(minLength: 0)
                    Text("13:00")
                    Spacer(minLength: 0)
                    Text("17:00")
                    Spacer(minLength: 0)
                    Text("21:00")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(WorkingHoursPalette.muted)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    dayLegendRow(color: WorkingHoursPalette.indigo, text: "Standard day \(draft.standardDayStart)–\(draft.standardDayEnd)")
                    dayLegendRow(
                        color: WorkingHoursPalette.cardBorder,
                        text: "\(draft.breakPaid ? "Paid" : "Unpaid") break \(draft.unpaidBreakMinutes) min (\(draft.breakWindowStart)–\(draft.breakWindowEnd))"
                    )
                    dayLegendRow(
                        color: WorkingHoursPalette.amber,
                        text: "Overtime ×\(formatMultiplier(draft.weekdayOutsideStandardMultiplier))"
                    )
                }
                .padding(.top, 8)
            } else {
                Text("Enter valid 24h times to see the day.")
                    .font(.subheadline)
                    .foregroundStyle(WorkingHoursPalette.muted)
            }
        }
    }

    private func dayLegendRow(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.footnote)
                .foregroundStyle(WorkingHoursPalette.ink)
        }
    }

    private func setWeekendMode(keyPath: WritableKeyPath<OrgPayrollTimePolicy, OrgWeekendDayPayrollSettings>, allHours: Bool) {
        var settings = draft[keyPath: keyPath]
        if allHours {
            settings.allHoursAtMultiplierMode = true
        } else {
            settings.allHoursAtMultiplierMode = false
            settings.useCustomStandardDayWindow = true
            if settings.customStandardStart == nil { settings.customStandardStart = draft.standardDayStart }
            if settings.customStandardEnd == nil { settings.customStandardEnd = "13:00" }
            if settings.countsAsHours == nil { settings.countsAsHours = draft.standardPaidHours }
        }
        draft[keyPath: keyPath] = settings
    }

    // MARK: - Saturday

    private var saturdaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(color: WorkingHoursPalette.amber, title: "Saturday")

            workingHoursCard {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(WorkingHoursPalette.amber.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: "clock")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WorkingHoursPalette.amber)
                    }
                    Text("Choose how a Saturday shift is paid — a fixed-length day on a defined window, or every hour worked at the multiplier.")
                        .font(.subheadline)
                        .foregroundStyle(Color(.systemGray))
                        .fixedSize(horizontal: false, vertical: true)
                }

                WorkingHoursSegmentedPicker(
                    selection: Binding(
                        get: { draft.saturday.allHoursAtMultiplierMode ? 0 : 1 },
                        set: { mode in
                            setWeekendMode(keyPath: \.saturday, allHours: mode == 0)
                        }
                    ),
                    options: [(0, "All hours at one rate"), (1, "Standard window + overtime")]
                )

                if draft.saturday.allHoursAtMultiplierMode {
                    saturdayAllHoursContent(settings: $draft.saturday)
                } else {
                    saturdayWindowContent(settings: $draft.saturday, title: "Saturday")
                }

                cardDivider
                weekendLunchBreakContent(keyPath: \.saturday, day: .saturday, accent: WorkingHoursPalette.amber)
                cardDivider
                WorkingHoursWeekendPreview(policy: draft, day: .saturday, accent: WorkingHoursPalette.amber)
            }
        }
    }

    @ViewBuilder
    private func saturdayWindowContent(settings: Binding<OrgWeekendDayPayrollSettings>, title: String) -> some View {
        HStack(spacing: 12) {
            timeFieldColumn(label: "Window start", text: Binding(
                get: { settings.wrappedValue.customStandardStart ?? "" },
                set: { settings.wrappedValue.customStandardStart = $0.isEmpty ? nil : $0 }
            ))
            timeFieldColumn(label: "Window end", text: Binding(
                get: { settings.wrappedValue.customStandardEnd ?? "" },
                set: { settings.wrappedValue.customStandardEnd = $0.isEmpty ? nil : $0 }
            ))
        }

        tintedInfoBox(
            text: settings.wrappedValue.breakPaid == false
                ? "A shift covering \(settings.wrappedValue.customStandardStart ?? draft.standardDayStart)–\(settings.wrappedValue.customStandardEnd ?? "13:00") (\(formatHoursDisplay(saturdayWindowSpanHours(settings.wrappedValue)))) is paid as a flat day, less the unpaid lunch break it covers — set how many hours that day counts as below."
                : "A shift covering \(settings.wrappedValue.customStandardStart ?? draft.standardDayStart)–\(settings.wrappedValue.customStandardEnd ?? "13:00") (\(formatHoursDisplay(saturdayWindowSpanHours(settings.wrappedValue)))) is simply paid as a flat day — set how many hours that day counts as below.",
            tint: WorkingHoursPalette.amber
        )

        stepperRow(
            label: "Counts as",
            value: Binding(
                get: { settings.wrappedValue.resolvedCountsAsHours(fallback: draft.standardPaidHours) },
                set: { settings.wrappedValue.countsAsHours = $0 }
            ),
            step: 0.5,
            min: limits?.paidHours.min ?? 1,
            max: limits?.paidHours.max ?? 12,
            suffix: "h"
        )

        multiplierRow(
            title: "Rate outside the window",
            subtitle: "Hours inside the window count as standard hours.",
            value: Binding(
                get: { settings.wrappedValue.outsideStandardWindowMultiplier },
                set: { settings.wrappedValue.outsideStandardWindowMultiplier = $0 }
            ),
            accent: WorkingHoursPalette.amber
        )

        if let start = settings.wrappedValue.customStandardStart,
           let end = settings.wrappedValue.customStandardEnd {
            WorkingHoursTimelineBar(
                windowStart: start,
                windowEnd: end,
                breakStart: nil,
                breakEnd: nil,
                accentColor: WorkingHoursPalette.amber,
                axisStartMinutes: 6 * 60,
                axisEndMinutes: 18 * 60
            )
            .frame(height: 7)
        }

        gradientSummaryCard(
            topColor: WorkingHoursPalette.amberGradientTop,
            bottomColor: WorkingHoursPalette.amberGradientBottom,
            rows: [],
            footerLabel: "A \(settings.wrappedValue.customStandardStart ?? draft.standardDayStart)–\(settings.wrappedValue.customStandardEnd ?? "13:00") \(title) pays",
            footerValue: "\(formatHoursDisplay(settings.wrappedValue.resolvedCountsAsHours(fallback: draft.standardPaidHours))) @ 1x",
            accent: WorkingHoursPalette.amber
        )
    }

    @ViewBuilder
    private func saturdayAllHoursContent(settings: Binding<OrgWeekendDayPayrollSettings>) -> some View {
        multiplierRow(
            title: "Multiplier on every hour",
            subtitle: nil,
            value: Binding(
                get: { settings.wrappedValue.allHoursMultiplier },
                set: { settings.wrappedValue.allHoursMultiplier = $0 }
            ),
            accent: WorkingHoursPalette.amber
        )

        tintedInfoBox(
            text: settings.wrappedValue.breakPaid == false
                ? "No fixed window — the hours booked on a Saturday, less the unpaid lunch break, are paid at \(formatMultiplier(settings.wrappedValue.allHoursMultiplier))x."
                : "No fixed window — whatever hours are booked on a Saturday are paid at \(formatMultiplier(settings.wrappedValue.allHoursMultiplier))x.",
            tint: WorkingHoursPalette.amber
        )
    }

    // MARK: - Weekend lunch break (RULEBOOK 1.19.0 §4.3)

    /// That day's break as the rule reads it (`weekendBreakFor`: each missing field the weekday break). The controls show
    /// it, so an untouched day is prefilled from the weekday lunch and stays unset until changed.
    private func weekendBreak(_ day: RulebookWeekendDay) -> RulebookWeekendBreak {
        CanonicalBusinessEngine.weekendBreakFor(policy: draft, weekday: day)
            ?? RulebookWeekendBreak(paid: true, minutes: draft.unpaidBreakMinutes, start: draft.breakWindowStart, end: draft.breakWindowEnd)
    }

    @ViewBuilder
    private func weekendLunchBreakContent(
        keyPath: WritableKeyPath<OrgPayrollTimePolicy, OrgWeekendDayPayrollSettings>,
        day: RulebookWeekendDay,
        accent: Color
    ) -> some View {
        let current = weekendBreak(day)
        let copy = CanonicalBusinessEngine.weekendLunchBreakCopy(policy: draft, weekday: day)
        let name = day == .saturday ? "Saturday" : "Sunday"
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(copy?.title ?? "Lunch break on \(name)")
                    .font(.body.weight(.semibold))
                if let detail = copy?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            WorkingHoursSegmentedPicker(
                selection: Binding(
                    get: { current.paid ? 1 : 0 },
                    set: { draft[keyPath: keyPath].breakPaid = $0 == 1 }
                ),
                options: [(1, "Paid"), (0, "Unpaid")]
            )
            .frame(maxWidth: 160)
            .accessibilityIdentifier("organisationWorkingHours.\(day.rawValue).lunchPaid")
        }

        breakLengthRow(label: "\(name) break length", minutes: Binding(
            get: { current.minutes },
            set: { draft[keyPath: keyPath].breakMinutes = $0 }
        ))

        HStack(spacing: 12) {
            timeFieldColumn(label: "Break start", text: Binding(
                get: { current.start },
                set: { draft[keyPath: keyPath].breakWindowStart = $0.isEmpty ? nil : $0 }
            ), isBreakTime: true)
            timeFieldColumn(label: "Break end", text: Binding(
                get: { current.end },
                set: { draft[keyPath: keyPath].breakWindowEnd = $0.isEmpty ? nil : $0 }
            ), isBreakTime: true)
        }
        .tint(accent)
    }

    // MARK: - Sunday

    private var sundaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(color: WorkingHoursPalette.rose, title: "Sunday")

            workingHoursCard {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(WorkingHoursPalette.rose.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: "sun.max")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WorkingHoursPalette.rose)
                    }
                    Text("Sunday is usually the simplest rule of the week — most firms either pay every hour at a flat multiplier, or pay a fixed day regardless of hours worked.")
                        .font(.subheadline)
                        .foregroundStyle(Color(.systemGray))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Same setup as Saturday")
                            .font(.body.weight(.semibold))
                        Text("Mirror Saturday's pay rules on Sunday")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    WorkingHoursToggle(isOn: Binding(
                        get: { draft.sundaySameAsSaturday },
                        set: { same in
                            // RULEBOOK 1.19.0 §4.3: "Sunday same as Saturday" copies Saturday's rules, lunch break
                            // included (web `patchWeekend('sunday', { ...draft.saturday, sameAsSaturday: true })`).
                            if same { draft.sunday = draft.saturday }
                            draft.sundaySameAsSaturday = same
                        }
                    ))
                }

                if draft.sundaySameAsSaturday {
                    tintedInfoBox(
                        text: "Sunday uses Saturday's rules for payroll and scheduling.",
                        tint: WorkingHoursPalette.rose
                    )
                } else {
                    WorkingHoursSegmentedPicker(
                        selection: Binding(
                            get: { draft.sunday.allHoursAtMultiplierMode ? 0 : 1 },
                            set: { mode in
                                setWeekendMode(keyPath: \.sunday, allHours: mode == 0)
                            }
                        ),
                        options: [(0, "All hours at one rate"), (1, "Standard window + overtime")]
                    )

                    if draft.sunday.allHoursAtMultiplierMode {
                        sundayAllHoursContent(settings: $draft.sunday)
                    } else {
                        saturdayWindowContent(settings: $draft.sunday, title: "Sunday")
                    }

                    cardDivider
                    weekendLunchBreakContent(keyPath: \.sunday, day: .sunday, accent: WorkingHoursPalette.rose)
                }

                cardDivider
                WorkingHoursWeekendPreview(policy: draft, day: .sunday, accent: WorkingHoursPalette.rose)
            }
        }
    }

    @ViewBuilder
    private func sundayAllHoursContent(settings: Binding<OrgWeekendDayPayrollSettings>) -> some View {
        multiplierRow(
            title: "Multiplier on every hour worked",
            subtitle: settings.wrappedValue.breakPaid == false ? "Hours worked less the unpaid lunch break" : "Every hour worked",
            value: Binding(
                get: { settings.wrappedValue.allHoursMultiplier },
                set: { settings.wrappedValue.allHoursMultiplier = $0 }
            ),
            accent: WorkingHoursPalette.rose
        )
    }

    // MARK: - Bottom bar

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    showingImmediateSaveWarning = true
                } label: {
                    Group {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Save")
                                .font(.body.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .accessibilityIdentifier("organisationWorkingHours.save")
                .buttonStyle(.plain)
                .foregroundStyle(isDirty ? Color.white : WorkingHoursPalette.muted)
                .background(isDirty ? WorkingHoursPalette.indigo : ProjectWorksRevampColors.disabledFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: isDirty ? WorkingHoursPalette.indigo.opacity(0.25) : .clear, radius: 4, y: 2)
                .disabled(!isDirty || !isFormValid || isSaving)
                .opacity((!isDirty || !isFormValid || isSaving) ? 0.85 : 1)
                .onlineOnly(isOnline: smartCache.isOnline, showsMessage: false)

                Button {
                    showingScheduleSheet = true
                } label: {
                    Text("Schedule")
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .accessibilityIdentifier("organisationWorkingHours.schedule")
                .buttonStyle(.plain)
                .foregroundStyle(WorkingHoursPalette.indigo)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(WorkingHoursPalette.indigo.opacity(0.35), lineWidth: 1)
                )
                .disabled(!isFormValid || isSaving)
                .opacity(!isFormValid || isSaving ? 0.55 : 1)
                .onlineOnly(isOnline: smartCache.isOnline, showsMessage: false)

                Button {
                    clearDraft()
                } label: {
                    Text("Clear")
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .accessibilityIdentifier("organisationWorkingHours.clear")
                .buttonStyle(.plain)
                .foregroundStyle(WorkingHoursPalette.muted)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(WorkingHoursPalette.cardBorder, lineWidth: 1)
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            if !smartCache.isOnline {
                // RULEBOOK §2: Save and Schedule are online only.
                Label(OfflinePolicy.onlineOnlyMessage, systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
                    .accessibilityIdentifier("offlinePolicy.onlineOnlyMessage")
            }
        }
    }

    // MARK: - Shared layout helpers

    private func workingHoursCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .padding(16)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func sectionLabel(color: Color, title: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(WorkingHoursPalette.muted)
                .tracking(1.1)
        }
        .padding(.bottom, 2)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(ProjectWorksRevampColors.wellFill)
            .frame(height: 1)
    }

    private func timeFieldColumn(label: String, text: Binding<String>, isBreakTime: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WorkingHoursPalette.muted)
            WorkingHoursTimeField(text: text, isBreakTime: isBreakTime)
        }
        .frame(maxWidth: .infinity)
    }

    /// RULEBOOK 1.20.3 §4.3: break length in `PAYROLL_BREAK_TIME_STEP_MINUTES` (15) steps within
    /// `PAYROLL_POLICY_LIMITS.breakMinutes` (0, 15, 30, 45 … 120); a saved length off the step
    /// (`payrollBreakMinutesOnStep` false, e.g. 20) is kept and listed as "(saved)" until changed.
    private func breakLengthRow(label: String, minutes: Binding<Int>) -> some View {
        let low = Int(limits?.breakMinutes.min ?? 0)
        let high = Int(limits?.breakMinutes.max ?? 120)
        let choices = Array(stride(from: low, through: high, by: max(1, CanonicalBusinessEngine.payrollBreakTimeStepMinutes)))
        let saved = CanonicalBusinessEngine.payrollBreakMinutesOnStep(minutes.wrappedValue) ? nil : minutes.wrappedValue
        return HStack {
            Text(label)
                .font(.subheadline.weight(.medium))
            Spacer()
            Menu {
                if let saved {
                    Button("\(saved) min (saved)") { minutes.wrappedValue = saved }
                }
                ForEach(choices, id: \.self) { value in
                    Button("\(value) min") { minutes.wrappedValue = value }
                }
            } label: {
                Text(saved == nil ? "\(minutes.wrappedValue) min" : "\(minutes.wrappedValue) min (saved)")
                    .font(.body.weight(.bold))
                    .monospacedDigit()
            }
            .accessibilityIdentifier("organisationWorkingHours.breakLength")
        }
    }

    private func stepperRow(label: String, value: Binding<Double>, step: Double, min: Double, max: Double, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WorkingHoursPalette.muted)
            Spacer()
            WorkingHoursStepper(value: value, step: step, min: min, max: max, suffix: suffix)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ProjectWorksRevampColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ProjectWorksRevampColors.wellFill, lineWidth: 1)
        )
    }

    private func multiplierRow(title: String, subtitle: String?, value: Binding<Double>, accent: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            WorkingHoursMultiplierField(value: value, accent: accent)
        }
    }

    private func tintedInfoBox(text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("ⓘ")
                .font(.subheadline)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(tint.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.15), lineWidth: 1)
        )
    }

    private func gradientSummaryCard(
        topColor: Color,
        bottomColor: Color,
        rows: [(String, String, Bool)],
        footerLabel: String,
        footerValue: String,
        accent: Color
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.0)
                        .font(.subheadline)
                        .foregroundStyle(WorkingHoursPalette.muted)
                    Spacer()
                    Text(row.1)
                        .font(.body.weight(.bold))
                        .foregroundStyle(WorkingHoursPalette.ink)
                }
                .padding(.vertical, 10)
                if index < rows.count - 1 {
                    Divider().opacity(0.5)
                }
            }
            if !rows.isEmpty {
                Divider().opacity(0.5)
            }
            HStack {
                Text(footerLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.opacity(0.9))
                Spacer()
                Text(footerValue)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(accent)
            }
            .padding(.top, rows.isEmpty ? 0 : 10)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [topColor, bottomColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Schedule sheet

    private var scheduleChangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Effective from",
                    selection: $scheduleEffectiveDate,
                    in: Self.firstSchedulableDay...,
                    displayedComponents: .date
                )
                    .accessibilityIdentifier("organisationWorkingHours.effectiveFrom")
                Section {
                    Text("Bookings before this date keep the current working hours. From this date onward, these draft settings apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Schedule change")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingScheduleSheet = false }
                        .accessibilityIdentifier("organisationWorkingHours.cancel2")
                        .tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        Task { await saveScheduled() }
                    }
                    .accessibilityIdentifier("organisationWorkingHours.schedule2")
                    .font(.body.weight(.semibold))
                    .tint(.white)
                    .disabled(!isFormValid || isSaving)
                    .onlineOnly(isOnline: smartCache.isOnline, showsMessage: false)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Data

    private func loadDraft() {
        var loaded = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        loaded = sanitizePolicy(loaded)
        draft = loaded
        baselineDraft = loaded
        baseStateJSON = firebaseBackend.currentOrganization?.payrollPolicyStateJSON
        // RULEBOOK 1.20.0: the firm's break window is loaded as saved (no auto-centring), so an unchanged draft is clean.
    }

    private func sanitizePolicy(_ policy: OrgPayrollTimePolicy) -> OrgPayrollTimePolicy {
        var out = policy
        if !isValidHM(out.standardDayStart) {
            out.standardDayStart = OrgPayrollTimePolicy.default.standardDayStart
        }
        if !isValidHM(out.standardDayEnd) {
            out.standardDayEnd = OrgPayrollTimePolicy.default.standardDayEnd
        }
        let breakLimits = limits?.breakMinutes
        let paidLimits = limits?.paidHours
        out.unpaidBreakMinutes = Swift.max(Int(breakLimits?.min ?? 0), Swift.min(Int(breakLimits?.max ?? 120), out.unpaidBreakMinutes))
        out.standardPaidHours = Swift.max(paidLimits?.min ?? 1, Swift.min(paidLimits?.max ?? 12, out.standardPaidHours))
        out.weekdayOutsideStandardMultiplier = clampMultiplier(out.weekdayOutsideStandardMultiplier)
        out.saturday = sanitizeWeekendSettings(out.saturday, fallbackPaid: out.standardPaidHours)
        out.sunday = sanitizeWeekendSettings(out.sunday, fallbackPaid: out.standardPaidHours)
        return out
    }

    private func sanitizeWeekendSettings(_ settings: OrgWeekendDayPayrollSettings, fallbackPaid: Double) -> OrgWeekendDayPayrollSettings {
        var out = settings
        out.allHoursMultiplier = clampMultiplier(out.allHoursMultiplier)
        out.outsideStandardWindowMultiplier = clampMultiplier(out.outsideStandardWindowMultiplier)
        if let start = out.customStandardStart, !isValidHM(start) { out.customStandardStart = nil }
        if let end = out.customStandardEnd, !isValidHM(end) { out.customStandardEnd = nil }
        if let minutes = out.breakMinutes {
            out.breakMinutes = Swift.max(Int(limits?.breakMinutes.min ?? 0), Swift.min(Int(limits?.breakMinutes.max ?? 120), minutes))
        }
        if let start = out.breakWindowStart, !isValidHM(start) { out.breakWindowStart = nil }
        if let end = out.breakWindowEnd, !isValidHM(end) { out.breakWindowEnd = nil }
        if let counts = out.countsAsHours {
            out.countsAsHours = Swift.max(limits?.paidHours.min ?? 1, Swift.min(limits?.paidHours.max ?? 12, counts))
        }
        if !out.allHoursAtMultiplierMode,
           out.customStandardStart == nil,
           out.customStandardEnd == nil {
            out.customStandardStart = OrgPayrollTimePolicy.default.standardDayStart
            out.customStandardEnd = "13:00"
            out.countsAsHours = out.countsAsHours ?? fallbackPaid
        }
        return out
    }

    private func clampMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return 1.5 }
        return Swift.max(limits?.multiplier.min ?? 1, Swift.min(limits?.multiplier.max ?? 3, value))
    }

    private func clearDraft() {
        draft = baselineDraft
        saveSucceeded = false
        errorMessage = nil
    }

    private func saveImmediately() async {
        guard isFormValid else { return }
        isSaving = true
        errorMessage = nil
        saveSucceeded = false
        // RULEBOOK 1.19.0 §4.3/§8: a working-hours change never rewrites stored bookings or signed sheets. Each day is
        // priced under the policy in effect on it (history first), so today's bookings are not re-timed here (the
        // former `PayrollPolicyBookingRecalibrator` pass rewrote them, which web never does).
        do {
            try await firebaseBackend.applyOrganizationPayrollTimePolicyImmediately(draft, baseStateJSON: baseStateJSON, previous: baselineDraft)
            await MainActor.run {
                isSaving = false
                baselineDraft = draft
                saveSucceeded = true
                // Saved: back to the previous screen.
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveScheduled() async {
        guard isFormValid else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await firebaseBackend.scheduleOrganizationPayrollTimePolicyChange(
                draft,
                effectiveFrom: scheduleEffectiveDate,
                baseStateJSON: baseStateJSON,
                previous: baselineDraft
            )
            await MainActor.run {
                isSaving = false
                baselineDraft = draft
                showingScheduleSheet = false
                saveSucceeded = true
            }
            // Let the sheet close, then go back to the previous screen.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Online, after confirmation: `payrollTimePolicyCancelScheduleWriteFields` on the server document.
    private func cancelScheduledChange() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await firebaseBackend.cancelScheduledOrganizationPayrollTimePolicyChange(
                baseStateJSON: firebaseBackend.currentOrganization?.payrollPolicyStateJSON
            )
            isSaving = false
            if !isDirty { loadDraft() }
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Validation & helpers

    private func saturdayWindowSpanHours(_ settings: OrgWeekendDayPayrollSettings) -> Double {
        guard let s = settings.customStandardStart,
              let e = settings.customStandardEnd,
              let sm = ManagerScheduleInterval.parseMinutes(s),
              let em = ManagerScheduleInterval.parseMinutes(e),
              em > sm else { return 0 }
        return Double(em - sm) / 60.0
    }

    /// `validatePayrollTimePolicy` (rulebook limits and clock checks).
    private var isFormValid: Bool {
        validationMessage == nil
    }

    private func isValidHM(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = trimmed.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) else { return false }
        guard r.lowerBound == trimmed.startIndex && r.upperBound == trimmed.endIndex else { return false }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return false }
        return h >= 0 && h < 24 && m >= 0 && m < 60
    }

    private func formatHoursDisplay(_ hours: Double) -> String {
        let sign = hours < 0 ? "-" : ""
        let abs = abs(hours)
        let whole = Int(abs)
        let frac = Int(round((abs - Double(whole)) * 60))
        if frac == 0 { return "\(sign)\(whole)h" }
        return "\(sign)\(whole)h \(frac)m"
    }

    private func formatMultiplier(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - Weekend live calculation (RULEBOOK 1.19.0 §4.3, web `WeekendDayPreview`)

/// One weekend day's preview for a draft policy: the example span, the bands and the per-day rows. Memoised by the
/// draft so a redraw never runs the script again.
nonisolated private struct WorkingHoursWeekendPreviewModel: Sendable {
    let summary: String
    let title: String
    let rows: [RulebookBookingDayBreakdownRow]

    nonisolated struct Key: Hashable, Sendable {
        let policy: OrgPayrollTimePolicy
        let day: String
    }

    private static let memo = RulebookAnswerMemo<Key, WorkingHoursWeekendPreviewModel>(limit: 64)
    /// Web reads its fixed preview days (`WEEKEND_PREVIEW_DAY_KEYS`) in Europe/London.
    private static let previewZone = "Europe/London"

    /// RULEBOOK 1.20.3 `weekendDayPreview(draft, weekday, timeZone)`: the example hours, the summary (break, minutes
    /// taken off, paid hours) and the rows — all from the script, from the draft, so Paid / Unpaid, length and times
    /// change it at once. Read in Europe/London as web does (only the weekday matters).
    @MainActor static func make(policy: OrgPayrollTimePolicy, day: RulebookWeekendDay) -> WorkingHoursWeekendPreviewModel? {
        memo.value(for: Key(policy: policy, day: day.rawValue)) {
            guard let preview = CanonicalBusinessEngine.weekendDayPreview(
                policy: policy, weekday: day.rawValue, timeZone: previewZone
            ), !preview.rows.isEmpty else { return nil }
            let name = day == .saturday ? "Saturday" : "Sunday"
            return WorkingHoursWeekendPreviewModel(
                summary: preview.summary,
                title: "\(name) example · \(preview.start)–\(preview.end)",
                rows: preview.rows
            )
        }
    }
}

/// The live calculation under Saturday and Sunday, as Monday–Friday has. No figure is computed here.
private struct WorkingHoursWeekendPreview: View {
    let policy: OrgPayrollTimePolicy
    let day: RulebookWeekendDay
    let accent: Color

    var body: some View {
        if let model = WorkingHoursWeekendPreviewModel.make(policy: policy, day: day) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.summary)
                    .font(.footnote)
                    .foregroundStyle(WorkingHoursPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .tracking(0.8)
                    ForEach(model.rows) { row in
                        if row.lines.isEmpty {
                            Text(row.line)
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                        } else {
                            ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                                HStack {
                                    Text(line.label)
                                        .font(line.kind == "total" ? .subheadline.weight(.semibold) : .subheadline)
                                        .foregroundStyle(line.kind == "total" ? accent : WorkingHoursPalette.muted)
                                    Spacer()
                                    Text(line.value)
                                        .font(line.kind == "total" ? .body.weight(.heavy) : .body.weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(line.kind == "total" ? accent : WorkingHoursPalette.ink)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("organisationWorkingHours.\(day.rawValue).preview")
        }
    }
}

// MARK: - Reusable controls

private struct WorkingHoursSegmentedPicker: View {
    let selection: Binding<Int>
    let options: [(Int, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button {
                    selection.wrappedValue = option.0
                } label: {
                    Text(option.1)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selection.wrappedValue == option.0 ? Color(.systemBackground) : Color.clear)
                        .foregroundStyle(selection.wrappedValue == option.0 ? Color.primary : Color(.systemGray))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: selection.wrappedValue == option.0 ? Color.black.opacity(0.06) : .clear, radius: 2, y: 1)
                }
                .accessibilityIdentifier("workingHoursSegmentedPicker.row.\(option)")
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(ProjectWorksRevampColors.wellFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct WorkingHoursToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? WorkingHoursPalette.indigo : Color(.systemGray3))
                    .frame(width: 46, height: 27)
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
                    .frame(width: 23, height: 23)
                    .padding(2)
            }
        }
        .accessibilityIdentifier("workingHoursToggle.button")
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }
}

private struct WorkingHoursStepper: View {
    @Binding var value: Double
    let step: Double
    let min: Double
    let max: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 0) {
            Button {
                value = Swift.max(min, roundedStep(value - step, step: step))
            } label: {
                Text("–")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("workingHoursStepper.button")
            .buttonStyle(.plain)

            Text(displayValue)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 52)

            Button {
                value = Swift.min(max, roundedStep(value + step, step: step))
            } label: {
                Text("+")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("workingHoursStepper.button2")
            .buttonStyle(.plain)
        }
        .background(ProjectWorksRevampColors.wellFill)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var displayValue: String {
        if suffix == " min" {
            return "\(Int(value))\(suffix)"
        }
        if abs(value - value.rounded()) < 0.05 {
            return "\(Int(value))\(suffix)"
        }
        return String(format: "%.1f%@", value, suffix)
    }

    private func roundedStep(_ raw: Double, step: Double) -> Double {
        guard step > 0 else { return raw }
        return (raw / step).rounded() * step
    }
}

private struct WorkingHoursMultiplierField: View {
    @Binding var value: Double
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            TextField("×", value: $value, format: .number)
                .accessibilityIdentifier("workingHoursMultiplierField.textField")
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.body.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 56)
                .padding(.vertical, 8)
                .background(ProjectWorksRevampColors.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(WorkingHoursPalette.cardBorder, lineWidth: 1)
                )
            Text("x")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(red: 0.580, green: 0.639, blue: 0.722))
        }
    }
}

/// RULEBOOK 1.20.2 / 1.20.3 §4.3: day start and finish (weekday and weekend windows) are picked on the 30-minute step
/// (`PAYROLL_POLICY_TIME_STEP_MINUTES`, `payrollPolicyTimeOnStep`); lunch-break start and end on the 15-minute step
/// (`PAYROLL_BREAK_TIME_STEP_MINUTES`, `payrollBreakTimeOnStep`), e.g. 10:00–10:45. A time saved off its step is kept
/// and listed as "07:45 (saved)" until changed; `validatePayrollTimePolicy(policy, previous)` refuses it only then.
private struct WorkingHoursTimeField: View {
    @Binding var text: String
    /// A lunch-break start / end (15-minute step) rather than a day start / finish (30-minute step).
    var isBreakTime: Bool = false

    private var step: Int {
        isBreakTime ? CanonicalBusinessEngine.payrollBreakTimeStepMinutes : CanonicalBusinessEngine.payrollPolicyTimeStepMinutes
    }

    private var stepTimes: [String] {
        stride(from: 0, to: 24 * 60, by: max(1, step)).map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }

    /// The picker only offers on-step times, so a current value off this field's step is the saved one.
    private var offStepSaved: String? {
        guard !text.isEmpty else { return nil }
        let onStep = isBreakTime
            ? CanonicalBusinessEngine.payrollBreakTimeOnStep(text)
            : CanonicalBusinessEngine.payrollPolicyTimeOnStep(text)
        return onStep ? nil : text
    }

    private var label: String {
        guard !text.isEmpty else { return "—" }
        return text == offStepSaved ? "\(text) (saved)" : text
    }

    var body: some View {
        Menu {
            if let offStepSaved {
                Button("\(offStepSaved) (saved)") { text = offStepSaved }
            }
            ForEach(stepTimes, id: \.self) { time in
                Button(time) { text = time }
            }
        } label: {
            HStack {
                Text(label)
                    .font(.body.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(WorkingHoursPalette.ink)
                    .frame(maxWidth: .infinity)
                Image(systemName: "clock")
                    .font(.subheadline)
                    .foregroundStyle(Color(.systemGray3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ProjectWorksRevampColors.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(WorkingHoursPalette.cardBorder, lineWidth: 1)
            )
        }
        .accessibilityIdentifier("workingHoursTimeField.n0730")
    }
}

/// Mon–Fri day from 05:00 to 21:00: overtime behind, the standard window, then the unpaid break.
private struct WorkingHoursDayTimeline: View {
    let dayStart: String
    let dayEnd: String
    let breakStart: String
    let breakEnd: String

    private let from = 5 * 60
    private let to = 21 * 60

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let span = CGFloat(max(1, to - from))
            let xPos: (Int) -> CGFloat = { minutes in
                let clipped = min(to, max(from, minutes))
                return CGFloat(clipped - from) / span * width
            }
            let start = ManagerScheduleInterval.parseMinutes(dayStart) ?? from
            let end = ManagerScheduleInterval.parseMinutes(dayEnd) ?? to
            let breakFrom = ManagerScheduleInterval.parseMinutes(breakStart) ?? start
            let breakTo = ManagerScheduleInterval.parseMinutes(breakEnd) ?? start
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ProjectWorksRevampColors.amberTint)
                if end > start {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(WorkingHoursPalette.indigo)
                        .frame(width: max(4, xPos(end) - xPos(start)), height: height)
                        .offset(x: xPos(start))
                }
                if breakTo > breakFrom {
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: max(3, xPos(breakTo) - xPos(breakFrom)), height: height)
                        .offset(x: xPos(breakFrom))
                }
            }
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }
}

private struct WorkingHoursTimelineBar: View {
    let windowStart: String
    let windowEnd: String
    let breakStart: String?
    let breakEnd: String?
    let accentColor: Color
    let axisStartMinutes: Int
    let axisEndMinutes: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let axisSpan = Swift.max(1, axisEndMinutes - axisStartMinutes)
            let xPos: (Int) -> CGFloat = { minutes in
                let clipped = Swift.min(axisEndMinutes, Swift.max(axisStartMinutes, minutes))
                return CGFloat(clipped - axisStartMinutes) / CGFloat(axisSpan) * w
            }
            let ws = ManagerScheduleInterval.parseMinutes(windowStart) ?? axisStartMinutes
            let we = ManagerScheduleInterval.parseMinutes(windowEnd) ?? axisEndMinutes
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ProjectWorksRevampColors.wellFill)
                if we > ws {
                    Capsule()
                        .fill(accentColor)
                        .frame(width: Swift.max(4, xPos(we) - xPos(ws)), height: h)
                        .offset(x: xPos(ws))
                }
                if let bs = breakStart, let be = breakEnd,
                   let bsm = ManagerScheduleInterval.parseMinutes(bs),
                   let bem = ManagerScheduleInterval.parseMinutes(be), bem > bsm {
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: Swift.max(3, xPos(bem) - xPos(bsm)), height: h)
                        .offset(x: xPos(bsm))
                }
            }
        }
    }
}
