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

    private var selectedPin: SiteMapPin? {
        pins.first(where: { $0.id == selectedPinId })
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                OSMMapView(region: $region, pins: pins, selectedPinId: $selectedPinId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let selectedPin {
                    schedulePanel(for: selectedPin)
                } else {
                    Text("Tap a pin to view site bookings")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .navigationTitle("Site Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
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

    private func schedulePanel(for pin: SiteMapPin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(pin.title)
                    .font(.headline)
                Spacer()
                Text(dayLabel(selectedDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
            region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
            )
        }

        let dayBookings = bookingStore.bookings.filter {
            Calendar.current.isDate($0.date, inSameDayAs: targetDate)
        }
        let bookedProjectIds = Set(dayBookings.map(\.projectId))

        let allProjects = (projectStore.projects + projectStore.smallWorks)
            .filter { bookedProjectIds.contains($0.id) && $0.isLive }

        var builtPins: [SiteMapPin] = []
        for project in allProjects {
            guard let coordinate = await GeocodingCacheService.shared.coordinate(for: project.siteAddress) else { continue }
            let siteBookings = dayBookings.filter { $0.projectId == project.id }
            let rows = siteBookings
                .sorted { $0.timeSlot.displayName < $1.timeSlot.displayName }
                .compactMap { booking -> String? in
                    guard let operative = operativeStore.operatives.first(where: { $0.id == booking.operativeId }) else { return nil }
                    return "\(booking.timeSlot.displayName) - \(operative.name)"
                }
            builtPins.append(
                SiteMapPin(
                    id: project.id.uuidString,
                    title: "\(project.jobNumber) \(project.siteName)",
                    subtitle: project.siteAddress,
                    coordinate: coordinate,
                    scheduleRows: rows
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
}

private struct SiteMapPin: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let scheduleRows: [String]
}

private struct OSMMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let pins: [SiteMapPin]
    @Binding var selectedPinId: String?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.setRegion(region, animated: false)
        map.showsCompass = true

        let overlay = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        overlay.canReplaceMapContent = true
        map.addOverlay(overlay, level: .aboveLabels)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.setRegion(region, animated: true)
        let existing = map.annotations.compactMap { $0 as? SitePinAnnotation }
        map.removeAnnotations(existing)

        let annotations = pins.map { pin in
            SitePinAnnotation(id: pin.id, coordinate: pin.coordinate, title: pin.title, subtitle: pin.subtitle)
        }
        map.addAnnotations(annotations)

        if let selectedPinId,
           let annotation = annotations.first(where: { $0.id == selectedPinId }) {
            map.selectAnnotation(annotation, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedPinId: $selectedPinId)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        @Binding var selectedPinId: String?

        init(selectedPinId: Binding<String?>) {
            self._selectedPinId = selectedPinId
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            selectedPinId = (view.annotation as? SitePinAnnotation)?.id
        }
    }
}

private final class SitePinAnnotation: NSObject, MKAnnotation {
    let id: String
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(id: String, coordinate: CLLocationCoordinate2D, title: String, subtitle: String) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}
