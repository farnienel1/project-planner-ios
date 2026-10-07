import XCTest
@testable import Project_Planner

@MainActor
enum LogicFixtures {
    static let policy = OrgPayrollTimePolicy.default

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    static func day(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0,
        calendar: Calendar = .current
    ) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts)!
    }

    static func booking(
        on day: Date,
        slot: TimeSlot = .fullDay,
        start: String? = nil,
        end: String? = nil,
        breakRemoved: Bool = false,
        status: BookingStatus = .confirmed,
        operativeId: UUID = UUID(),
        projectId: UUID = UUID()
    ) -> Booking {
        Booking(
            operativeId: operativeId,
            projectId: projectId,
            date: day,
            timeSlot: slot,
            bookedBy: "unit-test",
            status: status,
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: breakRemoved
        )
    }

    static func selfEmployedUser(
        id: String = "user-1",
        email: String = "worker@example.com",
        dayRate: Double = 200
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "org-test",
            role: .operative,
            firstName: "Ada",
            surname: "Lovelace",
            permissions: UserPermissions(operativeMode: true),
            dayRate: dayRate,
            employmentType: .selfEmployed
        )
    }

    static func operative(id: UUID, email: String, dayRate: Double = 200) -> Operative {
        Operative(
            id: id,
            firstName: "Ada",
            lastName: "Lovelace",
            email: email,
            startDate: Date(timeIntervalSince1970: 0),
            dayRate: dayRate
        )
    }

    static func holiday(
        userId: String,
        start: Date,
        end: Date,
        status: HolidayStatus = .approved,
        slot: HolidayTimeSlot = .fullDay
    ) -> HolidayBooking {
        HolidayBooking(
            organizationId: "org-test",
            userId: userId,
            startDate: start,
            endDate: end,
            status: status,
            timeSlot: slot
        )
    }

    static func variation(
        id: String,
        voNumber: String,
        sequence: Int,
        status: VariationStatus = .open,
        isDeleted: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Variation {
        Variation(
            id: id,
            orgId: "org-test",
            parentType: .project,
            parentId: "project-a",
            parentName: "100 · Site",
            origin: .app,
            voNumber: voNumber,
            sequence: sequence,
            voNumberLocked: status != .open,
            numberHistory: [],
            heading: "Heading",
            description: "",
            status: status,
            labour: [],
            materials: [],
            evidence: [],
            totalLabourHours: 0,
            materialLineCount: 0,
            evidenceCount: 0,
            createdByUid: "user-1",
            createdByName: "Ada",
            createdAt: createdAt,
            updatedByUid: "user-1",
            updatedAt: createdAt,
            statusHistory: [],
            submittedAt: status == .submitted ? createdAt : nil,
            closedAt: status == .closed ? createdAt : nil,
            isDeleted: isDeleted
        )
    }

    static func managerBooking(
        on day: Date,
        start: String,
        end: String,
        userId: String = "user-1"
    ) -> ManagerSiteBooking {
        ManagerSiteBooking(
            userId: userId,
            date: day,
            timeSlot: .customHours,
            locationType: .office,
            workStartTime: start,
            workEndTime: end
        )
    }
}

func XCTAssertClose(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double = 0.001,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
}
