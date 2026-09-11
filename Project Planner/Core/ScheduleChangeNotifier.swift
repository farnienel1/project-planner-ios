//
//  ScheduleChangeNotifier.swift
//  Project Planner
//
//  Broadcasts booking / manager schedule changes so open screens refresh warnings and UI.
//

import Foundation

extension Notification.Name {
    static let bookingStoreDidChange = Notification.Name("bookingStoreDidChange")
    /// Posted after warnings are recomputed (e.g. settings saved). `userInfo["count"]` = active warning count.
    static let warningsDidRecompute = Notification.Name("warningsDidRecompute")
    /// Request Home to recompute org-horizon warnings after the Warnings sheet has closed.
    static let warningsNeedsHomeRefresh = Notification.Name("warningsNeedsHomeRefresh")
}

enum ScheduleChangeNotifier {
    static func postBookingStoreDidChange() {
        NotificationCenter.default.post(name: .bookingStoreDidChange, object: nil)
    }
}

