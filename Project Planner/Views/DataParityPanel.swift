//
//  DataParityPanel.swift
//  Project Planner
//
//  RULEBOOK 1.38.0 §27 "Data check" — the admin panel. Owner change 11 Nov: nothing about the data check is shown in
//  the launch build. The panel renders only when `dataCheckPanelVisible({ viewerIsAdmin, dataCheckPanelEnabled })`,
//  i.e. for an admin while `platformConfig/app.dataCheckPanel` is on (`dataCheckPanelEnabled`; missing = off); otherwise
//  it is an empty view. The text is `dataParitySummary` (organisation zone). The check itself always runs silently
//  (`DataParityMonitor`).
//

import SwiftUI

struct DataParityPanel: View {
    let viewerIsAdmin: Bool
    @ObservedObject private var monitor = DataParityMonitor.shared
    @State private var panelSwitchOn = SecuritySwitchContext.dataCheckPanel

    private var visible: Bool {
        CanonicalBusinessEngine.dataCheckPanelVisible(viewerIsAdmin: viewerIsAdmin, dataCheckPanelEnabled: panelSwitchOn)
    }

    var body: some View {
        Group {
            if visible {
                panel
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataCheckPanelSwitchDidChange)) { _ in
            panelSwitchOn = SecuritySwitchContext.dataCheckPanel
        }
    }

    private var summary: RulebookDataParitySummary {
        CanonicalBusinessEngine.dataParitySummary(
            entry: monitor.latestEntry,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier
        )
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Data check", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(monitor.isRunning ? "Checking…" : "Check now") {
                    Task { await monitor.run(trigger: "manual") }
                }
                .font(.footnote.weight(.semibold))
                .disabled(monitor.isRunning)
                .accessibilityIdentifier("dataCheck.checkNow")
            }
            Text(summary.title)
                .font(.footnote)
                .foregroundStyle(summary.tone == "warning" ? Color.red : Color.primary)
            ForEach(summary.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("manageUsers.dataCheck")
    }
}
