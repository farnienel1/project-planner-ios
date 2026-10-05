//
//  PPHomeComponents.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  Visual building blocks for the Home screen.
//  Every type here is either:
//    • a background / container, or
//    • a LABEL view to put inside an EXISTING Button / NavigationLink, or
//    • a ButtonStyle.
//  None of them own actions, state, data loading or navigation.
//

import SwiftUI

// MARK: - Navy backdrop (drawing-grid texture + soft glow)

struct PPBlueprintGrid: Shape {
    var spacing: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x: CGFloat = 0
        while x <= rect.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= rect.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }
        return path
    }
}

struct PPNavyBackdrop: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            PPColor.navy

            PPBlueprintGrid(spacing: 18)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
                .mask(
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            RadialGradient(colors: [PPColor.glow.opacity(0.55), .clear],
                           center: .center, startRadius: 0, endRadius: 150)
                .frame(width: 300, height: 300)
                .offset(x: 90, y: -60)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Puts the navy backdrop behind the Home header and extends it upward
/// behind the status bar and into the pull-to-refresh / bounce area.
struct PPNavyHeaderBackground: ViewModifier {
    var bleed: CGFloat = 900

    func body(content: Content) -> some View {
        content
            .background(alignment: .bottom) {
                PPNavyBackdrop()
                    .padding(.top, -bleed)
            }
            // Text inside the header uses .primary/.secondary → white on navy.
            .environment(\.colorScheme, .dark)
    }
}

/// The light content area that slides up over the navy (quick actions, up next).
struct PPContentSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PPColor.page,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: PPMetrics.contentCornerRadius,
                    topTrailingRadius: PPMetrics.contentCornerRadius,
                    style: .continuous
                )
            )
            .padding(.top, -PPMetrics.contentOverlap)
    }
}

extension View {
    func ppNavyHeader() -> some View { modifier(PPNavyHeaderBackground()) }
    func ppContentSheet() -> some View { modifier(PPContentSheet()) }
}

// MARK: - Header buttons on navy (Refresh, Notifications, Overview settings, Quick create sparkle)

struct PPOnNavyCircleButtonStyle: ButtonStyle {
    var size: CGFloat = PPMetrics.headerButton

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .ppPressEffect(configuration.isPressed)
    }
}

/// Small red dot for the existing unread-notification indicator (only if one already exists).
struct PPBellDot: View {
    var body: some View {
        Circle()
            .fill(Color(ppHex: 0xFF4D55))
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(PPColor.navy, lineWidth: 2))
            .offset(x: -2, y: 2)
            .accessibilityHidden(true)
    }
}

// MARK: - Greeting

struct PPGreetingLabel: View {
    let dateText: String       // e.g. "Monday 5 Oct"  (keep existing string/formatter)
    let greeting: String       // e.g. "Hi, Test"      (keep existing string)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(dateText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(PPColor.onNavySecondary)
            Text(greeting)
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Overview

struct PPOverviewTitle: View {
    let eyebrow: String        // "Today's overview"
    let count: String          // "8"
    let countLabel: String     // "active projects"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(PPColor.onNavySecondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(count).foregroundStyle(.white)
                Text(countLabel).foregroundStyle(Color.white.opacity(0.6))
            }
            .font(.system(.title3, design: .rounded))
            .fontWeight(.bold)
            .lineLimit(1)
        }
    }
}

/// Hi-vis "Heads up" pill. Apply to the EXISTING Heads up button.
struct PPHeadsUpButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(PPColor.hiVisInk).frame(width: 6, height: 6)
            configuration.label
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(PPColor.hiVisInk)
        .padding(.horizontal, 12)
        .frame(height: PPMetrics.smallHeaderButton)
        .background(PPColor.hiVis, in: Capsule())
        .ppPressEffect(configuration.isPressed)
    }
}

/// One stat column. Values/labels come from the existing view model unchanged.
struct PPStat: View {
    let value: String
    let label: String
    var highlight: Bool = false   // true for Warnings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(highlight ? PPColor.warningAmber : .white)
            Text(label)
                .font(.caption)
                .foregroundStyle(PPColor.onNavyCaption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PPStatDivider: View {
    var body: some View {
        Rectangle()
            .fill(PPColor.onNavyHairline)
            .frame(width: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Warnings / Tasks chips (inside the navy header)

/// Apply to the EXISTING Warnings and Tasks buttons.
struct PPOnNavyChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.09)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .ppPressEffect(configuration.isPressed)
    }
}

struct PPStatusChipLabel: View {
    let symbol: String
    let family: PPFamily
    let title: String     // "Warnings" / "Tasks"
    let value: String     // "9" / "0"
    let unit: String      // "active" / "pending"

    var body: some View {
        HStack(spacing: 10) {
            PPIconTile(symbol: symbol, family: family, size: PPMetrics.chipIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Section header ("Quick actions", "Up next")

struct PPSectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
            Spacer(minLength: 8)
            HStack(spacing: 14) { trailing }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}

extension PPSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// MARK: - Quick actions (springboard-style 4-column grid)

enum PPQuickActionGrid {
    static var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PPMetrics.quickActionColumnSpacing),
              count: PPMetrics.quickActionColumns)
    }
    static let rowSpacing = PPMetrics.quickActionRowSpacing
}

/// LABEL for each EXISTING quick-action Button / NavigationLink.
struct PPQuickActionLabel: View {
    let title: String
    let symbol: String
    let family: PPFamily

    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12.5

    var body: some View {
        VStack(spacing: 7) {
            PPIconTile(symbol: symbol, family: family,
                       size: PPMetrics.quickActionIcon, lifted: true)
            Text(title)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: 82)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Restyled remove badge for Customise / jiggle mode. Put inside the EXISTING remove button.
struct PPRemoveBadgeLabel: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(PPFamily.system.bottom, in: Circle())
            .overlay(Circle().strokeBorder(PPColor.page, lineWidth: 2))
    }
}

// MARK: - Up next

struct PPCalendarStub: View {
    let weekday: String   // "TUE"
    let day: String       // "6"

    var body: some View {
        VStack(spacing: 0) {
            Text(weekday.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(PPColor.danger)
            Text(day)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .monospacedDigit()
                .padding(.vertical, 5)
        }
        .frame(width: 46)
        .background(PPColor.well)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PPTagPill: View {
    let text: String     // "FULL DAY", "C984" — existing strings

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(PPColor.brand)
            .background(PPColor.brand.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// LABEL for each EXISTING Up next row button / link.
struct PPUpNextRowLabel: View {
    let weekday: String
    let day: String
    let title: String     // "71 Broadwick Street"
    let time: String      // "07:30"
    var tag: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            PPCalendarStub(weekday: weekday, day: day)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(time)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let tag { PPTagPill(text: tag) }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .background(PPColor.card,
                    in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
    }
}

/// Day heading above Up next rows, e.g. "Tuesday 6th October".
struct PPDayHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Maintenance — Soon — Coming in a future update" card.
struct PPComingSoonCard: View {
    let title: String
    let subtitle: String
    let badge: String
    var symbol: String = "wrench.adjustable.fill"
    var family: PPFamily = .trade

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous)
        HStack(spacing: 12) {
            PPIconTile(symbol: symbol, family: family, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(badge.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(PPFamily.trade.bottom)
                        .background(PPFamily.trade.bottom.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(PPColor.well, in: shape)
        .overlay(shape.strokeBorder(Color(.separator),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
