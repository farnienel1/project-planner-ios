import Foundation

/// The 272-row UK operative qualification library seeded into a new organisation.
/// The rows are the packed web library. Search and section chips stay in `CanonicalBusinessEngine`.
enum StarterQualificationLibrary {
    static let version = 1

    struct Row: Decodable, Equatable, Sendable {
        let code: String
        let section: String
        let subsection: String
        let name: String
        let awardingBody: String
        let level: Int?
        let renewYears: Double?
        let renewalType: String
        let status: String
        let notes: String
    }

    static func rows() -> [Row] {
        var seen = Set<String>()
        var bundles = Bundle.allBundles + Bundle.allFrameworks
        bundles.append(Bundle.main)
        bundles.append(Bundle(for: FirebaseBackend.self))
        for bundle in bundles {
            let path = bundle.bundleURL.path
            guard seen.insert(path).inserted else { continue }
            if let decoded = decode(in: bundle), !decoded.isEmpty { return decoded }
            // A hosted unit test loads from the .xctest inside the app's PlugIns folder.
            if path.hasSuffix(".xctest") {
                let appURL = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                if let app = Bundle(url: appURL), let decoded = decode(in: app), !decoded.isEmpty {
                    return decoded
                }
            }
        }
        return []
    }

    private static func decode(in bundle: Bundle) -> [Row]? {
        var urls: [URL] = []
        if let listed = bundle.url(forResource: "starter-qualification-library", withExtension: "json") {
            urls.append(listed)
        }
        urls.append(bundle.bundleURL.appendingPathComponent("starter-qualification-library.json"))
        if let resources = bundle.resourceURL {
            urls.append(resources.appendingPathComponent("starter-qualification-library.json"))
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([Row].self, from: data),
                  !decoded.isEmpty else { continue }
            return decoded
        }
        return nil
    }

    static func qualifications(createdAt: Date = Date()) -> [Qualification] {
        rows().map { row in
            Qualification(
                id: row.code,
                name: row.name,
                hasEndDate: false,
                createdAt: createdAt,
                updatedAt: createdAt,
                code: row.code,
                section: row.section,
                subsection: row.subsection,
                awardingBody: row.awardingBody,
                level: row.level,
                renewYears: row.renewYears,
                renewalType: row.renewalType,
                status: row.status,
                notes: row.notes
            )
        }
    }
}
