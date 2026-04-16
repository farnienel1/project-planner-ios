//
//  PlaygroundDemoSeeder.swift
//  Project Planner
//
//  Inserts shared Firestore demo project, small works, tasks, and bookings so all roles
//  (including role-testing previews) see the same data.
//

import Foundation

@MainActor
enum PlaygroundDemoSeeder {
    static let demoProjectJobNumber = "DEMO-PP-PROJ"
    static let demoSmallWorksJobNumber = "DEMO-PP-SW"
    private static let demoClientName = "Playground Demo Client"

    /// Creates demo records if missing. Uses the first active operative for sample bookings when available.
    static func seedIfNeeded(
        projectStore: ProjectStore,
        taskStore: ProjectTaskStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        firebaseBackend: FirebaseBackend,
        createdByName: String
    ) async throws -> String {
        if projectStore.projects.contains(where: { $0.jobNumber == demoProjectJobNumber }) {
            return "Playground demo is already in this organization. Open Projects / Small Works to view DEMO-PP-PROJ and DEMO-PP-SW."
        }

        let demoClient: Client
        if let existing = projectStore.clients.first(where: { $0.name == demoClientName }) {
            demoClient = existing
        } else {
            let c = Client(name: demoClientName, contactPerson: "Demo", email: "demo@example.com")
            await projectStore.addClient(c)
            demoClient = projectStore.clients.first(where: { $0.id == c.id }) ?? c
        }

        let cal = Calendar.current
        let today = Date()
        let startMain = cal.date(byAdding: .day, value: -14, to: today) ?? today
        let endMain = cal.date(byAdding: .day, value: 90, to: today) ?? today
        let startSW = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let endSW = cal.date(byAdding: .day, value: 45, to: today) ?? today

        let mainProject = Project(
            jobNumber: demoProjectJobNumber,
            siteName: "Riverside Unit Refit",
            siteAddress: "1 River Lane, Demo City, DC1 1AA",
            client: demoClient,
            startDate: startMain,
            endDate: endMain,
            jobType: .catA,
            manager: .farnie,
            isLive: true,
            description: "Playground demo project — edit as any admin/manager to test sync across roles.",
            notes: "Seeded for strength testing."
        )

        try await projectStore.addProject(mainProject)

        var swProject = Project(
            jobNumber: demoSmallWorksJobNumber,
            siteName: "Lobby Snagging",
            siteAddress: "99 High Street, Test Town, TT1 1TT",
            client: demoClient,
            startDate: startSW,
            endDate: endSW,
            jobType: .smallWorks,
            manager: .farnie,
            isLive: true,
            description: "Playground demo small works.",
            notes: "Seeded for strength testing."
        )
        swProject.customJobType = "Snagging"

        try await projectStore.addSmallWorks(swProject)

        guard let proj = projectStore.projects.first(where: { $0.jobNumber == demoProjectJobNumber }),
              let sw = projectStore.projects.first(where: { $0.jobNumber == demoSmallWorksJobNumber }) else {
            throw NSError(domain: "PlaygroundDemoSeeder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Demo projects not found after save."])
        }

        let sampleOp = operativeStore.activeOperatives.first ?? operativeStore.allOperatives.first
        let targetOpId = sampleOp?.id

        let t1 = ProjectTask(
            projectId: proj.id,
            title: "First fix electrics — demo",
            details: "Check containment and first-fix positions.",
            createdBy: createdByName,
            assignedOperativeId: targetOpId,
            assignedOperativeIds: targetOpId.map { [$0] } ?? [],
            dueDate: cal.date(byAdding: .day, value: 3, to: today),
            status: .todo
        )
        try await taskStore.addTask(t1)

        let t2 = ProjectTask(
            projectId: sw.id,
            title: "Snag list — demo",
            details: "Walk lobby and log paint touch-ups.",
            createdBy: createdByName,
            assignedOperativeId: targetOpId,
            assignedOperativeIds: targetOpId.map { [$0] } ?? [],
            dueDate: cal.date(byAdding: .day, value: 5, to: today),
            status: .inProgress
        )
        try await taskStore.addTask(t2)

        var bookingNote = ""
        if let op = sampleOp {
            let d1 = cal.date(byAdding: .day, value: 2, to: today) ?? today
            let d2 = cal.date(byAdding: .day, value: 4, to: today) ?? today
            await bookingStore.bookOperative(
                op,
                on: d1,
                timeSlot: .morning,
                for: proj,
                bookedBy: createdByName,
                notes: "Playground demo booking",
                notificationService: nil
            )
            await bookingStore.bookOperative(
                op,
                on: d2,
                timeSlot: .afternoon,
                for: sw,
                bookedBy: createdByName,
                notes: "Playground demo small works visit",
                notificationService: nil
            )
        } else {
            bookingNote = " No operatives in the org yet — add an operative to see demo bookings on My Schedule."
        }

        await taskStore.loadData()
        bookingStore.loadData()
        projectStore.loadData()
        operativeStore.loadData()

        return "Playground demo added: project \(demoProjectJobNumber), small works \(demoSmallWorksJobNumber), tasks, and sample data.\(bookingNote)"
    }
}
