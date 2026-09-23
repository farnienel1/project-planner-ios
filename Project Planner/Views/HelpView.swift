//
//  HelpView.swift
//  Project Planner
//
//  Created by Assistant on 21/11/2025.
//

import SwiftUI
import UIKit

struct HelpView: View {
    /// When Help is opened as the More-menu tab (not via Settings NavigationLink).
    var showsTabBackButton: Bool = false

    @State private var selectedCategory: HelpCategory? = nil
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Help & support")
                SettingsHubChrome.card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find answers and how-to guides")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text("Browse a topic or expand a frequent question. Get in touch via your organisation admin if you still need help.")
                            .font(.system(size: 12))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 12)
                }

                SettingsHubChrome.sectionTitle("Search")
                SettingsHubChrome.card {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        TextField("Search topics", text: $searchText)
                            .font(.system(size: 14))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                    .padding(.vertical, 12)
                }

                SettingsHubChrome.sectionTitle("Browse topics")
                SettingsHubChrome.card {
                    ForEach(Array(filteredCategories.enumerated()), id: \.element.id) { index, category in
                        Button {
                            selectedCategory = category
                        } label: {
                            SettingsHubChrome.row(
                                icon: category.icon,
                                iconBg: ProjectWorksRevampColors.blue.opacity(0.12),
                                iconFg: ProjectWorksRevampColors.blue,
                                title: category.title,
                                subtitle: category.description
                            )
                        }
                        .buttonStyle(.plain)
                        if index < filteredCategories.count - 1 {
                            SettingsHubChrome.divider()
                        }
                    }
                }

                SettingsHubChrome.sectionTitle("Frequently asked questions")
                SettingsHubChrome.card {
                    ForEach(Array(faqs.enumerated()), id: \.offset) { index, faq in
                        FAQCard(faq: faq)
                        if index < faqs.count - 1 {
                            SettingsHubChrome.divider()
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Help & support")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .toolbar {
            if showsTabBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                }
            }
        }
        .sheet(item: $selectedCategory) { category in
            CategoryHelpView(category: category)
        }
    }

    private var filteredCategories: [HelpCategory] {
        if searchText.isEmpty {
            return HelpCategory.allCases
        }
        return HelpCategory.allCases.filter { category in
            category.title.localizedCaseInsensitiveContains(searchText) ||
            category.description.localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct FAQCard: View {
    let faq: FAQ
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(faq.question)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                }
                if isExpanded {
                    Text(faq.answer)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Category Help View

struct CategoryHelpView: View {
    let category: HelpCategory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHubChrome.sectionTitle(category.title)
                    SettingsHubChrome.card {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(ProjectWorksRevampColors.blue.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: category.icon)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.blue)
                            }
                            Text(category.description)
                                .font(.system(size: 13))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                    }

                    SettingsHubChrome.sectionTitle("How to use")
                    SettingsHubChrome.card {
                        ForEach(Array(category.steps.enumerated()), id: \.offset) { index, step in
                            StepView(number: index + 1, step: step)
                            if index < category.steps.count - 1 {
                                SettingsHubChrome.divider()
                            }
                        }
                    }

                    if !category.tips.isEmpty {
                        SettingsHubChrome.sectionTitle("Tips")
                        SettingsHubChrome.card {
                            ForEach(Array(category.tips.enumerated()), id: \.offset) { index, tip in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "lightbulb.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                    Text(tip)
                                        .font(.system(size: 13))
                                        .foregroundStyle(ProjectWorksRevampColors.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 11)
                                if index < category.tips.count - 1 {
                                    SettingsHubChrome.divider()
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .appChromeNavigationBarSurface()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct StepView: View {
    let number: Int
    let step: HelpStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(ProjectWorksRevampColors.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(step.description)
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Models

enum HelpCategory: String, Identifiable, CaseIterable {
    case projects
    case smallWorks
    case operatives
    case managers
    case bookings
    case clients
    case settings
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .projects: return "Projects"
        case .smallWorks: return "Small Works"
        case .operatives: return "Operatives"
        case .managers: return "Managers"
        case .bookings: return "Bookings"
        case .clients: return "Clients"
        case .settings: return "Settings"
        }
    }
    
    var icon: String {
        switch self {
        case .projects: return "folder.fill"
        case .smallWorks: return "hammer.fill"
        case .operatives: return "person.3.fill"
        case .managers: return "person.badge.key.fill"
        case .bookings: return "calendar"
        case .clients: return "building.2.fill"
        case .settings: return "gearshape.fill"
        }
    }
    
    var description: String {
        switch self {
        case .projects: return "Learn how to create, manage, and track projects"
        case .smallWorks: return "Create and manage small works jobs separately"
        case .operatives: return "Add and manage operatives and qualifications"
        case .managers: return "Manage project managers and their assignments"
        case .bookings: return "Schedule operatives to projects and manage bookings"
        case .clients: return "Add and manage client information"
        case .settings: return "Configure app settings and manage your account"
        }
    }
    
    var steps: [HelpStep] {
        switch self {
        case .projects:
            return [
                HelpStep(title: "View All Projects", description: "Navigate to the Projects tab from the bottom menu bar to see all your projects organized by status."),
                HelpStep(title: "Filter Projects", description: "Use the filter chips at the top (All, Upcoming, Active, Completed, Inactive) to filter projects by status."),
                HelpStep(title: "Create New Project", description: "Tap the + button in the top right corner to create a new project. Fill in job number, site name, address, dates, client, and job type."),
                HelpStep(title: "View Project Details", description: "Tap on any project card to see full details including week overview, bookings, and site location map."),
                HelpStep(title: "Edit Project", description: "On the project details page, tap the edit button (gear icon) to modify project information."),
                HelpStep(title: "Schedule Operatives", description: "From the project details page, tap 'Schedule Operative' to book operatives for specific dates and times (AM, PM, or Full Day)."),
                HelpStep(title: "Change Week View", description: "Use the arrow buttons next to 'Change week' to navigate between weeks and see bookings for different time periods.")
            ]
        case .smallWorks:
            return [
                HelpStep(title: "Access Small Works", description: "Tap 'Small Works' in the bottom menu bar to view all small works jobs."),
                HelpStep(title: "Create Small Works", description: "Tap the + button to create a new small works job. These are separate from regular projects and have their own collection."),
                HelpStep(title: "Select Job Type", description: "Choose a job type for display (e.g., 'CAT A', 'CAT B'). If no job type is selected, 'N/A' will be shown on the card."),
                HelpStep(title: "Manage Small Works", description: "View, edit, and delete small works jobs just like regular projects. They appear in their own separate list.")
            ]
        case .operatives:
            return [
                HelpStep(title: "View Operatives", description: "Go to the 'More' menu (tap the three dots at bottom right), then tap 'Operatives' to see all your operatives."),
                HelpStep(title: "Filter by Status", description: "Use the 'Active' and 'Inactive' toggle at the top to filter operatives by their status."),
                HelpStep(title: "Add New Operative", description: "Tap the + button in the top right, then fill in first name, last name, email, phone, start date, and trade type."),
                HelpStep(title: "Edit Operative", description: "Tap on an operative card, then tap the settings cog icon to edit their information, qualifications, and day rate."),
                HelpStep(title: "Qualifications", description: "Use Qualifications in the main menu (or Manage Users → Qualifications) to assign templates, expiry dates, and certificates."),
                HelpStep(title: "Add Qualifications", description: "Tap 'Manage Qualifications' to add qualifications with issue dates and expiry dates. The app tracks which qualifications are expired."),
                HelpStep(title: "Delete Operative", description: "From the edit view, tap the delete button to remove an operative. This action cannot be undone.")
            ]
        case .managers:
            return [
                HelpStep(title: "View Managers", description: "Tap 'Managers' in the bottom menu bar to see all managers in card format."),
                HelpStep(title: "Filter Managers", description: "Use the 'Active' and 'Inactive' toggle to filter managers by status."),
                HelpStep(title: "Add Manager", description: "Tap the + button and fill in manager details including name, email, and phone number."),
                HelpStep(title: "Assign to Project", description: "When creating or editing a project, select a manager from the dropdown. The manager's name will appear on the project card."),
                HelpStep(title: "Edit Manager", description: "Tap on a manager card, then tap the settings cog icon to edit their information or change their status.")
            ]
        case .bookings:
            return [
                HelpStep(title: "Schedule from Project", description: "Open a project, tap 'Schedule Operative' button below the week navigation, then select operatives and dates."),
                HelpStep(title: "Select Time Slot", description: "Choose AM, PM, or Full Day for each operative booking. This helps organize daily schedules."),
                HelpStep(title: "View Week Overview", description: "On the project details page, see all bookings for the week displayed as vertical bubbles with day names and operative assignments."),
                HelpStep(title: "Navigate Weeks", description: "Use the arrow buttons next to 'Change week' to move forward or backward through weeks."),
                HelpStep(title: "Current Day Highlight", description: "The current day is highlighted in blue with white text in the week overview for easy identification.")
            ]
        case .clients:
            return [
                HelpStep(title: "Create Client", description: "When creating a project or small works, tap 'Create Client' if the client doesn't exist yet. Fill in client name, email, and phone."),
                HelpStep(title: "Select Existing Client", description: "Choose from the dropdown list of existing clients when creating projects."),
                HelpStep(title: "Client Information", description: "Client details (name, email, phone) are stored and reused across all projects for that client.")
            ]
        case .settings:
            return [
                HelpStep(title: "Access Settings", description: "Go to the 'More' menu (three dots), then tap 'Settings'."),
                HelpStep(title: "View Account Info", description: "See your email and organization information at the top of the Settings page."),
                HelpStep(title: "Diagnose Missing Data", description: "If data is missing, tap 'Diagnose Missing Data' to get a detailed report of what's wrong and how to fix it."),
                HelpStep(title: "Force Reload Data", description: "Tap 'Force Reload Data' to manually reload all data from Firebase if something seems out of sync."),
                HelpStep(title: "Manually Link Organization", description: "If automatic organization linking fails, use 'Manually Link Organization' and enter your Organization ID to link your account."),
                HelpStep(title: "Sign Out", description: "Tap 'Sign Out' at the bottom of the Account section to log out of your account.")
            ]
        }
    }
    
    var tips: [String] {
        switch self {
        case .projects:
            return [
                "Use descriptive job numbers to easily identify projects",
                "Set accurate start and end dates for better project tracking",
                "Assign managers to projects for clear responsibility",
                "The week overview shows all bookings at a glance",
                "Pull down on the projects list to refresh data"
            ]
        case .smallWorks:
            return [
                "Small works are kept separate from regular projects",
                "Job types are optional - use them for categorization",
                "Each small works job has its own card for easy identification"
            ]
        case .operatives:
            return [
                "Keep qualification templates up to date so staff can assign them on My Qualifications",
                "Track qualification expiry dates to ensure compliance",
                "Set hourly rates for accurate cost tracking",
                "Deactivate operatives instead of deleting them to preserve history",
                "The app prevents duplicate operatives by checking first and last name"
            ]
        case .managers:
            return [
                "Assign managers early in project creation for better organization",
                "Managers can be assigned to multiple projects",
                "Deactivate managers who are no longer active instead of deleting"
            ]
        case .bookings:
            return [
                "Book operatives well in advance to avoid scheduling conflicts",
                "Use AM/PM slots for half-day bookings",
                "Full Day bookings are best for all-day assignments",
                "Check the week overview regularly to balance workload"
            ]
        case .clients:
            return [
                "Create clients once and reuse them across projects",
                "Keep client contact information up to date",
                "Client names are searchable when creating new projects"
            ]
        case .settings:
            return [
                "Run diagnostics if you notice missing data",
                "Force reload data after major changes",
                "Keep your organization ID handy for troubleshooting",
                "Contact support if manual linking doesn't work"
            ]
        }
    }
}

struct HelpStep {
    let title: String
    let description: String
}

struct FAQ: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

// MARK: - FAQs Data

extension HelpView {
    var faqs: [FAQ] {
        [
            FAQ(
                question: "How do I create a new project?",
                answer: "Navigate to Projects tab, tap the + button in the top right, fill in all required fields (job number, site name, address, dates, client), select a job type if desired, assign a manager if needed, then tap Create."
            ),
            FAQ(
                question: "What's the difference between Projects and Small Works?",
                answer: "Projects and Small Works are separate collections. Small Works are typically smaller jobs that you want to track separately. Both function similarly but are stored in different Firebase collections for better organization."
            ),
            FAQ(
                question: "How do I schedule an operative to a project?",
                answer: "Open the project details page, tap 'Schedule Operative' (located below the week navigation), select one or more operatives, choose dates, and select time slots (AM, PM, or Full Day)."
            ),
            FAQ(
                question: "Why can't I see my projects or operatives?",
                answer: "First, check that you're logged in and your organization is linked. If data is missing, go to Settings > Diagnose Missing Data. You can also try Settings > Force Reload Data. If issues persist, use Settings > Manually Link Organization with your Organization ID."
            ),
            FAQ(
                question: "How do I add qualifications to an operative?",
                answer: "From Manage Users open the person and tap Qualifications, or use Qualifications → My Qualifications for your own. Assign organisation templates, then set expiry dates and upload certificates. Organisation templates are managed under Qualifications → Organisation Qualifications (admins, or managers with Manage Qualifications on)."
            ),
            FAQ(
                question: "Can I delete a project or operative?",
                answer: "Yes, but be careful as deletion is permanent. For projects, use the delete option in edit mode. For operatives, use the delete button in the edit view. Consider deactivating instead of deleting to preserve history."
            ),
            FAQ(
                question: "How do I change my job type selection?",
                answer: "Job types are optional. When creating or editing a project/small works, select a job type from the dropdown, or leave it empty to show 'N/A'. Changing job type does not move the item between Projects and Small Works - those are determined by which collection it was created in."
            ),
            FAQ(
                question: "What if I see 'Custom Manager' on a project card?",
                answer: "This usually means the manager ID wasn't properly linked. Edit the project and select a manager from the dropdown. The manager's name should then appear correctly on the card."
            ),
            FAQ(
                question: "How do I navigate back from Operatives or Settings?",
                answer: "Use the blue chevron back arrow in the top left corner. This will take you back to the Home tab. The grey default back button should be hidden."
            ),
            FAQ(
                question: "My data isn't saving. What should I do?",
                answer: "Check your internet connection first. If online, go to Settings > Diagnose Missing Data to check for organization linking issues. Try Settings > Force Reload Data. If problems persist, ensure your account is properly linked to an organization using the Manual Link option."
            )
        ]
    }
}

#Preview {
    HelpView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
}

