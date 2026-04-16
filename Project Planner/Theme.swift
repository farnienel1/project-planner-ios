//
//  Theme.swift
//  Project Planner
//
//  Created by Assistant on 03/10/2025.
//

import SwiftUI

// MARK: - Color Theme
extension Color {
    struct theme {
        // Get primary color from a specific color scheme
        static func primary(for colorScheme: AppColorScheme) -> Color {
            return colorScheme.color
        }
        
        // Default primary (blue) for backward compatibility
        static let primary = Color(red: 0.051, green: 0.404, blue: 0.929) // #0d67ed
        
        static let primaryLight = Color(red: 0.075, green: 0.612, blue: 0.996) // #139cfe
        static let secondary = Color.green
        static let background = Color(.systemBackground)
        static let surface = Color(.secondarySystemBackground)
        static let text = Color.primary
        static let textSecondary = Color.secondary
        static let error = Color.red
        static let success = Color.green
        static let warning = Color.orange
    }
}

// MARK: - Color Scheme Environment Key
struct ColorSchemeKey: EnvironmentKey {
    static let defaultValue: AppColorScheme = .blue
}

extension EnvironmentValues {
    var appColorScheme: AppColorScheme {
        get { self[ColorSchemeKey.self] }
        set { self[ColorSchemeKey.self] = newValue }
    }
}

// MARK: - View Extension for Color Scheme
extension View {
    func appColorScheme(_ scheme: AppColorScheme) -> some View {
        environment(\.appColorScheme, scheme)
    }
}

// MARK: - Helper for getting primary color
extension Color {
    static func primaryColor(for scheme: AppColorScheme) -> Color {
        return Color.theme.primary(for: scheme)
    }
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .background(Color.theme.primary)
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(Color.theme.primary)
            .padding()
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.theme.primary, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .background(Color.theme.error)
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SuccessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .background(Color.theme.success)
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Card Style
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.theme.surface)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

// MARK: - Input Field Style
struct InputFieldStyle: ViewModifier {
    var isError: Bool = false
    
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.theme.surface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isError ? Color.theme.error : Color.gray.opacity(0.3), lineWidth: 1)
            )
    }
}

extension View {
    func inputFieldStyle(isError: Bool = false) -> some View {
        modifier(InputFieldStyle(isError: isError))
    }
}

