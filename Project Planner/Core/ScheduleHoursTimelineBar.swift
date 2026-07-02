//
//  ScheduleHoursTimelineBar.swift
//  Project Planner
//
//  Clock-based schedule hours bar: standard window in blue, overtime in amber,
//  unpaid break as a narrow orange stripe. Shared by My Schedule and project scheduling.
//

import SwiftUI

struct ScheduleWorkInterval: Identifiable, Equatable {
    let id = UUID()
    let startMinute: Int
    let endMinute: Int
    var breakRemoved: Bool = false
}

enum ScheduleHoursTimelineSupport {
    static let defaultClipLo = 6 * 60
    static let defaultClipHi = 18 * 60

    static func xFraction(_ minutes: Int, clipLo: Int, clipHi: Int) -> CGFloat {
        let clipped = min(clipHi, max(clipLo, minutes))
        let span = CGFloat(clipHi - clipLo)
        guard span > 0 else { return 0 }
        return CGFloat(clipped - clipLo) / span
    }

    static func breakRange(
        policy: OrgPayrollTimePolicy,
        day: Date,
        workStart: Int,
        workEnd: Int,
        breakIncluded: Bool
    ) -> (Int, Int)? {
        guard breakIncluded,
              !policy.breakPaid,
              policy.unpaidBreakMinutes > 0,
              PayrollTimePolicyCatalog.isWeekday(day),
              let bws = ManagerScheduleInterval.parseMinutes(policy.breakWindowStart),
              let bwe = ManagerScheduleInterval.parseMinutes(policy.breakWindowEnd),
              bwe > bws else { return nil }
        let b0 = max(workStart, bws)
        let b1 = min(workEnd, bwe)
        guard b1 > b0 else { return nil }
        return (b0, b1)
    }

    static func workIntervals(
        manager: [ManagerSiteBooking],
        operative: [Booking],
        policy: OrgPayrollTimePolicy
    ) -> [ScheduleWorkInterval] {
        var out: [ScheduleWorkInterval] = []
        for booking in manager {
            guard let iv = ManagerScheduleInterval.clashInterval(for: booking, policy: policy) else { continue }
            out.append(ScheduleWorkInterval(startMinute: iv.0, endMinute: iv.1, breakRemoved: booking.isBreakRemoved))
        }
        for booking in operative {
            guard let iv = OperativeBookingInterval.clashInterval(for: booking, policy: policy) else { continue }
            out.append(ScheduleWorkInterval(startMinute: iv.0, endMinute: iv.1, breakRemoved: booking.isBreakRemoved))
        }
        return out
    }
}

struct ScheduleHoursTimelineBar: View {
    let day: Date
    let policy: OrgPayrollTimePolicy
    let workIntervals: [ScheduleWorkInterval]
    var workStart: String?
    var workEnd: String?
    var breakIncluded: Bool = true
    var centerLabel: String? = nil
    var clipLo: Int = ScheduleHoursTimelineSupport.defaultClipLo
    var clipHi: Int = ScheduleHoursTimelineSupport.defaultClipHi
    var barHeight: CGFloat = 28

    private static let overtimeOrange = Color(red: 0.95, green: 0.55, blue: 0.2)
    private static let breakOrange = Color(red: 0.98, green: 0.65, blue: 0.15)

    private var timeline: PayrollTimePolicyCatalog.DayTimelinePolicy {
        PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
    }

    private var resolvedIntervals: [ScheduleWorkInterval] {
        if !workIntervals.isEmpty { return workIntervals }
        guard let startText = workStart, let endText = workEnd,
              let sm = ManagerScheduleInterval.parseMinutes(startText),
              let em = ManagerScheduleInterval.parseMinutes(endText), em > sm else { return [] }
        return [ScheduleWorkInterval(startMinute: sm, endMinute: em, breakRemoved: !breakIncluded)]
    }

    private var showBreakStripe: Bool {
        breakIncluded && resolvedIntervals.contains { !$0.breakRemoved }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let xPos: (Int) -> CGFloat = { minutes in
                ScheduleHoursTimelineSupport.xFraction(minutes, clipLo: clipLo, clipHi: clipHi) * w
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.949, green: 0.953, blue: 0.961))

                ForEach(resolvedIntervals) { interval in
                    workIntervalLayers(interval, xPos: xPos, height: h)
                }

                if showBreakStripe,
                   let span = mergedWorkSpan,
                   let br = ScheduleHoursTimelineSupport.breakRange(
                       policy: policy,
                       day: day,
                       workStart: span.0,
                       workEnd: span.1,
                       breakIncluded: true
                   ) {
                    let bl = xPos(br.0)
                    let bw = max(2, xPos(br.1) - bl)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.breakOrange.opacity(0.95))
                        .frame(width: bw, height: max(4, h - 6))
                        .offset(x: bl, y: 3)
                }

                if let centerLabel, !centerLabel.isEmpty {
                    Text(centerLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0)
                        .padding(.leading, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: barHeight)
    }

    private var mergedWorkSpan: (Int, Int)? {
        let starts = resolvedIntervals.map(\.startMinute)
        let ends = resolvedIntervals.map(\.endMinute)
        guard let lo = starts.min(), let hi = ends.max(), hi > lo else { return nil }
        return (lo, hi)
    }

    @ViewBuilder
    private func workIntervalLayers(_ interval: ScheduleWorkInterval, xPos: (Int) -> CGFloat, height: CGFloat) -> some View {
        let w0 = max(interval.startMinute, clipLo)
        let w1 = min(interval.endMinute, clipHi)
        guard w1 > w0 else { return }

        if timeline.allHoursAtMultiplier {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.overtimeOrange.opacity(0.92))
                .frame(width: max(4, xPos(w1) - xPos(w0)), height: height)
                .offset(x: xPos(w0))
        } else {
            let ds = timeline.standardWindowStartMinutes ?? (7 * 60 + 30)
            let de = timeline.standardWindowEndMinutes ?? (16 * 60)
            let s0 = max(ds, clipLo)
            let s1 = min(de, clipHi)
            let midLeft = max(w0, s0)
            let midRight = min(w1, s1)
            let leftOt0 = w0
            let leftOt1 = min(w1, s0)
            let rightOt0 = max(w0, s1)
            let rightOt1 = w1

            if leftOt1 > leftOt0 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.overtimeOrange.opacity(0.92))
                    .frame(width: max(4, xPos(leftOt1) - xPos(leftOt0)), height: height)
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
                    .frame(width: max(4, xPos(midRight) - xPos(midLeft)), height: height)
                    .offset(x: xPos(midLeft))
            }
            if rightOt1 > rightOt0 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.overtimeOrange.opacity(0.92))
                    .frame(width: max(4, xPos(rightOt1) - xPos(rightOt0)), height: height)
                    .offset(x: xPos(rightOt0))
            }
        }
    }
}
