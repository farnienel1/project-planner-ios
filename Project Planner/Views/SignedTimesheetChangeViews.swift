//
//  SignedTimesheetChangeViews.swift
//  Project Planner
//
//  RULEBOOK 1.47.0 §8: the yellow warning triangle and message shown when a signed timesheet's bookings changed since
//  the person signed. Layout only: whether to show them is `signedTimesheetBookingChanges`, the words are the script's.
//

import SwiftUI
import FirebaseFirestore

/// A small yellow warning triangle. Tapping it shows `SIGNED_TIMESHEET_CHANGED_MESSAGE` with an OK button.
struct SignedTimesheetChangedTriangle: View {
    var message: String = CanonicalBusinessEngine.signedTimesheetChangedMessage
    /// The popup's title: the 1.47.0 label, or — RULEBOOK 1.55.0 §8, for a revision due — the revision's title
    /// (`TIMESHEET_REVISION_DUE_NOTICE_TITLE`). Defaults from the message.
    var title: String? = nil
    @State private var showMessage = false

    private var popupTitle: String {
        if let title { return title }
        return message == CanonicalBusinessEngine.timesheetRevisionDueMessage
            ? CanonicalBusinessEngine.timesheetRevisionDueNoticeTitle
            : CanonicalBusinessEngine.signedTimesheetChangedLabel
    }

    var body: some View {
        Button {
            showMessage = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(.systemYellow))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(popupTitle)
        .accessibilityIdentifier("timesheets.bookingsChangedTriangle")
        .alert(popupTitle, isPresented: $showMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

/// The message on the sheet itself while the person must review and sign again.
struct SignedTimesheetChangedBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(.systemYellow))
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.systemYellow).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timesheets.bookingsChangedBanner")
    }
}

/// RULEBOOK 1.55.0 §8: "REV 1" beside a timesheet's status (`timesheetRevisionLabel`). Layout only.
struct TimesheetRevisionBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color(.systemIndigo))
            .background(Color(.systemIndigo).opacity(0.14), in: Capsule())
            .accessibilityLabel(label)
            .accessibilityIdentifier("timesheets.revisionBadge")
    }
}

/// RULEBOOK 1.55.0 §8: the earlier versions of a pay run, read only, under the version shown (`timesheetEarlierVersions`,
/// newest first; `TIMESHEET_EARLIER_VERSIONS_LABEL`, `TIMESHEET_ORIGINAL_VERSION_LABEL`). Each row names its version and
/// when it was exported; `onDownload` (when given) shares that version's PDF. Layout only.
struct TimesheetEarlierVersionsList: View {
    let versions: [TimesheetVersionInfo]
    var onDownload: ((TimesheetVersionInfo) -> Void)? = nil

    private func title(_ version: TimesheetVersionInfo) -> String {
        version.revision == 0
            ? CanonicalBusinessEngine.timesheetOriginalVersionLabel
            : CanonicalBusinessEngine.timesheetRevisionLabel(version.revision)
    }

    /// When the version was exported, in the organisation's business time zone (never the device's).
    private func exportedText(_ version: TimesheetVersionInfo) -> String? {
        guard let stamp = version.data["exportedAt"] as? Timestamp else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: OrganizationRulebookContext.timeZone)
        return "Exported \(stamp.dateValue().formatted(style))"
    }

    var body: some View {
        if !versions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(CanonicalBusinessEngine.timesheetEarlierVersionsLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(versions, id: \.documentId) { version in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(version))
                                .font(.footnote.weight(.semibold))
                            if let exported = exportedText(version) {
                                Text(exported)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if let onDownload {
                            Button {
                                onDownload(version)
                            } label: {
                                Label("Download PDF", systemImage: "arrow.down.doc")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("timesheets.earlierVersion.\(version.revision).downloadPDF")
                        }
                    }
                }
            }
            .accessibilityIdentifier("timesheets.earlierVersions")
        }
    }
}

/// Owner item 23 (23 Nov): on User Timesheets → Exported, every exported version of a pay run, oldest first — Original,
/// REV 1, REV 2 — each with its invoice number, signed date, total, the difference from the version before it and its
/// own Download PDF (`TimesheetExportedVersionRow.rows`, web `exportedVersionRows`). Layout only: every figure and word
/// is the rulebook's; each PDF is drawn from that version's stored signed copy.
struct TimesheetExportedVersionsList: View {
    let rows: [TimesheetExportedVersionRow]
    var onDownload: ((TimesheetExportedVersionRow) -> Void)? = nil

    /// The signed date in the organisation's business time zone (never the device's).
    private func signedText(_ row: TimesheetExportedVersionRow) -> String? {
        guard let signedAt = row.signedAt else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: OrganizationRulebookContext.timeZone)
        return "Signed \(signedAt.formatted(style))"
    }

    var body: some View {
        if rows.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Versions of this pay run · \(rows.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.label)
                                    .font(.footnote.weight(.semibold))
                                if row.latest {
                                    Text("Latest")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .foregroundStyle(.green)
                                        .background(Color.green.opacity(0.14), in: Capsule())
                                }
                            }
                            if !row.invoiceNumber.isEmpty {
                                Text(row.invoiceNumber)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let signed = signedText(row) {
                                Text(signed)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text(row.totalText)
                                    .font(.caption.weight(.semibold))
                                if let difference = row.differenceText {
                                    Text(difference)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 8)
                        if let onDownload {
                            Button {
                                onDownload(row)
                            } label: {
                                Label("Download PDF", systemImage: "arrow.down.doc")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Download PDF of \(row.label)")
                            .accessibilityIdentifier("timesheets.exportedVersion.\(row.version.revision).downloadPDF")
                        }
                    }
                }
            }
            .accessibilityIdentifier("timesheets.exportedVersions")
        }
    }
}

/// Hands the screen's stores to `SignedTimesheetChangeContext`, so list rows, counts and the My Timesheets entry can
/// ask the rulebook whether a signed sheet's bookings changed. Plumbing only.
private struct SignedTimesheetChangeAttachment: ViewModifier {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore

    func body(content: Content) -> some View {
        content.onAppear {
            SignedTimesheetChangeContext.shared.attach(
                firebaseBackend: firebaseBackend,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                operativeStore: operativeStore,
                projectStore: projectStore,
                userStore: userStore
            )
        }
    }
}

extension View {
    /// RULEBOOK 1.47.0 §8: lets lists and counts read each signed sheet's booking change (`SignedTimesheetChangeContext`).
    func attachesSignedTimesheetChanges() -> some View {
        modifier(SignedTimesheetChangeAttachment())
    }
}
