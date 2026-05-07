import SwiftUI
import MapKit

struct OrgSitesMapView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
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
                    Text("Tap a pin to view job info")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .navigationTitle("Site Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        Task {
                            let center = await resolveDefaultCenter()
                            await MainActor.run {
                                region = MKCoordinateRegion(center: center, span: defaultMapSpan)
                                selectedPinId = nil
                                dismiss()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView()
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
            HStack {
                Text(pin.siteName)
                    .font(.headline)
                Spacer()
                Text(pin.pinKind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(pin.pinKind.color.opacity(0.15))
                    .foregroundColor(pin.pinKind.color)
                    .clipShape(Capsule())
            }

            Group {
                infoRow(label: "Job Number", value: pin.jobNumber)
                infoRow(label: "Job Name", value: pin.siteName)
                infoRow(label: "Client", value: pin.clientName)
                infoRow(label: "Manager", value: pin.managerName)
                infoRow(label: "Operatives On Site", value: "\(pin.operativeCount)")
            }

            HStack {
                Text(dayLabel(selectedDate))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Button {
                    selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
            }

            if pin.scheduleRows.isEmpty {
                Text("No bookings for this day.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(pin.scheduleRows, id: \.self) { row in
                    Text(row)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
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
        return formatter.string(from: date)
    }

    private func loadMapData() async {
        isLoading = true
        defer { isLoading = false }

        let targetDate = Calendar.current.startOfDay(for: selectedDate)
        let center = await resolveDefaultCenter()
        await MainActor.run {
            // Keep current focus while user is interacting with a selected pin.
            if selectedPinId == nil {
                region = MKCoordinateRegion(
                    center: center,
                    span: defaultMapSpan
                )
            }
        }

        let dayBookings = bookingStore.bookings.filter {
            Calendar.current.isDate($0.date, inSameDayAs: targetDate)
        }

        let allProjects = (projectStore.projects + projectStore.smallWorks)
            .filter(\.isLive)

        var builtPins: [SiteMapPin] = []
        for project in allProjects {
            guard let coordinate = await GeocodingCacheService.shared.coordinate(for: project.siteAddress) else { continue }
            let siteBookings = dayBookings.filter { $0.projectId == project.id }
            let operativeCount = Set(siteBookings.map(\.operativeId)).count
            let rows = siteBookings
                .sorted { $0.timeSlot.displayName < $1.timeSlot.displayName }
                .compactMap { booking -> String? in
                    guard let operative = operativeStore.operatives.first(where: { $0.id == booking.operativeId }) else { return nil }
                    return "\(booking.timeSlot.displayName) - \(operative.name)"
                }
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

    private func pinKind(for project: Project) -> SitePinKind {
        switch project.jobType {
        case .smallWorks:
            return .smallWorks
        case .maintenance:
            return .maintenance
        default:
            return .project
        }
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
            .map { "\($0.id)|\($0.coordinate.latitude)|\($0.coordinate.longitude)|\($0.pinKind.displayName)" }
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
