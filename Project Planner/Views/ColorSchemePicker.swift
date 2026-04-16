//
//  ColorSchemePicker.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct ColorSchemePicker: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @State private var selectedScheme: AppColorScheme
    
    init() {
        // Initialize with a default value, will be updated from appSettings
        _selectedScheme = State(initialValue: .blue)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a color scheme for icons and accents throughout the app")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                    Button(action: {
                        selectedScheme = scheme
                        Task {
                            await appSettings.updateColorScheme(scheme)
                        }
                    }) {
                        VStack(spacing: 8) {
                            Circle()
                                .fill(scheme.color)
                                .frame(width: 60, height: 60)
                                .overlay(
                                    Circle()
                                        .stroke(selectedScheme == scheme ? Color.primary : Color.clear, lineWidth: 4)
                                )
                                .shadow(color: scheme.color.opacity(0.3), radius: 5, x: 0, y: 2)
                            
                            Text(scheme.displayName)
                                .font(.caption)
                                .fontWeight(selectedScheme == scheme ? .semibold : .regular)
                                .foregroundColor(.primary)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            selectedScheme = appSettings.settings.colorScheme
        }
        .onChange(of: appSettings.settings.colorScheme) { oldValue, newValue in
            selectedScheme = newValue
        }
    }
}

