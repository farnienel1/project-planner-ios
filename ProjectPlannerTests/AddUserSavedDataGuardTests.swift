import CryptoKit
import XCTest

/// Add User restyle (UI only, docs/design/add-user-ui/add-user-ui-spec.md §1, §5): the code that builds the saved user
/// document and the invitation, decides when Next is enabled, seeds the templates and runs every button must not change
/// in a restyle. Each guarded body is hashed with its whitespace collapsed (re-indenting it inside a new layout is fine)
/// and compared with the hash recorded from origin/main 6da3df4, before the restyle. A failure here is a behaviour
/// change: make it in its own PR, say why, and record the new hash there.
///
/// New baseline (RULEBOOK 1.34.0 §11, ghost operatives — a deliberate behaviour change, not a restyle): Add user gains
/// the Ghost account toggle. `init(mode:startAsGhost:)` replaces `init(mode:)`; `footerBlockingMessage`,
/// `lineManagerPickerFootnote`, `canProceed` and `createUser()` gain the ghost branches (`ghostCreateError`,
/// `createGhostAccount()`); the account-type card's action moved into `selectAccountType(_:)` (also used when the
/// toggle switches the type to operative), now guarded on its own. Every other recorded hash is unchanged.
///
/// Owner decision 7 Nov "1b" (RULEBOOK 1.34.0 §18, `ghostAccountsEnabled` / `ghostToggleVisible`): the Ghost account
/// toggle shows only while `platformConfig/app.ghostAccounts` is on. Only unguarded properties changed (`ghostMode`,
/// `ghostFormRows`, `ghostToggleCard`); every recorded hash is unchanged.
///
/// New baseline (RULEBOOK 1.36.0 §11, owner decision 10 Nov "warn about a duplicate name when adding a user" — a
/// deliberate behaviour change): `createUser()` gains one line after the form's own checks, `if stopForDuplicateName()
/// { return }` (`usersWithSameName`; Add anyway saves as before). Its hash was recomputed with this test's own
/// extraction (marker through the closing brace, whitespace collapsed, SHA-256). Every other recorded hash is unchanged.
///
/// New baseline (RULEBOOK 1.40.0 §4.4, owner decision 11 Nov H35 — a deliberate behaviour change): Add user no longer
/// sets a "remaining this year" figure; `inviteRemainingOverride` returns nil (a joiner is pro rata from their start
/// date, and extra days are an adjustment with a reason). Its hash was recomputed with this test's own extraction.
/// Every other recorded hash is unchanged.
final class AddUserSavedDataGuardTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// (file, marker that starts the declaration, SHA-256 of the declaration through its closing brace).
    private static let guardedBodies: [(file: String, marker: String, sha256: String)] = [
        ("Project Planner/Views/AddUserView.swift", "init(mode: AddUserMode = .admin, startAsGhost: Bool = false) {", "247745521dd1353c645ce8aa578d7a93ac217d8c1dd4075085dad08f211f48a5"),
        ("Project Planner/Views/AddUserView.swift", "private var footerBlockingMessage: String? {", "d33f6041ae8a03aa5d83662a0ce188acb49bf8d7e46fed1f52812d5ef9460ca2"),
        ("Project Planner/Views/AddUserView.swift", "private var inviteDraftUserForValidation: AppUser {", "c5253af924de9aedbe59857f0157c457eeb8eda9c7fed6267aa8354d7c7323eb"),
        ("Project Planner/Views/AddUserView.swift", "private var lineManagerSelectionValid: Bool {", "2c461a46a4041d42a5842ef6ca9f497d8de9ec61f4984cfec47f0ef8947a8eb0"),
        ("Project Planner/Views/AddUserView.swift", "private var lineManagerPickerFootnote: String {", "bf523f014322df1d2036b5d84499ff2e9476af2fa900b4f1ff8e50b76991272e"),
        ("Project Planner/Views/AddUserView.swift", "private var lineManagerCandidates: [AppUser] {", "006673d9542e5469989b75109a5c1091661f766d6a3e0c774cdbd27e343b3d17"),
        ("Project Planner/Views/AddUserView.swift", "private var lineManagerSummary: String {", "e8f06da82202af7aae99b4853f5b6d904b4e2b89ca25f931f24d71b699f7af5d"),
        ("Project Planner/Views/AddUserView.swift", "private func resetAnnualLeaveInviteDefaults() {", "f17b78c831a34b530fa859da42d803b6a17859082423f27a12679e754660398c"),
        ("Project Planner/Views/AddUserView.swift", "private func parseAnnualLeaveDaysForInvite() -> Double {", "a2e00bbf0a0e9ff9b8c4a7d9ffa3cc1eeb94ff1771abea044789b77af5739a4e"),
        ("Project Planner/Views/AddUserView.swift", "private var inviteRemainingOverride: CanonicalBusinessEngine.CanonicalRemainingOverride? {", "c44279ed31eb598090e5366520effa9c616f3e62b0f1e5d115794be899909fd0"),
        ("Project Planner/Views/AddUserView.swift", "private var annualLeaveAllowanceCopy: CanonicalBusinessEngine.CanonicalAnnualLeaveAllowanceCopy {", "0eb42bcf835ccec753425e18594d650432f9f7e392a07571ecc558b02bc97744"),
        ("Project Planner/Views/AddUserView.swift", "private var permissionsDescriptionHeader: String {", "b6b8c0d3df760a1c7d3b2b570ec5b1fbdf3b866dfabf31dd6072559bbb6b6bd7"),
        ("Project Planner/Views/AddUserView.swift", "private func applyPermissionsForInvitedType() {", "33d474cf3f9ad5e4fd366549fa2164a47adc434718cf0c13a5552c360a425ea9"),
        ("Project Planner/Views/AddUserView.swift", "private var invitePermissionDraft: [String: Any] {", "1a70860ae521bf1858f341cf3e07a3323bfad43c874cd331eac56a5b49271509"),
        ("Project Planner/Views/AddUserView.swift", "private func invitePermissionRows(mode: RulebookPermissionToggleMode) -> [RulebookPermissionToggleRow] {", "910fdef4f9e2573cca0c245b6ec921c4c765ffb06788929adb3680df701a9887"),
        ("Project Planner/Views/AddUserView.swift", "private func invitePermissionBinding(_ row: RulebookPermissionToggleRow) -> Binding<Bool> {", "589261d2eb8c1a5dcf0e7a866d9b3d80d0ee3e42731c89f57cdd9b91ae4a57ac"),
        ("Project Planner/Views/AddUserView.swift", "private var invitePermissionsToWrite: UserPermissions {", "6e4ff469d9b2fb7b94ddc07927a1dee85b27c93155bd239c45cea4cbe56da4fe"),
        ("Project Planner/Views/AddUserView.swift", "private var tradeRequiredAndValid: Bool {", "daefbd43eb0126d1b33bae743904a37098bd1fa98fed61a7027fd4f7a71c3c5c"),
        ("Project Planner/Views/AddUserView.swift", "private var canProceed: Bool {", "f761028506ed7bc29bc0fd97fc2a9c2b601288218e751ce7fb51659aab2d6edb"),
        ("Project Planner/Views/AddUserView.swift", "private var permissionItems: [(title: String, isEnabled: Bool)] {", "5f76ebc97e2930051e69ce0887f282e12163a915c3790fd5e91506a4244fa8de"),
        ("Project Planner/Views/AddUserView.swift", "private func createUser() {", "2a1793230f0b66215eb5723ed8c27a843ef5fdd3a342ad837e2ef33114b0036d"),
        ("Project Planner/Views/AddUserView.swift", "private func selectAccountType(_ type: InvitedAccountType) {", "a846baaaebb8e47e6ec8c2bedc84cb80b245c804d8ac41033a4a47324a5b7f46"),
        ("Project Planner/Views/AddUserView.swift", "private func isValidEmail(_ email: String) -> Bool {", "ac5ea654949375615d90976779a1e2f18161b42a663942ca9619b587cb7dd855"),
        ("Project Planner/Views/AddUserView.swift", "private var dayRateBindingForSelectedType: Binding<String> {", "1f7fc10c322c040b92c27ab0caeb97182b6f0a1456cdb6f2a7928f32d8f6cffa"),
        ("Project Planner/Views/AddUserView.swift", "private var selectedDayRateTextForReview: String {", "e5e78b880102a9102ad53f258d402cc372e22b6a1e442a2cebebe54a1207204a"),
        ("Project Planner/Views/AddUserView.swift", "private var adderMaySetInvitePay: Bool {", "42b80539f20a655daff5d7b8503898812afa3d822971610a731d465d9c830f02"),
        ("Project Planner/Views/AddUserView.swift", "private var inviteRateRequired: Bool {", "452e386bc61fa7ec3d910ffdbf8666d0c27ec03749d1036e550659d928e2f858"),
        ("Project Planner/Views/AddUserView.swift", "private var inviteRateError: String? {", "fad106cd84ec83d476aefdd66a9acaec1149665c17c0e508b805c60bce5a23c4"),
        ("Project Planner/Views/AddUserView.swift", "private func parseDayRate(from text: String) -> Double? {", "4e11b49a1697c80b0865b461ffd9799999c4d9a063b6a9a71e64f234470f9aa6"),
        ("Project Planner/Views/AddUserView.swift", "private var canEnterTaxIds: Bool {", "346516714eb61e394808c413a17e5c9bd211038a1fbdcd10c04c3b9ab0b0ba80"),
        ("Project Planner/Views/AddUserView.swift", ".onAppear {", "929817d430ed90c85ce34111b226ec3ffec9dbdfdc937f79a4fc0eb9fb4d13ca"),
        ("Project Planner/Views/AddUserView.swift", ".sheet(isPresented: $showingLineManagerPicker) {", "3ba51efd2a302e1462900b887e99fcedc7cd0c017f41e6523d13e5aa427dc93f"),
        ("Project Planner/Views/AddUserView.swift", ".onChange(of: selectedLineManagerUserIds) { _, newIds in", "9bab5b123f134e7b7fb07750e10f3f244a02db4417dcf7dc414333cbe82bdac3"),
        ("Project Planner/Views/AddUserView.swift", ".onChange(of: vatNumber) { _, newValue in", "4daef6ac20d090c5836de80d90c7ec99c4fd318d7cc3b5b9b6fa7eeccf1b3379"),
        ("Project Planner/Views/AddUserView.swift", ".onChange(of: utrNumber) { _, newValue in", "8afb250c477bd0f7c77cc43adfdb2ea6ef1fa5742986d583dda31625a679fdb2"),
        ("Project Planner/FirebaseBackend.swift", "func createUserInvitation(email: String,", "032dd80a8e5ca27aae0723b01a598e8c5e29e76aab9b2221e2c6cbf7cf2acb9b"),
        ("Project Planner/FirebaseBackend.swift", "static func inviteUserRateFields(dayRate: Double?) -> InviteUserRateFields? {", "d048aab66526037ceaf3e3e6e90702c98ffc043e60b942f63a1bd7d19d1feffa"),
        ("Project Planner/Core/UserStore.swift", "func inviteUser(firstName: String,", "890f7b91c366ffaef2a4ddfb45ec24d69d3d478cd3e5f2ab72728ee5cbd41793"),
        ("Project Planner/Core/AddUserPermissionSeeding.swift", "static func select(", "18c09df467b70a01b69c82b87b9025dff0b3e6ab8864ed2e6af52d0a1322dc23"),
    ]

    /// Inline button actions and enable rules that must still be in AddUserView.swift, whitespace collapsed.
    private static let requiredSnippets: [String] = [
        "Button(\"Cancel\") { dismiss() }",
        "withAnimation { currentStep -= 1 }",
        "if currentStep == finalReviewStep { createUser() } else { withAnimation { if mode == .admin && currentStep == 1 {",
        "applyPermissionsForInvitedType() } currentStep += 1 } }",
        "!canProceed || isCreating || (currentStep == finalReviewStep && !smartCache.isOnline)",
        "showingLineManagerPicker = true",
        ".onChange(of: employmentType) { _, _ in rateFieldError = nil }",
    ]

    /// The account-type card's action, from its guard through the call that changes the type (RULEBOOK 1.34.0: the
    /// line-manager reset it used to hold inline is `selectAccountType(_:)`, a guarded body above).
    private static let accountTypeCardAction = (
        start: "guard !lockedToOperative, invitedAccountType != type else { return }",
        end: "selectAccountType(type)",
        sha256: "58eb974cc2946071750dba0163f362d223b2151e02a0cb9000f0058dbe392174"
    )

    static func normalized<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The declaration that starts at `marker` (which must occur once), through the brace that closes its first `{`.
    static func declaration(startingAt marker: String, in text: String) -> Substring? {
        guard let start = text.range(of: marker),
              text.range(of: marker, range: start.upperBound..<text.endIndex) == nil,
              let open = text[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return text[start.lowerBound...index] }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testSavedDataAndRulesCodeIsUnchangedByTheRestyle() throws {
        var problems: [String] = []
        for item in Self.guardedBodies {
            let text = try source(item.file)
            guard let body = Self.declaration(startingAt: item.marker, in: text) else {
                problems.append("\(item.file): '\(item.marker)' is missing or no longer unique")
                continue
            }
            let hash = Self.sha256(Self.normalized(body))
            if hash != item.sha256 {
                problems.append("\(item.file): '\(item.marker)' changed (sha256 \(hash))")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testButtonActionsAndEnableRulesAreUnchanged() throws {
        let view = Self.normalized(try source("Project Planner/Views/AddUserView.swift"))
        for snippet in Self.requiredSnippets {
            XCTAssertTrue(view.contains(Self.normalized(snippet)), "AddUserView no longer has: \(snippet)")
        }
        let action = Self.accountTypeCardAction
        let start = try XCTUnwrap(view.range(of: Self.normalized(action.start)), "account-type card action missing")
        let end = try XCTUnwrap(
            view.range(of: Self.normalized(action.end), range: start.upperBound..<view.endIndex),
            "account-type card action end missing"
        )
        XCTAssertEqual(Self.sha256(String(view[start.lowerBound..<end.upperBound])), action.sha256)
    }
}
