//
//  ToolboxTalkLibrary.swift
//  Project Planner
//
//  Built-in TBT catalogue parsed from the bundled TOOLBOX-TALK-LIBRARY.md.
//  Titles, purpose and key points come from that file so Firestore placeholders
//  ("TBT", "custom", "uploaded toolbox talk") cannot wipe the library.
//

import Foundation

enum ToolboxTalkLibrary {
    static func isPlaceholderTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        return lower == "tbt"
            || lower == "custom"
            || lower == "toolbox talk"
            || lower == "untitled talk"
            || lower == "untitled"
            || lower == "uploaded toolbox talk"
            || lower == "custom toolbox talk"
            || lower == "uploaded talk"
            || lower.hasPrefix("tbt-") && !lower.contains(" ")
    }

    static func bundledTalks(now: Date = Date()) -> [HSToolboxTalk] {
        if let parsed = parseBundledMarkdown(now: now), parsed.count >= 20 {
            return parsed
        }
        return fallbackTalks(now: now)
    }

    static func catalogById(now: Date = Date()) -> [String: HSToolboxTalk] {
        Dictionary(uniqueKeysWithValues: bundledTalks(now: now).map { ($0.id, $0) })
    }

    /// Overlay the real library onto stored talks. Library IDs always keep MD titles.
    /// Uploaded/custom talks with a non-library id keep their own title.
    static func merge(stored: [HSToolboxTalk], platform: [HSToolboxTalk]) -> [HSToolboxTalk] {
        let catalog = catalogById()
        var byId: [String: HSToolboxTalk] = catalog
        for talk in platform where !isPlaceholderTitle(talk.title) {
            if catalog[talk.id] == nil {
                byId[talk.id] = talk
            }
        }

        var merged: [HSToolboxTalk] = []
        var seen = Set<String>()
        for talk in stored {
            if seen.contains(talk.id) { continue }
            seen.insert(talk.id)
            if let catalogTalk = catalog[talk.id] {
                merged.append(repairedLibraryTalk(stored: talk, catalog: catalogTalk))
                byId.removeValue(forKey: talk.id)
                continue
            }
            if talk.source == .uploaded || talk.fileURL?.isEmpty == false {
                var uploaded = talk
                uploaded.source = .uploaded
                if isPlaceholderTitle(uploaded.title) {
                    if let fileName = uploaded.fileNameHint {
                        uploaded.title = fileName
                    }
                }
                merged.append(uploaded)
                continue
            }
            if isPlaceholderTitle(talk.title) {
                continue
            }
            merged.append(talk)
        }
        for leftover in byId.values.sorted(by: { $0.id < $1.id }) {
            if !seen.contains(leftover.id) {
                merged.append(leftover)
            }
        }
        return merged
    }

    static func resolvedTitle(talkId: String, storedTalks: [HSToolboxTalk]) -> String {
        if let catalog = catalogById()[talkId] {
            return catalog.title
        }
        if let talk = storedTalks.first(where: { $0.id == talkId }), !isPlaceholderTitle(talk.title) {
            return talk.title
        }
        return "Toolbox talk"
    }

    // MARK: - Repair

    private static func repairedLibraryTalk(stored: HSToolboxTalk, catalog: HSToolboxTalk) -> HSToolboxTalk {
        var repaired = stored
        repaired.source = .library
        repaired.status = stored.status == .draft ? .draft : .approved
        if isPlaceholderTitle(stored.title) {
            repaired.title = catalog.title
        }
        if stored.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isPlaceholderTitle(stored.purpose) {
            repaired.purpose = catalog.purpose
        }
        if stored.keyPoints.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            repaired.keyPoints = catalog.keyPoints
        }
        if stored.trades.isEmpty && !catalog.trades.isEmpty {
            repaired.trades = catalog.trades
            repaired.isGeneral = catalog.isGeneral
            repaired.category = catalog.category
        }
        if stored.category != catalog.category && isPlaceholderTitle(stored.title) {
            repaired.category = catalog.category
            repaired.isGeneral = catalog.isGeneral
        }
        return repaired
    }

    // MARK: - Markdown parse

    private static func parseBundledMarkdown(now: Date) -> [HSToolboxTalk]? {
        guard let url = Bundle.main.url(forResource: "TOOLBOX-TALK-LIBRARY", withExtension: "md")
                ?? Bundle.main.url(forResource: "TOOLBOX-TALK-LIBRARY", withExtension: "md", subdirectory: "Resources") else {
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseMarkdown(text, now: now)
    }

    static func parseMarkdown(_ text: String, now: Date = Date()) -> [HSToolboxTalk] {
        var talks: [HSToolboxTalk] = []
        var currentTrade: String? = nil
        var currentIsGeneral = true
        var currentId: String?
        var currentTitle: String?
        var currentPurpose = ""
        var currentPoints: [String] = []
        var inKeyPoints = false

        func flush() {
            guard let id = currentId, let title = currentTitle else { return }
            let isGeneral = currentIsGeneral || currentTrade == nil
            talks.append(
                HSToolboxTalk(
                    id: id,
                    title: title,
                    category: isGeneral ? .general : .trade,
                    isGeneral: isGeneral,
                    trades: isGeneral ? [] : [currentTrade ?? ""].filter { !$0.isEmpty },
                    purpose: currentPurpose.trimmingCharacters(in: .whitespacesAndNewlines),
                    keyPoints: currentPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                    source: .library,
                    ownerOrganizationId: nil,
                    status: .approved,
                    version: 1,
                    updatedAt: now,
                    fileURL: nil
                )
            )
            currentId = nil
            currentTitle = nil
            currentPurpose = ""
            currentPoints = []
            inKeyPoints = false
        }

        let heading = try? NSRegularExpression(pattern: #"^\*\*(TBT-[A-Z]+-\d+)\s*[·•\-–]\s*(.+?)\*\*\s*$"#)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                flush()
                let headingTrade = tradeFromSectionHeading(line)
                currentTrade = headingTrade.trade
                currentIsGeneral = headingTrade.isGeneral
                continue
            }
            if line.hasPrefix("## ") {
                flush()
                continue
            }
            if let heading,
               let match = heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let idRange = Range(match.range(at: 1), in: line),
               let titleRange = Range(match.range(at: 2), in: line) {
                flush()
                currentId = String(line[idRange])
                currentTitle = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard currentId != nil else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("purpose:") {
                currentPurpose = String(line.dropFirst("Purpose:".count)).trimmingCharacters(in: .whitespaces)
                inKeyPoints = false
                continue
            }
            if lower.hasPrefix("key points:") || lower == "key points" {
                inKeyPoints = true
                continue
            }
            if inKeyPoints {
                var point = line
                if point.hasPrefix("- ") || point.hasPrefix("– ") || point.hasPrefix("• ") {
                    point = String(point.dropFirst(2))
                }
                if !point.isEmpty {
                    currentPoints.append(point)
                }
            } else if currentPurpose.isEmpty == false, !line.isEmpty, !line.hasPrefix(">") {
                currentPurpose += " " + line
            }
        }
        flush()
        return talks
    }

    private static func tradeFromSectionHeading(_ line: String) -> (trade: String?, isGeneral: Bool) {
        let lower = line.lowercased()
        if lower.contains("isgeneral:true") || lower.contains("general h&s") {
            return (nil, true)
        }
        let mapping: [(needle: String, trade: String)] = [
            ("electrical", "Electrical"),
            ("mechanical", "Mechanical / HVAC"),
            ("plumbing", "Plumbing & Gas"),
            ("groundworks", "Groundworks"),
            ("scaffolding", "Scaffolding"),
            ("brick", "Brick & Block"),
            ("joinery", "Joinery"),
            ("carpentry", "Joinery"),
            ("drylining", "Drylining"),
            ("painting", "Painting"),
            ("roofing", "Roofing"),
            ("demolition", "Demolition"),
            ("steel", "Steel Fixing"),
            ("plant", "Plant"),
        ]
        for item in mapping where lower.contains(item.needle) {
            return (item.trade, false)
        }
        return (nil, true)
    }

    private static func fallbackTalks(now: Date) -> [HSToolboxTalk] {
        func make(id: String, title: String, trade: String?) -> HSToolboxTalk {
            let isGeneral = trade == nil
            return HSToolboxTalk(
                id: id,
                title: title,
                category: isGeneral ? .general : .trade,
                isGeneral: isGeneral,
                trades: trade.map { [$0] } ?? [],
                purpose: "Review controls and safe method of work for \(title.lowercased()) before starting the task.",
                keyPoints: [
                    "Brief the team on hazards and controls for this task.",
                    "Confirm competence, permits, and PPE requirements before work starts.",
                    "Stop work and escalate if site conditions change or controls fail."
                ],
                source: .library,
                ownerOrganizationId: nil,
                status: .approved,
                version: 1,
                updatedAt: now,
                fileURL: nil
            )
        }
        func numbered(_ prefix: String, _ titles: [String], trade: String?) -> [HSToolboxTalk] {
            titles.enumerated().map { make(id: String(format: "\(prefix)-%03d", $0.offset + 1), title: $0.element, trade: trade) }
        }
        return numbered("TBT-GEN", [
            "Working at Height", "Working Near Openings, Voids & Risers", "Manual Handling",
            "Slips, Trips & Falls on the Level", "Personal Protective Equipment (PPE)",
            "COSHH — Hazardous Substances", "Dust & Silica (RCS) Control", "Noise at Work",
            "Hand-Arm Vibration (HAVS)", "Fire Safety & Emergency Procedures"
        ], trade: nil)
            + numbered("TBT-ELE", ["Safe Isolation Procedure", "Working Near Live Services & Cable Strike"], trade: "Electrical")
            + numbered("TBT-MEC", ["Hot Works Permit Controls", "Lifting and Rigging Awareness"], trade: "Mechanical / HVAC")
            + numbered("TBT-PLG", ["Gas Safe Working and Purging", "Legionella and Water Hygiene"], trade: "Plumbing & Gas")
            + numbered("TBT-GRD", ["Excavations and Services Avoidance", "Trench Support and Edge Protection"], trade: "Groundworks")
            + numbered("TBT-SCA", ["Scaffold Handover and Tagging", "Working on Incomplete Scaffolds"], trade: "Scaffolding")
            + numbered("TBT-BRK", ["Trestles and Hop-Up Safety", "Mortar Mix and Silica Dust"], trade: "Brick & Block")
            + numbered("TBT-JOI", ["Wood Dust and Extraction", "Bench and Portable Saw Safety"], trade: "Joinery")
            + numbered("TBT-DRY", ["Board Handling and Cuts", "MEWP Use for Partitions"], trade: "Drylining")
            + numbered("TBT-PNT", ["Solvent Ventilation and PPE", "Working from Podiums"], trade: "Painting")
            + numbered("TBT-ROO", ["Roof Edge Protection", "Fragile Roof Awareness"], trade: "Roofing")
            + numbered("TBT-DEM", ["Soft Strip Sequencing", "Services Isolation Before Strip"], trade: "Demolition")
            + numbered("TBT-STL", ["Bar Cutting and Bending Safety", "Manual Handling of Bundles"], trade: "Steel Fixing")
            + numbered("TBT-PLA", ["Plant and Pedestrian Segregation", "Daily Plant Checks"], trade: "Plant")
    }
}

private extension HSToolboxTalk {
    var fileNameHint: String? {
        guard let raw = fileURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "%20", with: " ")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
