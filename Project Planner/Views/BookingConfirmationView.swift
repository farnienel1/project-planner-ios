//
//  BookingConfirmationView.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import SwiftUI

struct BookingConfirmationView: View {
    @Binding var isPresented: Bool
    @State private var animateTick = false
    
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 82))
                .foregroundColor(.green)
                .scaleEffect(animateTick ? 1.0 : 0.65)
                .opacity(animateTick ? 1.0 : 0.4)
                .animation(.spring(response: 0.35, dampingFraction: 0.72), value: animateTick)
            
            Text("Booking Confirmed")
                .font(.title3)
                .fontWeight(.bold)
            
            Text("Operatives have been successfully booked.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button("Done") { isPresented = false }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(12)
                .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .onAppear {
            animateTick = true
            // Auto-close and return user to the schedule page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                isPresented = false
            }
        }
    }
}




