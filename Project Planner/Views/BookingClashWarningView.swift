//
//  BookingClashWarningView.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import SwiftUI

struct BookingClashWarningView: View {
    @Binding var clashes: [ScheduleOperativeView.BookingClash]
    @Binding var isPresented: Bool
    let onCancel: () -> Void
    let onContinue: () -> Void
    
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Warning Header
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)
                        
                        Text("Booking Clash Detected")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("The following bookings conflict with existing schedules:")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top)
                    
                    // Clash Details
                    VStack(spacing: 16) {
                        ForEach(clashes) { clash in
                            ClashDetailCard(clash: clash, isCancelled: clash.cancelled) { cancelled in
                                if let index = clashes.firstIndex(where: { $0.id == clash.id }) {
                                    clashes[index].cancelled = cancelled
                                }
                            }
                            .environmentObject(projectStore)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Action Buttons
                    VStack(spacing: 12) {
                        Button(action: onContinue) {
                            Text("Continue with Booking")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                        
                        Button(action: onCancel) {
                            Text("Cancel This Selection")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Warning")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ClashDetailCard: View {
    let clash: ScheduleOperativeView.BookingClash
    let isCancelled: Bool
    let onToggle: (Bool) -> Void
    
    @EnvironmentObject var projectStore: ProjectStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundColor(.orange)
                    .font(.title3)
                
                Text("Clash Detected")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isCancelled {
                    Text("CANCELLED")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red)
                        .cornerRadius(6)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                BookingDetailRow(title: "Operative", value: clash.operative.name)
                
                BookingDetailRow(title: "Date", value: clash.date, isDate: true)
                
                BookingDetailRow(title: "New Booking Time", value: clash.newTimeSlot.displayName)
                
                BookingDetailRow(title: "Existing Booking Time", value: clash.existingBooking.timeSlot.displayName)
                
                if let project = clash.existingProject {
                    BookingDetailRow(title: "Existing Project", value: "\(project.jobNumber) - \(project.siteName)")
                }
                
                BookingDetailRow(title: "Booked By", value: clash.existingBooking.bookedBy)
            }
            
            if !isCancelled {
                Button(action: {
                    onToggle(true)
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Cancel This Booking")
                    }
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
            } else {
                Button(action: {
                    onToggle(false)
                }) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Restore This Booking")
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isCancelled ? Color.red.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 2)
        )
    }
}

// MARK: - Booking Detail Row

private struct BookingDetailRow: View {
    let title: String
    let value: Any
    var isDate: Bool = false
    
    var body: some View {
        HStack {
            Text(title + ":")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            if isDate, let dateValue = value as? Date {
                Text(dateValue, style: .date)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            } else if let stringValue = value as? String {
                Text(stringValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
        }
    }
}

#Preview {
    BookingClashWarningView(
        clashes: .constant([]),
        isPresented: .constant(true),
        onCancel: {},
        onContinue: {}
    )
}



