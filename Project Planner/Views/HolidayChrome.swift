//
//  HolidayChrome.swift
//  Project Planner
//
//  Shared colour tokens for personal and managed annual leave screens.
//

import SwiftUI

enum HolidayChrome {
    static let canvas = Color(red: 0.97, green: 0.973, blue: 0.98)
    static let ink = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let muted = Color(red: 0.42, green: 0.447, blue: 0.502)
    static let border = Color(red: 0.933, green: 0.941, blue: 0.953)
    static let accent = Color(red: 0.094, green: 0.373, blue: 0.647)
    static let taken = Color(red: 0.133, green: 0.545, blue: 0.318)
    static let pending = Color(red: 0.89, green: 0.22, blue: 0.22)
    /// Pending request count in summary hero (distinct from calendar request red).
    static let pendingMetric = Color(red: 0.98, green: 0.62, blue: 0.09)
    /// Approved half-day on the booking calendar (distinct from pending request orange).
    static let halfDayBooked = Color(red: 0.95, green: 0.52, blue: 0.12)
}

struct AnnualLeaveRemoveBookingConfirm: View {
    var title: String = "Remove annual leave?"
    var message: String = "Are you sure you want to remove this user's annual leave booking? It has already been approved and booked in."
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(HolidayChrome.pendingMetric)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(HolidayChrome.ink)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(HolidayChrome.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onYes) {
                    Text("Yes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(HolidayChrome.taken)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(action: onNo) {
                    Text("No")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(HolidayChrome.pending)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
    }
}
