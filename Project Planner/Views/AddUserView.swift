//
//  AddUserView.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import SwiftUI

struct AddUserView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    /// The level `permissions` was last seeded for (`AddUserPermissionSeeding`); nil before the first seed.
    @State private var permissionsSeededLevel: RulebookPermissionLevel?
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
    @State private var annualLeaveEnabledInvite = true
    @State private var remainingLeaveText = "25"
    @State private var vatNumber = ""
    @State private var utrNumber = ""

    /// A new person has no uid yet, so this is the admin half of `canViewSensitiveProfile`.
    private var canEnterTaxIds: Bool {
        userStore.canViewSensitiveProfile(of: "")
    }
    @State private var isCreating = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    /// RULEBOOK 1.14.0 `payRateRequiredError`, shown under the rate field after a refused create.
    @State private var rateFieldError: String?
    
    private var totalSteps: Int { 4 }
    
    private var finalReviewStep: Int { totalSteps }
    
    init(mode: AddUserMode = .admin) {
        self.mode = mode
        if mode == .managerAddingOperative {
            _invitedAccountType = State(initialValue: .operative)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                wizardHeader
                if showSuccess {
                    successView
                        .ppAddUserSheet()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(stepTitle)
                                .font(.system(.title2, design: .rounded))
                                .fontWeight(.bold)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, 4)
                            stepContentInner
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PPMetrics.screenGutter)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                    }
                    .ppAddUserSheet()
                    wizardFooter
                }
            }
            .background(PPNavyBackdrop().ignoresSafeArea())
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

    // MARK: - Header (navy, display only)

    /// Tracker labels (spec §3): "Permissions" reads "Access" in the tracker and the step heading only.
    private static let trackerTitles = ["Type", "Details", "Access", "Review"]

    private var wizardHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("addUser.cancel")
                    .buttonStyle(PPOnNavyPillButtonStyle())
                Spacer(minLength: 4)
                Text("Add new user")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text("Step \(currentStep) of \(totalSteps)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPAddUserColor.headerMuted)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            headerUserCard
            if currentStep == finalReviewStep && !showSuccess {
                PPStatRow(items: reviewHeaderStats)
            }
            PPStepTracker(steps: trackerSteps, doneColor: PPAddUserColor.stepDone)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(currentStep) of \(totalSteps)")
                .accessibilityValue(Self.trackerTitles[min(max(currentStep, 1), Self.trackerTitles.count) - 1])
                .accessibilityIdentifier("addUser.stepTracker")
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .environment(\.colorScheme, .dark)
    }

    /// Display only: done steps get a tick and a blue bar, the current step the amber stripes. Not tappable (as before).
    private var trackerSteps: [PPStepTrackerItem] {
        Self.trackerTitles.enumerated().map { index, title in
            let step = index + 1
            return PPStepTrackerItem(
                id: step,
                title: title,
                isDone: step < currentStep || showSuccess,
                isCurrent: step == currentStep && !showSuccess
            )
        }
    }

    /// Spec §1 "Header extras": the placeholder shows until a first name or surname is typed (owner decision 6).
    private var headerHasName: Bool {
        !(firstName + surname).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var headerInitials: String {
        let letters = [firstName, surname].compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).first }
        return String(letters).uppercased()
    }

    private var headerFamily: PPFamily {
        switch invitedAccountType {
        case .admin: return .plan
        case .manager: return .people
        case .operative: return .trade
        }
    }

    /// Chips for the values already entered: account type, employment type, trade and line manager.
    private var headerChips: [String] {
        var chips = [invitedAccountType.title, employmentType.title]
        if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager,
           !tradePresetRaw.isEmpty {
            chips.append(StaffTradeType.displayLabel(presetRaw: tradePresetRaw, custom: tradeCustomText))
        }
        if !selectedLineManagerUserIds.isEmpty || hasNoLineManager {
            chips.append("Line manager: \(lineManagerSummary)")
        }
        return chips
    }

    /// The live user card. It reads the fields of this flow and writes nothing.
    @ViewBuilder
    private var headerUserCard: some View {
        if headerHasName {
            PPUserPreviewCard(
                name: "\(firstName) \(surname)".trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: currentStep == finalReviewStep ? email : nil,
                initials: headerInitials,
                family: headerFamily,
                chips: currentStep == finalReviewStep ? [] : headerChips
            )
        } else {
            PPUserPreviewCard(
                name: "New user",
                subtitle: "Choose an account type to start",
                initials: nil,
                family: headerFamily
            )
        }
    }

    /// Review header figures: account type, modules on (of the rows shown) and annual leave days. Display only.
    private var reviewHeaderStats: [PPStatItem] {
        let rows = permissionItems
        let enabled = rows.filter(\.isEnabled).count
        let leave = annualLeaveEnabledInvite
            ? "\(AnnualLeaveUsageHeroView.formatLeaveDays(parseAnnualLeaveDaysForInvite())) days"
            : "Off"
        return [
            PPStatItem(id: "type", value: invitedAccountType.title, label: "Account type"),
            PPStatItem(id: "modules", value: "\(enabled) of \(rows.count)", label: "Modules"),
            PPStatItem(id: "leave", value: leave, label: "Annual leave"),
        ]
    }

    @ViewBuilder
    private var stepContentInner: some View {
        switch currentStep {
        case 1: stepAccountType
        case 2: stepDetailsWithManager
        case 3: stepPermissionsControlled
        case 4: stepReview
        default: EmptyView()
        }
    }

    // MARK: - Bottom bar

    /// RULEBOOK §2: creating the user sends the invite, so the last step is online only.
    private var wizardFooter: some View {
        PPWizardBottomBar(
            backEnabled: currentStep > 1,
            backAction: {
                withAnimation { currentStep -= 1 }
            },
            primaryTitle: primaryButtonTitle,
            primarySymbol: currentStep == finalReviewStep ? "envelope.fill" : "arrow.right",
            primarySymbolLeading: currentStep == finalReviewStep,
            primaryEnabled: !(!canProceed || isCreating || (currentStep == finalReviewStep && !smartCache.isOnline)),
            disabledTitle: nextDisabledTitle,
            isBusy: isCreating,
            primaryAction: {
                if currentStep == finalReviewStep {
                    createUser()
                } else {
                    withAnimation {
                        if mode == .admin && currentStep == 1 {
                            // Seeds only a new level; the line-manager picks were already reset by the account-type
                            // card when the type changed (`AddUserLineManagerSelection`), so Next keeps them.
                            applyPermissionsForInvitedType()
                        }
                        currentStep += 1
                    }
                }
            }
        ) {
            if currentStep == finalReviewStep && !smartCache.isOnline {
                Label(OfflinePolicy.onlineOnlyMessage, systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("offlinePolicy.onlineOnlyMessage")
            }
            // A refused save's message, directly above the buttons (as before).
            if let refusal = refusedCreateMessage {
                PPErrorCallout(message: refusal)
                    .accessibilityIdentifier("addUser.blockingMessage")
            }
        }
    }

    /// The message shown above Next / Create User: a refused create first, else the line-manager rule on the
    /// details step once the rest of the step is filled in.
    private var footerBlockingMessage: String? {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        guard currentStep == 2,
              invitedAccountType == .operative || invitedAccountType == .manager || invitedAccountType == .admin,
              !firstName.isEmpty, !surname.isEmpty, !email.isEmpty else { return nil }
        var draft = inviteDraftUserForValidation
        draft.setLineManagerUserIds(Array(selectedLineManagerUserIds).sorted())
        return AnnualLeaveApproval.lineManagerRequiredError(for: draft, users: userStore.organizationUsers)
    }

    /// Display only: `footerBlockingMessage` when it is a refused save's message.
    private var refusedCreateMessage: String? {
        guard let errorMessage, !errorMessage.isEmpty else { return nil }
        return footerBlockingMessage
    }

    /// Display only: `footerBlockingMessage` when it is the line-manager rule on the details step. Shown in the
    /// Line manager card and on the disabled Next button.
    private var lineManagerInlineMessage: String? {
        guard refusedCreateMessage == nil else { return nil }
        return footerBlockingMessage
    }

    /// Cosmetic label for the same Next / Create User action (spec §3).
    private var primaryButtonTitle: String {
        switch currentStep {
        case 1: return "Next: details"
        case 2: return "Next: access"
        case 3: return "Next: review"
        default: return isCreating ? "Creating…" : "Create User"
        }
    }

    /// What the disabled button says (owner decision 5): the rulebook's line-manager message when that blocks the
    /// step, otherwise a generic line. Read from the same `canProceed` / `footerBlockingMessage`; no new rule.
    private var nextDisabledTitle: String {
        if currentStep == finalReviewStep { return primaryButtonTitle }
        if let lineManagerInlineMessage { return lineManagerInlineMessage }
        return "Fill in the required fields to continue"
    }

    // MARK: - Progress (legacy name kept for references)
    
    private var progressSlider: some View {
        EmptyView()
    }
    
    private var stepTitle: String {
        switch currentStep {
        case 1: return "Account Type"
        case 2: return "User Details"
        case 3: return "Access"
        case 4: return "Review"
        default: return ""
        }
    }
    
    // MARK: - Steps
    
    private var stepAccountType: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .managerAddingOperative
                ? "This account is an operative. Super admin is never assigned from here."
                : "Choose what kind of account this will be. Super admin is never assigned from here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 11) {
                if mode != .managerAddingOperative {
                    accountTypeCard(.admin, symbol: "shield.fill", family: .plan, description: "Full organisation access except operative mode.")
                    accountTypeCard(.manager, symbol: "briefcase.fill", family: .people, description: "Manage teams, schedules and optional modules.")
                }
                accountTypeCard(.operative, symbol: "wrench.and.screwdriver.fill", family: .trade, description: "Schedule, annual leave and qualifications.")
            }
        }
    }

    private func accountTypeCard(_ type: InvitedAccountType, symbol: String, family: PPFamily, description: String) -> some View {
        let selected = invitedAccountType == type
        let lockedToOperative = mode == .managerAddingOperative
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            guard !lockedToOperative, invitedAccountType != type else { return }
            let previousLevel = RulebookPermissionLevel(rawValue: invitedAccountType.rawValue) ?? .manager
            invitedAccountType = type
            applyPermissionsForInvitedType()
            resetAnnualLeaveInviteDefaults()
            let lineManagers = AddUserLineManagerSelection.afterAccountTypeSelection(
                previous: previousLevel,
                next: RulebookPermissionLevel(rawValue: type.rawValue) ?? .manager,
                lineManagerIds: selectedLineManagerUserIds,
                hasNoLineManager: hasNoLineManager,
                // RULEBOOK 1.24.0 §11 `CanonicalBusinessEngine` `lineManagerSelectionAfterLevelChange`: the invite draft
                // as `person`, as `lineManagerCandidates` gets it.
                person: inviteDraftUserForValidation,
                roster: userStore.organizationUsers
            )
            selectedLineManagerUserIds = lineManagers.lineManagerIds
            hasNoLineManager = lineManagers.hasNoLineManager
        } label: {
            HStack(spacing: 14) {
                PPIconTile(symbol: symbol, family: family, size: 44, lifted: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .strokeBorder(selected ? PPAddUserColor.selected : Color(.separator), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if selected {
                        Circle()
                            .fill(PPAddUserColor.selected)
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card, in: shape)
            .overlay(shape.strokeBorder(selected ? PPAddUserColor.selected : PPBookingColor.cardBorder, lineWidth: selected ? 2 : 0.5))
            .shadow(color: selected ? PPAddUserColor.selected.opacity(0.18) : .clear, radius: 8, x: 0, y: 3)
            .contentShape(shape)
        }
        .accessibilityIdentifier("addUser.accountType.\(type.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .buttonStyle(.plain)
    }
    
    private var stepDetailsOnly: some View {
        stepDetailsWithManagerWithoutManagerPicker
    }
    
    /// RULEBOOK 1.11.0 §11: `lineManagerSummary(person, roster)`.
    private var lineManagerSummary: String {
        LineManagerRulebook.summary(
            for: inviteDraftUserForValidation,
            selectedIds: selectedLineManagerUserIds,
            hasNoLineManager: hasNoLineManager,
            roster: userStore.organizationUsers
        )
    }

    private var inviteDraftUserForValidation: AppUser {
        // RULEBOOK 1.27.0 §11 `inviteDraftLineManagerSubject`: id `INVITE_DRAFT_PERSON_ID` and the typed email as the
        // shared rule reads it, passed as `person` to `lineManagerCandidates`, `lineManagerSelectionAfterLevelChange`
        // and `lineManagerRequiredError`, so the invitee is never offered as their own line manager.
        AppUser(
            id: CanonicalBusinessEngine.inviteDraftPersonId,
            email: CanonicalBusinessEngine.inviteDraftLineManagerEmail(email: email, level: invitedAccountType.rawValue),
            organizationId: userStore.currentUser?.organizationId ?? "",
            role: UserRole(rawValue: invitedAccountType.rawValue) ?? .manager,
            permissions: permissions,
            hasNoLineManager: hasNoLineManager,
            // RULEBOOK 1.28.0 `selfManageToggles`: a PAYE admin needs only Annual Leave Management to have no line manager.
            employmentType: employmentType
        )
    }

    /// RULEBOOK 1.33.0 §11 `canChangeLineManager(actor, invite, { isCreate: true })`.
    private var mayChangeLineManager: Bool {
        guard let actor = userStore.currentUser else { return false }
        return CanonicalBusinessEngine.canChangeLineManager(
            actor: actor.lineManagerAccessRow,
            target: inviteDraftUserForValidation.lineManagerAccessRow,
            isCreate: true
        )
    }

    /// `lineManagerRequiredError` for the invite as it will be saved (RULEBOOK §8, §11).
    private var lineManagerSelectionValid: Bool {
        var draft = inviteDraftUserForValidation
        draft.setLineManagerUserIds(Array(selectedLineManagerUserIds).sorted())
        return AnnualLeaveApproval.lineManagerRequiredError(for: draft, users: userStore.organizationUsers) == nil
    }

    @ViewBuilder
    private var lineManagerPickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPFormSectionLabel(text: "Line manager(s)")
            VStack(alignment: .leading, spacing: 12) {
                Text(lineManagerPickerFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showingLineManagerPicker = true
                } label: {
                    lineManagerPickerLabel
                }
                .accessibilityIdentifier("addUser.chevronRight")
                .buttonStyle(.plain)
                // RULEBOOK 1.33.0 §11 `canChangeLineManager` (`isCreate`): set while adding, by admins and, for an
                // operative, by a manager with the Operatives permission.
                .disabled(!mayChangeLineManager)
                // The rulebook's line-manager message (`footerBlockingMessage`), shown inside this card (spec §4).
                if let lineManagerInlineMessage {
                    PPErrorCallout(message: lineManagerInlineMessage)
                        .accessibilityIdentifier("addUser.blockingMessage")
                }
            }
            .ppFormCard(isError: lineManagerInlineMessage != nil)
        }
        .sheet(isPresented: $showingLineManagerPicker) {
            LineManagersMultiSelectSheet(
                candidates: lineManagerCandidates,
                selectedIds: $selectedLineManagerUserIds,
                allowNoLineManager: LineManagerRulebook.allowsNoLineManager(for: inviteDraftUserForValidation),
                hasNoLineManager: $hasNoLineManager
            )
        }
        .onChange(of: selectedLineManagerUserIds) { _, newIds in
            if !newIds.isEmpty { hasNoLineManager = false }
        }
    }

    /// Display only (owner decision 4): the existing `lineManagerSummary` label as one chip, or a dashed
    /// "Choose line manager" button while nothing is chosen. Both open the same Line managers sheet.
    @ViewBuilder
    private var lineManagerPickerLabel: some View {
        if selectedLineManagerUserIds.isEmpty && !hasNoLineManager {
            Label("Choose line manager", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PPColor.brand.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .contentShape(Rectangle())
                .accessibilityValue(lineManagerSummary)
        } else {
            HStack(spacing: 8) {
                PPChip(text: lineManagerSummary, symbol: "person.fill", tone: .blue)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .ppFormField()
            .contentShape(Rectangle())
        }
    }

    /// RULEBOOK §8, §11: `lineManagerRequiredError` on the invite with nobody chosen says whether one is required
    /// (every operative and manager, whatever self-book); only admins may have none.
    private var lineManagerPickerFootnote: String {
        var unassigned = inviteDraftUserForValidation
        unassigned.hasNoLineManager = false
        if AnnualLeaveApproval.lineManagerRequiredError(for: unassigned, users: userStore.organizationUsers) != nil {
            return "Required. Timesheets and annual leave requests from this person go to these line manager(s)."
        }
        // RULEBOOK 1.28.0: an admin may have no line manager only with the self-manage toggles on
        // (`lineManagerRequiredError` above already answered "not required" for this draft).
        return "Optional while Annual Leave Management and Timesheet self-sign are on. Otherwise timesheets and annual leave requests from this person go to these line manager(s)."
    }

    private var stepDetailsWithManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepDetailsWithManagerWithoutManagerPicker

            if invitedAccountType == .operative || invitedAccountType == .manager || invitedAccountType == .admin {
                lineManagerPickerSection
            }
        }
    }

    /// One field of the grouped details card: label above value.
    private func detailsField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PPFormFieldLabel(text: label)
            field()
                .frame(minHeight: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var stepDetailsWithManagerWithoutManagerPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enter the user's basic information")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                detailsField("First Name") {
                    TextField("Enter first name", text: $firstName)
                        .accessibilityIdentifier("addUser.enterFirstName")
                }
                Divider().padding(.leading, 14)
                detailsField("Surname") {
                    TextField("Enter surname", text: $surname)
                        .accessibilityIdentifier("addUser.enterSurname")
                }
                Divider().padding(.leading, 14)
                detailsField("Email Address") {
                    TextField("Enter email address", text: $email)
                        .accessibilityIdentifier("addUser.enterEmailAddress")
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }
                Divider().padding(.leading, 14)
                detailsField("Mobile Number") {
                    TextField("Enter mobile number", text: $mobileNumber)
                        .accessibilityIdentifier("addUser.enterMobileNumber")
                        .keyboardType(.phonePad)
                }
            }
            .ppFormCard(padding: 0)

            PPFormSectionLabel(text: "Employment")
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    PPFormFieldLabel(text: "Employment Type")
                    // Same value as the old segmented Picker: a tap sets `employmentType`.
                    PPSegmentedPills(
                        items: EmploymentType.allCases.map { type in
                            PPSegmentItem(id: type, title: type.title, accessibilityIdentifier: "addUser.employmentType.\(type.rawValue)")
                        },
                        isSelected: { $0 == employmentType },
                        onSelect: { employmentType = $0 }
                    )
                }

                if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                    StaffTradeTypeFormSection(
                        presetRaw: $tradePresetRaw,
                        customText: $tradeCustomText,
                        title: "Trade type *",
                        footnote: "Required for operatives and managers.",
                        style: .card
                    )
                }

                // RULEBOOK 1.14.0 §8, §11: every level has a rate field, because a self-employed person of any level
                // needs a rate (`payRateRequiredError`) when the adder may set pay.
                if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager
                    || invitedAccountType == .admin {
                    VStack(alignment: .leading, spacing: 6) {
                        PPFormFieldLabel(text: inviteRateRequired ? "Day rate *" : "Day rate (optional)")
                        HStack(spacing: 6) {
                            Text("£")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField("e.g. 250", text: dayRateBindingForSelectedType)
                                .accessibilityIdentifier("addUser.eG250")
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                            Text("per day")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .ppFormField()
                        if let rateFieldError {
                            Text(rateFieldError)
                                .font(.caption)
                                .foregroundStyle(PPColor.danger)
                                .accessibilityIdentifier("addUser.payRateRequired")
                        }
                        Text(inviteRateRequired
                             ? CanonicalBusinessEngine.payRateRequiredMessage
                             : (invitedAccountType == .operative || mode == .managerAddingOperative
                                ? "Stored on their user account."
                                : "Optional. Leave blank if not needed."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .onChange(of: employmentType) { _, _ in rateFieldError = nil }
                }

                // Admins only (`canViewSensitiveProfile` for someone else). Saved to the placeholder's private/taxIds.
                if canEnterTaxIds {
                    let taxLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                    taxLayout {
                        VStack(alignment: .leading, spacing: 6) {
                            PPFormFieldLabel(text: "VAT number (optional)")
                            TextField("If VAT registered", text: $vatNumber)
                                .accessibilityIdentifier("addUser.ifVATRegistered")
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .onChange(of: vatNumber) { _, newValue in
                                    let limit = CanonicalBusinessEngine.sensitiveValueMax ?? 20
                                    if newValue.count > limit { vatNumber = String(newValue.prefix(limit)) }
                                }
                                .ppFormField()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            PPFormFieldLabel(text: "UTR number (optional)")
                            TextField("Unique Taxpayer Reference", text: $utrNumber)
                                .accessibilityIdentifier("addUser.uniqueTaxpayerReference")
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .onChange(of: utrNumber) { _, newValue in
                                    let limit = CanonicalBusinessEngine.sensitiveValueMax ?? 20
                                    if newValue.count > limit { utrNumber = String(newValue.prefix(limit)) }
                                }
                                .ppFormField()
                        }
                    }
                }

                if mode == .admin {
                    PPInfoBox(text: "Timesheets follow employment type. Self-employed users get My Timesheets; PAYE users keep the current pay run until it is paid, then schedule no longer fills timesheets.")
                }
            }
            .ppFormCard()
        }
    }
    
    /// RULEBOOK 1.11.0 §11: `lineManagerCandidates(person, roster)` — active admins, super admins and managers,
    /// never an operative, a pending invite, a deleted profile or the person themself.
    private var lineManagerCandidates: [AppUser] {
        LineManagerRulebook.candidates(for: inviteDraftUserForValidation, roster: userStore.organizationUsers)
    }
    
    private func resetAnnualLeaveInviteDefaults() {
        let defaults = userStore.organizationAnnualLeaveDefaults()
        annualLeaveDaysText = defaults.daysPerYear.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(defaults.daysPerYear))
            : String(format: "%.1f", defaults.daysPerYear)
        annualLeaveStartMonth = defaults.startMonth
        // RULEBOOK 1.12.0 §4.4: a stored mismatch reads as 12 months from the start (`leaveYearEndMonth`), so an
        // invite never inherits a year the save would refuse.
        annualLeaveEndMonth = CanonicalBusinessEngine.leaveYearEndMonth(startMonth: defaults.startMonth) ?? defaults.endMonth
        annualLeaveCarriesOver = defaults.carriesOver
        annualLeaveEnabledInvite = true
        remainingLeaveText = annualLeaveDaysText
    }

    private func parseAnnualLeaveDaysForInvite() -> Double {
        let t = annualLeaveDaysText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(t), d > 0 else { return userStore.organizationAnnualLeaveDefaults().daysPerYear }
        return AnnualLeavePolicy.clampDaysPerYear(d)
    }

    private var inviteRemainingOverride: CanonicalBusinessEngine.CanonicalRemainingOverride? {
        guard annualLeaveEnabledInvite else { return nil }
        let days = parseAnnualLeaveDaysForInvite()
        let t = remainingLeaveText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Double(t), raw >= 0 else { return nil }
        let remaining = CanonicalBusinessEngine.snapLeaveDays(raw)
        guard abs(remaining - days) > 0.001 else { return nil }
        let yearKey = CanonicalBusinessEngine.leaveYearBounds(
            startMonth: annualLeaveStartMonth,
            endMonth: annualLeaveEndMonth,
            onDayKey: CanonicalBusinessEngine.dayKey(for: Date())
        )?.yearKey ?? ""
        guard !yearKey.isEmpty else { return nil }
        return CanonicalBusinessEngine.applyRemainingOverride(
            remaining: remaining,
            taken: 0,
            pending: 0,
            yearKey: yearKey
        )
    }

    private var annualLeaveAllowanceCopy: CanonicalBusinessEngine.CanonicalAnnualLeaveAllowanceCopy {
        CanonicalBusinessEngine.annualLeaveAllowanceCopy() ?? CanonicalBusinessEngine.CanonicalAnnualLeaveAllowanceCopy(
            toggleTitle: "Annual leave allowance",
            toggleDescription: "Turn off annual leave allowances using this toggle. This is generally used for self-employed staff who do not get paid annual leave, therefore they do not have a set number of days per year.",
            toggleNote: "When off, this person can still book and see annual leave. They see days taken in the company leave year, not a remaining balance or days per year.",
            remainingTitle: "Manually adjust this user's remaining annual leave allowance for this year",
            remainingNote: "This number will reset to the Days per year figure at the end of your company year."
        )
    }

    private var annualLeaveInvitationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPFormSectionLabel(text: "Annual leave allowance")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    PPIconTile(symbol: "sun.max.fill", family: .trade, size: 30)
                    Toggle(isOn: $annualLeaveEnabledInvite) {
                        Text(annualLeaveAllowanceCopy.toggleTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(PPAddUserColor.selected)
                    .accessibilityIdentifier("addUser.annualLeaveAllowance")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(annualLeaveAllowanceCopy.toggleDescription)
                    Text(annualLeaveAllowanceCopy.toggleNote)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPColor.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if annualLeaveEnabledInvite {
                    AnnualLeaveEntitlementEditor(
                        daysText: $annualLeaveDaysText,
                        startMonth: $annualLeaveStartMonth,
                        endMonth: $annualLeaveEndMonth,
                        carriesOver: $annualLeaveCarriesOver,
                        isEnabled: true,
                        style: .card
                    )
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(annualLeaveAllowanceCopy.remainingTitle)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField("Remaining", text: $remainingLeaveText)
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                                .accessibilityIdentifier("addUser.remainingLeave")
                            Text("days left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .ppFormField()
                        Text(annualLeaveAllowanceCopy.remainingNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .ppFormCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepPermissionsControlled: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !permissionsDescriptionHeader.isEmpty {
                Text(permissionsDescriptionHeader)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            if invitedAccountType == .operative {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Operative mode provides very limited access to the platform. It allows access to their schedule, request annual leave and maintain their qualifications.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text("The below features are additional options, which need to be selected to provide access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPAddUserColor.infoBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 4)
            }
            // RULEBOOK 1.11.0 §11: `permissionToggleRows({ level, user: draft, mode: 'add' })` — the same rows as
            // the summary and Edit User. Admins: every toggle on and greyed out except Annual Leave Management;
            // managers: Materials and Site audit on and greyed out; operatives: Materials and Site audit.
            // A row locked on shows "Included"; a row locked off keeps a disabled switch (owner decision 2).
            PPFormSectionLabel(text: "Modules")
            VStack(spacing: 0) {
                let rows = invitePermissionRows(mode: .add).filter(\.visible)
                ForEach(Array(rows.enumerated()), id: \.element.field) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, 42)
                    }
                    PPToggleRow(
                        title: row.label,
                        description: row.help,
                        symbol: PPToggleRow.symbol(for: row.field),
                        isOn: invitePermissionBinding(row),
                        isLocked: !row.editable
                    )
                    // RULEBOOK 1.28.0 `permissionToggleRows` `note` (a PAYE admin's Timesheet self-sign).
                    if let note = row.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 42)
                            .padding(.bottom, 6)
                            .accessibilityIdentifier("addUser.permissionNote.\(row.field)")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .ppFormCard(padding: 0)

            annualLeaveInvitationSection
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
    
    /// One Account row on Review: label left, value right.
    private func reviewRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var stepReview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Review before sending the invitation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                Text("Account")
                    .font(.headline)
                    .padding(.bottom, 2)
                if mode == .admin {
                    reviewRow("Type") {
                        Text(invitedAccountType.title)
                    }
                } else {
                    Text("Operative (invited by manager)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 10)
                }

                Divider()
                reviewRow("Name") {
                    Text("\(firstName) \(surname)")
                }

                Divider()
                reviewRow("Email") {
                    Text(email)
                }

                Divider()
                reviewRow("Employment type") {
                    Text(employmentType.title)
                }

                if !mobileNumber.isEmpty {
                    Divider()
                    reviewRow("Mobile") {
                        Text(mobileNumber)
                    }
                }

                if permissions.operativeMode || permissions.manager || permissions.adminAccess {
                    Divider()
                    reviewRow("Line manager") {
                        Text(lineManagerSummary)
                    }
                }

                let reviewDayRate = selectedDayRateTextForReview
                if !reviewDayRate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()
                    reviewRow("Day rate") {
                        Text(reviewDayRate)
                            .monospacedDigit()
                    }
                }

                if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                    Divider()
                    reviewRow("Trade") {
                        Text(StaffTradeType.displayLabel(presetRaw: tradePresetRaw, custom: tradeCustomText))
                    }
                }

                if mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager {
                    Divider()
                    annualLeaveReviewRow
                }
            }
            .ppFormCard()

            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions summary")
                    .font(.headline)

                permissionsAccessColumns
            }
            .ppFormCard()
            .padding(.top, 12)
        }
    }
    
    // MARK: - Success
    
    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(PPFamily.sites.top)
                .accessibilityHidden(true)
            
            VStack(spacing: 8) {
                Text("User Created Successfully!")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text("An invitation email has been sent to \(email)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(PPBookingColor.primaryGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .accessibilityIdentifier("addUser.done")
            .buttonStyle(PPPressableButtonStyle())
        }
        .padding(20)
    }
    
    // MARK: - Validation & permissions
    
    /// RULEBOOK 1.11.0 §11: Add User starts each level with `addUserPermissionDefaults(level)`, applied only when the
    /// level is first chosen or changes (`AddUserPermissionSeeding`), so a step change or a step re-appearing never
    /// replaces the toggles the admin picked.
    private func applyPermissionsForInvitedType() {
        let level = RulebookPermissionLevel(rawValue: invitedAccountType.rawValue) ?? .manager
        let seeded = AddUserPermissionSeeding.select(level: level, current: permissions, seededLevel: permissionsSeededLevel)
        permissions = seeded.permissions
        permissionsSeededLevel = seeded.seededLevel
    }

    /// The Add User draft as the permission rules read it (the chosen level's role).
    private var invitePermissionDraft: [String: Any] {
        CanonicalBusinessEngine.permissionSubject(
            permissions: permissions,
            role: invitedAccountType.rawValue,
            isSuperAdmin: false,
            employmentType: employmentType.rawValue
        )
    }

    /// `permissionToggleRows` for the chosen level and the draft.
    private func invitePermissionRows(mode: RulebookPermissionToggleMode) -> [RulebookPermissionToggleRow] {
        let level = RulebookPermissionLevel(rawValue: invitedAccountType.rawValue) ?? .manager
        return CanonicalBusinessEngine.permissionToggleRows(level: level, user: invitePermissionDraft, mode: mode)
    }

    /// An editable row changes the draft; a locked row shows the rulebook's value.
    private func invitePermissionBinding(_ row: RulebookPermissionToggleRow) -> Binding<Bool> {
        guard row.editable else { return .constant(row.value) }
        return Binding(
            get: { permissions.flag(row.field) ?? row.value },
            set: { permissions.setFlag(row.field, $0) }
        )
    }

    /// The toggles the invitation stores: `permissionsWriteMap(draft, level)` (an admin's locked toggles on).
    private var invitePermissionsToWrite: UserPermissions {
        let level = RulebookPermissionLevel(rawValue: invitedAccountType.rawValue) ?? .manager
        guard let map = CanonicalBusinessEngine.permissionsWriteMap(invitePermissionDraft, level: level) else { return permissions }
        return permissions.applying(map)
    }
    
    private var tradeRequiredAndValid: Bool {
        guard mode == .managerAddingOperative || invitedAccountType == .operative || invitedAccountType == .manager else {
            return true
        }
        return StaffTradeTypeFormSection.isValid(presetRaw: tradePresetRaw, customText: tradeCustomText)
    }
    
    private var canProceed: Bool {
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
    
    /// Review reads the allowance toggle. The days field stays at the company default when the toggle is off, so this must not call `parseAnnualLeaveDaysForInvite()` in that case.
    @ViewBuilder
    private var annualLeaveReviewRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Annual leave")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if annualLeaveEnabledInvite {
                let months = AnnualLeavePolicy.shortMonthSymbols()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: "\(AnnualLeaveUsageHeroView.formatLeaveDays(parseAnnualLeaveDaysForInvite())) days / year")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("\(months[annualLeaveStartMonth - 1]) → \(months[annualLeaveEndMonth - 1])")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(annualLeaveCarriesOver ? "Carries over" : "No carry over")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Off")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// RULEBOOK 1.11.0 §11: the summary rows are `permissionToggleRows(..., mode: 'summary')`, the same set Add User
    /// showed for this level.
    private var permissionItems: [(title: String, isEnabled: Bool)] {
        invitePermissionRows(mode: .summary)
            .filter(\.visible)
            .map { (title: $0.label, isEnabled: $0.value) }
    }

    /// Same flags as `permissionItems`. Allowed and denied are split for the review layout only.
    private var permissionsAccessColumns: some View {
        let allowed = permissionItems.filter(\.isEnabled)
        let denied = permissionItems.filter { !$0.isEnabled }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Can access · \(allowed.count)".uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(PPAddUserColor.includedInk)
                PPWrapLayout {
                    ForEach(allowed, id: \.title) { item in
                        PPAccessChip(title: item.title, allowed: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Can't access · \(denied.count)".uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(PPAddUserColor.errorInk)
                PPWrapLayout {
                    ForEach(denied, id: \.title) { item in
                        PPAccessChip(title: item.title, allowed: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private func createUser() {
        if permissions.operativeMode && (permissions.adminAccess || permissions.manager || permissions.operatives) {
            errorMessage = "Operative mode cannot be combined with admin, manager, or operative management flags."
            return
        }
        
        if annualLeaveEnabledInvite {
            let t = remainingLeaveText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = Double(t), d >= 0 else {
                errorMessage = "Enter the remaining allowance in steps of 0.5."
                return
            }
        }

        // RULEBOOK 1.14.0 §8, §11 `payRateRequiredError`: a self-employed person needs a day rate above 0, checked only
        // when the adder may set this person's pay (`canChangePersonPay`).
        if let payMessage = inviteRateError {
            rateFieldError = payMessage
            errorMessage = payMessage
            return
        }

        // RULEBOOK 1.12.0 §4.4 `validateLeaveYearMonths`: the invite's leave year must be 12 months.
        if let leaveYearError = CanonicalBusinessEngine.leaveYearMonthsError(
            startMonth: annualLeaveStartMonth,
            endMonth: annualLeaveEndMonth
        ) {
            errorMessage = leaveYearError
            return
        }

        guard !isCreating else { return }
        
        isCreating = true
        errorMessage = nil
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isCreating = false
                    errorMessage = "Organization not loaded. Please wait a moment and try again."
                }
                return
            }
            do {
                let claimInput = try await firebaseBackend.inviteEmailClaimInput(
                    email: email,
                    organizationId: organizationId
                )
                guard let blocked = CanonicalBusinessEngine.inviteEmailHasLiveClaim(claimInput) else {
                    await MainActor.run {
                        isCreating = false
                        errorMessage = "Could not check whether this email is already in the organisation. Try again."
                    }
                    return
                }
                if blocked {
                    await MainActor.run {
                        isCreating = false
                        errorMessage = "A user with the email address '\(email)' already exists in this organization. Each email address can only be used once per organization."
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = "Could not check whether this email is already in the organisation. Try again."
                }
                return
            }
            let parsedDayRate = parseDayRate(from: selectedDayRateTextForReview)
            let needsTrade = mode == .managerAddingOperative || permissions.operativeMode || permissions.manager
            let tCustom: String? = {
                guard tradePresetRaw == StaffTradeType.other.rawValue else { return nil }
                let t = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }()
            let managerIds = hasNoLineManager ? [] : Array(selectedLineManagerUserIds)
            let success = await userStore.inviteUser(
                firstName: firstName,
                surname: surname,
                email: email,
                mobileNumber: mobileNumber.isEmpty ? nil : mobileNumber,
                permissions: invitePermissionsToWrite,
                employmentType: employmentType,
                assignedManagerUserId: managerIds.first,
                assignedManagerUserIds: managerIds,
                hasNoLineManager: hasNoLineManager,
                invitedOperativeDayRate: permissions.operativeMode ? parsedDayRate : nil,
                invitedManagerDayRate: permissions.manager ? parsedDayRate : nil,
                invitedTradeTypePreset: needsTrade ? tradePresetRaw : nil,
                invitedTradeTypeCustom: needsTrade ? tCustom : nil,
                annualLeaveDaysPerYear: parseAnnualLeaveDaysForInvite(),
                annualLeaveYearStartMonth: annualLeaveStartMonth,
                annualLeaveYearEndMonth: annualLeaveEndMonth,
                annualLeaveCarriesOver: annualLeaveCarriesOver,
                annualLeaveEnabled: annualLeaveEnabledInvite,
                annualLeaveYearAllowance: inviteRemainingOverride?.annualLeaveYearAllowance,
                annualLeaveYearAllowanceKey: inviteRemainingOverride?.annualLeaveYearAllowanceKey,
                timesheetsEnabled: AppUser.defaultTimesheetsEnabled(for: permissions, employmentType: employmentType),
                vatNumber: canEnterTaxIds ? vatNumber : nil,
                utrNumber: canEnterTaxIds ? utrNumber : nil
            )
            
            // RULEBOOK 1.31.0 §13 (owner decision 7): the admins hear that an operative was added (`operative_created`,
            // company activity, never the actor) — invited by an admin or a manager with the Operatives permission.
            if success {
                let invited = invitePermissionsToWrite
                if invited.operativeMode && !invited.manager && !invited.adminAccess {
                    let name = "\(firstName) \(surname)".trimmingCharacters(in: .whitespacesAndNewlines)
                    await userStore.notificationService?.notifyOperativeInvited(
                        userId: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        name: name.isEmpty ? email : name
                    )
                }
            }
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
                rateFieldError = nil
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
        if invitedAccountType == .manager || invitedAccountType == .admin {
            return managerDayRateText
        }
        return ""
    }

    /// `canChangePersonPay` for the person being added (an operative for an operative invite).
    private var adderMaySetInvitePay: Bool {
        userStore.canChangePayOfNewPerson(isOperative: mode == .managerAddingOperative || invitedAccountType == .operative)
    }

    /// The rate field is required: self-employed (`payRateRequiredError` with no rate fails) and the adder may set pay.
    private var inviteRateRequired: Bool {
        adderMaySetInvitePay
            && PayRateRequiredRulebook.error(employmentType: employmentType, payBasis: "day", amount: nil) != nil
    }

    /// `payRateRequiredError` for the invite as it will be saved: a day rate (Add User writes `payBasis` `day`).
    private var inviteRateError: String? {
        guard adderMaySetInvitePay else { return nil }
        return PayRateRequiredRulebook.error(
            employmentType: employmentType,
            payBasis: "day",
            amount: parseDayRate(from: selectedDayRateTextForReview)
        )
    }

    private func parseDayRate(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}

#Preview {
    AddUserView()
        .environmentObject(UserStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(SmartCacheService())
}
