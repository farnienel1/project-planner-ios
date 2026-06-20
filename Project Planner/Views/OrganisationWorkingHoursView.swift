//
//  OrganisationWorkingHoursView.swift
//  Project Planner
//
//  Edits organisations/{orgId}.payrollTimePolicy — weekday, Saturday, Sunday, save + schedule.
//

import SwiftUI

// MARK: - Palette (TSX reference)

private enum WorkingHoursPalette {
    static let canvas = Color(red: 0.965, green: 0.969, blue: 0.984) // #f6f7fb
    static let cardBorder = Color(red: 0.886, green: 0.910, blue: 0.941) // slate-200
    static let ink = Color(red: 0.059, green: 0.090, blue: 0.165) // slate-900
    static let muted = Color(red: 0.392, green: 0.455, blue: 0.545) // slate-500
    static let indigo = Color(red: 0.310, green: 0.275, blue: 0.898) // #4f46e5
    static let amber = Color(red: 0.851, green: 0.467, blue: 0.024) // #d97706
    static let rose = Color(red: 0.882, green: 0.114, blue: 0.282) // #e11d48
    static let indigoGradientTop = Color(red: 0.933, green: 0.941, blue: 0.992)
    static let indigoGradientBottom = Color(red: 0.953, green: 0.910, blue: 0.992)
    static let amberGradientTop = Color(red: 1.0, green: 0.953, blue: 0.878)
    static let amberGradientBottom = Color(red: 1.0, green: 0.969, blue: 0.929)
    static let roseGradientTop = Color(red: 1.0, green: 0.894, blue: 0.910)
    static let roseGradientBottom = Color(red: 1.0, green: 0.941, blue: 0.961)
}

// MARK: - Main view

struct OrganisationWorkingHoursView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OrgPayrollTimePolicy.default
    @State private var baselineDraft = OrgPayrollTimePolicy.default
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingImmediateSaveWarning = false
    @State private var showingScheduleSheet = false
    @State private var showingCancelConfirm = false
    @State private var scheduleEffectiveDate = Calendar.current.startOfDay(for: Date())
    @State private var saveSucceeded = false

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
                }

                Text("Changes apply to new timesheet entries from today. Existing approved timesheets aren't recalculated.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(.systemGray))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 100)
            }
        }
        .background(WorkingHoursPalette.canvas.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(WorkingHoursPalette.canvas.opacity(0.92), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WorkingHoursPalette.ink)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Working hours")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(WorkingHoursPalette.ink)
                    Text("Organisation default")
                        .font(.system(size: 11))
                        .foregroundStyle(WorkingHoursPalette.muted)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .task { loadDraft() }
        .sheet(isPresented: $showingScheduleSheet) {
            scheduleChangeSheet
        }
        .alert("Apply changes today?", isPresented: $showingImmediateSaveWarning) {
            Button("Decline Changes", role: .cancel) { }
            Button("Approve Changes") {
                Task { await saveImmediately() }
            }
        } message: {
            Text("If you save these settings now, they will take immediate effect. Any bookings on today's schedule will have these new working hours applied. This will be reflected in the weekly report, timesheets and on invoices. If you would like these changes to take effect from a future date, then use the Schedule Changes Button.")
        }
        .alert("Discard changes?", isPresented: $showingCancelConfirm) {
            Button("Keep editing", role: .cancel) { }
            Button("Discard", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("You have unsaved changes. Discard them and leave this screen?")
        }
    }

    // MARK: - Intro & banners

    private var introText: some View {
        Text("These rules apply across the firm and decide how hours are costed on every timesheet — set the standard week, then how Saturday and Sunday are treated.")
            .font(.system(size: 13))
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
                Text("New working hours take effect on \(scheduled.effectiveFrom.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.047, green: 0.459, blue: 0.294))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.925, green: 0.992, blue: 0.961))
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
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WorkingHoursPalette.muted)
                .tracking(1.2)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 10) {
                glanceRow(
                    label: "Mon–Fri",
                    color: WorkingHoursPalette.indigo,
                    text: "\(draft.standardDayStart)–\(draft.standardDayEnd)  ·  \(formatHoursDisplay(draft.computedWeekdayPaidHours)) paid  ·  OT \(formatMultiplier(draft.weekdayOutsideStandardMultiplier))x"
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
            return "Every hour worked  ·  \(formatMultiplier(sat.allHoursMultiplier))x"
        }
        let start = sat.customStandardStart ?? draft.standardDayStart
        let end = sat.customStandardEnd ?? "13:00"
        let flat = sat.resolvedCountsAsHours(fallback: draft.standardPaidHours)
        return "\(start)–\(end)  ·  \(formatHoursDisplay(flat)) flat  ·  \(formatMultiplier(sat.outsideStandardWindowMultiplier))x"
    }

    private var sundayGlanceText: String {
        if draft.sundaySameAsSaturday {
            return "Same as Saturday"
        }
        let sun = draft.sunday
        if sun.allHoursAtMultiplierMode {
            return "Every hour worked  ·  \(formatMultiplier(sun.allHoursMultiplier))x"
        }
        let start = sun.customStandardStart ?? draft.standardDayStart
        let end = sun.customStandardEnd ?? "13:00"
        let flat = sun.resolvedCountsAsHours(fallback: draft.standardPaidHours)
        return "\(start)–\(end)  ·  \(formatHoursDisplay(flat)) flat  ·  \(formatMultiplier(sun.outsideStandardWindowMultiplier))x"
    }

    private func glanceRow(label: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Color(red: 0.2, green: 0.255, blue: 0.333))
                .frame(width: 64, alignment: .leading)
            Text(text)
                .font(.system(size: 12.5))
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
                .onChange(of: draft.standardDayStart) { _, _ in syncBreakWindowPlacement() }
                .onChange(of: draft.standardDayEnd) { _, _ in syncBreakWindowPlacement() }

                cardDivider

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lunch break")
                            .font(.system(size: 14, weight: .semibold))
                        Text(draft.breakPaid
                             ? "Paid — counts toward hours worked"
                             : "Unpaid — deducted from paid hours")
                            .font(.system(size: 12))
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

                stepperRow(
                    label: "Break length",
                    value: Binding(
                        get: { Double(draft.unpaidBreakMinutes) },
                        set: {
                            draft.unpaidBreakMinutes = Int($0)
                            syncBreakWindowPlacement()
                        }
                    ),
                    step: 5,
                    min: 0,
                    max: 90,
                    suffix: " min"
                )

                cardDivider

                weekdayTimelineBar

                gradientSummaryCard(
                    topColor: WorkingHoursPalette.indigoGradientTop,
                    bottomColor: WorkingHoursPalette.indigoGradientBottom,
                    rows: [
                        ("Span (start to end)", formatHoursDisplay(weekdaySpanHours), false),
                        (draft.breakPaid ? "Break (paid, no deduction)" : "Less unpaid break",
                         draft.breakPaid ? "—" : "−\(formatHoursDisplay(Double(draft.unpaidBreakMinutes) / 60))", false),
                    ],
                    footerLabel: "Standard paid day",
                    footerValue: formatHoursDisplay(draft.computedWeekdayPaidHours),
                    accent: WorkingHoursPalette.indigo
                )

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

    private var weekdayTimelineBar: some View {
        VStack(spacing: 6) {
            WorkingHoursTimelineBar(
                windowStart: draft.standardDayStart,
                windowEnd: draft.standardDayEnd,
                breakStart: draft.breakPaid ? nil : draft.breakWindowStart,
                breakEnd: draft.breakPaid ? nil : draft.breakWindowEnd,
                accentColor: WorkingHoursPalette.indigo,
                axisStartMinutes: 6 * 60,
                axisEndMinutes: 18 * 60
            )
            .frame(height: 7)

            HStack {
                Text("06:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("18:00")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color(.systemGray))
        }
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
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.systemGray))
                        .fixedSize(horizontal: false, vertical: true)
                }

                WorkingHoursSegmentedPicker(
                    selection: Binding(
                        get: { draft.saturday.allHoursAtMultiplierMode ? 1 : 0 },
                        set: { mode in
                            var sat = draft.saturday
                            sat.allHoursAtMultiplierMode = mode == 1
                            if mode == 0 {
                                sat.useCustomStandardDayWindow = true
                                if sat.customStandardStart == nil { sat.customStandardStart = draft.standardDayStart }
                                if sat.customStandardEnd == nil { sat.customStandardEnd = "13:00" }
                                if sat.countsAsHours == nil { sat.countsAsHours = draft.standardPaidHours }
                            }
                            draft.saturday = sat
                        }
                    ),
                    options: [(0, "Defined window"), (1, "Hours × multiplier")]
                )

                if draft.saturday.allHoursAtMultiplierMode {
                    saturdayAllHoursContent(settings: $draft.saturday)
                } else {
                    saturdayWindowContent(settings: $draft.saturday, title: "Saturday")
                }
            }
        }
    }

    @ViewBuilder
    private func saturdayWindowContent(settings: Binding<OrgWeekendDayPayrollSettings>, title: String) -> some View {
        HStack(spacing: 12) {
            timeFieldColumn(label: "Window starts", text: Binding(
                get: { settings.wrappedValue.customStandardStart ?? "" },
                set: { settings.wrappedValue.customStandardStart = $0.isEmpty ? nil : $0 }
            ))
            timeFieldColumn(label: "Window ends", text: Binding(
                get: { settings.wrappedValue.customStandardEnd ?? "" },
                set: { settings.wrappedValue.customStandardEnd = $0.isEmpty ? nil : $0 }
            ))
        }

        tintedInfoBox(
            text: "No break is deducted inside this window. A shift covering \(settings.wrappedValue.customStandardStart ?? draft.standardDayStart)–\(settings.wrappedValue.customStandardEnd ?? "13:00") (\(formatHoursDisplay(saturdayWindowSpanHours(settings.wrappedValue)))) is simply paid as a flat day — set how many hours that day counts as below.",
            tint: WorkingHoursPalette.amber
        )

        stepperRow(
            label: "Counts as",
            value: Binding(
                get: { settings.wrappedValue.resolvedCountsAsHours(fallback: draft.standardPaidHours) },
                set: { settings.wrappedValue.countsAsHours = $0 }
            ),
            step: 0.5,
            min: 1,
            max: 14,
            suffix: "h"
        )

        multiplierRow(
            title: "Outside the window",
            subtitle: "Time worked before \(settings.wrappedValue.customStandardStart ?? draft.standardDayStart) or after \(settings.wrappedValue.customStandardEnd ?? "13:00")",
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
            text: "No fixed window — whatever hours are booked on a Saturday are paid at \(formatMultiplier(settings.wrappedValue.allHoursMultiplier))x, with no unpaid break deducted.",
            tint: WorkingHoursPalette.amber
        )
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
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.systemGray))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Same setup as Saturday")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Mirror Saturday's pay rules on Sunday")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    WorkingHoursToggle(isOn: $draft.sundaySameAsSaturday)
                }

                if draft.sundaySameAsSaturday {
                    tintedInfoBox(
                        text: "Sunday uses Saturday's rules for payroll and scheduling.",
                        tint: WorkingHoursPalette.rose
                    )
                } else {
                    WorkingHoursSegmentedPicker(
                        selection: Binding(
                            get: { draft.sunday.allHoursAtMultiplierMode ? 1 : 0 },
                            set: { mode in
                                var sun = draft.sunday
                                sun.allHoursAtMultiplierMode = mode == 1
                                if mode == 0 {
                                    sun.useCustomStandardDayWindow = true
                                    if sun.customStandardStart == nil { sun.customStandardStart = draft.standardDayStart }
                                    if sun.customStandardEnd == nil { sun.customStandardEnd = "13:00" }
                                    if sun.countsAsHours == nil { sun.countsAsHours = draft.standardPaidHours }
                                }
                                draft.sunday = sun
                            }
                        ),
                        options: [(0, "Defined window"), (1, "Hours × multiplier")]
                    )

                    if draft.sunday.allHoursAtMultiplierMode {
                        sundayAllHoursContent(settings: $draft.sunday)
                    } else {
                        saturdayWindowContent(settings: $draft.sunday, title: "Sunday")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sundayAllHoursContent(settings: Binding<OrgWeekendDayPayrollSettings>) -> some View {
        multiplierRow(
            title: "Multiplier on every hour worked",
            subtitle: "No unpaid break applied",
            value: Binding(
                get: { settings.wrappedValue.allHoursMultiplier },
                set: { settings.wrappedValue.allHoursMultiplier = $0 }
            ),
            accent: WorkingHoursPalette.rose
        )

        gradientSummaryCard(
            topColor: WorkingHoursPalette.roseGradientTop,
            bottomColor: WorkingHoursPalette.roseGradientBottom,
            rows: [],
            footerLabel: "Example: a 6 hour Sunday pays",
            footerValue: formatHoursDisplay(6 * settings.wrappedValue.allHoursMultiplier),
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
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(WorkingHoursPalette.indigo)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: WorkingHoursPalette.indigo.opacity(0.25), radius: 4, y: 2)
                .disabled(!isFormValid || isSaving)
                .opacity(!isFormValid || isSaving ? 0.55 : 1)

                Button {
                    showingScheduleSheet = true
                } label: {
                    Text("Schedule")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
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

                Button {
                    clearDraft()
                } label: {
                    Text("Clear")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
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
        }
    }

    // MARK: - Shared layout helpers

    private func workingHoursCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(WorkingHoursPalette.cardBorder, lineWidth: 1)
        )
    }

    private func sectionLabel(color: Color, title: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WorkingHoursPalette.muted)
                .tracking(1.1)
        }
        .padding(.bottom, 2)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color(red: 0.945, green: 0.961, blue: 0.976))
            .frame(height: 1)
    }

    private func timeFieldColumn(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(WorkingHoursPalette.muted)
            WorkingHoursTimeField(text: text)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepperRow(label: String, value: Binding<Double>, step: Double, min: Double, max: Double, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WorkingHoursPalette.muted)
            Spacer()
            WorkingHoursStepper(value: value, step: step, min: min, max: max, suffix: suffix)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.973, green: 0.980, blue: 0.988))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(red: 0.945, green: 0.961, blue: 0.976), lineWidth: 1)
        )
    }

    private func multiplierRow(title: String, subtitle: String?, value: Binding<Double>, accent: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
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
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
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
                        .font(.system(size: 13))
                        .foregroundStyle(WorkingHoursPalette.muted)
                    Spacer()
                    Text(row.1)
                        .font(.system(size: 14, weight: .bold))
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
                    .font(.system(size: 13.5, weight: .semibold))
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
                    in: Calendar.current.startOfDay(for: Date())...,
                    displayedComponents: .date
                )
                Section {
                    Text("Bookings before this date keep the current working hours. From this date onward, these draft settings apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingScheduleSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        Task { await saveScheduled() }
                    }
                    .disabled(!isFormValid || isSaving)
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
        syncBreakWindowPlacement()
    }

    private func sanitizePolicy(_ policy: OrgPayrollTimePolicy) -> OrgPayrollTimePolicy {
        var out = policy
        if !isValidHM(out.standardDayStart) {
            out.standardDayStart = OrgPayrollTimePolicy.default.standardDayStart
        }
        if !isValidHM(out.standardDayEnd) {
            out.standardDayEnd = OrgPayrollTimePolicy.default.standardDayEnd
        }
        out.unpaidBreakMinutes = Swift.max(0, Swift.min(90, out.unpaidBreakMinutes))
        out.standardPaidHours = Swift.max(1, Swift.min(24, out.standardPaidHours))
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
        if let counts = out.countsAsHours {
            out.countsAsHours = Swift.max(1, Swift.min(24, counts))
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
        return Swift.max(1, Swift.min(3, value))
    }

    private func clearDraft() {
        draft = baselineDraft
        saveSucceeded = false
        errorMessage = nil
    }

    private func syncBreakWindowPlacement() {
        guard let ds = ManagerScheduleInterval.parseMinutes(draft.standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(draft.standardDayEnd),
              de > ds else { return }
        let span = de - ds
        let breakMins = max(0, draft.unpaidBreakMinutes)
        let breakStart = ds + max(0, (span - breakMins) / 2)
        draft.breakWindowStart = ManagerScheduleInterval.formatMinutes(breakStart)
        draft.breakWindowEnd = ManagerScheduleInterval.formatMinutes(breakStart + breakMins)
    }

    private func saveImmediately() async {
        guard isFormValid else { return }
        isSaving = true
        errorMessage = nil
        saveSucceeded = false
        do {
            try await firebaseBackend.applyOrganizationPayrollTimePolicyImmediately(draft)
            await MainActor.run {
                isSaving = false
                baselineDraft = draft
                saveSucceeded = true
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
            try await firebaseBackend.scheduleOrganizationPayrollTimePolicyChange(draft, effectiveFrom: scheduleEffectiveDate)
            await MainActor.run {
                isSaving = false
                baselineDraft = draft
                showingScheduleSheet = false
                saveSucceeded = true
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Validation & helpers

    private var weekdaySpanHours: Double {
        guard let ds = ManagerScheduleInterval.parseMinutes(draft.standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(draft.standardDayEnd),
              de > ds else { return 0 }
        return Double(de - ds) / 60.0
    }

    private func saturdayWindowSpanHours(_ settings: OrgWeekendDayPayrollSettings) -> Double {
        guard let s = settings.customStandardStart,
              let e = settings.customStandardEnd,
              let sm = ManagerScheduleInterval.parseMinutes(s),
              let em = ManagerScheduleInterval.parseMinutes(e),
              em > sm else { return 0 }
        return Double(em - sm) / 60.0
    }

    private var isFormValid: Bool {
        isValidHM(draft.standardDayStart)
            && isValidHM(draft.standardDayEnd)
            && isValidHM(draft.breakWindowStart)
            && isValidHM(draft.breakWindowEnd)
            && draft.weekdayOutsideStandardMultiplier > 0
            && weekendValid(draft.saturday)
            && (draft.sundaySameAsSaturday || weekendValid(draft.sunday))
    }

    private func weekendValid(_ w: OrgWeekendDayPayrollSettings) -> Bool {
        if w.allHoursMultiplier <= 0 || w.outsideStandardWindowMultiplier <= 0 { return false }
        if w.allHoursAtMultiplierMode { return true }
        guard let s = w.customStandardStart, let e = w.customStandardEnd,
              isValidHM(s), isValidHM(e) else { return false }
        return (w.countsAsHours ?? draft.standardPaidHours) > 0
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

// MARK: - Computed weekday paid hours

private extension OrgPayrollTimePolicy {
    var computedWeekdayPaidHours: Double {
        guard let ds = ManagerScheduleInterval.parseMinutes(standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(standardDayEnd), de > ds else {
            return standardPaidHours
        }
        var hours = Double(de - ds) / 60.0
        if !breakPaid {
            hours = max(0, hours - standardUnpaidBreakHours)
        }
        return hours
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
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selection.wrappedValue == option.0 ? Color(.systemBackground) : Color.clear)
                        .foregroundStyle(selection.wrappedValue == option.0 ? Color.primary : Color(.systemGray))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: selection.wrappedValue == option.0 ? Color.black.opacity(0.06) : .clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(red: 0.945, green: 0.961, blue: 0.976))
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
            .buttonStyle(.plain)

            Text(displayValue)
                .font(.system(size: 13.5, weight: .bold))
                .monospacedDigit()
                .frame(minWidth: 52)

            Button {
                value = Swift.min(max, roundedStep(value + step, step: step))
            } label: {
                Text("+")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .background(Color(red: 0.945, green: 0.961, blue: 0.976))
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
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 56)
                .padding(.vertical, 8)
                .background(Color(red: 0.973, green: 0.980, blue: 0.988))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(WorkingHoursPalette.cardBorder, lineWidth: 1)
                )
            Text("x")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.580, green: 0.639, blue: 0.722))
        }
    }
}

private struct WorkingHoursTimeField: View {
    @Binding var text: String
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField("07:30", text: $draft)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(Color(.systemGray3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.973, green: 0.980, blue: 0.988))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(focused ? WorkingHoursPalette.indigo.opacity(0.35) : WorkingHoursPalette.cardBorder, lineWidth: 1)
        )
        .onAppear { draft = text }
        .onChange(of: text) { _, newValue in
            if !focused { draft = newValue }
        }
    }

    private func commit() {
        let clamped = clampTimeInput(draft, fallback: text)
        draft = clamped
        text = clamped
    }

    private func clampTimeInput(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = trimmed.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression),
           r.lowerBound == trimmed.startIndex && r.upperBound == trimmed.endIndex {
            let parts = trimmed.split(separator: ":")
            if parts.count == 2, let hRaw = Int(parts[0]), let mRaw = Int(parts[1]) {
                return String(format: "%02d:%02d", Swift.min(23, Swift.max(0, hRaw)), Swift.min(59, Swift.max(0, mRaw)))
            }
        }
        let digits = trimmed.filter(\.isNumber)
        if digits.count == 3 || digits.count == 4 {
            let hPart = String(digits.prefix(digits.count - 2))
            let mPart = String(digits.suffix(2))
            if let hRaw = Int(hPart), let mRaw = Int(mPart) {
                return String(format: "%02d:%02d", Swift.min(23, Swift.max(0, hRaw)), Swift.min(59, Swift.max(0, mRaw)))
            }
        }
        return fallback
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
                    .fill(Color(red: 0.945, green: 0.961, blue: 0.976))
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
