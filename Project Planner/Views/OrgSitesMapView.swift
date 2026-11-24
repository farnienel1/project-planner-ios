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
        let allProjects = works.filter { pinByJob[$0.id.uuidString.lowercased()] != nil }

        var builtPins: [SiteMapPin] = []
        let nameOperatives = operativeStore.allOperatives
        let nameUsers = userStore.bookingNameUsers
        // Working hours in effect on the day shown (RULEBOOK §4.3), as Daily Overview prices it.
        let dayPolicy = firebaseBackend.payrollPolicy(for: targetDate)
        let dayManagerBookings = managerScheduleStore.managerSiteBookings.filter {
            OrganizationRulebookContext.dayKey($0.date) == dayKey
                && ($0.locationType == .project || $0.locationType == .smallWork)
        }
        let leaveOnDay = leaveRecordsOnDay(dayKey: dayKey)
        for project in allProjects {
            guard let coordinate = await GeocodingCacheService.shared.coordinate(for: project.siteAddress) else { continue }
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
            let bookedPeople: [(id: String, name: String)] =
                siteBookings.map { booking -> (id: String, name: String) in
                    (booking.storedOperativeId, rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: nameOperatives, users: nameUsers))
                }
                + managerHere.map { booking -> (id: String, name: String) in
                    let user = userStore.organizationUsers.first { $0.id.caseInsensitiveCompare(booking.userId) == .orderedSame }
                    let name = user.map { $0.fullName.isEmpty ? $0.email : $0.fullName } ?? "Unknown person"
                    return (booking.userId, name)
                }
            let leaveNames = peopleOnLeave(bookedPeople: bookedPeople, leave: leaveOnDay)
            let summary = SiteMapJobDaySummary.make(
                peopleOnSite: operativeCount,
                results: results.map(SiteMapJobDaySummary.HoursInput.init(result:)),
                onLeaveNames: leaveNames
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
            if let selectedPinId, !builtPins.contains(where: { $0.id == selectedPinId }) {
                self.selectedPinId = nil
            }
        }
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

    /// `dailyOverviewLeaveRows` (RULEBOOK 1.53.0, as Daily Overview): approved leave records whose leave days include
    /// the day. Empty when the rule did not answer.
    private func leaveRecordsOnDay(dayKey: String) -> [HolidayBooking] {
        let candidates = holidayStore.bookings.filter { $0.startDayKey <= dayKey && $0.endDayKey >= dayKey }
        guard let ids = CanonicalBusinessEngine.dailyOverviewLeaveRecordIds(
            records: candidates.map {
                (id: $0.documentId, startDayKey: $0.startDayKey, endDayKey: $0.endDayKey, timeSlot: $0.timeSlot.rawValue, status: $0.status.rawValue)
            },
            dayKey: dayKey,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            bankHolidayDayKeys: OrganizationBankHolidays.dayKeys
        ) else { return [] }
        return candidates.filter { ids.contains($0.documentId) }
    }

    /// The people booked on this job that day who are on annual leave that day (a half day of leave beside a booking).
    /// Who a booked id is comes from the rulebook only (guardrail 1): `personIdSet` over the unfolded roster plus the
    /// `operatives` rows (every users document, former and same-email ids, rows on the same email), then
    /// `leaveRecordsForAccount` decides which records are theirs (ids without case, the email as `userId`). An
    /// operatives row linked to an account speaks for that account. Names as the schedule shows them.
    private func peopleOnLeave(bookedPeople: [(id: String, name: String)], leave: [HolidayBooking]) -> [String] {
        guard !leave.isEmpty else { return [] }
        let users = userStore.unfoldedOrganizationUsers
        let operatives = operativeStore.allOperatives
        let operativeRows = operatives.map {
            CanonicalBusinessEngine.CanonicalBookingPersonOperative(
                id: $0.documentId,
                email: $0.email.isEmpty ? nil : $0.email
            )
        }
        let roster = userStore.unfoldedRosterRows
            + operatives.map { ["id": $0.documentId, "email": $0.email] as [String: Any] }
        let records = leave.map { (userId: $0.userId, operativeId: $0.operativeIdRaw) }
        var names: [String] = []
        var seen = Set<String>()
        for (personId, name) in bookedPeople {
            let trimmed = personId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { continue }
            let row = operatives.first { $0.documentId.caseInsensitiveCompare(trimmed) == .orderedSame }
            let accountId = row?.linkedUserId.flatMap { $0.isEmpty ? nil : $0 } ?? trimmed
            let user = users.first { $0.id.caseInsensitiveCompare(accountId) == .orderedSame }
            let email = user.map(\.email) ?? row?.email ?? ""
            let person: [String: Any] = user.map(RulebookPeople.person) ?? ["id": accountId, "email": email]
            guard let ids = CanonicalBusinessEngine.personIdSet(person: person, roster: roster) else { continue }
            let allIds = Array(Set(ids + [trimmed]))
            seen.formUnion(allIds.map { $0.lowercased() })
            guard let matched = CanonicalBusinessEngine.leaveRecordsForAccount(
                records: records,
                account: CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                    id: accountId,
                    email: email.isEmpty ? nil : email,
                    formerIds: user?.formerUserIds,
                    aliasIds: allIds
                ),
                operatives: operativeRows
            ), !matched.isEmpty else { continue }
            names.append(name)
        }
        return names
    }
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
/// Overview's overtime tile) and the people booked there who are on annual leave that day. No figure is worked out
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
