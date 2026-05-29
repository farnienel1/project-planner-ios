import SwiftUI

struct HolidayReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var operativeStore: OperativeStore

    let user: AppUser

    @State private var selectedYear: Int

    init(user: AppUser) {
        self.user = user
        let currentYear = Calendar.current.component(.year, from: Date())
        _selectedYear = State(initialValue: currentYear)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    yearPicker
                    summaryCard
                    bookingsList
                }
                .padding(16)
            }
            .navigationTitle("Holiday Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await holidayStore.loadData()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(user.fullName)
                .font(.title3)
                .fontWeight(.semibold)
            Text(user.email)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var joinDate: Date {
        if let operative = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
            return operative.startDate
        }
        return user.createdAt
    }

    private var availableYears: [Int] {
        let cal = Calendar.current
        let startYear = cal.component(.year, from: joinDate)
        let endYear = cal.component(.year, from: Date())
        guard startYear <= endYear else { return [endYear] }
        return Array(startYear...endYear)
    }

    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableYears, id: \.self) { year in
                    Button {
                        selectedYear = year
                    } label: {
                        Text("\(year)")
                            .font(.headline)
                            .foregroundColor(selectedYear == year ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(selectedYear == year ? Color.indigo : Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                }
            }
        }
    }

    private var yearBookings: [HolidayBooking] {
        let cal = Calendar.current
        let yearStart = cal.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!
        let yearEnd = cal.date(from: DateComponents(year: selectedYear, month: 12, day: 31))!

        let operative = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() })

        return holidayStore.bookings
            .filter { $0.status == .approved }
            .filter { booking in
                if let operative, booking.operativeId == operative.id { return true }
                if booking.userId == user.id { return true }
                return false
            }
            .filter { booking in
                // include any booking overlapping this year
                let start = cal.startOfDay(for: booking.startDate)
                let end = cal.startOfDay(for: booking.endDate)
                return end >= yearStart && start <= yearEnd
            }
            .sorted { $0.startDate > $1.startDate }
    }

    private var totalDaysTaken: Int {
        yearBookings.reduce(0) { partial, booking in
            partial + daysCount(for: booking, inYear: selectedYear)
        }
    }

    private func daysCount(for booking: HolidayBooking, inYear year: Int) -> Int {
        let cal = Calendar.current
        let yearStart = cal.startOfDay(for: cal.date(from: DateComponents(year: year, month: 1, day: 1))!)
        let yearEnd = cal.startOfDay(for: cal.date(from: DateComponents(year: year, month: 12, day: 31))!)
        let start = max(cal.startOfDay(for: booking.startDate), yearStart)
        let end = min(cal.startOfDay(for: booking.endDate), yearEnd)
        guard start <= end else { return 0 }
        let days = cal.dateComponents([.day], from: start, to: end).day ?? 0
        return days + 1
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)
            Text("\(totalDaysTaken) day\(totalDaysTaken == 1 ? "" : "s") approved in \(selectedYear)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var bookingsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approved holiday")
                .font(.headline)
            if yearBookings.isEmpty {
                Text("No approved holiday for \(selectedYear).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(yearBookings) { booking in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(booking.startDate.formatted(date: .abbreviated, time: .omitted)) – \(booking.endDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("\(daysCount(for: booking, inYear: selectedYear)) day\(daysCount(for: booking, inYear: selectedYear) == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
            }
        }
    }
}

#Preview {
    HolidayReportView(user: AppUser(id: "1", email: "test@example.com", organizationId: "org", role: .manager, createdAt: Date(), firstName: "Test", surname: "User", isActive: true, passwordSet: true, permissions: UserPermissions(manager: true), isSuperAdmin: false))
        .environmentObject(HolidayStore())
        .environmentObject(OperativeStore())
}

