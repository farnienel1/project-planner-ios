//
//  MapPinPickerView.swift
//  Project Planner
//
//  Pan/zoom the map freely, tap anywhere to drop a pin, then confirm.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

struct MapPinPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let initialCoordinate: CLLocationCoordinate2D
    @Binding var selectedLatitude: Double?
    @Binding var selectedLongitude: Double?

    var onConfirm: (CLLocationCoordinate2D) -> Void

    @State private var pinCoordinate: CLLocationCoordinate2D

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
        _pinCoordinate = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            MapPinPickerMapView(
                pinCoordinate: $pinCoordinate,
                initialCoordinate: initialCoordinate
            )
            .ignoresSafeArea()
            .onChange(of: pinCoordinate.latitude) { _, newLat in
                selectedLatitude = newLat
                selectedLongitude = pinCoordinate.longitude
            }
            .onChange(of: pinCoordinate.longitude) { _, newLon in
                selectedLongitude = newLon
                selectedLatitude = pinCoordinate.latitude
            }
            .navigationTitle("Set pin on map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this pin") {
                        onConfirm(pinCoordinate)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct MapPinPickerMapView: UIViewRepresentable {
    @Binding var pinCoordinate: CLLocationCoordinate2D
    let initialCoordinate: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.isRotateEnabled = true
        mapView.showsScale = false
        mapView.pointOfInterestFilter = .excludingAll

        let center = initialCoordinate
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapView.setRegion(region, animated: false)

        let pin = MKPointAnnotation()
        pin.coordinate = pinCoordinate
        pin.title = "Site"
        mapView.addAnnotation(pin)
        context.coordinator.mapView = mapView
        context.coordinator.annotation = pin
        context.coordinator.parent = self

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTapMap(_:)))
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)

        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        guard let pin = context.coordinator.annotation else { return }
        if abs(pin.coordinate.latitude - pinCoordinate.latitude) > 0.000001 ||
            abs(pin.coordinate.longitude - pinCoordinate.longitude) > 0.000001 {
            pin.coordinate = pinCoordinate
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPinPickerMapView?
        weak var mapView: MKMapView?
        var annotation: MKPointAnnotation?

        @objc func didTapMap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = recognizer.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)

            annotation?.coordinate = coord
            parent?.pinCoordinate = coord
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let reuseId = "map-pin-picker"
            let view: MKMarkerAnnotationView
            if let dequeued = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView {
                view = dequeued
            } else {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
            }
            view.annotation = annotation
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "mappin.circle.fill")
            view.canShowCallout = false
            return view
        }
    }
}
