//
//  ManageUserProfileChrome.swift
//  Project Planner
//
//  Shared visual language for Manage Users / Edit User (operative-first).
//

import SwiftUI
import UIKit

enum ManageUserProfilePalette {
    static let primaryBlue = Color(red: 0x18 / 255, green: 0x5F / 255, blue: 0xA5 / 255)
    static let pageBackground = Color(red: 0xF7 / 255, green: 0xF8 / 255, blue: 0xFA / 255)
    static let cardBackground = Color.white
    static let cardBorder = Color(red: 0xEE / 255, green: 0xF0 / 255, blue: 0xF3 / 255)
    static let textPrimary = Color(red: 0x0B / 255, green: 0x10 / 255, blue: 0x20 / 255)
    static let textSecondary = Color(red: 0x6B / 255, green: 0x72 / 255, blue: 0x80 / 255)

    static let avatarGradientTop = Color(red: 0x7F / 255, green: 0x77 / 255, blue: 0xDD / 255)
    static let avatarGradientBottom = Color(red: 0x53 / 255, green: 0x4A / 255, blue: 0xB7 / 255)

    static let chipBlueBg = Color(red: 0xE6 / 255, green: 0xF1 / 255, blue: 0xFB / 255)
    static let chipTealBg = Color(red: 0xE1 / 255, green: 0xF5 / 255, blue: 0xEE / 255)
    static let chipAmberBg = Color(red: 0xFA / 255, green: 0xEE / 255, blue: 0xDA / 255)
    static let chipPurpleBg = Color(red: 0xEE / 255, green: 0xED / 255, blue: 0xFE / 255)
    static let chipCoralBg = Color(red: 0xFA / 255, green: 0xEC / 255, blue: 0xE7 / 255)
    static let chipPinkBg = Color(red: 0xFB / 255, green: 0xEA / 255, blue: 0xF0 / 255)
    static let chipRedBg = Color(red: 0xFC / 255, green: 0xEB / 255, blue: 0xEB / 255)

    static let chipBlueFg = primaryBlue
    static let chipTealFg = Color(red: 0x0F / 255, green: 0x6E / 255, blue: 0x56 / 255)
    static let chipAmberFg = Color(red: 0x85 / 255, green: 0x4F / 255, blue: 0x0B / 255)
    static let chipPurpleFg = Color(red: 0x53 / 255, green: 0x4A / 255, blue: 0xB7 / 255)
    static let chipCoralFg = Color(red: 0x99 / 255, green: 0x3C / 255, blue: 0x1D / 255)
    static let chipPinkFg = Color(red: 0x99 / 255, green: 0x35 / 255, blue: 0x56 / 255)
    static let chipRedFg = Color(red: 0xA3 / 255, green: 0x2D / 255, blue: 0x2D / 255)

    static let operativeChipLabel = Color(red: 0x3C / 255, green: 0x34 / 255, blue: 0x89 / 255)

    static let cardCornerRadius: CGFloat = 18
    static let iconChipSize: CGFloat = 34
    static let iconChipCornerRadius: CGFloat = 9
}

// MARK: - Section & card

struct ManageUserSectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ManageUserProfilePalette.textSecondary)
            .tracking(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}

struct ManageUserCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(ManageUserProfilePalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: ManageUserProfilePalette.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ManageUserProfilePalette.cardCornerRadius, style: .continuous)
                    .stroke(ManageUserProfilePalette.cardBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - Icon chip & rows

struct ManageUserIconChip: View {
    let systemName: String
    let background: Color
    let foreground: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: ManageUserProfilePalette.iconChipSize, height: ManageUserProfilePalette.iconChipSize)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: ManageUserProfilePalette.iconChipCornerRadius, style: .continuous))
    }
}

struct ManageUserCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(ManageUserProfilePalette.cardBorder)
            .frame(height: 0.5)
            .padding(.leading, ManageUserProfilePalette.iconChipSize + 24)
    }
}

struct ManageUserDetailStaticRow: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let label: String
    let value: String
    var showsTrailingPencil: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsTrailingPencil {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }
}

/// Editable single-line field matching Manage User detail styling.
struct ManageUserDetailTextFieldRow: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var autocapitalization: TextInputAutocapitalization = .never
    var disableAutocorrection: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                TextField(placeholder, text: $text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(disableAutocorrection)
                    .textContentType(contentType)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }
}

/// First + last name on one row (same card style as other user details).
struct ManageUserNameEditRow: View {
    @Binding var firstName: String
    @Binding var surname: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(
                systemName: "person.fill",
                background: ManageUserProfilePalette.chipPurpleBg,
                foreground: ManageUserProfilePalette.chipPurpleFg
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                HStack(spacing: 10) {
                    TextField("First name", text: $firstName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                        .textInputAutocapitalization(.words)
                        .textContentType(.givenName)
                    TextField("Last name", text: $surname)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                        .textInputAutocapitalization(.words)
                        .textContentType(.familyName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }
}

/// Row that opens a menu / navigation target (chevron).
struct ManageUserChevronRow: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}

struct ManageUserDayRateEditRow: View {
    @Binding var dayRateText: String
    let currencySymbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(
                systemName: "sterlingsign",
                background: ManageUserProfilePalette.chipCoralBg,
                foreground: ManageUserProfilePalette.chipCoralFg
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Day rate")
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                HStack(spacing: 4) {
                    Text(currencySymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    TextField("Leave blank if not set", text: $dayRateText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }
}

/// Permissions-style row with subtitle + toggle (40×24 target via scale).
struct ManageUserPermissionToggleRow: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDisabled ? ManageUserProfilePalette.textSecondary : ManageUserProfilePalette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(ManageUserProfilePalette.primaryBlue)
                .disabled(isDisabled)
                .scaleEffect(0.86)
                .frame(width: 44, height: 28)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

/// Permission row: tap the title to expand the description; toggle stays independent.
struct ManageUserExpandablePermissionToggleRow: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let title: String
    var description: String?
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
                Group {
                    if let description, !description.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            HStack(alignment: .center, spacing: 6) {
                                Text(title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(isDisabled ? ManageUserProfilePalette.textSecondary : ManageUserProfilePalette.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                                    .rotationEffect(.degrees(expanded ? 0 : -90))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isDisabled ? ManageUserProfilePalette.textSecondary : ManageUserProfilePalette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(ManageUserProfilePalette.primaryBlue)
                    .disabled(isDisabled)
                    .scaleEffect(0.86)
                    .frame(width: 44, height: 28)
            }
            if expanded, let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, ManageUserProfilePalette.iconChipSize + 24)
                    .padding(.trailing, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

/// Tappable row with subtitle + trailing chevron (e.g. Skills & qualifications).
struct ManageUserNavigationSubtitleRow: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account action buttons (card style)

struct ManageUserAccountActionButton: View {
    let iconName: String
    let iconBackground: Color
    let iconForeground: Color
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = ManageUserProfilePalette.textPrimary
    var borderColor: Color = ManageUserProfilePalette.cardBorder
    var showsChevron: Bool = true
    let action: () -> Void
    var isBusy: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(titleColor)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView()
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                }
            }
            .padding(14)
            .background(ManageUserProfilePalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}
