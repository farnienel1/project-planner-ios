//
//  MapPinPickerView.swift
//  Project Planner
//
//  Tap map to place a pin; returns WGS84 coordinates.
//

import SwiftUI
import MapKit

struct MapPinPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let initialCoordinate: CLLocationCoordinate2D
    @Binding var selectedLatitude: Double?
    @Binding var selectedLongitude: Double?

    var onConfirm: (CLLocationCoordinate2D) -> Void

    @State private var pin: CLLocationCoordinate2D
    @State private var position: MapCameraPosition

    init(
        initialCoordinate: CLLocationCoordinate2D,
        selectedLatitude: Binding<Double?>,
        selectedLongitude: Binding<Double?>,
        onConfirm: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        self.initialCoordinate = initialCoordinate
        _selectedLatitude = selectedLatitude
        _selectedLongitude = selectedLongitude
        self.onConfirm = onConfirm
        let start = CLLocationCoordinate2D(
            latitude: selectedLatitude.wrappedValue ?? initialCoordinate.latitude,
            longitude: selectedLongitude.wrappedValue ?? initialCoordinate.longitude
        )
        _pin = State(initialValue: start)
        _position = State(
            initialValue: .region(
                MKCoordinateRegion(center: start, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
            )
        )
    }

    var body: some View {
        NavigationStack {
            MapReader { reader in
                Map(position: $position) {
                    Annotation("Site", coordinate: pin) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.red)
                            .shadow(radius: 2)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            if let coord = reader.convert(value.location, from: .local) {
                                pin = coord
                            }
                        }
                )
            }
            .navigationTitle("Set pin on map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this pin") {
                        selectedLatitude = pin.latitude
                        selectedLongitude = pin.longitude
                        onConfirm(pin)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
