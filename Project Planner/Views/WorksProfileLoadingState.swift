//
//  WorksProfileLoadingState.swift
//  Project Planner
//
//  Job lists ask the rulebook (`CanonicalBusinessEngine.visibleJobs`) which jobs the signed-in person sees, and that
//  needs their profile. Until it loads the list is not "empty": this shows a loading state, retries a profile load
//  that stopped without a profile, and offers a retry after a wait, so a slow profile never leaves a manager on an
//  empty list. The list itself recomputes as soon as `UserStore.currentUser` is published.
//

import SwiftUI

struct WorksProfileLoadingState: View {
    @EnvironmentObject var userStore: UserStore
    @State private var waitedTooLong = false

    var body: some View {
        VStack(spacing: 12) {
            if waitedTooLong && !userStore.isLoading {
                Text(userStore.errorMessage ?? "Your profile hasn't loaded yet, so your jobs can't be listed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    waitedTooLong = false
                    Task { await userStore.loadCurrentUser() }
                }
                .accessibilityIdentifier("works.profileLoading.retry")
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView("Loading your profile...")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, PPMetrics.screenGutter)
        .accessibilityIdentifier("works.profileLoading")
        .task {
            // A load that already finished without a profile is started again once.
            if userStore.currentUser == nil && !userStore.isLoading {
                await userStore.loadCurrentUser()
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if userStore.currentUser == nil { waitedTooLong = true }
        }
    }
}
