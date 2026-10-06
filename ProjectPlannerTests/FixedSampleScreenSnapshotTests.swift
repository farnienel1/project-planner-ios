//
//  FixedSampleScreenSnapshotTests.swift
//  ProjectPlannerTests
//
//  Simulator: iPhone 16e, iOS 26.2 (UDID 9250FFF9-6782-4AF9-96C3-8E2C04D880A4).
//  Snapshot layout: ViewImageConfig.iPhone13 portrait, 390×844 pt @3x, the same
//  point size as iPhone 16e.
//
//  Record mode is off. These tests compare against the recorded references.
//  app-tests/APP_MAP.md was not in the repo when this file was added.
//  app-tests/VISUAL_ISSUES.md was not present, so no open-issue markers are attached.
//

import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import Project_Planner

@MainActor
final class FixedSampleScreenSnapshotTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_720_000_000)

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        UIView.setAnimationsEnabled(false)
    }

    override func invokeTest() {
        withSnapshotTesting(record: .never) {
            super.invokeTest()
        }
    }

    func testSignIn() {
        assertScreenModes(
            AuthenticationView()
                .environmentObject(FirebaseBackend())
                .environmentObject(UserStore())
        )
    }

    func testResetPassword() {
        assertScreenModes(ResetPasswordSnapshotHost())
    }

    func testChangePassword() {
        assertScreenModes(
            ChangePasswordView()
                .environmentObject(FirebaseBackend())
        )
    }

    func testHelpAndSupport() {
        assertScreenModes(HelpView())
    }

    func testHelpTopicProjects() {
        assertScreenModes(CategoryHelpView(category: .projects))
    }

    func testPrivacyAndTerms() {
        assertScreenModes(PrivacyPolicySnapshotHost())
    }

    func testChooseMode() {
        assertScreenModes(
            AppearanceModeView()
                .environmentObject(fixedSettingsStore(theme: .light))
        )
    }

    func testAppearanceSettings() {
        assertScreenModes(
            AppearanceSettingsView()
                .environmentObject(fixedSettingsStore(theme: .light))
        )
    }

    func testGeneralSettings() {
        assertScreenModes(
            GeneralAppSettingsView()
                .environmentObject(fixedSettingsStore(theme: .light))
        )
    }

    func testMyScheduleOptions() {
        let store = fixedSettingsStore(theme: .light)
        store.settings.myScheduleOptions = MyScheduleOptions(
            showOffice: true,
            showWorkingFromHome: false,
            showSiteSurvey: true,
            customItems: ["Plant"],
            customItemEnabled: ["Plant": true]
        )
        assertScreenModes(
            MyScheduleGeneralOptionsView()
                .environmentObject(store)
        )
    }

    func testJobTypes() {
        let store = ProjectStore()
        store.jobTypes = ["CAT A", "CAT B", "Maintenance"]
        assertScreenModes(
            JobTypesManagementView()
                .environmentObject(store)
        )
    }

    func testClients() {
        let store = ProjectStore()
        store.clients = [
            Client(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!,
                name: "RED Construction",
                contactPerson: "Project Manager",
                email: "pm@redconstruction.example",
                phone: "020 7946 0001",
                address: "71 Broadwick Street, London"
            ),
            Client(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2")!,
                name: "CBC",
                contactPerson: "Site Manager",
                email: "projects@cbc.example",
                phone: "020 7946 0002",
                address: "14 Mercer Street, London"
            ),
        ]
        assertScreenModes(
            ClientsView()
                .environmentObject(store)
                .environmentObject(NotificationService())
                .environmentObject(UserStore())
        )
    }

    func testNewClient() {
        assertScreenModes(
            CreateClientView()
                .environmentObject(ProjectStore())
        )
    }

    func testNewOperative() {
        assertScreenModes(
            CreateOperativeView()
                .environmentObject(OperativeStore())
                .environmentObject(NotificationService())
                .environmentObject(UserStore())
        )
    }

    func testNewManager() {
        assertScreenModes(
            CreateManagerView()
                .environmentObject(OperativeStore())
                .environmentObject(NotificationService())
                .environmentObject(UserStore())
        )
    }

    func testAddJobType() {
        assertScreenModes(
            AddJobTypeView()
                .environmentObject(ProjectStore())
        )
    }

    func testAddUser() {
        assertScreenModes(
            AddUserView(mode: .admin)
                .environmentObject(UserStore())
        )
    }

    func testVariationTracker() {
        let parentId = "parent-snapshot"
        let store = VariationStore(parentId: parentId, parentType: .project)
        var tracker = VariationTracker.disabled(parentId: parentId, parentType: .project)
        tracker.enabled = true
        store.tracker = tracker
        store.variations = [
            sampleVariation(id: "vo-1", number: "VO-001", sequence: 1, heading: "Extra containment", status: .open),
            sampleVariation(id: "vo-2", number: "VO-002", sequence: 2, heading: "Reception joinery", status: .submitted),
        ]
        assertScreenModes(
            VariationTrackerReadOnlyView(store: store, parentName: "C746 · BPR")
        )
    }

    private func fixedSettingsStore(theme: ThemePreference) -> AppSettingsStore {
        let store = AppSettingsStore()
        store.settings.theme = theme
        return store
    }

    private func sampleVariation(
        id: String,
        number: String,
        sequence: Int,
        heading: String,
        status: VariationStatus
    ) -> Variation {
        Variation(
            id: id,
            orgId: "org-snapshot",
            parentType: .project,
            parentId: "parent-snapshot",
            parentName: "C746 · BPR",
            origin: .app,
            voNumber: number,
            sequence: sequence,
            voNumberLocked: true,
            numberHistory: [],
            heading: heading,
            description: "Fixed sample variation",
            status: status,
            labour: [],
            materials: [],
            evidence: [],
            totalLabourHours: 6,
            materialLineCount: 0,
            evidenceCount: 0,
            createdByUid: "user-snapshot",
            createdByName: "Sample User",
            createdAt: fixedDate,
            updatedByUid: "user-snapshot",
            updatedAt: fixedDate,
            statusHistory: [],
            submittedAt: status == .submitted ? fixedDate : nil,
            closedAt: nil,
            isDeleted: false
        )
    }
}

private struct ResetPasswordSnapshotHost: View {
    @State private var email = "planner.snapshot@example.com"

    var body: some View {
        PasswordResetView(email: $email)
            .environmentObject(FirebaseBackend())
    }
}

private struct PrivacyPolicySnapshotHost: View {
    @State private var isAcceptanceRequired = false

    var body: some View {
        PrivacyPolicyView(isAcceptanceRequired: $isAcceptanceRequired)
    }
}
