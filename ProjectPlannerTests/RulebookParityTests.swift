import CryptoKit
import XCTest
@testable import Project_Planner

/// Proves the app runs the rulebook web published. `scripts/sync-rulebook-from-web.sh` mirrors the pack;
/// these fail when any mirrored file was edited by hand or copied without the others.
final class RulebookParityTests: XCTestCase {
    private struct Manifest: Decodable {
        let rulebookVersion: String
        let rulebookSha256: String
        let bundleSha256: String
        let exports: [String]
    }

    /// Repo root, from this file's path. The simulator can read the host checkout.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The file the app actually ships (app bundle), falling back to the checkout.
    private func bundledFile(_ name: String, _ ext: String) throws -> Data {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        return try Data(contentsOf: repoRoot.appendingPathComponent("Project Planner/Canonical/\(name).\(ext)"))
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: bundledFile("canonical-manifest", "json"))
    }

    private func rulebookMirror() throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("docs/RULEBOOK.md"))
    }

    func testPackedScriptMatchesTheManifestAndShaFile() throws {
        let script = try bundledFile("canonical-business", "js")
        let shaFile = try String(decoding: bundledFile("canonical-business.js", "sha256"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try manifest()
        XCTAssertEqual(sha256(script), manifest.bundleSha256, "canonical-business.js was not mirrored from web — run scripts/sync-rulebook-from-web.sh")
        XCTAssertEqual(shaFile, manifest.bundleSha256, "canonical-business.js.sha256 does not match the manifest")
    }

    func testScriptStampMatchesTheRulebookMirror() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp(), "rulebookStamp() missing — the packed script predates rulebook 1.0.0")
        let mirror = try rulebookMirror()
        let text = String(decoding: mirror, as: UTF8.self)
        let versionLine = text.split(separator: "\n").first { $0.hasPrefix("Version:") }
        let version = versionLine.map { $0.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(stamp.version, version, "docs/RULEBOOK.md Version: does not match the packed script")
        XCTAssertEqual(stamp.sha256, sha256(mirror), "docs/RULEBOOK.md is not byte-identical to the rulebook the script was built from")
        let manifest = try manifest()
        XCTAssertEqual(manifest.rulebookVersion, stamp.version)
        XCTAssertEqual(manifest.rulebookSha256, stamp.sha256)
    }

    func testEveryManifestExportIsInTheEvaluatedScript() throws {
        let exported = Set(CanonicalBusinessEngine.exportNames())
        XCTAssertFalse(exported.isEmpty, "the packed script did not evaluate")
        let missing = try manifest().exports.filter { !exported.contains($0) }
        XCTAssertEqual(missing, [], "exports named in canonical-manifest.json are missing from the script")
    }
}
