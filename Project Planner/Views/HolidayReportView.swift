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
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        yearPicker
                    }
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.top, 16)
                    .padding(.bottom, PPMetrics.headerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ppNavyHeader()

                    VStack(alignment: .leading, spacing: 0) {
                        summaryCard
                        bookingsList
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Holiday Report")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("holidayReport.done")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .task {
                await holidayStore.loadData()
            }
        }
    }

    private var header: some View {
        PPNavyPageTitle(eyebrow: "Holiday Report", title: user.fullName, subtitle: user.email)
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
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .foregroundStyle(selectedYear == year ? PPColor.navy : Color.white)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(
                                Capsule().fill(selectedYear == year ? Color.white : PPColor.onNavyFill)
                            )
                            .overlay(
                                Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: selectedYear == year ? 0 : 0.5)
                            )
                    }
                        .accessibilityIdentifier("holidayReport.row.\(year)")
                        .buttonStyle(PPPressableButtonStyle())
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
        VStack(alignment: .leading, spacing: 0) {
            PPGroupLabel(text: "Summary")
            PPGroupedCard {
                HStack(spacing: 13) {
                    PPIconTile(symbol: "sun.max.fill", family: .plan, size: 38)
                    Text("\(totalDaysTaken) day\(totalDaysTaken == 1 ? "" : "s") approved in \(selectedYear)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var bookingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPGroupLabel(text: "Approved holiday")
            if yearBookings.isEmpty {
                PPGroupedCard {
                    HStack(spacing: 13) {
                        PPIconTile(symbol: "calendar", family: .system, size: PPMetrics.menuIcon)
                        Text("No approved holiday for \(selectedYear).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(yearBookings) { booking in
                        HStack(spacing: 13) {
                            PPIconTile(symbol: "sun.max.fill", family: .plan, size: PPMetrics.menuIcon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(booking.startDate.formatted(date: .abbreviated, time: .omitted)) – \(booking.endDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("\(daysCount(for: booking, inYear: selectedYear)) day\(daysCount(for: booking, inYear: selectedYear) == 1 ? "" : "s")")
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: 54)
                        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
                    }
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

