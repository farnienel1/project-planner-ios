//
//  BookingConfirmationView.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import SwiftUI

struct BookingConfirmationView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                
                Text("Booking Successful")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Your booking has been confirmed.")
                    .font(.body)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    isPresented = false
                }) {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Success")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}




