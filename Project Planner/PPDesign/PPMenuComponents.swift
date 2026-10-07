//
//  PPMenuComponents.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  Visual building blocks for the Main Menu sheet and the More sheet.
//  Labels, containers and ButtonStyles only — no actions, no navigation, no data.
//

import SwiftUI

// MARK: - Grouped card container (used when the menu is a custom VStack, not a List)

struct PPGroupedCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(PPColor.card,
                        in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }
}

/// Hairline between rows inside a PPGroupedCard, inset to line up with the row text.
struct PPRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, 14 + PPMetrics.menuIcon + 13)
            .accessibilityHidden(true)
    }
}

/// Section title above a group: "NAVIGATE", "TOOLS", "TEAM", "APP & ACCOUNT", "QUICK CREATE".
struct PPGroupLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Menu row

/// LABEL for every EXISTING menu row Button / NavigationLink.
///
/// • `detail` = the count text that used to sit under the title ("5 on file",
///   "1 in progress", "0 open", "5 team members", "3 active"). It now sits on
///   the right, like iOS Settings. Same string, new position.
/// • `subtitle` = only for "Edit main menu bar" (keeps its two-line description).
/// • `showsChevron` = true for Buttons in a custom VStack. Set false inside a
///   List with NavigationLink (the system already draws a chevron).
struct PPMenuRowLabel: View {
    let title: String
    let symbol: String
    let family: PPFamily
    var detail: String? = nil
    var subtitle: String? = nil
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 13) {
            PPIconTile(symbol: symbol, family: family, size: PPMetrics.menuIcon)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: subtitle == nil ? 54 : 64)
        .contentShape(Rectangle())
    }
}

/// Row highlight on press for custom (non-List) menus.
struct PPMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : Color.clear)
    }
}

// MARK: - Quick create

/// Main Menu: navy Quick create card. `accessory` = the EXISTING sparkle button.
/// `tiles` = the EXISTING Project / Small work / User / Task buttons.
struct PPQuickCreateCard<Accessory: View, Tiles: View>: View {
    let eyebrow: String     // "Quick create"
    let title: String       // "Start something new"
    let accessory: Accessory
    let tiles: Tiles

    init(eyebrow: String,
         title: String,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder tiles: () -> Tiles) {
        self.eyebrow = eyebrow
        self.title = title
        self.accessory = accessory()
        self.tiles = tiles()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(eyebrow)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PPColor.onNavySecondary)
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
                Spacer()
                accessory
            }
            HStack(spacing: 8) { tiles }
        }
        .padding(14)
        .background(
            PPNavyBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .environment(\.colorScheme, .dark)
    }
}

/// LABEL for each Quick create tile (Project, Small work, User, Task).
/// onNavy = true inside PPQuickCreateCard (Main Menu); false in the More sheet.
struct PPQuickCreateTileLabel: View {
    let title: String
    let symbol: String
    let family: PPFamily
    var onNavy: Bool = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                if onNavy {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: PPMetrics.quickCreateIcon, height: PPMetrics.quickCreateIcon)
                        .background(Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    PPIconTile(symbol: symbol, family: family, size: PPMetrics.quickCreateIcon)
                }
                PPPlusBadge()
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(onNavy ? Color.white : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(onNavy ? Color.white.opacity(0.09) : PPColor.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(onNavy ? Color.white.opacity(0.14) : Color.clear, lineWidth: 0.5)
        )
    }
}

// MARK: - Sheet headers

/// Main Menu: large title on the left. Put the EXISTING "Done" button in `trailing`
/// and call `.ppProminentCapsule()` on it.
struct PPLargeSheetHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)
            Spacer()
            trailing
        }
        .padding(.horizontal, 2)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

/// More: centred inline title. Put the EXISTING close button in `leading`
/// and call `.ppGlassCircle()` on it.
struct PPInlineSheetHeader<Leading: View>: View {
    let title: String
    let leading: Leading

    init(_ title: String, @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.leading = leading()
    }

    var body: some View {
        ZStack {
            Text(title).font(.headline)
            HStack { leading; Spacer() }
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

// MARK: - Sign out & footer

/// Apply to the EXISTING Sign out button. Label/action unchanged.
struct PPSignOutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(PPColor.danger)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous)
                    .fill(configuration.isPressed ? Color(.systemFill) : PPColor.card)
            )
            .padding(.top, 22)
    }
}

struct PPVersionFooter: View {
    let text: String     // "Project Planner · v1.0" — keep existing string
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }
}
