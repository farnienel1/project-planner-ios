//
//  DataParityPanel.swift
//  Project Planner
//
//  RULEBOOK 1.38.0 §27 "Data check" — the admin panel, under Settings → Data health (web: the Data health page).
//  Owner change 11 Nov: nothing about the data check is shown in the launch build. Settings shows the Data health row
//  only when `dataCheckPanelVisible({ viewerIsAdmin, dataCheckPanelEnabled })` is true, i.e. for an admin while
//  `platformConfig/app.dataCheckPanel` is on (`dataCheckPanelEnabled`; missing = off); otherwise there is no row, no
//  panel and no gap. The switch is read through `DataParityMonitor.panelSwitchOn`, which follows the switch, an
//  organisation switch and return to the foreground. The text is `dataParitySummary` (organisation zone). The check
//  itself always runs silently (`DataParityMonitor`).
//

import SwiftUI

/// Settings → Data health (admins, only while the panel switch is on).
struct DataHealthView: View {
    let viewerIsAdmin: Bool

    var body: some View {
        ScrollView {
            DataParityPanel(viewerIsAdmin: viewerIsAdmin)
                .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Data health")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DataParityPanel: View {
    let viewerIsAdmin: Bool
    @ObservedObject private var monitor = DataParityMonitor.shared

    var body: some View {
        if monitor.panelVisible(viewerIsAdmin: viewerIsAdmin) {
            panel
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
        .accessibilityIdentifier("dataHealth.dataCheck")
    }
}
