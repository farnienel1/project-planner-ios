//
//  ProjectsView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import FirebaseAuth

/// Row token. Putting the whole `Project` in the navigation path crashes when the list is built.
private struct OpenedProjectToken: Hashable {
    let projectId: UUID
}

struct ProjectsView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    /// Default to Active so the list opens on current jobs; use All / Completed chips for older work.
    @State private var selectedStatus: ProjectStatus? = .active
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var showingCreateProject = false
    @State private var deadlineAssignedProjectIds: Set<UUID> = []
    /// RULEBOOK 1.33.0 §21: the person's own list (picks in `organizations/{orgId}/worksListPicks/{uid}`).
    @StateObject private var myWorks = MyWorksPicksModel()
    /// The My list chosen (true) or a status chip chosen (false); nil is the rulebook's default (`defaultWorksListTab`).
    @State private var myListChosen: Bool? = nil
    @State private var showingMyWorksPicker = false
    /// 1.33.1: `myWorksPickerRows` taken once when the ⚙ opens; the sheet keeps this snapshot.
    @State private var myWorksPickerRows: [MyWorksPickerRow] = []
    /// `myWorksIds` taken with the rows: the whole stored list, so Save keeps ids of hidden or deleted jobs.
    @State private var myWorksPickerStoredIds: [String] = []
    /// 1.33.1 (owner report: My list took ~20 s): the §21 answers for this screen, asked again only when an input
    /// changes, never once per tile, chip and render (`WorksListScreenCache`).
    @State private var listCache = WorksListScreenCache()
    /// A hung project read must not leave this screen on the spinner until the system kills the app.
    @State private var stoppedBlockingLoader = false

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
            kind: .projects,
            rows: myWorksPickerRows,
            storedIds: myWorksPickerStoredIds,
            accent: WorksDashboardListStyle.projects.accent,
            ready: myWorks.pickerReady,
            startsFromPrefill: myWorks.pickerStartsFromPrefill
        ) { ids in
            guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
                  let uid = firebaseBackend.currentUser?.uid else {
                throw NSError(domain: "MyWorks", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in to an organisation."])
            }
            // 1.33.1: hands the list to Firestore and returns; the server's answer is awaited in the background
            // (bounded), so the sheet closes at once and never waits on "Saving…".
            try myWorks.save(backend: firebaseBackend, organizationId: orgId, uid: uid, kind: .projects, ids: ids)
        }
    }

    /// Opens the ⚙ with a snapshot of `myWorksPickerRows` (asked once, not on every render while it is open).
    private func openMyWorksPicker() {
        myWorksPickerRows = listCache.pickerRows(listInputs, picks: myWorks.picks)
        myWorksPickerStoredIds = listCache.storedIds(listInputs, picks: myWorks.picks)
        showingMyWorksPicker = true
    }

    /// #210 review fix 2: the server's first answer arrived while the ⚙ is open — take its rows once more (the sheet
    /// replays the person's ticks on them), so Save never writes the pre-fill over a list saved on another device.
    private func myWorksServerAnswered(_ answered: Bool) {
        guard answered, showingMyWorksPicker else { return }
        myWorksPickerRows = listCache.pickerRows(listInputs, picks: myWorks.picks)
        myWorksPickerStoredIds = listCache.storedIds(listInputs, picks: myWorks.picks)
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
                .accessibilityIdentifier("projects.myList.saveError")
        } else if showsMyList, myWorks.pendingSync {
            Text(MyWorksPicksModel.pendingSyncMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                .accessibilityIdentifier("projects.myList.pendingSync")
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
            Text(CanonicalBusinessEngine.myWorksEmptyTitle(.projects))
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Button(CanonicalBusinessEngine.myWorksEmptyActionLabel(.projects)) {
                openMyWorksPicker()
            }
            .accessibilityIdentifier("projects.myList.choose")
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
                title: "\(CanonicalBusinessEngine.myWorksTabLabel(.projects)) · \(myListJobs.count)",
                isSelected: showsMyList,
                selectedForeground: WorksDashboardPalette.ink,
                selectedFill: WorksDashboardListStyle.projects.accent,
                titleFont: .subheadline.weight(.semibold),
                horizontalPadding: 15,
                verticalPadding: 9,
                accessibilityIdentifier: "projects.filter.mine",
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
                .accessibilityIdentifier("projects.myList.picker")
                .accessibilityLabel("Choose projects for your list")
            }
        }
    }

    private var canCreateProjects: Bool {
        userStore.canManageWorkCatalogue(.projects)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                PPColor.page.ignoresSafeArea()
                projectsRootContent
            }
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                    }
                        .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                        .accessibilityIdentifier("projects.gobacktoprevioustab")
                }
                if canCreateProjects {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingCreateProject = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                        .accessibilityIdentifier("projects.add")
                        .accessibilityLabel("New project")
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .navigationDestination(for: OpenedProjectToken.self) { token in
                projectDetailDestination(token.projectId)
            }
            .background(
                // This will be overridden by child views that set preference to true
                Color.clear
                    .preference(key: HideBottomMenuKey.self, value: false)
            )
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("resetNavigationForTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 1, !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("selectTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 1 {
                    if !navigationPath.isEmpty {
                        navigationPath = NavigationPath()
                    }
                    selectedStatus = .active
                    // RULEBOOK 1.33.0 §21: back to the default filter (My Projects for admins and managers).
                    myListChosen = nil
                }
            }
            .onAppear {
                // Ensure Active is selected (Inactive filter removed from UI)
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
                guard !isSmallWorks else { return }
                openPendingCatalogueJob()
            }
            .task {
                await refreshDeadlineAssignedProjectIds()
            }
            .task(id: projectStore.isLoading) {
                guard projectStore.isLoading else {
                    stoppedBlockingLoader = false
                    return
                }
                stoppedBlockingLoader = false
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if projectStore.isLoading {
                    stoppedBlockingLoader = true
                }
            }
            .sheet(isPresented: $showingMyWorksPicker) {
                myWorksPickerSheet
            }
            .onChange(of: myWorks.confirmedByServer) { _, answered in
                myWorksServerAnswered(answered)
            }
            .sheet(isPresented: $showingCreateProject) {
                CreateProjectView()
                    .environmentObject(projectStore)
                    .environmentObject(operativeStore)
                    .environmentObject(notificationService)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
        }
    }

    private var isWaitingForVisibilityData: Bool {
        guard userStore.isOperativeMode() else { return false }
        if operativeStore.isLoading || bookingStore.isLoading { return true }
        return userStore.currentUser == nil
    }

    private var showsBlockingLoader: Bool {
        if stoppedBlockingLoader { return false }
        let storeHasProjects = projectStore.projects.contains { !$0.isSmallWorksDocument }
        if projectStore.isLoading && !storeHasProjects && projectsBeforeStatusFilter.isEmpty {
            return true
        }
        return false
    }

    private var projectsRootContent: some View {
        Group {
            if showsBlockingLoader {
                ProgressView("Loading projects...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        projectsNavyHeader
                        VStack(alignment: .leading, spacing: 0) {
                            myListSaveNote
                            projectsSheetContent
                        }
                            // Launch checklist 1.20: tighter gap under the header (web PR #286, 34px → 16px).
                            .padding(.top, 10)
                            .padding(.bottom, 24)
                            .ppContentSheet()
                    }
                }
                .refreshable {
                    projectStore.loadData()
                }
            }
        }
    }

    /// Home-style navy header: title, the existing Active / Upcoming / Completed tiles, search and filter chips.
    private var projectsNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                title: WorksDashboardListStyle.projects.title,
                subtitle: WorksDashboardListStyle.projects.subtitle
            )
            .accessibilityAddTraits(.isHeader)
            WorksDashboardStatsRow(counts: listCounts, selectedStatus: statusSelection)
                .padding(.top, 18)
            WorksDashboardSearchRow(text: $searchText, placeholder: WorksDashboardListStyle.projects.searchPlaceholder) {
                Menu {
                    if hasMyList {
                        Button("\(CanonicalBusinessEngine.myWorksTabLabel(.projects)) · \(myListJobs.count)") { myListChosen = true }
                            .accessibilityIdentifier("projects.filter.mine")
                    }
                    Button("All · \(listCounts.all)") { chooseStatus(nil) }
                        .accessibilityIdentifier("projects.filter.all")
                    Button("Active · \(listCounts.active)") { chooseStatus(.active) }
                        .accessibilityIdentifier("projects.filter.active")
                    Button("Upcoming · \(listCounts.upcoming)") { chooseStatus(.upcoming) }
                        .accessibilityIdentifier("projects.filter.upcoming")
                    Button("Completed · \(listCounts.completed)") { chooseStatus(.completed) }
                        .accessibilityIdentifier("projects.filter.completed")
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(WorksDashboardListStyle.projects.accent)
                }
                    .accessibilityIdentifier("projects.all")
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
    private var projectsSheetContent: some View {
        if userStore.displayJobAccessViewer == nil {
            // No profile yet: `visibleJobs` has no viewer, so the list is unknown, not empty.
            WorksProfileLoadingState()
        } else if isWaitingForVisibilityData {
            ProgressView("Finding jobs assigned to you...")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else if showsMyList && !myWorks.loaded && !projectsBeforeStatusFilter.isEmpty {
            myListLoadingState
        } else if showsMyList && filteredProjects.isEmpty && !projectsBeforeStatusFilter.isEmpty {
            myListEmptyState
        } else if searchFilteredProjects.isEmpty {
            if filteredProjects.isEmpty {
                emptyStateView
            } else {
                emptySearchState
            }
        } else {
            LazyVStack(spacing: 13) {
                ForEach(searchFilteredProjects) { project in
                    Button {
                        navigationPath.append(OpenedProjectToken(projectId: project.id))
                    } label: {
                        WorksDashboardCard(
                            project: project,
                            listAccent: WorksDashboardListStyle.projects.accent,
                            showsClientAndManager: !userStore.isOperativeMode()
                        )
                        .environmentObject(operativeStore)
                    }
                    .accessibilityIdentifier("projects.row.\(project.id)")
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
                    selectedFill: WorksDashboardListStyle.projects.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "projects.filter.all",
                    action: { chooseStatus(nil) }
                )
                WorksRevampFilterChip(
                    title: "Active · \(listCounts.active)",
                    isSelected: !showsMyList && selectedStatus == .active,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.projects.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "projects.filter.active",
                    action: { chooseStatus(.active) }
                )
                WorksRevampFilterChip(
                    title: "Upcoming · \(listCounts.upcoming)",
                    isSelected: !showsMyList && selectedStatus == .upcoming,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.projects.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "projects.filter.upcoming",
                    action: { chooseStatus(.upcoming) }
                )
                WorksRevampFilterChip(
                    title: "Completed · \(listCounts.completed)",
                    isSelected: !showsMyList && selectedStatus == .completed,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.projects.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "projects.filter.completed",
                    action: { chooseStatus(.completed) }
                )
            }
        }
    }

    private var searchFilteredProjects: [Project] {
        let base = filteredProjects
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
            Text("No projects match your search.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            PPIconTile(symbol: emptyStateIcon, family: .sites, size: PPMetrics.quickActionIcon, lifted: true)
            
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
                Button("Show all projects") {
                    chooseStatus(nil)
                }
                .accessibilityIdentifier("projects.showAll")
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)
            } else if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil || isUnmatchedOperativeWithJobs {
                Button("Retry") {
                    projectStore.loadData()
                }
                .accessibilityIdentifier("projects.retry")
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
        return "folder"
    }

    private var emptyStateTitle: String {
        if isEmptyDueToStatusFilterOnly {
            return "No projects in this filter"
        }
        if isUnmatchedOperativeWithJobs {
            return "Jobs couldn’t be matched to you"
        }
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "Couldn’t load projects"
        }
        return "No projects found"
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
        if canCreateProjects {
            return WorksDashboardListStyle.projects.emptyCreatePrompt
        }
        return "Nothing here right now."
    }

    private var isUnmatchedOperativeWithJobs: Bool {
        userStore.isOperativeMode()
            && resolvedCurrentOperative == nil
            && projectStore.projects.contains { !$0.isSmallWorksDocument }
    }
    
    /// Regular projects (not small works), with operative visibility applied but without status chip filter.
    /// RULEBOOK 1.21.0 §21: the list is `worksListMembership(jobs, projects)` (every document of
    /// the kind, inactive included, once by id) and `visibleJobs(..., viewer, context)` (by account id and email,
    /// never by name; an operative's jobs are their bookings, tasks and deadlines). No Swift visibility rule.
    private var projectsBeforeStatusFilter: [Project] {
        listAnswers.visible
    }

    /// What this screen's §21 answers depend on (the loaded stores; deadline jobs by stored id).
    private var listInputs: WorksListScreenInputs {
        let deadlineIds: [String] = deadlineAssignedProjectIds.isEmpty ? [] : (projectStore.projects + projectStore.smallWorks)
            .filter { deadlineAssignedProjectIds.contains($0.id) }
            .map(\.documentId)
        return WorksListScreenInputs(
            kind: .projects,
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

    private func openPendingCatalogueJob() {
        guard let projectId = WorkCatalogueDeepLink.take(isSmallWorks: false) else { return }
        navigationPath = NavigationPath()
        navigationPath.append(OpenedProjectToken(projectId: projectId))
    }

    @ViewBuilder
    private func projectDetailDestination(_ projectId: UUID) -> some View {
        if let project = projectStore.projects.first(where: { $0.id == projectId && !$0.isSmallWorksDocument })
            ?? projectStore.projects.first(where: { $0.id == projectId }) {
            ProjectDetailView(project: project)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(appSettings)
                .background(
                    Color.clear
                        .preference(key: HideBottomMenuKey.self, value: true)
                )
        } else {
            ContentUnavailableView("Project unavailable", systemImage: "folder", description: Text("Pull to refresh and try again."))
        }
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
        return !projectsBeforeStatusFilter.isEmpty && filteredProjects.isEmpty
    }
    
    private var filteredProjects: [Project] {
        // RULEBOOK 1.33.0 §21: the My list (`myWorksList`) is its own filter, every status.
        if showsMyList { return myListJobs }
        var projects = projectsBeforeStatusFilter
        
        if let status = selectedStatus {
            // RULEBOOK 1.21.0 §21 `worksInTab`: inactive jobs are under Completed; All keeps every job.
            projects = listCache.jobs(listInputs, chip: status)
        }
        
        return projects
    }
}

struct ProjectDetailRowView: View {
    let project: Project
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var operativeStore: OperativeStore

    var body: some View {
        Group {
            if userStore.isOperativeMode() {
                operativeCompactCard
            } else {
                fullDetailCard
            }
        }
    }

    private var operativeCompactCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.jobNumber)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text(project.siteName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text(project.siteAddress)
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var fullDetailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(project.jobNumber)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .tracking(-0.2)
                        jobTypePill
                    }
                    Text(project.siteName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
                Spacer(minLength: 8)
                statusPill
            }

            VStack(alignment: .leading, spacing: 6) {
                rowIcon("building.2", project.client.name)
                rowIcon("mappin.and.ellipse", project.siteAddress)
                rowIcon("person", managerDisplayName)
                rowIcon("calendar", dateRangeDisplay)
            }

            listProgressSection
        }
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func rowIcon(_ system: String, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var jobTypePill: some View {
        Text(jobTypeLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.jobTypePillInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ProjectWorksRevampColors.jobTypePillBg)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .tracking(0.3)
    }

    private var jobTypeLabel: String {
        if let c = project.customJobType, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return c.uppercased()
        }
        return project.jobType.rawValue
    }

    private var managerDisplayName: String {
        if let managerId = project.managerId,
           let manager = operativeStore.allManagers.first(where: { $0.id == managerId }) {
            return "\(manager.firstName) \(manager.lastName)"
        }
        return project.manager.displayName
    }

    private var dateRangeDisplay: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "\(f.string(from: project.startDate)) – \(f.string(from: project.endDate))"
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            if project.status == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Circle()
                    .fill(statusAccent)
                    .frame(width: 5, height: 5)
            }
            Text(project.status.rawValue)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(statusPillForeground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(statusPillBackground)
        .clipShape(Capsule())
    }

    private var statusAccent: Color {
        switch project.status {
        case .active: return ProjectWorksRevampColors.activeGreen
        case .upcoming: return ProjectWorksRevampColors.upcomingAmber
        case .completed, .inactive: return ProjectWorksRevampColors.muted
        }
    }

    private var statusPillForeground: Color {
        switch project.status {
        case .active: return ProjectWorksRevampColors.activeGreen
        case .upcoming: return ProjectWorksRevampColors.upcomingAmber
        case .completed, .inactive: return ProjectWorksRevampColors.muted
        }
    }

    private var statusPillBackground: Color {
        switch project.status {
        case .active: return ProjectWorksRevampColors.greenTint // #E1F5EE
        case .upcoming: return ProjectWorksRevampColors.amberTint
        case .completed, .inactive: return ProjectWorksRevampColors.grayTint // #F2F3F5
        }
    }

    private var listProgressSection: some View {
        let pct = WorksListProgress.fraction(for: project)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Progress")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Spacer()
                Text("\(WorksListProgress.percentDisplay(for: project))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(project.status == .completed ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ProjectWorksRevampColors.border)
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            project.status == .completed
                                ? AnyShapeStyle(ProjectWorksRevampColors.placeholderInk)
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .frame(width: max(4, geo.size.width * pct), height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(.top, 4)
    }
}

struct AddProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    
    @State private var jobNumber = ""
    @State private var siteName = ""
    @State private var siteAddress = ""
    @State private var selectedClient: Client?
    @State private var startDate = Date()
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var selectedJobType: JobType = .catA
    @State private var selectedManager: ManagerLegacy = .farnie
    @State private var description = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Project Details") {
                    TextField("Job Number", text: $jobNumber)
                        .accessibilityIdentifier("addProject.jobNumber")
                    TextField("Site Name", text: $siteName)
                        .accessibilityIdentifier("addProject.siteName")
                    TextField("Site Address", text: $siteAddress, axis: .vertical)
                        .accessibilityIdentifier("addProject.siteAddress")
                        .lineLimit(3...6)
                }
                
                Section("Client & Type") {
                    Picker("Client", selection: $selectedClient) {
                        Text("Select Client").tag(nil as Client?)
                        ForEach(projectStore.clients) { client in
                            Text(client.name).tag(client as Client?)
                        }
                    }
                        .accessibilityIdentifier("addProject.client")
                    
                    Picker("Job Type", selection: $selectedJobType) {
                        ForEach(JobType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                        .accessibilityIdentifier("addProject.jobType")
                }
                
                Section("Schedule") {
                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                        .accessibilityIdentifier("addProject.startDate")
                    DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                        .accessibilityIdentifier("addProject.endDate")
                    
                    Picker("Manager", selection: $selectedManager) {
                        ForEach(ManagerLegacy.allCases) { manager in
                            Text(manager.displayName).tag(manager)
                        }
                    }
                        .accessibilityIdentifier("addProject.manager")
                }
                
                Section("Additional Info") {
                    TextField("Description", text: $description, axis: .vertical)
                        .accessibilityIdentifier("addProject.description")
                        .lineLimit(3...6)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .accessibilityIdentifier("addProject.notes")
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Add Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                        .accessibilityIdentifier("addProject.cancel")
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveProject()
                    }
                    .accessibilityIdentifier("addProject.save")
                    .disabled(!isFormValid)
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !jobNumber.isEmpty && 
        !siteName.isEmpty && 
        !siteAddress.isEmpty && 
        selectedClient != nil
    }
    
    private func saveProject() {
        guard let client = selectedClient else { return }
        
        let project = Project(
            jobNumber: jobNumber,
            siteName: siteName,
            siteAddress: siteAddress,
            client: client,
            startDate: startDate,
            endDate: endDate,
            jobType: selectedJobType,
            manager: selectedManager,
            description: description.isEmpty ? nil : description,
            notes: notes.isEmpty ? nil : notes
        )
        
        Task {
            do {
                try await projectStore.addProject(project)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Error adding project: \(error.localizedDescription)")
                // You might want to show an alert to the user here
            }
        }
    }
}

#Preview {
    ProjectsView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(UserStore())
        .environmentObject(AppSettingsStore())
        .environmentObject(NotificationService())
}
