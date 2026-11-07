//
//  ScheduleBookingSaveOutcome.swift
//  Project Planner
//
//  1.33.1: what the project / small works "Schedule booking" screen does once Confirm has saved. Screen flow only —
//  which bookings are written, and how, is unchanged (`BookingStore`). Before 1.33.1 the screen judged an edit by the
//  store's last `errorMessage` (which an earlier load could have left) and, when nothing counted as saved, cleared every
//  choice and stayed open with nothing said.
//

import Foundation

enum ScheduleBookingSaveOutcome: Equatable {
    /// Every booking confirmed by the server: the "Booking Confirmed" sheet, then the screen closes.
    case confirmed
    /// Every booking kept, at least one queued as Pending sync (the server did not confirm in time, or offline).
    case pendingSync(String)
    /// Some bookings kept (saved or queued), some refused: the message says why.
    case savedWithProblem(String)
    /// Nothing saved and the store said why (for example a refusal): the screen stays with the choices kept.
    case notSaved(String)
    /// Nothing new to save (every booking was already there with these hours).
    case nothingToSave

    static let nothingToSaveMessage = "Nothing new to save. These people are already booked at these times."

    /// 1.33.1 review item 4: decided from each booking's own outcome (`BookingSaveResult`), never from a count made
    /// before the save ran. A queued booking counts as saved (Pending sync), never as "not saved".
    static func decide(results: [BookingSaveResult]) -> ScheduleBookingSaveOutcome {
        guard !results.isEmpty else { return .nothingToSave }
        var refusal: String?
        var queued: String?
        var keptCount = 0
        for result in results {
            switch result {
            case .saved:
                keptCount += 1
            case .queued(let message):
                keptCount += 1
                if queued == nil { queued = message }
            case .refused(let message):
                if refusal == nil { refusal = message }
            }
        }
        let refusalMessage = (refusal?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "This booking could not be saved."
        if keptCount == 0 { return .notSaved(refusalMessage) }
        if refusal != nil { return .savedWithProblem(refusalMessage) }
        if let queued {
            let text = queued.trimmingCharacters(in: .whitespacesAndNewlines)
            return .pendingSync(text.isEmpty ? BookingStore.pendingSyncMessage : text)
        }
        return .confirmed
    }

    /// Whether the screen's choices are cleared (they are kept only when nothing saved, so the booker can try again).
    var clearsSelection: Bool {
        if case .notSaved = self { return false }
        return true
    }

    /// Whether OK on the alert closes the screen.
    var closesScreen: Bool {
        switch self {
        case .confirmed, .pendingSync, .savedWithProblem, .nothingToSave: return true
        case .notSaved: return false
        }
    }
}

struct ScheduleBookingSaveAlert: Identifiable, Equatable {
    let id = UUID()
    let outcome: ScheduleBookingSaveOutcome
    let message: String

    var title: String {
        switch outcome {
        case .confirmed: return "Booking confirmed"
        case .pendingSync: return "Booking saved — Pending sync"
        case .savedWithProblem: return "Some bookings not saved"
        case .notSaved: return "Booking not saved"
        case .nothingToSave: return "Nothing to save"
        }
    }
}
