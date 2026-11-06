//
//  PPAddUserComponents.swift
//  Project Planner — Add New User UI upgrade (UI ONLY)
//
//  Tokens and building blocks for the 4-step Add New User flow (docs/design/add-user-ui/add-user-ui-spec.md §2–§3).
//  Reuses the Home and booking look (PPColor / PPFamily / PPBookingColor). Labels, containers and styles only:
//  no actions of their own, no data, no calculations, no navigation. Every value shown is passed in.
//

import SwiftUI

// MARK: - Tokens

/// Spec §2 tokens that the booking upgrade did not already add. Dark mode comes from dynamic colours.
enum PPAddUserColor {
    /// Header secondary text and inactive step labels (`headerMuted`).
    static let headerMuted = Color(ppHex: 0x93A1BC)
    /// Selected card border and radio, switches on (`selected`).
    static let selected = Color.ppDynamic(light: 0x2F6FE0, dark: 0x5A8BFF)
    /// Completed step bars (`stepDone`).
    static let stepDone = Color(ppHex: 0x3B7BF0)
    /// Locked-on permission badge and "Can access" chips (`included`).
    static let includedInk = Color.ppDynamic(light: 0x0B6B47, dark: 0x5FD8B4)
    static let includedBackground = Color.ppDynamic(light: 0xEAF7F1, dark: 0x123A2C)
    /// Validation callout (`error`).
    static let errorInk = Color.ppDynamic(light: 0x9F1C22, dark: 0xFFB4B7)
    static let errorBackground = Color.ppDynamic(light: 0xFDECEC, dark: 0x3A1517)
    static let errorBorder = Color.ppDynamic(light: 0xF4B4B7, dark: 0x7A2A2E)
    static let errorIcon = Color(ppHex: 0xE5484D)
    /// Blue info box.
    static let infoBackground = Color.ppDynamic(light: 0xEEF4FF, dark: 0x16284A)
    /// Inputs and pickers inside a card (`field`).
    static let field = Color.ppDynamic(light: 0xF6F8FC, dark: 0x1C1C1E)
}

// MARK: - Sheet container

extension View {
    /// The light sheet under the navy header: page background with a 28pt top radius (`sheetBg`).
    func ppAddUserSheet() -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: PPMetrics.contentCornerRadius,
            topTrailingRadius: PPMetrics.contentCornerRadius,
            style: .continuous
        )
        // Content is clipped to the rounded top; the fill runs on under the home indicator.
        return self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
            .background(shape.fill(PPColor.page).ignoresSafeArea(edges: .bottom))
    }

    /// A grouped card (`card`, radius 18). `isError` turns the border red (spec §4, the line manager card).
    func ppFormCard(isError: Bool = false, padding: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card, in: shape)
            .overlay(
                shape.strokeBorder(
                    isError ? PPAddUserColor.errorBorder : PPBookingColor.cardBorder,
                    lineWidth: isError ? 1.5 : 0.5
                )
            )
    }

    /// An input or picker tile inside a card (`field`, radius 12).
    func ppFormField(minHeight: CGFloat = 44) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(PPAddUserColor.field, in: shape)
            .overlay(shape.strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5))
    }
}

// MARK: - Section label and field label

/// Small uppercase label over a grouped card ("EMPLOYMENT", "MODULES").
struct PPFormSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Label above a value inside a grouped card.
struct PPFormFieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Info box and error callout

/// Blue info box with an info glyph. Text is passed in unchanged.
struct PPInfoBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPAddUserColor.infoBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Red validation callout with a filled warning triangle (`error`). Shows a message it is given; decides nothing.
struct PPErrorCallout: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PPAddUserColor.errorIcon)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(PPAddUserColor.errorInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPAddUserColor.errorBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PPAddUserColor.errorBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live user card (header, display only)

/// The header's live user card: avatar, name, a subtitle and chips. Every value is passed in; nothing is written.
struct PPUserPreviewCard: View {
    let name: String
    let subtitle: String?
    /// nil shows the empty "person" avatar.
    let initials: String?
    let family: PPFamily
    var chips: [String] = []

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let initials, !initials.isEmpty {
                PPInitialsAvatar(initials: initials, family: family, size: 44)
            } else {
                Image(systemName: "person")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(PPColor.onNavyStroke, lineWidth: 1))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(PPAddUserColor.headerMuted)
                        .lineLimit(2)
                }
                if !chips.isEmpty {
                    PPChipRow {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                            PPChip(text: chip, tone: .onNavy)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toggle row (module rows, "Included" locked state)

/// One permission row: icon tile, name with an expand chevron, and a switch. A row locked ON shows a green
/// "Included" badge instead of the switch; a row locked OFF keeps a disabled switch. The switch writes only the
/// binding it is given.
struct PPToggleRow: View {
    let title: String
    let description: String
    let symbol: String
    @Binding var isOn: Bool
    var isLocked: Bool = false

    @State private var expanded = false

    private var showsIncluded: Bool { isLocked && isOn }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Blue when on or locked on, grey when off (spec §4).
            PPIconTile(symbol: symbol, family: isOn ? .plan : .system, size: 30)
                .opacity(isOn ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 5) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isLocked && !isOn ? Color.secondary : Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("permissionToggle.chevronDown")
                .accessibilityHint(expanded ? "Hides the description" : "Shows the description")
                .buttonStyle(.plain)
                if expanded {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsIncluded {
                Label("Included", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPAddUserColor.includedInk)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(PPAddUserColor.includedBackground, in: Capsule())
                    .accessibilityLabel("\(title), included, locked")
                    .accessibilityIdentifier("permissionToggle.included")
            } else {
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .accessibilityIdentifier("permissionToggle.toggle")
                    .tint(PPAddUserColor.selected)
                    .disabled(isLocked)
                    .opacity(isLocked ? 0.6 : 1)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    /// Display-only glyph for a permission field (`PERMISSION_TOGGLE_CATALOGUE` field names).
    static func symbol(for field: String) -> String {
        switch field {
        case "adminAccess": return "shield.fill"
        case "projects": return "folder.fill"
        case "smallWorks": return "hammer.fill"
        case "weeklyReports": return "doc.text.fill"
        case "dailyOverview": return "calendar"
        case "subContractors": return "person.2.fill"
        case "annualLeaveSelfBook": return "sun.max.fill"
        case "timesheetSelfSign": return "signature"
        case "operatives": return "person.3.fill"
        case "qualifications": return "rosette"
        case "wholesalersOrderHistory": return "shippingbox.fill"
        case "materials": return "cube.box.fill"
        case "siteAudit": return "checklist"
        default: return "square.grid.2x2.fill"
        }
    }
}

// MARK: - Wizard bottom bar (Back + Next / Create User)

/// White bar with Back (secondary) and the primary button. When the primary is disabled it reads `disabledTitle` in
/// readable grey (spec §3). Both buttons run exactly the actions they are given.
struct PPWizardBottomBar<Top: View>: View {
    let backEnabled: Bool
    let backAction: () -> Void
    let primaryTitle: String
    var primarySymbol: String? = nil
    var primarySymbolLeading: Bool = false
    let primaryEnabled: Bool
    let disabledTitle: String
    var isBusy: Bool = false
    let primaryAction: () -> Void
    let top: Top

    init(
        backEnabled: Bool,
        backAction: @escaping () -> Void,
        primaryTitle: String,
        primarySymbol: String? = nil,
        primarySymbolLeading: Bool = false,
        primaryEnabled: Bool,
        disabledTitle: String,
        isBusy: Bool = false,
        primaryAction: @escaping () -> Void,
        @ViewBuilder top: () -> Top
    ) {
        self.backEnabled = backEnabled
        self.backAction = backAction
        self.primaryTitle = primaryTitle
        self.primarySymbol = primarySymbol
        self.primarySymbolLeading = primarySymbolLeading
        self.primaryEnabled = primaryEnabled
        self.disabledTitle = disabledTitle
        self.isBusy = isBusy
        self.primaryAction = primaryAction
        self.top = top()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        VStack(spacing: 10) {
            top
            HStack(spacing: 10) {
                Button(action: backAction) {
                    Text("Back")
                        .font(.headline)
                        .foregroundStyle(backEnabled ? Color.primary : Color.secondary)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                        .background(PPColor.well, in: shape)
                        .contentShape(shape)
                }
                .accessibilityIdentifier("addUser.back")
                .buttonStyle(PPPressableButtonStyle())
                .disabled(!backEnabled)

                Button(action: primaryAction) {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else if primaryEnabled, primarySymbolLeading, let primarySymbol {
                            Image(systemName: primarySymbol).font(.subheadline.weight(.bold))
                        }
                        Text(primaryEnabled || isBusy ? primaryTitle : disabledTitle)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        if primaryEnabled, !isBusy, !primarySymbolLeading, let primarySymbol {
                            Image(systemName: primarySymbol).font(.subheadline.weight(.bold))
                        }
                    }
                    .font(primaryEnabled || isBusy ? Font.headline : Font.footnote.weight(.semibold))
                    .foregroundStyle(primaryEnabled || isBusy ? Color.white : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if primaryEnabled || isBusy {
                            shape.fill(PPBookingColor.primaryGradient)
                        } else {
                            shape.fill(PPColor.well)
                        }
                    }
                    .contentShape(shape)
                }
                .accessibilityIdentifier("addUser.creating")
                .buttonStyle(PPPressableButtonStyle())
                .disabled(!primaryEnabled)
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(PPColor.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Wrapping chips (Review)

/// Lays chips out left to right and wraps them onto new lines. Layout only.
struct PPWrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A "Can access" (green tick) or "Can't access" (grey with red cross) chip.
struct PPAccessChip: View {
    let title: String
    let allowed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: allowed ? "checkmark" : "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(allowed ? PPAddUserColor.includedInk : PPAddUserColor.errorIcon)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(allowed ? PPAddUserColor.includedInk : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(allowed ? PPAddUserColor.includedBackground : PPColor.well, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(allowed ? "Can access \(title)" : "Cannot access \(title)")
    }
}
