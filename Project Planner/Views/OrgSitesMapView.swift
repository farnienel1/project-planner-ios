import SwiftUI
import MapKit

struct OrgSitesMapView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var holidayStore: HolidayStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date = Date()
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
    )
    @State private var pins: [SiteMapPin] = []
    @State private var selectedPinId: String?
    @State private var isLoading = false
    /// Owner 24 Nov (web PR #440): off by default — Active and Upcoming jobs only.
    @State private var showCompleted = false
    /// Jobs that could not be placed from their address (web "Jobs without an address").
    @State private var unplacedJobs: [UnplacedSiteJob] = []
    @State private var showingUnplaced = false
    @State private var pinPickerJob: Project?
    @State private var pinPickerLatitude: Double?
    @State private var pinPickerLongitude: Double?
    @State private var pinSaveError: String?
    private let defaultMapSpan = MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    /// Owner report 24 Nov: opened on the office (company details map pin), about a 10-mile radius around it.
    private static let officeRadiusMeters: CLLocationDistance = 16_093
    private let selectedJobMapSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

    private var selectedPin: SiteMapPin? {
        pins.first(where: { $0.id == selectedPinId })
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                mapControlsBar
                OSMMapView(region: $region, pins: pins, selectedPinId: $selectedPinId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let selectedPin {
                    infoCard(for: selectedPin)
                } else {
                    HStack(spacing: 12) {
                        PPIconTile(symbol: "mappin.and.ellipse", family: .sites, size: PPMetrics.menuIcon)
                        Text("Tap a pin to view job info")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PPColor.page)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(height: 0.5)
                            .accessibilityHidden(true)
                    }
                }
            }
            .navigationTitle("Site Map")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        Task {
                            let center = await resolveDefaultCenter()
                            await MainActor.run {
                                region = initialRegion(center: center)
                                selectedPinId = nil
                                dismiss()
                            }
                        }
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("orgSitesMap.done")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .task { await loadMapData() }
            .onChange(of: selectedDate) { _, _ in
                Task { await loadMapData() }
            }
            .onChange(of: showCompleted) { _, _ in
                Task { await loadMapData() }
            }
            .sheet(isPresented: $showingUnplaced) {
                unplacedSheet
            }
        }
    }

    private func infoCard(for pin: SiteMapPin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PPIconTile(symbol: "mappin.circle.fill", family: .sites, size: 36)
                Text(pin.siteName)
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                Spacer()
                Text(pin.pinKind.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(pin.pinKind.color.opacity(0.15))
                    .foregroundColor(pin.pinKind.color)
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Job Number", value: pin.jobNumber)
                infoRow(label: "Job Name", value: pin.siteName)
                infoRow(label: "Client", value: pin.clientName)
                infoRow(label: "Manager", value: pin.managerName)
            }
            .padding(12)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            // The selected day's summary for this job, from the rulebook rules Daily Overview uses.
            HStack(spacing: 8) {
                summaryTile(value: "\(pin.summary.peopleOnSite)", label: "On site", symbol: "person.2.fill")
                summaryTile(value: pin.summary.hoursText, label: "Hours", symbol: "clock.fill")
                summaryTile(value: pin.summary.overtimeText, label: "Overtime", symbol: "flame.fill")
                summaryTile(value: "\(pin.summary.onLeaveCount)", label: "On leave", symbol: "sun.max.fill")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("orgSitesMap.summary")
            if !pin.summary.onLeaveNames.isEmpty {
                Text("On annual leave: " + pin.summary.onLeaveNames.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPFamily.plan.bottom)
                Text(dayLabel(selectedDate))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    selectedDate = OrganizationRulebookContext.calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("orgSitesMap.previous")
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)

                Button {
                    selectedDate = OrganizationRulebookContext.calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .accessibilityIdentifier("orgSitesMap.next")
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)
            }

            if pin.scheduleRows.isEmpty {
                Text("No bookings for this day.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(pin.scheduleRows, id: \.self) { row in
                    Text(row)
                        .font(.subheadline)
                }
            }
        }
        .padding(PPMetrics.screenGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.page)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
    }

    private func summaryTile(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .accessibilityHidden(true)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            Text(value.isEmpty ? "N/A" : value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy"
        formatter.timeZone = OrganizationRulebookContext.timeZone
        return formatter.string(from: date)
    }

    private func loadMapData() async {
        isLoading = true
        defer { isLoading = false }

        // RULEBOOK 1.53.0: the organisation day, never the device's.
        let targetDate = OrganizationRulebookContext.calendar.startOfDay(for: selectedDate)
        let center = await resolveDefaultCenter()
        await MainActor.run {
            // Keep current focus while user is interacting with a selected pin.
            if selectedPinId == nil {
                region = initialRegion(center: center)
            }
        }

        // RULEBOOK 1.23.0 §21 `CanonicalBusinessEngine.siteMapPins`: the organisation day, bookings that occupy it
        // (cancelled never), manager site bookings on the job, each person once; jobs that are not inactive.
        let dayKey = OrganizationRulebookContext.dayKey(targetDate)
        let dayBookings = bookingStore.bookings.filter {
            OrganizationRulebookContext.dayKey($0.date) == dayKey && $0.occupiesDay
        }
        let works = ProjectWorksMerge.uniqueWorks(projectStore.projects)
        let people: [[String: Any]] = userStore.organizationUsers.map(RulebookRosterLists.levelRow)
            + operativeStore.allOperatives.map { ["id": Booking.operativeMatchKey(for: $0.id), "email": $0.email] as [String: Any] }
            + operativeStore.allManagers.map { ["id": $0.id.uuidString, "email": $0.email] as [String: Any] }
        let pinInput: [String: Any] = [
            "jobs": works.map { ["id": $0.id.uuidString, "isLive": $0.isLive] as [String: Any] },
            "bookings": bookingStore.bookings.map { booking -> [String: Any] in
                ["projectId": booking.projectId.uuidString, "operativeId": Booking.operativeMatchKey(for: booking.operativeId),
                 "dayKey": OrganizationRulebookContext.dayKey(booking.date), "status": booking.status.rawValue]
            },
            "managerSiteBookings": managerScheduleStore.managerSiteBookings.map { booking -> [String: Any] in
                ["userId": booking.userId, "locationId": booking.locationId.map { $0.uuidString as Any } ?? NSNull(),
                 "locationType": booking.locationType.rawValue, "dayKey": OrganizationRulebookContext.dayKey(booking.date)]
            },
            "dayKey": dayKey,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "people": people,
        ]
        let scriptPins = CanonicalBusinessEngine.siteMapPins(pinInput) ?? []
        let pinByJob = Dictionary(scriptPins.map { ($0.jobId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        // Owner 24 Nov (web PR #440 `siteMapJobShown`): Active and Upcoming jobs always, Completed only with the toggle
        // or when someone is booked on it that day, inactive never. Status is the rulebook's (`jobWorkStatus`,
        // `worksTab`, §21) on the day shown in the organisation zone. `siteMapPins` already leaves inactive jobs out.
        let includeCompleted = showCompleted
        let allProjects = works.filter { project in
            guard let pin = pinByJob[project.id.uuidString.lowercased()] else { return false }
            let tab = CanonicalBusinessEngine.jobWorkStatus(project, now: targetDate).map(CanonicalBusinessEngine.worksTab)
            return SiteMapPlacementRules.jobShown(
                isLive: project.isLive,
                tab: tab,
                includeCompleted: includeCompleted,
                bookedThatDay: pin.bookingCount > 0 || pin.peopleCount > 0
            )
        }

        // Web PR #440's order: the saved map pin, then an address stored as "lat, lng" text, then the UK postcode
        // (postcodes.io, else Apple geocoding of the postcode alone). Only postcodes are sent; nothing is written.
        var lookups = await PostcodeLookupService.shared.cached()
        let toLookUp = allProjects.compactMap { project -> String? in
            guard placement(for: project, lookups: lookups) == nil else { return nil }
            return SiteMapPlacementRules.postcode(field: project.postcode, addressTexts: [project.siteAddress])
        }
        if !toLookUp.isEmpty {
            let answers = await PostcodeLookupService.shared.lookup(toLookUp)
            lookups.merge(answers) { _, new in new }
        }

        var builtPins: [SiteMapPin] = []
        var builtUnplaced: [UnplacedSiteJob] = []
        let nameOperatives = operativeStore.allOperatives
        let nameUsers = userStore.bookingNameUsers
        // Working hours in effect on the day shown (RULEBOOK §4.3), as Daily Overview prices it.
        let dayPolicy = firebaseBackend.payrollPolicy(for: targetDate)
        let dayManagerBookings = managerScheduleStore.managerSiteBookings.filter {
            OrganizationRulebookContext.dayKey($0.date) == dayKey
                && ($0.locationType == .project || $0.locationType == .smallWork)
        }
        // RULEBOOK 1.82.0 §21 (owner 24 Nov): the whole company's approved leave that day, once for every pin.
        let companyLeave = companyLeaveOnDay(dayKey: dayKey)
        for project in allProjects {
            let spot = placement(for: project, lookups: lookups) ?? .lookupFailed(
                postcode: SiteMapPlacementRules.postcode(field: project.postcode, addressTexts: [project.siteAddress]) ?? ""
            )
            guard let coordinate = spot.coordinate else {
                builtUnplaced.append(UnplacedSiteJob(project: project, placement: spot, pinKind: pinKind(for: project)))
                continue
            }
            let siteBookings = dayBookings.filter { $0.projectId == project.id }
            let operativeCount = pinByJob[project.id.uuidString.lowercased()]?.peopleCount ?? 0
            let rows = siteBookings
                .sorted { $0.timeSlot.displayName < $1.timeSlot.displayName }
                .map { booking -> String in
                    // Same name the schedule shows; a booking with no catalogue row is not dropped from the pin.
                    let name = rosterNameForLabourBooking(
                        operativeId: booking.operativeId,
                        operatives: nameOperatives,
                        users: nameUsers
                    )
                    return "\(booking.timeSlot.displayName) - \(name)"
                }
            let managerHere = dayManagerBookings.filter { $0.locationId == project.id }
            let results = siteBookings.map { $0.payrollHoursResult(policy: dayPolicy) }
                + managerHere.map { $0.payrollHoursResult(policy: dayPolicy) }
            let summary = SiteMapJobDaySummary.make(
                peopleOnSite: operativeCount,
                results: results.map(SiteMapJobDaySummary.HoursInput.init(result:)),
                onLeaveNames: companyLeave
            )
            builtPins.append(
                SiteMapPin(
                    id: project.id.uuidString,
                    jobNumber: project.jobNumber,
                    siteName: project.siteName,
                    clientName: project.client.name,
                    managerName: resolveManagerName(for: project),
                    coordinate: coordinate,
                    scheduleRows: rows,
                    operativeCount: operativeCount,
                    summary: summary,
                    pinKind: pinKind(for: project),
                    coordinateSpanOnSelect: selectedJobMapSpan
                )
            )
        }

        await MainActor.run {
            pins = builtPins
            unplacedJobs = builtUnplaced.sorted { $0.project.siteName.localizedCaseInsensitiveCompare($1.project.siteName) == .orderedAscending }
            if let selectedPinId, !builtPins.contains(where: { $0.id == selectedPinId }) {
                self.selectedPinId = nil
            }
        }
    }

    /// Where one job goes (`SiteMapPlacementRules.placement`); nil while its postcode has not been looked up.
    private func placement(for project: Project, lookups: [String: PostcodeLookupAnswer]) -> SiteMapPlacement? {
        SiteMapPlacementRules.placement(
            latitude: project.latitude,
            longitude: project.longitude,
            addressLine1: project.addressLine1,
            postcodeField: project.postcode,
            formattedAddress: project.siteAddress,
            lookups: lookups
        )
    }

    // MARK: - Completed toggle, key and "Jobs without an address" (web PR #440)

    private var mapControlsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                legendItem(color: SitePinKind.project.color, label: "Project")
                legendItem(color: SitePinKind.smallWorks.color, label: "Small works")
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Map key: blue dots are projects, red dots are small works")
            Toggle("Show completed jobs", isOn: $showCompleted)
                .font(.subheadline.weight(.semibold))
                .tint(PPColor.brand)
                .accessibilityIdentifier("orgSitesMap.showCompleted")
            if let text = SiteMapPlacementRules.unplacedText(
                count: unplacedJobs.filter { !isLookupFailed($0.placement) }.count,
                lookupFailedCount: unplacedJobs.filter { isLookupFailed($0.placement) }.count
            ) {
                Button {
                    showingUnplaced = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.slash")
                        Text(text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text("See which")
                            .fontWeight(.semibold)
                    }
                    .font(.footnote)
                    .foregroundStyle(PPColor.brand)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("orgSitesMap.unplaced")
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.vertical, 10)
        .background(PPColor.page)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func isLookupFailed(_ placement: SiteMapPlacement) -> Bool {
        if case .lookupFailed = placement { return true }
        return false
    }

    private var unplacedSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(unplacedJobs) { job in
                        unplacedRow(job)
                    }
                } footer: {
                    Text(unplacedJobs.count == 1
                        ? "This job could not be placed on the map from its address. Set the pin by hand and it is saved to the job."
                        : "These \(unplacedJobs.count) jobs could not be placed on the map from their addresses. Set the pin by hand and it is saved to the job.")
                }
                if let pinSaveError {
                    Section {
                        Text(pinSaveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Jobs without an address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingUnplaced = false }
                        .accessibilityIdentifier("orgSitesMap.unplaced.done")
                }
            }
            .sheet(item: $pinPickerJob) { job in
                MapPinPickerView(
                    initialCoordinate: region.center,
                    selectedLatitude: $pinPickerLatitude,
                    selectedLongitude: $pinPickerLongitude,
                    onConfirm: { coordinate in
                        Task { await savePin(coordinate, for: job) }
                    }
                )
            }
        }
    }

    private func unplacedRow(_ job: UnplacedSiteJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(job.pinKind.color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.project.siteName.isEmpty ? "Untitled site" : job.project.siteName)
                    .font(.subheadline.weight(.semibold))
                let address = job.project.displaySiteAddress
                Text([
                    job.project.jobNumber.isEmpty ? "—" : job.project.jobNumber,
                    job.pinKind == .smallWorks ? "Small works" : "Project",
                    address.isEmpty ? "No address" : address,
                    job.placement.unplacedReason,
                ].joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isLookupFailed(job.placement) {
                Button("Retry") {
                    Task { await loadMapData() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("orgSitesMap.unplaced.retry")
            } else if userStore.canEditJob(job.project) {
                // Admins and the job's managers (`canEditJob`, as web `userCanEditJob`).
                Button("Set pin") {
                    pinPickerLatitude = nil
                    pinPickerLongitude = nil
                    pinSaveError = nil
                    pinPickerJob = job.project
                }
                .buttonStyle(.borderedProminent)
                .tint(PPColor.brand)
                .accessibilityIdentifier("orgSitesMap.unplaced.setPin")
            } else {
                Text("Ask an admin to set the pin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 4)
    }

    /// Saves the pin through the existing job write (`ProjectStore.updateProject`: only the changed fields, to the
    /// collection the job was read from), as web `SetSitePinButton` does through `saveProject`.
    private func savePin(_ coordinate: CLLocationCoordinate2D, for job: Project) async {
        guard SiteMapPlacementRules.validCoordinate(coordinate.latitude, coordinate.longitude) != nil else {
            pinSaveError = "That pin could not be used. Try again."
            return
        }
        let sameRecord: (Project) -> Bool = { $0.id == job.id && $0.sourceCollection == job.sourceCollection }
        guard let base = projectStore.projects.first(where: sameRecord) ?? projectStore.smallWorksDocuments.first(where: sameRecord) else {
            pinSaveError = "This was deleted on another device."
            return
        }
        var updated = base
        updated.latitude = coordinate.latitude
        updated.longitude = coordinate.longitude
        updated.usesMapPinForLocation = true
        updated.updatedAt = Date()
        await projectStore.updateProject(updated, editedFrom: base)
        await loadMapData()
    }

    /// About a 10-mile radius around the office when the company details have a map pin; otherwise as before.
    private func initialRegion(center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        if let org = firebaseBackend.currentOrganization, org.defaultLatitude != nil, org.defaultLongitude != nil {
            return MKCoordinateRegion(
                center: center,
                latitudinalMeters: Self.officeRadiusMeters * 2,
                longitudinalMeters: Self.officeRadiusMeters * 2
            )
        }
        return MKCoordinateRegion(center: center, span: defaultMapSpan)
    }

    private func resolveDefaultCenter() async -> CLLocationCoordinate2D {
        guard let org = firebaseBackend.currentOrganization else {
            return CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        }

        if let lat = org.defaultLatitude, let lon = org.defaultLongitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        let officeAddress = [org.officeAddressLine1, org.officeCity, org.officePostcode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !officeAddress.isEmpty,
           let geocoded = await GeocodingCacheService.shared.coordinate(for: officeAddress) {
            return geocoded
        }

        if let fallback = CountryCapitalDirectory.option(for: org.countryCode) {
            if org.countryCode.uppercased() == "GB" {
                return CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
            }
            return CLLocationCoordinate2D(latitude: fallback.latitude, longitude: fallback.longitude)
        }
        return CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    }

    private func resolveManagerName(for project: Project) -> String {
        if let managerId = project.managerId,
           let manager = operativeStore.managers.first(where: { $0.id == managerId }) {
            return manager.fullName
        }
        return project.manager.displayName
    }

    /// Projects blue, small works red (owner 24 Nov). The collection decides the kind (RULEBOOK §17 `jobKind`), never
    /// the picker `jobType`.
    private func pinKind(for project: Project) -> SitePinKind {
        project.isSmallWorksDocument ? .smallWorks : .project
    }

    /// RULEBOOK 1.82.0 §21 `siteMapLeaveSummary` (owner 24 Nov, item 1): everyone in the company on approved annual
    /// leave on the day shown — leave is not tied to a job — one per person (the rulebook folds a person's ids and
    /// records), named as the roster names them. Empty when the rule did not answer (no count of our own).
    private func companyLeaveOnDay(dayKey: String) -> [String] {
        let records: [[String: Any]] = holidayStore.bookings.map { booking in
            [
                "id": booking.documentId,
                "userId": booking.userId ?? "",
                "operativeId": booking.operativeIdRaw ?? "",
                "startDayKey": booking.startDayKey,
                "endDayKey": booking.endDayKey,
                "timeSlot": booking.timeSlot.rawValue,
                "status": booking.status.rawValue,
            ]
        }
        let roster: [[String: Any]] = userStore.unfoldedOrganizationUsers.map { user in
            var row = RulebookPeople.person(user)
            row["name"] = user.fullName.isEmpty ? user.email : user.fullName
            return row
        }
        let operatives: [[String: Any]] = operativeStore.allOperatives.map { row in
            ["id": row.documentId, "email": row.email, "name": "\(row.firstName) \(row.lastName)".trimmingCharacters(in: .whitespaces)]
        }
        guard let summary = CanonicalBusinessEngine.siteMapLeaveSummary(
            records: records,
            dayKey: dayKey,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys,
            roster: roster,
            operatives: operatives
        ) else { return [] }
        return summary.people.map { $0.name ?? "Unknown person" }
    }
}

private struct UnplacedSiteJob: Identifiable {
    var id: String { "\(project.sourceCollection.rawValue)/\(project.documentId)" }
    let project: Project
    let placement: SiteMapPlacement
    let pinKind: SitePinKind
}

private struct SiteMapPin: Identifiable {
    let id: String
    let jobNumber: String
    let siteName: String
    let clientName: String
    let managerName: String
    let coordinate: CLLocationCoordinate2D
    let scheduleRows: [String]
    let operativeCount: Int
    let summary: SiteMapJobDaySummary
    let pinKind: SitePinKind
    let coordinateSpanOnSelect: MKCoordinateSpan
}

private enum SitePinKind {
    case project
    case smallWorks
    case maintenance

    var color: Color {
        switch self {
        case .project: return .blue
        case .smallWorks: return .red
        case .maintenance: return .orange
        }
    }

    var markerTintColor: UIColor {
        switch self {
        case .project: return .systemBlue
        case .smallWorks: return .systemRed
        case .maintenance: return .systemOrange
        }
    }

    var displayName: String {
        switch self {
        case .project: return "Project"
        case .smallWorks: return "Small Works"
        case .maintenance: return "Maintenance"
        }
    }
}

private struct OSMMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let pins: [SiteMapPin]
    @Binding var selectedPinId: String?
    
    private func pinSignature(for pins: [SiteMapPin]) -> String {
        pins
            .sorted(by: { $0.id < $1.id })
            .map { "\($0.id)|\($0.coordinate.latitude)|\($0.coordinate.longitude)|\($0.pinKind.displayName)|\($0.operativeCount)" }
            .joined(separator: ";")
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.pointOfInterestFilter = .includingAll
        map.showsCompass = true
        map.showsScale = true
        if #available(iOS 17.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat)
            config.pointOfInterestFilter = .includingAll
            map.preferredConfiguration = config
        }
        // Reliability fix:
        // Keep Apple base map visible and overlay OSM tiles on top. If OSM tiles fail/throttle,
        // users still see a working map instead of blank background.
        let overlay = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        overlay.canReplaceMapContent = false
        map.addOverlay(overlay, level: .aboveLabels)
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if !context.coordinator.isRegionApproximatelyEqual(lhs: map.region, rhs: region) {
            map.setRegion(region, animated: false)
        }

        let currentSignature = pinSignature(for: pins)
        if context.coordinator.lastPinsSignature != currentSignature {
            context.coordinator.lastPinsSignature = currentSignature
            let existing = map.annotations.compactMap { $0 as? SitePinAnnotation }
            map.removeAnnotations(existing)

            let annotations = pins.map { pin in
                SitePinAnnotation(
                    id: pin.id,
                    coordinate: pin.coordinate,
                    title: "\(pin.jobNumber) \(pin.siteName)",
                    subtitle: pin.clientName,
                    kind: pin.pinKind,
                    coordinateSpanOnSelect: pin.coordinateSpanOnSelect
                )
            }
            map.addAnnotations(annotations)
        }

        if let selectedPinId,
           let annotation = map.annotations.compactMap({ $0 as? SitePinAnnotation }).first(where: { $0.id == selectedPinId }),
           map.selectedAnnotations.compactMap({ $0 as? SitePinAnnotation }).first(where: { $0.id == selectedPinId }) == nil {
            map.selectAnnotation(annotation, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region, selectedPinId: $selectedPinId)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        @Binding var region: MKCoordinateRegion
        @Binding var selectedPinId: String?
        var lastPinsSignature: String = ""

        init(region: Binding<MKCoordinateRegion>, selectedPinId: Binding<String?>) {
            self._region = region
            self._selectedPinId = selectedPinId
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let selected = view.annotation as? SitePinAnnotation else { return }
            selectedPinId = selected.id
            let focusedRegion = MKCoordinateRegion(
                center: selected.coordinate,
                span: selected.coordinateSpanOnSelect
            )
            region = focusedRegion
            mapView.setRegion(focusedRegion, animated: true)
        }
        
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let selected = view.annotation as? SitePinAnnotation else { return }
            if selectedPinId == selected.id {
                selectedPinId = nil
            }
        }

        func isRegionApproximatelyEqual(lhs: MKCoordinateRegion, rhs: MKCoordinateRegion) -> Bool {
            let centerTolerance = 0.0001
            let spanTolerance = 0.0001
            let centerLatClose = abs(lhs.center.latitude - rhs.center.latitude) < centerTolerance
            let centerLonClose = abs(lhs.center.longitude - rhs.center.longitude) < centerTolerance
            let spanLatClose = abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < spanTolerance
            let spanLonClose = abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < spanTolerance
            return centerLatClose && centerLonClose && spanLatClose && spanLonClose
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? SitePinAnnotation else { return nil }
            let reuseIdentifier = "site-pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: reuseIdentifier)
            view.annotation = pin
            view.canShowCallout = false
            view.glyphText = "•"
            view.markerTintColor = pin.kind.markerTintColor
            return view
        }
    }
}

private final class SitePinAnnotation: NSObject, MKAnnotation {
    let id: String
    let kind: SitePinKind
    let coordinateSpanOnSelect: MKCoordinateSpan
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(
        id: String,
        coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String,
        kind: SitePinKind,
        coordinateSpanOnSelect: MKCoordinateSpan
    ) {
        self.id = id
        self.kind = kind
        self.coordinateSpanOnSelect = coordinateSpanOnSelect
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}

/// One job's figures for the day shown on the site map (owner 24 Nov): people on site (`siteMapPins.peopleCount`),
/// hours on site (the pay rule's `payrollHoursResult.totalPaidHours`, as Daily Overview), overtime (the clock hours at
/// the multiplier with any unpaid break as plain hours — `payrollMultipliedHours` and `overtimeTotalText`, as Daily
/// Overview's overtime tile) and (RULEBOOK 1.82.0 §21) everyone in the company on annual leave that day. No figure is worked out
/// here: it only adds up the rulebook's per-booking answers.
struct SiteMapJobDaySummary: Equatable {
    struct HoursInput: Equatable {
        var totalPaidHours: Double
        var outsideHours: Double
        var outsideMultiplier: Double
        var multipliedClockHours: Double?
        var multipliedBreakHours: Double?

        init(totalPaidHours: Double, outsideHours: Double, outsideMultiplier: Double, multipliedClockHours: Double?, multipliedBreakHours: Double?) {
            self.totalPaidHours = totalPaidHours
            self.outsideHours = outsideHours
            self.outsideMultiplier = outsideMultiplier
            self.multipliedClockHours = multipliedClockHours
            self.multipliedBreakHours = multipliedBreakHours
        }

        init(result: PayrollHoursResult) {
            let multiplied = result.multipliedHours
            self.init(
                totalPaidHours: result.totalPaidHours,
                outsideHours: result.outsideHours,
                outsideMultiplier: result.outsideMultiplier,
                multipliedClockHours: multiplied?.clockHours,
                multipliedBreakHours: multiplied?.breakHours
            )
        }
    }

    var peopleOnSite: Int
    var hours: Double
    var overtimeClockHours: Double
    var hoursText: String
    var overtimeText: String
    var onLeaveNames: [String]
    var onLeaveCount: Int { onLeaveNames.count }

    static func make(peopleOnSite: Int, results: [HoursInput], onLeaveNames: [String]) -> SiteMapJobDaySummary {
        let hours = results.reduce(0) { $0 + $1.totalPaidHours }
        var clock = 0.0
        var breakHours = 0.0
        var multipliers = Set<Double>()
        for result in results {
            clock += result.multipliedClockHours ?? result.outsideHours
            breakHours += result.multipliedBreakHours ?? 0
            if result.outsideHours > 0 { multipliers.insert(result.outsideMultiplier) }
        }
        let overtimeText: String
        if clock <= 0.0001 {
            overtimeText = "0h"
        } else if multipliers.count == 1, let rate = multipliers.first,
                  let text = CanonicalBusinessEngine.overtimeTotalText(clockHours: clock, multiplier: rate, breakHours: breakHours) {
            overtimeText = text
        } else {
            overtimeText = "\(ScheduleCoverageFormat.hours(clock))h OT"
        }
        return SiteMapJobDaySummary(
            peopleOnSite: peopleOnSite,
            hours: hours,
            overtimeClockHours: clock,
            hoursText: "\(ScheduleCoverageFormat.hours(hours))h",
            overtimeText: overtimeText,
            onLeaveNames: onLeaveNames
        )
    }
}


