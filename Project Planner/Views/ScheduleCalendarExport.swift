//
//  ScheduleCalendarExport.swift
//  Project Planner
//
//  Adds this week’s bookings to Apple Calendar, or launches Google Calendar /
//  Gmail / Outlook when those apps are installed (URL schemes + EventKit when
//  the account is on the iPhone).
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
            return "Opens Google Calendar, or Gmail if that’s what you use."
        case .outlook:
            return "Opens Outlook to add this week’s bookings."
        }
    }
}

enum ScheduleCalendarExport {
    static func add(
        events: [ScheduleCalendarEvent],
        to destination: ScheduleCalendarDestination,
        completion: @escaping (String) -> Void
    ) {
        guard !events.isEmpty else {
            completion("No bookings this week to add.")
            return
        }
        switch destination {
        case .apple:
            addToAppleCalendar(events: events, completion: completion)
        case .google, .outlook:
            addToExternalCalendar(events: events, destination: destination, completion: completion)
        }
    }

    static func addToAppleCalendar(
        events: [ScheduleCalendarEvent],
        completion: @escaping (String) -> Void
    ) {
        let store = EKEventStore()
        requestAccess(store: store) { granted in
            guard granted else {
                completion(accessDeniedMessage)
                return
            }
            let added = save(events: events, store: store, calendar: store.defaultCalendarForNewEvents)
            if added > 0 {
                completion("Added \(added) event(s) to Apple Calendar.")
            } else {
                completion("Could not add events to Apple Calendar.")
            }
        }
    }

    private static func addToExternalCalendar(
        events: [ScheduleCalendarEvent],
        destination: ScheduleCalendarDestination,
        completion: @escaping (String) -> Void
    ) {
        let store = EKEventStore()
        requestAccess(store: store) { granted in
            var added = 0
            if granted, let calendar = matchingCalendar(in: store, destination: destination) {
                added = save(events: events, store: store, calendar: calendar)
            }
            openExternalCalendar(events: events, destination: destination, savedCount: added, completion: completion)
        }
    }

    private static func openExternalCalendar(
        events: [ScheduleCalendarEvent],
        destination: ScheduleCalendarDestination,
        savedCount: Int,
        completion: @escaping (String) -> Void
    ) {
        let urls: [URL]
        switch destination {
        case .apple:
            urls = []
        case .google:
            urls = googleLaunchURLs(events: events, alreadySaved: savedCount > 0)
        case .outlook:
            urls = outlookLaunchURLs(events: events, alreadySaved: savedCount > 0)
        }
        openFirstAvailable(urls) { opened in
            let appName = destination.title
            if savedCount > 0, opened {
                completion("Added \(savedCount) event(s) and opened \(appName).")
            } else if savedCount > 0 {
                completion("Added \(savedCount) event(s) to \(appName). Open \(appName) to see them.")
            } else if opened {
                completion("Opened \(appName) with this week’s bookings. Save the event to add it.")
            } else {
                completion("Could not open \(appName). Install the app, or add the account in iOS Settings > Calendar.")
            }
        }
    }

    // MARK: - Google

    private static func googleLaunchURLs(events: [ScheduleCalendarEvent], alreadySaved: Bool) -> [URL] {
        var urls: [URL] = []
        if alreadySaved {
            urls.append(contentsOf: googleAppSchemes)
            if let gmail = URL(string: "googlegmail://") {
                urls.append(gmail)
            }
            if let week = googleWeekURL(from: events.first?.start ?? Date()) {
                urls.append(week)
            }
        } else {
            urls.append(contentsOf: googleCreateURLs(events: events))
            urls.append(contentsOf: googleAppSchemes)
            if let gmail = URL(string: "googlegmail://") {
                urls.append(gmail)
            }
            if let week = googleWeekURL(from: events.first?.start ?? Date()) {
                urls.append(week)
            }
        }
        return urls
    }

    private static var googleAppSchemes: [URL] {
        [
            "com.google.calendar://",
            "googlecalendar://",
            "comgooglecalendar://"
        ].compactMap(URL.init(string:))
    }

    private static func googleCreateURLs(events: [ScheduleCalendarEvent]) -> [URL] {
        let packed = packedEvent(from: events)
        let dates = "\(googleStamp(packed.start))/\(googleStamp(packed.end))"
        let tz = TimeZone.current.identifier
        var urls: [URL] = []

        var app = URLComponents(string: "com.google.calendar://")
        app?.queryItems = [
            URLQueryItem(name: "action", value: "create"),
            URLQueryItem(name: "text", value: packed.title),
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "details", value: packed.details),
            URLQueryItem(name: "ctz", value: tz)
        ]
        if let url = app?.url {
            urls.append(url)
        }

        var web = URLComponents(string: "https://calendar.google.com/calendar/render")
        web?.queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: packed.title),
            URLQueryItem(name: "dates", value: "\(icsUTC(packed.start))/\(icsUTC(packed.end))"),
            URLQueryItem(name: "details", value: packed.details),
            URLQueryItem(name: "ctz", value: tz)
        ]
        if let url = web?.url {
            urls.append(url)
        }
        return urls
    }

    private static func googleWeekURL(from date: Date) -> URL? {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        return URL(string: "https://calendar.google.com/calendar/r/week/\(y)/\(m)/\(d)")
    }

    private static func googleStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }

    // MARK: - Outlook

    private static func outlookLaunchURLs(events: [ScheduleCalendarEvent], alreadySaved: Bool) -> [URL] {
        var urls: [URL] = []
        if alreadySaved {
            urls.append(contentsOf: [
                "ms-outlook://calendar",
                "ms-outlook://"
            ].compactMap(URL.init(string:)))
        } else {
            urls.append(contentsOf: outlookCreateURLs(events: events))
            urls.append(contentsOf: [
                "ms-outlook://calendar",
                "ms-outlook://"
            ].compactMap(URL.init(string:)))
        }
        return urls
    }

    private static func outlookCreateURLs(events: [ScheduleCalendarEvent]) -> [URL] {
        let packed = packedEvent(from: events)
        let start = outlookStamp(packed.start)
        let end = outlookStamp(packed.end)
        var urls: [URL] = []

        var app = URLComponents(string: "ms-outlook://events/new")
        app?.queryItems = [
            URLQueryItem(name: "title", value: packed.title),
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
            URLQueryItem(name: "body", value: packed.details)
        ]
        if let url = app?.url {
            urls.append(url)
        }

        for host in ["https://outlook.office.com/calendar/deeplink/compose",
                     "https://outlook.live.com/calendar/0/deeplink/compose"] {
            var web = URLComponents(string: host)
            web?.queryItems = [
                URLQueryItem(name: "rru", value: "addevent"),
                URLQueryItem(name: "subject", value: packed.title),
                URLQueryItem(name: "startdt", value: start),
                URLQueryItem(name: "enddt", value: end),
                URLQueryItem(name: "body", value: packed.details)
            ]
            if let url = web?.url {
                urls.append(url)
            }
        }
        return urls
    }

    private static func outlookStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Event pack (one compose screen for a whole week)

    private static func packedEvent(from events: [ScheduleCalendarEvent]) -> (title: String, start: Date, end: Date, details: String) {
        let sorted = events.sorted { $0.start < $1.start }
        guard let first = sorted.first else {
            return ("This week’s bookings", Date(), Date().addingTimeInterval(3600), "")
        }
        if sorted.count == 1 {
            return (first.title, first.start, first.end, "")
        }
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        var lines: [String] = ["This week’s Project Planner bookings:", ""]
        for item in sorted {
            lines.append("\(day.string(from: item.start))  \(time.string(from: item.start))–\(time.string(from: item.end))  \(item.title)")
        }
        let week = DateFormatter()
        week.dateFormat = "d MMM"
        let last = sorted.last ?? first
        let title = "Project Planner — \(week.string(from: first.start))–\(week.string(from: last.start))"
        return (title, first.start, first.end, lines.joined(separator: "\n"))
    }

    // MARK: - EventKit

    private static var accessDeniedMessage: String {
        "Calendar access is off for Project Planner on this iPhone. Turn it on in iOS Settings > Privacy & Security > Calendars."
    }

    private static func requestAccess(store: EKEventStore, completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            completion(false)
            return
        }
        if #available(iOS 17.0, *) {
            if status == .fullAccess || status == .writeOnly {
                completion(true)
                return
            }
            Task {
                let full = (try? await store.requestFullAccessToEvents()) ?? false
                if full {
                    await MainActor.run { completion(true) }
                    return
                }
                let write = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
                await MainActor.run { completion(write) }
            }
        } else if status == .authorized {
            completion(true)
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    private static func matchingCalendar(in store: EKEventStore, destination: ScheduleCalendarDestination) -> EKCalendar? {
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        switch destination {
        case .apple:
            return store.defaultCalendarForNewEvents
        case .google:
            return writable.first(where: { calendar in isGoogleCalendar(calendar) })
        case .outlook:
            return writable.first(where: { calendar in isOutlookCalendar(calendar) })
        }
    }

    private static func calendarBlob(_ calendar: EKCalendar) -> String {
        "\(calendar.title) \(calendar.source.title) \(calendar.source.sourceIdentifier)".lowercased()
    }

    private static func isGoogleCalendar(_ calendar: EKCalendar) -> Bool {
        let blob = calendarBlob(calendar)
        return blob.contains("gmail") || blob.contains("google") || blob.contains("googlemail")
    }

    private static func isOutlookCalendar(_ calendar: EKCalendar) -> Bool {
        if calendar.source.sourceType == .exchange { return true }
        let blob = calendarBlob(calendar)
        return blob.contains("outlook")
            || blob.contains("hotmail")
            || blob.contains("office 365")
            || blob.contains("office365")
            || blob.contains("microsoft")
            || blob.contains("live.com")
            || blob.contains("msn.com")
    }

    private static func save(events: [ScheduleCalendarEvent], store: EKEventStore, calendar: EKCalendar?) -> Int {
        guard let calendar else { return 0 }
        var added = 0
        for item in events {
            let event = EKEvent(eventStore: store)
            event.title = item.title
            event.startDate = item.start
            event.endDate = item.end
            event.calendar = calendar
            do {
                try store.save(event, span: .thisEvent)
                added += 1
            } catch {
                continue
            }
        }
        return added
    }

    private static func openFirstAvailable(_ urls: [URL], completion: @escaping (Bool) -> Void) {
        let usable = urls.filter { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            if scheme == "http" || scheme == "https" { return true }
            return UIApplication.shared.canOpenURL(url)
        }
        func tryIndex(_ index: Int) {
            guard index < usable.count else {
                completion(false)
                return
            }
            UIApplication.shared.open(usable[index], options: [:]) { success in
                if success {
                    completion(true)
                } else {
                    tryIndex(index + 1)
                }
            }
        }
        tryIndex(0)
    }

    private static func icsUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}

struct ScheduleCalendarDestinationPicker: View {
    let events: [ScheduleCalendarEvent]
    var onResult: (String) -> Void
    var onDismiss: () -> Void

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
        onDismiss()
        ScheduleCalendarExport.add(events: events, to: destination, completion: onResult)
    }
}
