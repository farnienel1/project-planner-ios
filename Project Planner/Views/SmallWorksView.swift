//
//  SmallWorksView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI
import FirebaseAuth
import UIKit

struct SmallWorksView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    /// Default to Active so the list opens on current jobs; use All / Completed chips for older work.
    @State private var selectedStatus: ProjectStatus? = .active
    @State private var selectedProject: Project? = nil
    @State private var showingEditProject = false
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var showingCreateSmallWorks = false
    @State private var deadlineAssignedProjectIds: Set<UUID> = []
    /// RULEBOOK 1.33.0 §21: the person's own list (picks in `organizations/{orgId}/worksListPicks/{uid}`).
    @StateObject private var myWorks = MyWorksPicksModel()
    /// The My list chosen (true) or a status chip chosen (false); nil is the rulebook's default (`defaultWorksListTab`).
    @State private var myListChosen: Bool? = nil
    @State private var showingMyWorksPicker = false
    /// 1.33.1: `myWorksPickerRows` taken once when the ⚙ opens; the sheet keeps this snapshot.
    @State private var myWorksPickerRows: [MyWorksPickerRow] = []
    /// 1.33.1 (owner report: My list took ~20 s): the §21 answers for this screen, asked again only when an input
    /// changes, never once per tile, chip and render (`WorksListScreenCache`).
    @State private var listCache = WorksListScreenCache()

    private var listCounts: WorksListStatusCounts {
        listAnswers.counts
    }

    // MARK: My list (RULEBOOK 1.33.0 §21)

    /// `hasMyWorksList`: admins and managers get the My list; operatives never.
    private var hasMyList: Bool {
        listAnswers.hasMyList
    }

    /// The My list is shown: chosen, or the first and default filter (`defaultWorksListTab` = `mine`).
    private var showsMyList: Bool {
        guard hasMyList else { return false }
        return myListChosen ?? listAnswers.myListIsDefault
    }

    /// `myWorksList`: the saved picks, else the jobs they manage (until their first save); every status.
    private var myListJobs: [Project] {
        listCache.myList(listInputs, picks: myWorks.picks, loaded: myWorks.loaded)
    }

    /// The status filter as the tiles and chips see it: none while the My list is shown; choosing one leaves the My list.
    private var statusSelection: Binding<ProjectStatus?> {
        Binding(
            get: { showsMyList ? nil : selectedStatus },
            set: { selectedStatus = $0; myListChosen = false }
        )
    }

    private func chooseStatus(_ status: ProjectStatus?) {
        selectedStatus = status
        myListChosen = false
    }

    private func refreshMyWorksListener() {
        guard hasMyList else {
            myWorks.stop()
            return
        }
        myWorks.listen(
            backend: firebaseBackend,
            organizationId: firebaseBackend.currentOrganization?.firestoreDocumentId,
            uid: firebaseBackend.currentUser?.uid
        )
    }

    private var myWorksPickerSheet: some View {
        MyWorksPickerSheet(
            kind: .smallWorks,
            rows: myWorksPickerRows,
            accent: WorksDashboardListStyle.smallWorks.accent,
            ready: myWorks.pickerReady,
            startsFromPrefill: myWorks.pickerStartsFromPrefill
        ) { ids in
            guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
                  let uid = firebaseBackend.currentUser?.uid else {
                throw NSError(domain: "MyWorks", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in to an organisation."])
            }
            // 1.33.1: hands the list to Firestore and returns; the server's answer is awaited in the background
            // (bounded), so the sheet closes at once and never waits on "Saving…".
            try myWorks.save(backend: firebaseBackend, organizationId: orgId, uid: uid, kind: .smallWorks, ids: ids)
        }
    }

    /// Opens the ⚙ with a snapshot of `myWorksPickerRows` (asked once, not on every render while it is open).
    private func openMyWorksPicker() {
        myWorksPickerRows = listCache.pickerRows(listInputs, picks: myWorks.picks)
        showingMyWorksPicker = true
    }

    /// #210 review fix 2: the server's first answer arrived while the ⚙ is open — take its rows once more (the sheet
    /// replays the person's ticks on them), so Save never writes the pre-fill over a list saved on another device.
    private func myWorksServerAnswered(_ answered: Bool) {
        guard answered, showingMyWorksPicker else { return }
        myWorksPickerRows = listCache.pickerRows(listInputs, picks: myWorks.picks)
    }

    /// After a save: Pending sync while the server has not confirmed it, or the refusal (the stored list comes back).
    @ViewBuilder
    private var myListSaveNote: some View {
        if showsMyList, let message = myWorks.saveError {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                .accessibilityIdentifier("smallWorks.myList.saveError")
        } else if showsMyList, myWorks.pendingSync {
            Text(MyWorksPicksModel.pendingSyncMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                .accessibilityIdentifier("smallWorks.myList.pendingSync")
        }
    }

    private var myListLoadingState: some View {
        ProgressView("Loading your list…")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private var myListEmptyState: some View {
        VStack(spacing: 14) {
            PPIconTile(symbol: "star", family: .sites, size: PPMetrics.quickActionIcon, lifted: true)
            Text(CanonicalBusinessEngine.myWorksEmptyTitle(.smallWorks))
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Button(CanonicalBusinessEngine.myWorksEmptyActionLabel(.smallWorks)) {
                openMyWorksPicker()
            }
            .accessibilityIdentifier("smallWorks.myList.choose")
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(PPColor.brand)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var myListChips: some View {
        if hasMyList {
            WorksRevampFilterChip(
                title: "\(CanonicalBusinessEngine.myWorksTabLabel(.smallWorks)) · \(myListJobs.count)",
                isSelected: showsMyList,
                selectedForeground: WorksDashboardPalette.ink,
                selectedFill: WorksDashboardListStyle.smallWorks.accent,
                titleFont: .subheadline.weight(.semibold),
                horizontalPadding: 15,
                verticalPadding: 9,
                accessibilityIdentifier: "smallWorks.filter.mine",
                action: { myListChosen = true }
            )
            if showsMyList {
                Button {
                    openMyWorksPicker()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WorksDashboardPalette.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(ProjectWorksRevampColors.surface))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("smallWorks.myList.picker")
                .accessibilityLabel("Choose small works for your list")
            }
        }
    }

    private var canCreateSmallWorks: Bool {
        userStore.canManageWorkCatalogue(.smallWorks)
    }
    
    private var smallWorksProjects: [Project] {
        projectStore.smallWorks
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                PPColor.page.ignoresSafeArea()
                smallWorksRootContent
            }
            .navigationTitle("Small works")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("")
                        .accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                    }
                        .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                        .accessibilityIdentifier("smallWorks.gobacktoprevioustab")
                }
                if canCreateSmallWorks {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingCreateSmallWorks = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                        .accessibilityIdentifier("smallWorks.add")
                        .accessibilityLabel("New small work")
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("resetNavigationForTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 2 {
                    // Reset navigation to root
                    navigationPath.removeLast(navigationPath.count)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("selectTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 2 {
                    // Reset navigation when Small Works tab is selected
                    navigationPath.removeLast(navigationPath.count)
                    selectedStatus = .active
                    // RULEBOOK 1.33.0 §21: back to the default filter (My Small works for admins and managers).
                    myListChosen = nil
                }
            }
            .onAppear {
                if selectedStatus == .inactive || selectedStatus == nil {
                    selectedStatus = .active
                }
                openPendingCatalogueJob()
                refreshMyWorksListener()
            }
            .onChange(of: firebaseBackend.currentOrganization?.firestoreDocumentId) { _, _ in
                // Organisation context: a switch re-subscribes; the previous company's picks are never shown.
                refreshMyWorksListener()
            }
            .onChange(of: hasMyList) { _, _ in refreshMyWorksListener() }
            .onReceive(NotificationCenter.default.publisher(for: .pushWorkCatalogueDetail)) { note in
                let isSmallWorks = note.userInfo?["isSmallWorks"] as? Bool ?? false
                guard isSmallWorks else { return }
                openPendingCatalogueJob()
            }
            .onChange(of: projectStore.projects.count) { _, _ in
                openPendingCatalogueJob()
            }
            .task {
                await refreshDeadlineAssignedProjectIds()
            }
            .sheet(isPresented: $showingEditProject) {
                if let project = selectedProject {
                    EditProjectView(project: project)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                }
            }
            .sheet(isPresented: $showingMyWorksPicker) {
                myWorksPickerSheet
            }
            .onChange(of: myWorks.confirmedByServer) { _, answered in
                myWorksServerAnswered(answered)
            }
            .sheet(isPresented: $showingCreateSmallWorks) {
                CreateSmallWorksView()
                    .environmentObject(projectStore)
                    .environmentObject(operativeStore)
                    .environmentObject(notificationService)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .background(
                Color.clear
                    .preference(key: HideBottomMenuKey.self, value: false)
            )
        }
    }

    private var showsBlockingLoader: Bool {
        let storeHasSmallWorks = !projectStore.smallWorks.isEmpty
        if projectStore.isLoading && !storeHasSmallWorks && smallWorksBeforeStatusFilter.isEmpty {
            return true
        }
        return false
    }

    private func openPendingCatalogueJob() {
        guard WorkCatalogueDeepLink.peek(isSmallWorks: true),
              let projectId = WorkCatalogueDeepLink.pendingProjectId,
              let project = projectStore.smallWorks.first(where: { $0.id == projectId })
                ?? projectStore.projects.first(where: { $0.id == projectId }) else { return }
        guard WorkCatalogueDeepLink.take(isSmallWorks: true) != nil else { return }
        navigationPath = NavigationPath()
        navigationPath.append(project)
    }

    private var isWaitingForVisibilityData: Bool {
        guard userStore.isOperativeMode() else { return false }
        if operativeStore.isLoading || bookingStore.isLoading { return true }
        return userStore.currentUser == nil
    }

    private var smallWorksRootContent: some View {
        Group {
            if showsBlockingLoader {
                ProgressView("Loading small works...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        smallWorksNavyHeader
                        VStack(alignment: .leading, spacing: 0) {
                            myListSaveNote
                            smallWorksSheetContent
                        }
                            // Launch checklist 1.20: tighter gap under the header (web PR #286, 34px → 16px).
                            .padding(.top, 10)
                            .padding(.bottom, 24)
                            .ppContentSheet()
                    }
                }
                .navigationDestination(for: Project.self) { project in
                    ProjectDetailView(project: project)
                        .environmentObject(bookingStore)
                        .environmentObject(operativeStore)
                        .environmentObject(projectStore)
                        .background(
                            Color.clear
                                .preference(key: HideBottomMenuKey.self, value: true)
                        )
                }
                .refreshable {
                    projectStore.loadData()
                }
            }
        }
    }

    /// Home-style navy header: title, the existing Active / Upcoming / Completed tiles, search and filter chips.
    private var smallWorksNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                title: WorksDashboardListStyle.smallWorks.title,
                subtitle: WorksDashboardListStyle.smallWorks.subtitle
            )
            .accessibilityAddTraits(.isHeader)
            WorksDashboardStatsRow(counts: listCounts, selectedStatus: statusSelection)
                .padding(.top, 18)
            WorksDashboardSearchRow(text: $searchText, placeholder: WorksDashboardListStyle.smallWorks.searchPlaceholder) {
                Menu {
                    if hasMyList {
                        Button("\(CanonicalBusinessEngine.myWorksTabLabel(.smallWorks)) · \(myListJobs.count)") { myListChosen = true }
                            .accessibilityIdentifier("smallWorks.filter.mine")
                    }
                    Button("All · \(listCounts.all)") { chooseStatus(nil) }
                        .accessibilityIdentifier("smallWorks.filter.all")
                    Button("Active · \(listCounts.active)") { chooseStatus(.active) }
                        .accessibilityIdentifier("smallWorks.filter.active")
                    Button("Upcoming · \(listCounts.upcoming)") { chooseStatus(.upcoming) }
                        .accessibilityIdentifier("smallWorks.filter.upcoming")
                    Button("Completed · \(listCounts.completed)") { chooseStatus(.completed) }
                        .accessibilityIdentifier("smallWorks.filter.completed")
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(WorksDashboardListStyle.smallWorks.accent)
                }
                    .accessibilityIdentifier("smallWorks.all")
            }
            // Launch checklist 1.20: tiles → search → chips gap tightened to match web (PR #286, 12px → 8px).
            .padding(.top, 8)
            filterChipsRow
                .padding(.top, 8)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 8)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    /// Light sheet: the job cards, or the existing loading / empty states.
    @ViewBuilder
    private var smallWorksSheetContent: some View {
        if userStore.displayJobAccessViewer == nil {
            // No profile yet: `visibleJobs` has no viewer, so the list is unknown, not empty.
            WorksProfileLoadingState()
        } else if isWaitingForVisibilityData {
            ProgressView("Finding jobs assigned to you...")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else if showsMyList && !myWorks.loaded && !smallWorksBeforeStatusFilter.isEmpty {
            myListLoadingState
        } else if showsMyList && filteredSmallWorks.isEmpty && !smallWorksBeforeStatusFilter.isEmpty {
            myListEmptyState
        } else if searchFilteredSmallWorks.isEmpty {
            if filteredSmallWorks.isEmpty {
                emptyStateView
            } else {
                emptySearchState
            }
        } else {
            LazyVStack(spacing: 13) {
                ForEach(searchFilteredSmallWorks) { project in
                    NavigationLink(value: project) {
                        WorksDashboardCard(
                            project: project,
                            listAccent: WorksDashboardListStyle.smallWorks.accent,
                            showsClientAndManager: !userStore.isOperativeMode()
                        )
                        .environmentObject(operativeStore)
                    }
                    .accessibilityIdentifier("smallWorks.row.\(project.id)")
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                myListChips
                WorksRevampFilterChip(
                    title: "All · \(listCounts.all)",
                    isSelected: !showsMyList && selectedStatus == nil,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.all",
                    action: { chooseStatus(nil) }
                )
                WorksRevampFilterChip(
                    title: "Active · \(listCounts.active)",
                    isSelected: !showsMyList && selectedStatus == .active,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.active",
                    action: { chooseStatus(.active) }
                )
                WorksRevampFilterChip(
                    title: "Upcoming · \(listCounts.upcoming)",
                    isSelected: !showsMyList && selectedStatus == .upcoming,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.upcoming",
                    action: { chooseStatus(.upcoming) }
                )
                WorksRevampFilterChip(
                    title: "Completed · \(listCounts.completed)",
                    isSelected: !showsMyList && selectedStatus == .completed,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.completed",
                    action: { chooseStatus(.completed) }
                )
            }
        }
    }

    private var searchFilteredSmallWorks: [Project] {
        let base = filteredSmallWorks
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { p in
            p.jobNumber.lowercased().contains(q)
                || p.siteName.lowercased().contains(q)
                || p.siteAddress.lowercased().contains(q)
                || p.client.name.lowercased().contains(q)
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 12) {
            PPIconTile(symbol: "magnifyingglass", family: .system, size: 44)
            Text("No small works match your search.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            PPIconTile(symbol: emptyStateIcon, family: .trade, size: PPMetrics.quickActionIcon, lifted: true)
            
            Text(emptyStateTitle)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isEmptyDueToStatusFilterOnly {
                Button("Show all small works") {
                    chooseStatus(nil)
                }
                .accessibilityIdentifier("smallWorks.showAllSmallWorks")
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)
            } else if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil || isUnmatchedOperativeWithJobs {
                Button("Retry") {
                    projectStore.loadData()
                }
                .accessibilityIdentifier("smallWorks.retry")
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
    }

    private var emptyStateIcon: String {
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "wifi.exclamationmark"
        }
        return "hammer.fill"
    }

    private var emptyStateTitle: String {
        if isEmptyDueToStatusFilterOnly {
            return "No small works in this filter"
        }
        if isUnmatchedOperativeWithJobs {
            return "Jobs couldn’t be matched to you"
        }
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "Couldn’t load small works"
        }
        return "No small works found"
    }

    private var emptyStateMessage: String {
        if isEmptyDueToStatusFilterOnly {
            return "The current filter hides older or completed jobs. Choose “All” or “Completed” above to see everything."
        }
        if isUnmatchedOperativeWithJobs {
            return "Your account isn’t matched to an operative record yet, so assigned jobs can’t be listed. Pull to refresh, or ask an admin to check the email on your operative profile."
        }
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "This is a load problem, not deleted jobs. Pull down to retry. Existing jobs stay on the server and on web."
        }
        if canCreateSmallWorks {
            return WorksDashboardListStyle.smallWorks.emptyCreatePrompt
        }
        return "Nothing here right now."
    }

    private var isUnmatchedOperativeWithJobs: Bool {
        userStore.isOperativeMode()
            && resolvedCurrentOperative == nil
            && !projectStore.smallWorks.isEmpty
    }
    
    /// Small works with operative visibility applied but without status chip filter.
    /// RULEBOOK 1.21.0 §21: the list is `worksListMembership(jobs, smallWorks)` (every document of
    /// the kind, inactive included, once by id) and `visibleJobs(..., viewer, context)` (by account id and email,
    /// never by name; an operative's jobs are their bookings, tasks and deadlines). No Swift visibility rule.
    private var smallWorksBeforeStatusFilter: [Project] {
        listAnswers.visible
    }

    /// What this screen's §21 answers depend on (the loaded stores; deadline jobs by stored id).
    private var listInputs: WorksListScreenInputs {
        let deadlineIds: [String] = deadlineAssignedProjectIds.isEmpty ? [] : (projectStore.projects + projectStore.smallWorks)
            .filter { deadlineAssignedProjectIds.contains($0.id) }
            .map(\.documentId)
        return WorksListScreenInputs(
            kind: .smallWorks,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            viewer: userStore.displayJobAccessViewer,
            operatives: operativeStore.allOperatives,
            bookings: bookingStore.bookings,
            managerSiteBookings: managerScheduleStore.managerSiteBookings,
            tasks: taskStore.tasks,
            deadlineJobIds: deadlineIds
        )
    }

    /// `worksListMembership` + `visibleJobs`, `worksTabCounts`, `hasMyWorksList`, `defaultWorksListTab` — cached.
    private var listAnswers: WorksListScreenCache.Answers {
        listCache.answers(listInputs)
    }

    private func refreshDeadlineAssignedProjectIds() async {
        guard userStore.isOperativeMode(),
              let userId = userStore.currentUser?.id,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId ?? userStore.currentUser?.organizationId else {
            await MainActor.run { deadlineAssignedProjectIds = [] }
            return
        }
        let ids = await firebaseBackend.loadDeadlineAssignedProjectIds(userId: userId, organizationId: orgId, jobIds: projectStore.projects.map(\.documentId))
        await MainActor.run { deadlineAssignedProjectIds = ids }
    }

    /// The signed-in person's operatives row, on their email only (§21: never by name).
    private var resolvedCurrentOperative: Operative? {
        let normalizedEmail = userStore.currentUser?.email
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedEmail, !normalizedEmail.isEmpty else { return nil }
        return operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
        })
    }
    
    private var isEmptyDueToStatusFilterOnly: Bool {
        guard !showsMyList, selectedStatus != nil else { return false }
        return !smallWorksBeforeStatusFilter.isEmpty && filteredSmallWorks.isEmpty
    }
    
    private var filteredSmallWorks: [Project] {
        // RULEBOOK 1.33.0 §21: the My list (`myWorksList`) is its own filter, every status.
        if showsMyList { return myListJobs }
        var works = smallWorksBeforeStatusFilter
        
        if let status = selectedStatus {
            // RULEBOOK 1.21.0 §21 `worksInTab`: inactive jobs are under Completed; All keeps every job.
            works = listCache.jobs(listInputs, chip: status)
        }
        
        return works
    }
}

#Preview {
    SmallWorksView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
}

