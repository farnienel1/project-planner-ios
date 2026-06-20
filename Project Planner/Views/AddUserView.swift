//
//  AddUserView.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import SwiftUI

struct AddUserView: View {
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    enum AddUserMode {
        case admin
        case managerAddingOperative
    }
    
    enum InvitedAccountType: String, CaseIterable, Identifiable {
        case admin
        case manager
        case operative
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .admin: return "Administrator"
            case .manager: return "Manager"
            case .operative: return "Operative"
            }
        }
    }
    
    let mode: AddUserMode
    
    @State private var currentStep = 1
    @State private var invitedAccountType: InvitedAccountType = .manager
    @State private var firstName = ""
    @State private var surname = ""
    @State private var email = ""
    @State private var mobileNumber = ""
    @State private var employmentType: EmploymentType = .selfEmployed
    @State private var permissions = UserPermissions()
    @State private var selectedLineManagerUserIds: Set<String> = []
    @State private var hasNoLineManager = false
    @State private var showingLineManagerPicker = false
    @State private var operativeDayRateText = ""
    @State private var managerDayRateText = ""
    @State private var tradePresetRaw = StaffTradeType.electrician.rawValue
    @State private var tradeCustomText = ""
    @State private var annualLeaveDaysText = "25"
    @State private var annualLeaveStartMonth = 1
    @State private var annualLeaveEndMonth = 12
    @State private var annualLeaveCarriesOver = false
    @State private var timesheetsEnabled = false
    @State private var vatNumber = ""
    @State private var utrNumber = ""
    @State private var isCreating = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    
    private var totalSteps: Int {
        mode == .managerAddingOperative ? 3 : 4
    }
    
    private var finalReviewStep: Int { totalSteps }
    
    init(mode: AddUserMode = .admin) {
        self.mode = mode
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                ManageUserProfilePalette.pageBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    wizardHeader
                    if showSuccess {
                        successView
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                wizardProgressDots
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                                Text(stepTitle)
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, 12)
                                stepContentInner
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 24)
                            }
                            .padding(.top, 8)
                        }
                        wizardFooter
                    }
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                resetAnnualLeaveInviteDefaults()
                if mode == .managerAddingOperative {
                    invitedAccountType = .operative
                    applyPermissionsForInvitedType()
                    if let me = userStore.currentUser?.id {
                        selectedLineManagerUserIds = [me]
                    }
                } else {
                    applyPermissionsForInvitedType()
                }
            }
        }
    }

    private var wizardHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 17))
                    .foregroundStyle(ManageUserProfilePalette.listBlue)
                Spacer()
                Text(mode == .managerAddingOperative ? "Add Operative" : "Add New User")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Text("Step \(currentStep)/\(totalSteps)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
        }
        .background(ManageUserProfilePalette.pageBackground.opacity(0.95))
    }

    private var wizardProgressDots: some View {
        HStack(spacing: 0) {
            ForEach(1...totalSteps, id: \.self) { step in
                ZStack {
                    Circle()
                        .fill(step < currentStep ? ManageUserProfilePalette.avatarGradientTop : (step == currentStep ? ManageUserProfilePalette.avatarGradientTop : Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE8 / 255)))
                        .frame(width: 26, height: 26)
                    if step < currentStep {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(step == currentStep ? .white : ManageUserProfilePalette.textSecondary)
                    }
                }
                if step < totalSteps {
                    Rectangle()
                        .fill(step < currentStep ? ManageUserProfilePalette.avatarGradientTop : Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE8 / 255))
                        .frame(height: 2.5)
                        .padding(.horizontal, 5)
                }
            }
        }
    }

    @ViewBuilder
    private var stepContentInner: some View {
        if mode == .managerAddingOperative {
            switch currentStep {
            case 1: stepDetailsOnly
            case 2: stepManagerOperativeSummary
            case 3: stepReview
            default: EmptyView()
            }
        } else {
            switch currentStep {
            case 1: stepAccountType
            case 2: stepDetailsWithManager
            case 3: stepPermissionsControlled
            case 4: stepReview
            default: EmptyView()
            }
        }
    }

    private var wizardFooter: some View {
        HStack(spacing: 11) {
            Button {
                withAnimation { currentStep -= 1 }
            } label: {
                Text("Back")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(ManageUserProfilePalette.pageBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(currentStep <= 1)
            .opacity(currentStep <= 1 ? 0.35 : 1)

            Button {
                if currentStep == finalReviewStep {
                    createUser()
                } else {
                    withAnimation {
                        if mode == .admin && currentStep == 1 {
                            applyPermissionsForInvitedType()
                            if invitedAccountType == .operative {
                                selectedLineManagerUserIds.removeAll()
                                hasNoLineManager = false
                            }
                        }
                        currentStep += 1
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(currentStep == finalReviewStep ? (isCreating ? "Creating…" : "Create User") : "Next")
                        .font(.system(size: 16, weight: .bold))
                    if currentStep != finalReviewStep {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255), ManageUserProfilePalette.listBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255).opacity(0.28), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!canProceed || isCreating)
            .opacity((canProceed && !isCreating) ? 1 : 0.55)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }
    
    // MARK: - Progress (legacy name kept for references)
    
    private var progressSlider: some View {
        EmptyView()
    }
    
    private var stepTitle: String {
        if mode == .managerAddingOperative {
            switch currentStep {
            case 1: return "User Details"
            case 2: return "Operative"
            case 3: return "Review"
            default: return ""
            }
        }
        switch currentStep {
        case 1: return "Account Type"
        case 2: return "User Details"
        case 3: return "Permissions"
        case 4: return "Review"
        default: return ""
        }
    }
    
    // MARK: - Steps
    
    private var stepAccountType: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose what kind of account this will be. Super admin is never assigned from here.")
                .font(.system(size: 14))
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                .lineSpacing(3)
            VStack(spacing: 11) {
                accountTypeCard(.admin, icon: "🛡️", description: "Full organisation access except operative mode.")
                accountTypeCard(.manager, icon: "👔", description: "Manage teams, schedules and optional modules.")
                accountTypeCard(.operative, icon: "👷", description: "Schedule, annual leave and qualifications.")
            }
        }
    }

    private func accountTypeCard(_ type: InvitedAccountType, icon: String, description: String) -> some View {
        let selected = invitedAccountType == type
        return Button {
            invitedAccountType = type
            applyPermissionsForInvitedType()
            resetAnnualLeaveInviteDefaults()
            selectedLineManagerUserIds.removeAll()
            hasNoLineManager = false
        } label: {
            HStack(spacing: 14) {
                Text(icon)
                    .font(.system(size: 23))
                    .frame(width: 48, height: 48)
                    .background(ManageUserProfilePalette.chipPurpleBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    Text(description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(selected ? ManageUserProfilePalette.avatarGradientTop : Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if selected {
                        Circle()
                            .fill(ManageUserProfilePalette.avatarGradientTop)
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(16)
            .background(selected ? ManageUserProfilePalette.chipPurpleBg : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? ManageUserProfilePalette.avatarGradientTop : Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEB / 255), lineWidth: selected ? 2 : 1.5)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var stepDetailsOnly: some View {
        stepDetailsWithManagerWithoutManagerPicker
    }
    
    private var lineManagerSummary: String {
        if hasNoLineManager { return "No line manager" }
        if selectedLineManagerUserIds.isEmpty { return "Select manager(s)…" }
        let names = lineManagerCandidates
            .filter { selectedLineManagerUserIds.contains($0.id) }
            .map { $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.email : $0.fullName }
        if names.count == 1 { return names[0] }
        return "\(names.first ?? "Manager") +\(names.count - 1) more"
    }

    private var inviteDraftUserForValidation: AppUser {
        AppUser(
            id: "invite-draft",
            email: email,
            organizationId: userStore.currentUser?.organizationId ?? "",
            role: .manager,
            permissions: permissions,
            hasNoLineManager: hasNoLineManager
        )
    }

    private var lineManagerSelectionValid: Bool {
        if permissions.operativeMode {
            return !selectedLineManagerUserIds.isEmpty
        }
        if permissions.manager || permissions.adminAccess {
            if AnnualLeaveSelfBookPolicy.requiresLineManagerForAnnualLeaveRouting(for: inviteDraftUserForValidation) {
                return !selectedLineManagerUserIds.isEmpty
            }
            return !selectedLineManagerUserIds.isEmpty || hasNoLineManager
        }
        return true
    }

    @ViewBuilder
    private var lineManagerPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line manager(s)")
                .font(.headline)
            Text(lineManagerPickerFootnote)
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                showingLineManagerPicker = true
            } label: {
                HStack {
                    Text(lineManagerSummary)
                        .foregroundStyle(selectedLineManagerUserIds.isEmpty && !hasNoLineManager ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingLineManagerPicker) {
            LineManagersMultiSelectSheet(
                candidates: lineManagerCandidates,
                selectedIds: $selectedLineManagerUserIds,
                allowNoLineManager: !permissions.operativeMode && (permissions.manager || permissions.adminAccess),
                hasNoLineManager: $hasNoLineManager
            )
        }
        .onChange(of: selectedLineManagerUserIds) { _, newIds in
            if !newIds.isEmpty { hasNoLineManager = false }
        }
    }

    private var lineManagerPickerFootnote: String {
        if permissions.operativeMode {
            return "Holiday requests from this operative will go to their line manager(s) (and organisation admins)."
        }
        if AnnualLeaveSelfBookPolicy.requiresLineManagerForAnnualLeaveRouting(for: inviteDraftUserForValidation) {
            return "Required while annual leave self-book is off. Requests route to these line manager(s)."
        }
        return "Optional for senior staff who book their own annual leave. Choose No line manager if they approve their own leave."
    }

    private var stepDetailsWithManager: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepDetailsWithManagerWithoutManagerPicker

            if invitedAccountType == .operative || invitedAccountType == .manager || invitedAccountType == .admin {
                lineManagerPickerSection
            }
        }
    }
    
    private var stepDetailsWithManagerWithoutManagerPicker: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enter the user's basic information")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("First Name")
                        .font(.headline)
                    TextField("Enter first name", text: $firstName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Surname")
                        .font(.headline)
                    TextField("Enter surname", text: $surname)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email Address")
                        .font(.headline)
                    TextField("Enter email address", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mobile Number")
                        .font(.headline)
                    TextField("Enter mobile number", text: $mobileNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.phonePad)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Employment Type")
                        .font(.headline)
                    Picker("Employment Type", selection: $employmentType) {
                        ForEach(EmploymentType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: employmentType) { _, _ in
                        timesheetsEnabled = AppUser.defaultTimesheetsEnabled(for: permissions, employmentType: employmentType)
                    }
                }
                
                if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                    StaffTradeTypeFormSection(
                        presetRaw: $tradePresetRaw,
                        customText: $tradeCustomText,
                        title: "Trade type *",
                        footnote: "Required for operatives and managers."
                    )
                }
                
                if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Day rate (optional)")
                            .font(.headline)
                        TextField("e.g. 250", text: dayRateBindingForSelectedType)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.decimalPad)
                        Text(invitedAccountType == .manager ? "Optional for managers. Leave blank if not needed." : "Stored on the operative profile when their account is linked.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("VAT number (optional)")
                        .font(.headline)
                    TextField("If VAT registered", text: $vatNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .textInputAutocapitalization(.characters)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("UTR number (optional)")
                        .font(.headline)
                    TextField("Unique Taxpayer Reference", text: $utrNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .textInputAutocapitalization(.characters)
                }

                if mode == .admin {
                    Toggle(isOn: $timesheetsEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Timesheets")
                                .font(.headline)
                            Text("Operatives default to on; managers and admins default to off.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
    
    private var lineManagerCandidates: [AppUser] {
        userStore.organizationUsers.filter { u in
            !u.permissions.operativeMode &&
            (u.isSuperAdmin || u.permissions.adminAccess || u.permissions.manager) &&
            u.isActive &&
            u.passwordSet
        }
        .sorted { ($0.fullName.isEmpty ? $0.email : $0.fullName) < ($1.fullName.isEmpty ? $1.email : $1.fullName) }
    }
    
    private var stepManagerOperativeSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This person will be invited as an operative with a limited app view.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundColor(.indigo)
                    Text("Operative mode")
                        .font(.headline)
                }
                Text("Operative mode provides very limited access to the platform. It allows access to their schedule, request annual leave and maintain their qualifications.")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text("The below features are additional options, which need to be selected to provide access.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.indigo.opacity(0.08))
            .cornerRadius(12)

            lineManagerPickerSection
            .onAppear {
                permissions.operativeMode = true
                permissions.adminAccess = false
                permissions.manager = false
                permissions.operatives = false
                permissions.skills = false
                permissions.qualifications = false
                permissions.materials = false
                permissions.projects = true
                permissions.smallWorks = true
                if selectedLineManagerUserIds.isEmpty, let me = userStore.currentUser?.id {
                    selectedLineManagerUserIds = [me]
                }
            }

            annualLeaveInvitationSection
        }
    }
    
    private var invitePermissionDivider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.35))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func permissionInviteCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func resetAnnualLeaveInviteDefaults() {
        let defaults = userStore.organizationAnnualLeaveDefaults()
        annualLeaveDaysText = defaults.daysPerYear.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(defaults.daysPerYear))
            : String(format: "%.1f", defaults.daysPerYear)
        annualLeaveStartMonth = defaults.startMonth
        annualLeaveEndMonth = defaults.endMonth
        annualLeaveCarriesOver = defaults.carriesOver
    }

    private func parseAnnualLeaveDaysForInvite() -> Double {
        let t = annualLeaveDaysText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(t), d > 0 else { return userStore.organizationAnnualLeaveDefaults().daysPerYear }
        return AnnualLeavePolicy.clampDaysPerYear(d)
    }

    private var annualLeaveInvitationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Annual leave")
                .font(.headline)
            Text("Set how many days they receive each leave year, which months the year runs, and whether unused days carry over.")
                .font(.caption)
                .foregroundColor(.secondary)
            permissionInviteCard {
                AnnualLeaveEntitlementEditor(
                    daysText: $annualLeaveDaysText,
                    startMonth: $annualLeaveStartMonth,
                    endMonth: $annualLeaveEndMonth,
                    carriesOver: $annualLeaveCarriesOver,
                    isEnabled: true
                )
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepPermissionsControlled: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(permissionsDescriptionHeader)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                switch invitedAccountType {
                case .admin:
                    permissionInviteCard {
                        VStack(spacing: 0) {
                            PermissionToggle(
                                title: "Admin Access",
                                description: "Full organisation administration (excluding super-admin-only ownership actions).",
                                isOn: .constant(true),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Operative Management",
                                description: "Can open the Operatives tab and manage operative profiles.",
                                isOn: .constant(true),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Skills & Qualifications (org)",
                                description: "Can maintain organisation skills and qualifications catalogues.",
                                isOn: .constant(true),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Projects",
                                description: "Can create and manage projects.",
                                isOn: .constant(true),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Small Works",
                                description: "Can create and manage small works.",
                                isOn: .constant(true),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Operative Mode",
                                description: "Off for admin accounts.",
                                isOn: .constant(false),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Annual Leave Management",
                                description: "Can book their own annual leave. If unselected they will request leave for approval.",
                                isOn: $permissions.annualLeaveSelfBook,
                                isDisabled: hasNoLineManager,
                                style: .plainInset
                            )
                        }
                    }
                case .manager:
                    permissionInviteCard {
                        VStack(spacing: 0) {
                            PermissionToggle(
                                title: "Operatives",
                                description: "Can manage operatives and view their details. If turned off, this user can still assign operatives to projects and small works, but will not see the Operatives tab or full operative profiles.",
                                isOn: $permissions.operatives,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Annual Leave Management",
                                description: "Can book their own annual leave. If unselected the manager will need to request annual leave and have this approved.",
                                isOn: $permissions.annualLeaveSelfBook,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Weekly Report",
                                description: "Can open and pull weekly reports.",
                                isOn: $permissions.weeklyReports,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Daily Overview",
                                description: "Can open daily overview from the home screen and menus.",
                                isOn: $permissions.dailyOverview,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Sub Contractors",
                                description: "Can add and manage sub contractors. If unselected they can still book sub contractors in, but not manage their records.",
                                isOn: $permissions.subContractors,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Skills & Qualifications (org)",
                                description: "Managers can maintain skills and qualifications unless you change this later in Manage Users.",
                                isOn: .constant(true),
                                isDisabled: true,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Projects",
                                description: "Can create and manage projects. If unselected, this manager can still schedule operatives and sub contractors.",
                                isOn: $permissions.projects,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Small Works",
                                description: "Can create and manage small works. If unselected, this manager can still schedule operatives and sub contractors.",
                                isOn: $permissions.smallWorks,
                                isDisabled: false,
                                style: .plainInset
                            )
                            invitePermissionDivider
                            PermissionToggle(
                                title: "Operative Mode",
                                description: "Off for manager accounts.",
                                isOn: .constant(false),
                                isDisabled: true,
                                style: .plainInset
                            )
                        }
                    }
                case .operative:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Operative mode provides very limited access to the platform. It allows access to their schedule, request annual leave and maintain their qualifications.")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text("The below features are additional options, which need to be selected to provide access.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        permissionInviteCard {
                            VStack(spacing: 0) {
                                PermissionToggle(
                                    title: "Materials",
                                    description: "Can access material lists in projects and small works. They will not be able to send quotes or place orders.",
                                    isOn: $permissions.materials,
                                    isDisabled: false,
                                    style: .plainInset
                                )
                                invitePermissionDivider
                                PermissionToggle(
                                    title: "Site Audit",
                                    description: "Can view and submit site audits.",
                                    isOn: $permissions.siteAudit,
                                    isDisabled: false,
                                    style: .plainInset
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if invitedAccountType == .manager || invitedAccountType == .operative {
                    annualLeaveInvitationSection
                }
            }
        }
        .onAppear {
            applyPermissionsForInvitedType()
        }
    }
    
    private var permissionsDescriptionHeader: String {
        switch invitedAccountType {
        case .admin:
            return "Administrator template — all access except operative mode."
        case .manager:
            return "Choose optional manager access. Anything left off can be enabled later in Manage Users."
        case .operative:
            return ""
        }
    }
    
    private var stepReview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review before sending the invitation")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Account")
                        .font(.headline)
                    if mode == .admin {
                        HStack {
                            Text("Type:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(invitedAccountType.title)
                                .fontWeight(.medium)
                        }
                    } else {
                        Text("Operative (invited by manager)")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Name:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(firstName) \(surname)")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Email:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(email)
                            .fontWeight(.medium)
                    }
                HStack {
                    Text("Employment type:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(employmentType.title)
                        .fontWeight(.medium)
                }
                    
                    if !mobileNumber.isEmpty {
                        HStack {
                            Text("Mobile:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(mobileNumber)
                                .fontWeight(.medium)
                        }
                    }
                    
                    if permissions.operativeMode || permissions.manager || permissions.adminAccess {
                        HStack(alignment: .top) {
                            Text("Line manager:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(lineManagerSummary)
                                .fontWeight(.medium)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    
                    let reviewDayRate = selectedDayRateTextForReview
                    if !reviewDayRate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack {
                            Text("Day rate:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(reviewDayRate)
                                .fontWeight(.medium)
                        }
                    }
                    
                    if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                        HStack {
                            Text("Trade:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(StaffTradeType.displayLabel(presetRaw: tradePresetRaw, custom: tradeCustomText))
                                .fontWeight(.medium)
                        }
                    }

                    if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                        let months = AnnualLeavePolicy.shortMonthSymbols()
                        HStack {
                            Text("Annual leave:")
                                .foregroundColor(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(parseAnnualLeaveDaysForInvite()) days / year")
                                    .fontWeight(.medium)
                                Text("\(months[annualLeaveStartMonth - 1]) → \(months[annualLeaveEndMonth - 1])")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(annualLeaveCarriesOver ? "Carries over" : "No carry over")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions summary")
                        .font(.headline)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(permissionItems, id: \.title) { item in
                            HStack {
                                Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundColor(item.isEnabled ? .green : .red)
                                Text(item.title)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Success
    
    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            VStack(spacing: 8) {
                Text("User Created Successfully!")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("An invitation email has been sent to \(email)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .padding(20)
    }
    
    // MARK: - Validation & permissions
    
    private func applyPermissionsForInvitedType() {
        switch invitedAccountType {
        case .admin:
            permissions = UserPermissions(
                adminAccess: true,
                manager: true,
                operatives: true,
                skills: true,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                annualLeaveSelfBook: false,
                wholesalersOrderHistory: true
            )
        case .manager:
            permissions = UserPermissions(
                adminAccess: false,
                manager: true,
                operatives: false,
                skills: true,
                qualifications: true,
                materials: true,
                projects: false,
                smallWorks: false,
                operativeMode: false,
                annualLeaveSelfBook: false,
                weeklyReports: false,
                dailyOverview: true,
                subContractors: false,
                siteAudit: true,
                wholesalersOrderHistory: true
            )
        case .operative:
            permissions = UserPermissions(
                adminAccess: false,
                manager: false,
                operatives: false,
                skills: false,
                qualifications: false,
                materials: false,
                projects: true,
                smallWorks: true,
                operativeMode: true,
                siteAudit: true
            )
        }
        timesheetsEnabled = AppUser.defaultTimesheetsEnabled(for: permissions, employmentType: employmentType)
    }
    
    private var tradeRequiredAndValid: Bool {
        guard mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager else {
            return true
        }
        return StaffTradeTypeFormSection.isValid(presetRaw: tradePresetRaw, customText: tradeCustomText)
    }
    
    private var canProceed: Bool {
        if mode == .managerAddingOperative {
            switch currentStep {
            case 1:
                return !firstName.isEmpty && !surname.isEmpty && !email.isEmpty && isValidEmail(email) && tradeRequiredAndValid
            case 2:
                return lineManagerSelectionValid
            case 3:
                return true
            default:
                return false
            }
        }
        switch currentStep {
        case 1:
            return true
        case 2:
            let base = !firstName.isEmpty && !surname.isEmpty && !email.isEmpty && isValidEmail(email) && tradeRequiredAndValid
            if invitedAccountType == .operative || invitedAccountType == .manager || invitedAccountType == .admin {
                return base && lineManagerSelectionValid
            }
            return base
        case 3:
            return true
        case 4:
            return true
        default:
            return false
        }
    }
    
    private var permissionItems: [(title: String, isEnabled: Bool)] {
        [
            ("Admin Access", permissions.adminAccess),
            ("Manager", permissions.manager),
            ("Operative Management", permissions.operatives),
            ("Skills (org)", permissions.skills),
            ("Qualifications (org)", permissions.qualifications),
            ("Materials", permissions.materials),
            ("Projects", permissions.projects),
            ("Small Works", permissions.smallWorks),
            ("Operative Mode", permissions.operativeMode),
            ("Annual Leave Management", permissions.annualLeaveSelfBook),
            ("Weekly Reports", permissions.weeklyReports),
            ("Daily Overview", permissions.dailyOverview),
            ("Sub Contractors", permissions.subContractors),
            ("Site Audit", permissions.siteAudit)
        ]
    }
    
    private func createUser() {
        if permissions.operativeMode && (permissions.adminAccess || permissions.manager || permissions.operatives) {
            errorMessage = "Operative mode cannot be combined with admin, manager, or operative management flags."
            return
        }
        
        guard !isCreating else { return }
        
        isCreating = true
        errorMessage = nil
        
        Task {
            let parsedDayRate = parseDayRate(from: selectedDayRateTextForReview)
            let needsTrade = mode == .managerAddingOperative || permissions.operativeMode || permissions.manager
            let tCustom: String? = {
                guard tradePresetRaw == StaffTradeType.other.rawValue else { return nil }
                let t = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }()
            let managerIds = hasNoLineManager ? [] : Array(selectedLineManagerUserIds)
            let passAnnualLeaveInvite = mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager
            let success = await userStore.inviteUser(
                firstName: firstName,
                surname: surname,
                email: email,
                mobileNumber: mobileNumber.isEmpty ? nil : mobileNumber,
                permissions: permissions,
                employmentType: employmentType,
                assignedManagerUserId: managerIds.first,
                assignedManagerUserIds: managerIds,
                hasNoLineManager: hasNoLineManager,
                invitedOperativeDayRate: permissions.operativeMode ? parsedDayRate : nil,
                invitedManagerDayRate: permissions.manager ? parsedDayRate : nil,
                invitedTradeTypePreset: needsTrade ? tradePresetRaw : nil,
                invitedTradeTypeCustom: needsTrade ? tCustom : nil,
                annualLeaveDaysPerYear: passAnnualLeaveInvite ? parseAnnualLeaveDaysForInvite() : nil,
                annualLeaveYearStartMonth: passAnnualLeaveInvite ? annualLeaveStartMonth : nil,
                annualLeaveYearEndMonth: passAnnualLeaveInvite ? annualLeaveEndMonth : nil,
                annualLeaveCarriesOver: passAnnualLeaveInvite ? annualLeaveCarriesOver : nil,
                timesheetsEnabled: mode == .admin ? timesheetsEnabled : AppUser.defaultTimesheetsEnabled(for: permissions, employmentType: employmentType),
                vatNumber: vatNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : vatNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                utrNumber: utrNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : utrNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            
            await MainActor.run {
                isCreating = false
                if success {
                    withAnimation {
                        showSuccess = true
                    }
                } else {
                    errorMessage = userStore.errorMessage ?? "Failed to create user. Please try again."
                }
            }
        }
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }

    private var dayRateBindingForSelectedType: Binding<String> {
        Binding(
            get: {
                if mode == .managerAddingOperative || invitedAccountType == .operative {
                    return operativeDayRateText
                }
                return managerDayRateText
            },
            set: { newValue in
                if mode == .managerAddingOperative || invitedAccountType == .operative {
                    operativeDayRateText = newValue
                } else {
                    managerDayRateText = newValue
                }
            }
        )
    }

    private var selectedDayRateTextForReview: String {
        if mode == .managerAddingOperative || invitedAccountType == .operative {
            return operativeDayRateText
        }
        if invitedAccountType == .manager {
            return managerDayRateText
        }
        return ""
    }

    private func parseDayRate(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}

// MARK: - Permission Toggle Component

struct PermissionToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool
    var isDisabled: Bool = false
    var style: Style = .filledRow

    enum Style {
        case filledRow
        case plainInset
    }

    @State private var expanded = false

    var body: some View {
        let row = HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(isDisabled ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .tint(.indigo)
                .disabled(isDisabled)
        }

        Group {
            switch style {
            case .filledRow:
                row
                    .padding()
                    .background(isDisabled ? Color(.systemGray5) : Color(.systemGray6))
                    .cornerRadius(12)
            case .plainInset:
                row
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
            }
        }
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

#Preview {
    AddUserView()
        .environmentObject(UserStore())
}
