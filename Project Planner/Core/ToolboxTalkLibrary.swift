//
//  ToolboxTalkLibrary.swift
//  Project Planner
//
//  Built-in TBT catalogue. Never depends on a Mac Downloads path — that is what
//  made TestFlight/simulator titles collapse to "TBT" when a local .md parse
//  succeeded with the wrong headings and then got saved into Firestore.
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
    }

    static func bundledTalks(now: Date = Date()) -> [HSToolboxTalk] {
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

        let general = [
            "Working at Height", "Manual Handling", "PPE Selection and Use", "Slips Trips and Falls",
            "Fire Prevention and Emergency Routes", "Housekeeping and Waste Segregation",
            "Working Around Mobile Plant", "Noise and Vibration Awareness",
            "Site Induction and Welfare Rules", "Accident and Near-Miss Reporting"
        ]
        let electrical = [
            "Safe Isolation Procedure", "Temporary Electrical Installations", "Cable Management and Trip Prevention",
            "Testing and Verification Records", "Live Services Avoidance", "Portable Appliance Safety",
            "RCD and Circuit Protection", "Lockout Tagout for Electrical Works"
        ]
        let groundworks = [
            "Excavations and Services Avoidance", "Trench Support and Edge Protection",
            "Ground Stability and Weather Risk", "Plant Banksman Controls",
            "Manual Handling in Groundworks", "Confined Spaces Entry Control",
            "Buried Services Permit to Dig", "Backfilling and Compaction Safety"
        ]
        let joinery = [
            "Wood Dust and Extraction", "Bench and Portable Saw Safety", "Hand Tool Maintenance",
            "Ladder and Podium Use for Joiners", "Adhesives and Solvent Ventilation",
            "Fire Door Installation Controls", "Manual Handling of Sheet Materials", "Workshop Housekeeping Standards"
        ]
        let mechanical = [
            "Hot Works Permit Controls", "Lifting and Rigging Awareness", "Ductwork Installation Safety",
            "Pressurised Systems Isolation", "Plant Room Access Controls",
            "Working at Height for Mechanical Install", "Hand Arm Vibration in Mechanical Works",
            "Temporary Supports and Bracing"
        ]
        let plumbing = [
            "Gas Safe Working and Purging", "Legionella and Water Hygiene", "Pressure Testing Water Systems",
            "Soldering and Fire Watch", "Working in Service Voids", "Asbestos Awareness for Plumbing Works",
            "Safe Use of Pipe Press Tools", "Draining Down and Refill Controls"
        ]
        let scaffolding = [
            "Scaffold Handover and Tagging", "Working on Incomplete Scaffolds", "Loading Bays and Edge Protection",
            "Ladder Access and Hatch Discipline", "Alterations Without Authorisation"
        ]
        let brick = [
            "Trestles and Hop-Up Safety", "Mortar Mix and Silica Dust", "Manual Handling of Packs",
            "Edge Protection on Lifts", "Hot Weather and Cold Weather Working"
        ]
        let drylining = [
            "Board Handling and Cuts", "MEWP Use for Partitions", "Dust Extraction on Sanding",
            "Service Coordination in Walls", "Fire-Rated Partition Continuity"
        ]
        let painting = [
            "Solvent Ventilation and PPE", "Working from Podiums", "Spray Equipment Controls",
            "Lead Paint Awareness", "Waste and Rags Fire Risk"
        ]
        let roofing = [
            "Roof Edge Protection", "Fragile Roof Awareness", "Weather and Wind Controls",
            "Hot Works on Roofs", "Material Hoisting and Storage"
        ]
        let demolition = [
            "Soft Strip Sequencing", "Services Isolation Before Strip", "Dust and Noise Controls",
            "Temporary Support of Structure", "Waste Segregation and Needles"
        ]
        let steel = [
            "Bar Cutting and Bending Safety", "Manual Handling of Bundles", "Tying and Trip Hazards",
            "Working Around Crane Lifts", "PPE for Steel Fixing"
        ]
        let plant = [
            "Plant and Pedestrian Segregation", "Daily Plant Checks", "Banksman Signals",
            "Exclusion Zones", "Refuelling Controls"
        ]

        func numbered(_ prefix: String, _ titles: [String], trade: String?) -> [HSToolboxTalk] {
            titles.enumerated().map { make(id: String(format: "\(prefix)-%03d", $0.offset + 1), title: $0.element, trade: trade) }
        }

        return numbered("TBT-GEN", general, trade: nil)
            + numbered("TBT-ELE", electrical, trade: "Electrical")
            + numbered("TBT-GRD", groundworks, trade: "Groundworks")
            + numbered("TBT-JOI", joinery, trade: "Joinery")
            + numbered("TBT-MEC", mechanical, trade: "Mechanical / HVAC")
            + numbered("TBT-PLG", plumbing, trade: "Plumbing & Gas")
            + numbered("TBT-SCA", scaffolding, trade: "Scaffolding")
            + numbered("TBT-BRK", brick, trade: "Brick & Block")
            + numbered("TBT-DRY", drylining, trade: "Drylining")
            + numbered("TBT-PNT", painting, trade: "Painting")
            + numbered("TBT-ROO", roofing, trade: "Roofing")
            + numbered("TBT-DEM", demolition, trade: "Demolition")
            + numbered("TBT-STL", steel, trade: "Steel Fixing")
            + numbered("TBT-PLA", plant, trade: "Plant")
    }

    /// Overlay the real library onto stored talks so a bad Firestore seed cannot
    /// keep showing "TBT" as every heading. Uploaded/custom talks are kept.
    static func merge(stored: [HSToolboxTalk], platform: [HSToolboxTalk]) -> [HSToolboxTalk] {
        let bundled = bundledTalks()
        var byId: [String: HSToolboxTalk] = [:]
        for talk in bundled { byId[talk.id] = talk }
        for talk in platform where !isPlaceholderTitle(talk.title) {
            byId[talk.id] = talk
        }

        var merged: [HSToolboxTalk] = []
        var seen = Set<String>()
        for talk in stored {
            if seen.contains(talk.id) { continue }
            seen.insert(talk.id)
            if talk.source == .uploaded {
                var uploaded = talk
                if isPlaceholderTitle(uploaded.title) {
                    uploaded.title = talk.fileURL?.isEmpty == false ? "Uploaded toolbox talk" : "Custom toolbox talk"
                }
                merged.append(uploaded)
                continue
            }
            if let catalog = byId[talk.id] {
                var repaired = talk
                if isPlaceholderTitle(talk.title) {
                    repaired.title = catalog.title
                }
                if talk.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    repaired.purpose = catalog.purpose
                }
                if talk.keyPoints.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    repaired.keyPoints = catalog.keyPoints
                }
                if talk.trades.isEmpty && !catalog.trades.isEmpty {
                    repaired.trades = catalog.trades
                    repaired.isGeneral = catalog.isGeneral
                    repaired.category = catalog.category
                }
                merged.append(repaired)
                byId.removeValue(forKey: talk.id)
            } else if isPlaceholderTitle(talk.title) {
                continue
            } else {
                merged.append(talk)
            }
        }
        for leftover in byId.values.sorted(by: { $0.id < $1.id }) {
            if !seen.contains(leftover.id) {
                merged.append(leftover)
            }
        }
        return merged
    }

    static func resolvedTitle(talkId: String, storedTalks: [HSToolboxTalk]) -> String {
        if let talk = storedTalks.first(where: { $0.id == talkId }), !isPlaceholderTitle(talk.title) {
            return talk.title
        }
        if let bundled = bundledTalks().first(where: { $0.id == talkId }) {
            return bundled.title
        }
        return "Toolbox talk"
    }
}
