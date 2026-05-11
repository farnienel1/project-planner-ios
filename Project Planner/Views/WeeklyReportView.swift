import SwiftUI
import UIKit

struct WeeklyReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var subcontractorStore: SubcontractorStore

    @State private var startDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var isGenerating = false
    @State private var generatedCSVURL: URL?
    @State private var showShareSheet = false
    @State private var message: String?
    @State private var dayRateHistoryByUser: [String: [OperativeDayRateHistoryEntry]] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Choose week") {
                    Button("This Week (Mon-Sun): \(rangeLabel(thisWeekRange))") { setThisWeekRange() }
                    Button("Last Week (Mon-Sun): \(rangeLabel(lastWeekRange))") { setLastWeekRange() }
                }
                Section("Set date range") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                }
                Section {
                    Button {
                        generateCSVReport()
                    } label: {
                        HStack {
                            if isGenerating { ProgressView() }
                            Text(isGenerating ? "Generating..." : "Generate Report (CSV)")
                        }
                    }
                    .disabled(isGenerating)
                }
                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Weekly Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let generatedCSVURL {
                    WeeklyReportShareSheet(items: [generatedCSVURL])
                }
            }
            .onAppear {
                setThisWeekRange()
            }
        }
    }

    private func setThisWeekRange() {
        let thisWeek = thisWeekRange
        startDate = thisWeek.start
        endDate = thisWeek.end
    }

    private func setLastWeekRange() {
        let lastWeek = lastWeekRange
        startDate = lastWeek.start
        endDate = lastWeek.end
    }

    private var thisWeekRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        let monday = cal.startOfDay(for: cal.date(byAdding: .day, value: -daysFromMonday, to: now) ?? now)
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday
        return (monday, sunday)
    }

    private var lastWeekRange: (start: Date, end: Date) {
        let thisWeek = thisWeekRange
        let start = Calendar.current.date(byAdding: .day, value: -7, to: thisWeek.start) ?? thisWeek.start
        let end = Calendar.current.date(byAdding: .day, value: -7, to: thisWeek.end) ?? thisWeek.end
        return (start, end)
    }

    private func rangeLabel(_ range: (start: Date, end: Date)) -> String {
        "\(formatDate(range.start)) - \(formatDate(range.end))"
    }

    private func generateCSVReport() {
        isGenerating = true
        message = nil
        Task {
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                dayRateHistoryByUser = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? [:]
            }
            let csv = buildCSV()
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("WeeklyReport-\(Int(Date().timeIntervalSince1970)).csv")
            do {
                try csv.write(to: fileURL, atomically: true, encoding: .utf8)
                await MainActor.run {
                    generatedCSVURL = fileURL
                    message = "Report generated."
                    showShareSheet = true
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    message = "Failed to generate report: \(error.localizedDescription)"
                    isGenerating = false
                }
            }
        }
    }

    private func buildCSV() -> String {
        var rows: [[String]] = []
        rows.append(["Weekly Report"])
        rows.append(["From", formatDate(startDate), "To", formatDate(endDate)])
        rows.append([])
        rows.append(["PROJECT BREAKDOWN"])
        rows.append(["Project", "Job Number", "Person", "Trade", "Role", "Days"])

        let operativeRows = operativeProjectRows()
        let managerRows = managerProjectRows()
        let allProjectRows = operativeRows + managerRows
        let grouped = Dictionary(grouping: allProjectRows) { "\($0.projectName)|\($0.jobNumber)" }

        var projectGrandTotal = 0.0
        for key in grouped.keys.sorted() {
            guard let group = grouped[key] else { continue }
            var projectTotal = 0.0
            for row in group.sorted(by: projectWorkRowSort) {
                let tradeCell = row.tradeDisplay == "—" ? "" : row.tradeDisplay
                rows.append([row.projectName, row.jobNumber, row.personName, tradeCell, row.role, formatDays(row.days)])
                projectTotal += row.days
                projectGrandTotal += row.days
            }
            rows.append(["", "", "", "", "Project Total", formatDays(projectTotal)])
            rows.append([])
        }
        rows.append(["", "", "", "", "All Project Work Total", formatDays(projectGrandTotal)])
        rows.append([])
        
        rows.append(["SUB CONTRACTORS"])
        rows.append(["Project", "Job Number", "Sub Contractor", "Type", "Time", "Days"])
        var subcontractorTotal = 0.0
        for row in subcontractorRows() {
            rows.append([
                row.projectName,
                row.jobNumber,
                row.subcontractorName,
                row.subcontractorType,
                row.timeSlotLabel,
                formatDays(row.days)
            ])
            subcontractorTotal += row.days
        }
        rows.append(["", "", "", "", "Sub Contractor Total", formatDays(subcontractorTotal)])
        rows.append([])

        rows.append(["ANNUAL LEAVE"])
        rows.append(["Person", "Role", "Days", "Type"])
        var annualLeaveTotal = 0.0
        for leave in annualLeaveRows() {
            rows.append([leave.personName, leave.role, formatDays(leave.days), "Approved"])
            annualLeaveTotal += leave.days
        }
        rows.append(["", "", formatDays(annualLeaveTotal), "Annual Leave Total"])
        rows.append([])
        
        rows.append(["MANAGER/ADMIN ADDITIONAL SCHEDULE"])
        rows.append(["Person", "Location", "Time", "Days"])
        var additionalScheduleTotal = 0.0
        for row in managerAdditionalScheduleRows() {
            rows.append([row.personName, row.location, row.timeSlotLabel, formatDays(row.days)])
            additionalScheduleTotal += row.days
        }
        rows.append(["", "Total", "", formatDays(additionalScheduleTotal)])
        rows.append([])

        rows.append(["DAY RATE SUMMARY"])
        rows.append(["Person", "Role", "Days", "Day Rate", "Amount"])
        var totalAmount = 0.0
        for summary in labourRateSummaries().sorted(by: {
            if $0.name == $1.name {
                let leftRate = $0.rate ?? -1
                let rightRate = $1.rate ?? -1
                return leftRate < rightRate
            }
            return $0.name < $1.name
        }) {
            let amount = (summary.rate ?? 0) * summary.days
            rows.append([
                summary.name,
                summary.role,
                formatDays(summary.days),
                formatCurrency(summary.rate),
                formatCurrency(summary.rate == nil ? nil : amount)
            ])
            totalAmount += amount
        }
        rows.append(["", "", "", "Total", formatCurrency(totalAmount)])

        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
    }

    private func projectWorkRowSort(_ lhs: ProjectWorkRow, _ rhs: ProjectWorkRow) -> Bool {
        if lhs.tradeSortKey != rhs.tradeSortKey {
            return lhs.tradeSortKey < rhs.tradeSortKey
        }
        return lhs.personName.localizedCaseInsensitiveCompare(rhs.personName) == .orderedAscending
    }

    private func operativeProjectRows() -> [ProjectWorkRow] {
        let cal = Calendar.current
        let filtered = bookingStore.bookings.filter { booking in
            let day = cal.startOfDay(for: booking.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && booking.status != .cancelled
        }
        var totals: [String: Double] = [:]
        var rowsMap: [String: ProjectWorkRow] = [:]
        for booking in filtered {
            guard let operative = operativeStore.allOperatives.first(where: { $0.id == booking.operativeId }) else { continue }
            let project = projectStore.projects.first(where: { $0.id == booking.projectId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let projectName = project?.siteName ?? "Unknown"
            let jobNumber = project?.jobNumber ?? "N/A"
            let personName = operative.name
            let key = "\(projectName)|\(jobNumber)|\(personName)|Operative"
            let dayValue = bookingDayValue(from: booking.timeSlot)
            totals[key, default: 0] += dayValue
            rowsMap[key] = ProjectWorkRow(
                projectName: projectName,
                jobNumber: jobNumber,
                personName: personName,
                tradeDisplay: operative.displayTradeType,
                tradeSortKey: StaffTradeType.sortKey(presetRaw: operative.tradeTypePreset, custom: operative.tradeTypeCustom),
                role: "Operative",
                days: totals[key] ?? 0
            )
        }
        return Array(rowsMap.values)
    }

    private func managerProjectRows() -> [ProjectWorkRow] {
        let cal = Calendar.current
        let filtered = managerScheduleStore.managerSiteBookings.filter { booking in
            let day = cal.startOfDay(for: booking.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && (booking.locationType == .project || booking.locationType == .smallWork)
        }
        var totals: [String: Double] = [:]
        var rowsMap: [String: ProjectWorkRow] = [:]
        for booking in filtered {
            guard let user = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { continue }
            let project = projectStore.projects.first(where: { $0.id == booking.locationId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.locationId })
            let projectName = project?.siteName ?? "Unknown"
            let jobNumber = project?.jobNumber ?? "N/A"
            let personName = user.fullName
            let key = "\(projectName)|\(jobNumber)|\(personName)|Manager"
            let dayValue = managerDayValue(from: booking.timeSlot)
            totals[key, default: 0] += dayValue
            rowsMap[key] = ProjectWorkRow(
                projectName: projectName,
                jobNumber: jobNumber,
                personName: personName,
                tradeDisplay: user.displayTradeType,
                tradeSortKey: StaffTradeType.sortKey(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom),
                role: "Manager",
                days: totals[key] ?? 0
            )
        }
        return Array(rowsMap.values)
    }

    private func annualLeaveRows() -> [AnnualLeaveRow] {
        let cal = Calendar.current
        let approved = holidayStore.bookings.filter {
            $0.status == .approved && $0.cancellationRequestedAt == nil
        }
        var totals: [String: AnnualLeaveRow] = [:]
        for booking in approved {
            let days = overlappingDays(for: booking, calendar: cal)
            guard days > 0 else { continue }
            let dayValue = days * booking.timeSlot.dayValue
            if let uid = booking.userId, let u = userStore.organizationUsers.first(where: { $0.id == uid }) {
                let key = "\(u.fullName)|\(u.permissions.manager ? "Manager" : "User")"
                var row = totals[key] ?? AnnualLeaveRow(personName: u.fullName, role: u.permissions.manager ? "Manager" : "User", days: 0)
                row.days += dayValue
                totals[key] = row
            } else if let oid = booking.operativeId,
                      let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
                let key = "\(op.name)|Operative"
                var row = totals[key] ?? AnnualLeaveRow(personName: op.name, role: "Operative", days: 0)
                row.days += dayValue
                totals[key] = row
            }
        }
        return Array(totals.values).sorted(by: { $0.personName < $1.personName })
    }

    private func labourRateSummaries() -> [LabourRateSummary] {
        let cal = Calendar.current
        let operativeBookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && $0.status != .cancelled
        }
        let managerBookings = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
        }
        
        var totals: [String: LabourRateSummary] = [:]
        for booking in operativeBookings {
            guard let operative = operativeStore.allOperatives.first(where: { $0.id == booking.operativeId }) else { continue }
            let user = userStore.organizationUsers.first(where: { $0.email.lowercased() == operative.email.lowercased() })
            let rate = dayRateForOperativeBooking(user: user, operative: operative, on: booking.date)
            let days = bookingDayValue(from: booking.timeSlot)
            let key = labourRateKey(name: operative.name, role: "Operative", rate: rate)
            var summary = totals[key] ?? LabourRateSummary(name: operative.name, role: "Operative", rate: rate, days: 0)
            summary.days += days
            totals[key] = summary
        }
        
        for booking in managerBookings {
            guard let manager = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { continue }
            let managerName = manager.fullName.isEmpty ? manager.email : manager.fullName
            let rate = dayRateForUserOnDay(userId: manager.id, fallback: manager.dayRate, date: booking.date)
            let days = managerDayValue(from: booking.timeSlot)
            let key = labourRateKey(name: managerName, role: "Manager", rate: rate)
            var summary = totals[key] ?? LabourRateSummary(name: managerName, role: "Manager", rate: rate, days: 0)
            summary.days += days
            totals[key] = summary
        }
        
        return Array(totals.values)
    }
    
    private func managerAdditionalScheduleRows() -> [ManagerAdditionalScheduleRow] {
        let cal = Calendar.current
        let filtered = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && ($0.locationType == .office || $0.locationType == .workingFromHome || $0.locationType == .siteSurvey || $0.locationType == .custom)
        }
        return filtered.compactMap { booking in
            guard let person = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { return nil }
            let personName = person.fullName.isEmpty ? person.email : person.fullName
            let locationName: String
            if booking.locationType == .custom {
                let custom = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                locationName = custom.isEmpty ? "Custom" : custom
            } else {
                locationName = booking.locationType.displayName
            }
            return ManagerAdditionalScheduleRow(
                personName: personName,
                location: locationName,
                timeSlotLabel: booking.timeSlot.displayName,
                days: managerDayValue(from: booking.timeSlot)
            )
        }
        .sorted {
            if $0.personName == $1.personName {
                return $0.location < $1.location
            }
            return $0.personName < $1.personName
        }
    }
    
    private func subcontractorRows() -> [SubcontractorWorkRow] {
        let cal = Calendar.current
        let filtered = subcontractorStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && $0.status != .cancelled
        }
        return filtered.compactMap { booking in
            let project = projectStore.projects.first(where: { $0.id == booking.projectId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let subcontractor = subcontractorStore.subcontractors.first(where: { $0.id == booking.subcontractorId })
            guard let project, let subcontractor else { return nil }
            return SubcontractorWorkRow(
                projectName: project.siteName,
                jobNumber: project.jobNumber,
                subcontractorName: subcontractor.name,
                subcontractorType: subcontractor.subcontractorType,
                timeSlotLabel: booking.timeSlot.displayName,
                days: bookingDayValue(from: booking.timeSlot)
            )
        }
        .sorted {
            if $0.projectName == $1.projectName {
                return $0.subcontractorName < $1.subcontractorName
            }
            return $0.projectName < $1.projectName
        }
    }
    
    private func labourRateKey(name: String, role: String, rate: Double?) -> String {
        if let rate {
            return "\(name)|\(role)|\(rate)"
        }
        return "\(name)|\(role)|NO_RATE"
    }

    private func calendarDayStart(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Uses day-rate history keyed by user id; compares **calendar days** so a change effective “tomorrow” does not apply to today’s bookings.
    private func dayRateForUserOnDay(userId: String, fallback: Double?, date: Date) -> Double? {
        let history = (dayRateHistoryByUser[userId] ?? []).sorted(by: { $0.effectiveAt < $1.effectiveAt })
        let day = calendarDayStart(date)
        let rateFromHistory = history.last(where: { calendarDayStart($0.effectiveAt) <= day })?.dayRate
        return rateFromHistory ?? fallback
    }

    private func dayRateForOperativeBooking(user: AppUser?, operative: Operative, on date: Date) -> Double? {
        if let user {
            let fallback = operative.dayRate ?? user.dayRate
            return dayRateForUserOnDay(userId: user.id, fallback: fallback, date: date) ?? user.dayRate ?? operative.dayRate
        }
        return operative.dayRate
    }

    private func overlappingDays(for booking: HolidayBooking, calendar: Calendar) -> Double {
        let rangeStart = calendar.startOfDay(for: startDate)
        let rangeEnd = calendar.startOfDay(for: endDate)
        let start = max(calendar.startOfDay(for: booking.startDate), rangeStart)
        let end = min(calendar.startOfDay(for: booking.endDate), rangeEnd)
        guard start <= end else { return 0 }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return Double(days)
    }

    private func bookingDayValue(from timeSlot: TimeSlot) -> Double {
        switch timeSlot {
        case .fullDay: return 1
        case .morning, .afternoon: return 0.5
        default: return 0.5
        }
    }

    private func managerDayValue(from timeSlot: ManagerTimeSlot) -> Double {
        switch timeSlot {
        case .fullDay: return 1
        case .morning, .afternoon: return 0.5
        }
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formatDays(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatCurrency(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "£%.2f", value)
    }

    private func csvEscape(_ input: String) -> String {
        if input.contains(",") || input.contains("\"") || input.contains("\n") {
            return "\"\(input.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return input
    }
}

private struct ProjectWorkRow {
    let projectName: String
    let jobNumber: String
    let personName: String
    let tradeDisplay: String
    let tradeSortKey: String
    let role: String
    var days: Double
}

private struct AnnualLeaveRow {
    let personName: String
    let role: String
    var days: Double
}

private struct LabourRateSummary {
    let name: String
    let role: String
    let rate: Double?
    var days: Double
}

private struct SubcontractorWorkRow {
    let projectName: String
    let jobNumber: String
    let subcontractorName: String
    let subcontractorType: String
    let timeSlotLabel: String
    let days: Double
}

private struct ManagerAdditionalScheduleRow {
    let personName: String
    let location: String
    let timeSlotLabel: String
    let days: Double
}

private struct WeeklyReportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
