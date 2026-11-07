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
    /// Saved with nothing to report: the "Booking Confirmed" sheet, then the screen closes.
    case confirmed
    /// At least one booking saved, but the store reported something (for example "saved locally, will sync").
    case savedWithProblem(String)
    /// Nothing saved and the store said why (for example a refusal): the screen stays with the choices kept.
    case notSaved(String)
    /// Nothing new to save (every booking was already there with these hours).
    case nothingToSave

    static let nothingToSaveMessage = "Nothing new to save. These people are already booked at these times."

    static func decide(savedCount: Int, problem: String?) -> ScheduleBookingSaveOutcome {
        let message = problem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if savedCount > 0 {
            return message.isEmpty ? .confirmed : .savedWithProblem(message)
        }
        return message.isEmpty ? .nothingToSave : .notSaved(message)
    }

    /// Whether the screen's choices are cleared (they are kept only when nothing saved, so the booker can try again).
    var clearsSelection: Bool {
        if case .notSaved = self { return false }
        return true
    }

    /// Whether OK on the alert closes the screen.
    var closesScreen: Bool {
        switch self {
        case .confirmed, .savedWithProblem, .nothingToSave: return true
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
        case .savedWithProblem: return "Booking saved"
        case .notSaved: return "Booking not saved"
        case .nothingToSave: return "Nothing to save"
        }
    }
}
