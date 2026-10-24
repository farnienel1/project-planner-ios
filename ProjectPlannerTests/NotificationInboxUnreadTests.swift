import XCTest
@testable import Project_Planner

@MainActor
final class NotificationInboxUnreadTests: XCTestCase {
    func testListedUnreadCountStaysUntilARowIsMarkedRead() async {
        let service = NotificationService()
        let store = UserStore()
        store.currentUser = AppUser(
            id: "u1",
            email: "a@example.com",
            organizationId: "org",
            role: .operative
        )
        service.setUserStore(store)

        let first = notification(userId: "u1")
        let second = notification(userId: "u1")
        let someoneElse = notification(userId: "u2")
        service.notifications = [first, second, someoneElse]
        service.setUnreadCount(from: service.notifications)
        XCTAssertEqual(service.unreadCount, 2)

        await service.markAsRead(first)
        XCTAssertEqual(service.unreadCount, 1)
        XCTAssertEqual(service.notifications.first(where: { $0.id == second.id })?.isRead, false)
    }

    func testAnotherUsersRowIsHiddenAndVisibleRowsSortNewestFirst() {
        let service = NotificationService()
        let store = UserStore()
        store.currentUser = AppUser(
            id: "u1",
            email: "a@example.com",
            organizationId: "org",
            role: .operative
        )
        service.setUserStore(store)

        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_086_400)
        let other = notification(userId: "u2", createdAt: newer, isRead: false)
        let oldMine = notification(userId: "u1", createdAt: older, isRead: false)
        let newMine = notification(userId: "u1", createdAt: newer, isRead: true)
        let listed = service.listedInbox([other, oldMine, newMine], userId: "u1")

        XCTAssertEqual(listed.map(\.id), [newMine.id, oldMine.id])
        XCTAssertFalse(listed.contains { $0.userId == "u2" })

        service.notifications = listed
        service.setUnreadCount(from: listed)
        XCTAssertEqual(service.unreadCount, 1)
        XCTAssertEqual(
            CanonicalBusinessEngine.unreadNotificationBadgeCount(
                notifications: listed.map {
                    CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: $0.userId, isRead: $0.isRead)
                },
                userId: "u1"
            ),
            service.unreadCount
        )
    }

    func testClearingTheIconBadgeLeavesTheInAppCount() {
        let service = NotificationService()
        let store = UserStore()
        store.currentUser = AppUser(
            id: "u1",
            email: "a@example.com",
            organizationId: "org",
            role: .operative
        )
        service.setUserStore(store)
        service.notifications = [notification(userId: "u1"), notification(userId: "u1")]
        service.setUnreadCount(from: service.notifications)
        let before = service.unreadCount

        service.clearAppIconBadgeIfNeeded()

        XCTAssertEqual(CanonicalBusinessEngine.notificationIconBadgeClearsOnForeground, true)
        XCTAssertEqual(service.unreadCount, before)
        XCTAssertEqual(before, 2)
    }

    private func notification(userId: String, createdAt: Date = Date(), isRead: Bool = false) -> AppNotification {
        AppNotification(
            organizationId: "org",
            type: .bookingCreated,
            title: "Booking",
            message: "A booking was added.",
            userId: userId,
            isRead: isRead,
            createdAt: createdAt
        )
    }
}
