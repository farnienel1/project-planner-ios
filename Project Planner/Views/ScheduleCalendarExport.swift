//
//  ScheduleCalendarExport.swift
//  Project Planner
//
//  “Add this week to calendar”: Apple Calendar via EventKit; Google / Outlook via a
//  standard .ics file (the supported way to add a week of events without OAuth).
//

import EventKit
import SwiftUI
import UIKit

struct ScheduleCalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
}

enum ScheduleCalendarDestination: String, Identifiable, CaseIterable {
    case apple
    case google
    case outlook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Calendar"
        case .google: return "Google Calendar"
        case .outlook: return "Outlook"
        }
    }

    var systemImage: String {
        switch self {
        case .apple: return "applelogo"
        case .google: return "globe"
        case .outlook: return "envelope.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .apple:
            return "Adds this week’s bookings to the Calendar app on this iPhone."
        case .google:
            return "Creates a calendar file to open in Google Calendar."
        case .outlook:
            return "Creates a calendar file to open in Outlook."
        }
    }
}

enum ScheduleCalendarExport {
    static func icsDocument(events: [ScheduleCalendarEvent], calendarName: String = "Project Planner") -> String {
        let stamp = icsUTC(Date())
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Project Planner//Schedule//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(icsEscape(calendarName))"
        ]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.id.uuidString)@projectplanner")
            lines.append("DTSTAMP:\(stamp)")
            lines.append("DTSTART:\(icsUTC(event.start))")
            lines.append("DTEND:\(icsUTC(event.end))")
            lines.append("SUMMARY:\(icsEscape(event.title))")
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func writeTemporaryICS(events: [ScheduleCalendarEvent]) throws -> URL {
        let name = "Project-Planner-week.ics"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try icsDocument(events: events).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func addToAppleCalendar(
        events: [ScheduleCalendarEvent],
        completion: @escaping (String) -> Void
    ) {
        guard !events.isEmpty else {
            completion("No bookings this week to add.")
            return
        }
        let eventStore = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            completion("Calendar access is off for Project Planner on this iPhone. Turn it on in iOS Settings > Privacy & Security > Calendars.")
            return
        }
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                Task {
                    let granted = (try? await eventStore.requestWriteOnlyAccessToEvents()) ?? false
                    await MainActor.run {
                        if granted {
                            completion(saveAppleEvents(events, store: eventStore))
                        } else {
                            completion("Calendar access is needed to add events.")
                        }
                    }
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async {
                        if granted {
                            completion(saveAppleEvents(events, store: eventStore))
                        } else {
                            completion("Calendar access is needed to add events.")
                        }
                    }
                }
            }
            return
        }
        completion(saveAppleEvents(events, store: eventStore))
    }

    private static func saveAppleEvents(_ events: [ScheduleCalendarEvent], store: EKEventStore) -> String {
        var added = 0
        for item in events {
            let event = EKEvent(eventStore: store)
            event.title = item.title
            event.startDate = item.start
            event.endDate = item.end
            event.calendar = store.defaultCalendarForNewEvents
            do {
                try store.save(event, span: .thisEvent)
                added += 1
            } catch {
                return "Could not add some events: \(error.localizedDescription)"
            }
        }
        return added > 0 ? "Added \(added) event(s) to Apple Calendar." : "No bookings this week to add."
    }

    private static func icsUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private static func icsEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

struct ScheduleCalendarICSShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ScheduleCalendarDestinationPicker: View {
    let events: [ScheduleCalendarEvent]
    var onAppleResult: (String) -> Void
    var onDismiss: () -> Void
    var onShareICS: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add this week")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text("Choose which calendar to add this week’s bookings to.")
                .font(.system(size: 14))
                .foregroundStyle(ProjectWorksRevampColors.muted)

            VStack(spacing: 10) {
                ForEach(ScheduleCalendarDestination.allCases) { destination in
                    Button {
                        choose(destination)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: destination.systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                .frame(width: 36, height: 36)
                                .background(ProjectWorksRevampColors.blue.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                Text(destination.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        .padding(14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Cancel", action: onDismiss)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(20)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func choose(_ destination: ScheduleCalendarDestination) {
        switch destination {
        case .apple:
            onDismiss()
            ScheduleCalendarExport.addToAppleCalendar(events: events, completion: onAppleResult)
        case .google, .outlook:
            do {
                let url = try ScheduleCalendarExport.writeTemporaryICS(events: events)
                onShareICS(url)
            } catch {
                onDismiss()
                onAppleResult("Could not create a calendar file: \(error.localizedDescription)")
            }
        }
    }
}
