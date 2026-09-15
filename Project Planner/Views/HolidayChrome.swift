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
