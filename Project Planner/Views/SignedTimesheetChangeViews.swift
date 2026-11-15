//
//  SignedTimesheetChangeViews.swift
//  Project Planner
//
//  RULEBOOK 1.47.0 §8: the yellow warning triangle and message shown when a signed timesheet's bookings changed since
//  the person signed. Layout only: whether to show them is `signedTimesheetBookingChanges`, the words are the script's.
//

import SwiftUI

/// A small yellow warning triangle. Tapping it shows `SIGNED_TIMESHEET_CHANGED_MESSAGE` with an OK button.
struct SignedTimesheetChangedTriangle: View {
    var message: String = CanonicalBusinessEngine.signedTimesheetChangedMessage
    @State private var showMessage = false

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
        .accessibilityLabel(CanonicalBusinessEngine.signedTimesheetChangedLabel)
        .accessibilityIdentifier("timesheets.bookingsChangedTriangle")
        .alert(CanonicalBusinessEngine.signedTimesheetChangedLabel, isPresented: $showMessage) {
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
