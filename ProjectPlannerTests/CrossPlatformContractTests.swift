import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.11.0 cross-platform contract (v2): web `lib/canonical/cross-platform-contract.json`, mirrored here as
/// `CrossPlatformContract.json` by `scripts/sync-rulebook-from-web.sh` (sha256 in the manifest,
/// `RulebookParityTests`). Every sample — what web writes and what iOS writes — read through the packed script's
/// `readCrossPlatformSample` must equal `expected` (the check web's `crossPlatformContract.test.ts` runs), and where
/// iOS has its own model conversion the iOS-written sample must survive this app's reader and payload builder with
/// the same fields. A failure is either an iOS writer that drifted (fix it here) or a wrong sample (report it to web).
@MainActor
final class CrossPlatformContractTests: XCTestCase {
    private struct Contract {
        let timeZone: String
        let collections: [[String: Any]]
    }

    private func loadContract() throws -> Contract {
        let bundle = Bundle(for: CrossPlatformContractTests.self)
        let url = bundle.url(forResource: "CrossPlatformContract", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("CrossPlatformContract.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Contract(
            timeZone: root["timeZone"] as? String ?? "Europe/London",
            collections: try XCTUnwrap(root["collections"] as? [[String: Any]])
        )
    }

    /// JSON text with sorted keys, so equal values compare equal whatever the key order.
    private func canonicalJSON(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "<not JSON>"
    }

    private func samples(_ contract: Contract, collection id: String, platform: String) -> [[String: Any]] {
        let entry = contract.collections.first { $0["id"] as? String == id }
        return (entry?["samples"] as? [[String: Any]] ?? []).filter { $0["platform"] as? String == platform }
    }

    /// `{ seconds, nanoseconds }` in the contract is a Firestore Timestamp.
    private func firestoreData(_ value: Any) -> Any {
        if let map = value as? [String: Any] {
            if map.count == 2, let seconds = map["seconds"] as? NSNumber, let nanos = map["nanoseconds"] as? NSNumber {
                return Timestamp(seconds: seconds.int64Value, nanoseconds: nanos.int32Value)
            }
            return map.mapValues { firestoreData($0) }
        }
        if let list = value as? [Any] { return list.map { firestoreData($0) } }
        return value
    }

    /// The shape of a stored value: the kind of Firestore value it is.
    private func kind(_ value: Any) -> String {
        switch value {
        case is Timestamp: return "timestamp"
        case let map as [String: Any]:
            if map.count == 2, map["seconds"] != nil, map["nanoseconds"] != nil { return "timestamp" }
            return "map"
        case is [Any]: return "array"
        case is NSNull: return "null"
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        case is Bool: return "bool"
        default: return "other"
        }
    }

    // MARK: Readers

    func testEverySampleReadsAsExpected() throws {
        let contract = try loadContract()
        XCTAssertFalse(contract.collections.isEmpty)
        var checked = 0
        for entry in contract.collections {
            let id = entry["id"] as? String ?? "?"
            let reader = try XCTUnwrap(entry["reader"] as? String, id)
            var options: [String: Any] = ["timeZone": contract.timeZone]
            for (key, value) in entry["readerOptions"] as? [String: Any] ?? [:] { options[key] = value }
            for sample in entry["samples"] as? [[String: Any]] ?? [] {
                let platform = sample["platform"] as? String ?? "?"
                let got = CanonicalBusinessEngine.callJSON(
                    "readCrossPlatformSample",
                    arguments: [reader, sample["docId"] as? String ?? "", sample["data"] ?? [:], options]
                )
                let value = try XCTUnwrap(got, "\(id) \(platform): the packed script did not answer")
                XCTAssertEqual(canonicalJSON(value), canonicalJSON(sample["expected"] ?? NSNull()), "\(id) \(platform)")
                if let row = value as? [String: Any] {
                    XCTAssertNil(row["error"], "\(id) \(platform) is refused by its reader")
                    XCTAssertNotEqual(row["ok"] as? Bool, false, "\(id) \(platform) is refused by its reader")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testEveryContractReaderIsInThePackedScript() throws {
        let contract = try loadContract()
        let names = Set(CanonicalBusinessEngine.callJSON("crossPlatformContractReaderNames", arguments: []) as? [String] ?? [])
        for entry in contract.collections {
            let reader = entry["reader"] as? String ?? ""
            XCTAssertTrue(names.contains(reader), "\(reader) is not a packed contract reader")
        }
    }

    // MARK: iOS writers (keys and value kinds; the contract gives no builder inputs)

    /// `FirebaseBackend.jobDocumentPayload` (projects, small works): the iOS sample read by this app's job reader and
    /// written back by its payload builder has the same fields, each of the same kind, as the iOS sample.
    func testJobPayloadMatchesTheIOSSample() throws {
        let contract = try loadContract()
        for (collection, smallWorks) in [("projects", false), ("smallWorks", true)] {
            for sample in samples(contract, collection: collection, platform: "ios") {
                let docId = sample["docId"] as? String ?? ""
                let data = try XCTUnwrap(firestoreData(sample["data"] ?? [:]) as? [String: Any])
                let job = try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: docId, data: data)], smallWorks: smallWorks).first,
                                        "\(collection): the iOS sample is not read by this app")
                var payload = FirebaseBackend.jobDocumentPayload(job, organizationId: (sample["data"] as? [String: Any])?["organizationId"] as? String ?? "")
                    .filter { !($0.value is FieldValue) }
                // `managerUserIds` is written beside `managerIds` by `jobSaveFields` (`jobManagerUserIds` against the
                // loaded managers and roster, RULEBOOK 1.10.0 §16); the read copy keeps the stored list.
                if !job.storedManagerUserIds.isEmpty { payload["managerUserIds"] = job.storedManagerUserIds }
                // RULEBOOK 1.33.0 (owner decision 6 Nov): the managers' hide list is never written any more. The
                // contract's iOS sample (web `crossPlatformContract.samples.ts`) still lists it — reported to web.
                let stored = try XCTUnwrap(sample["data"] as? [String: Any]).filter { $0.key != "hiddenManagerUserIds" }
                // Every field the contract says iOS writes is written, as the same kind of value.
                for (key, value) in stored {
                    guard let written = payload[key] else {
                        XCTFail("\(collection).\(key) is in the contract's iOS sample but the iOS payload does not write it")
                        continue
                    }
                    XCTAssertEqual(kind(written), kind(value), "\(collection).\(key)")
                }
                // The projects sample is the whole payload; the small works sample is a partial copy (reported to web).
                if collection == "projects" {
                    XCTAssertEqual(Set(payload.keys), Set(stored.keys), "projects: iOS payload fields differ from the contract's iOS sample")
                }
            }
        }
    }

    /// 1.11.0 contract v2: an iOS sample with a `builder` is exactly what its rulebook writer produces from the input
    /// (the writer iOS calls). Runs the packed writer, unwraps `fields` / `set`, turns `timestampKeys` milliseconds
    /// into `{ seconds, nanoseconds }` and adds `appAdds` — what web's `buildContractSample` does.
    func testEveryBuilderSampleIsWhatItsPackedWriterProduces() throws {
        let contract = try loadContract()
        var built = 0
        for entry in contract.collections {
            let id = entry["id"] as? String ?? "?"
            for sample in entry["samples"] as? [[String: Any]] ?? [] {
                guard let builder = sample["builder"] as? [String: Any] else { continue }
                built += 1
                XCTAssertEqual(sample["platform"] as? String, "ios", "\(id): only iOS samples carry a builder")
                let writer = try XCTUnwrap(builder["writer"] as? String, id)
                let input = builder["input"] as? [String: Any] ?? [:]
                let arguments: [Any]
                switch writer {
                case "jobTypesWriteFields": arguments = [input["stored"] ?? NSNull(), input["next"] ?? NSNull()]
                case "variationTradesWriteFields": arguments = [input["stored"] ?? NSNull(), input["change"] ?? NSNull()]
                case "tradeTypeInventoryWriteFields": arguments = [input["stored"] ?? NSNull(), input["trades"] ?? NSNull()]
                default: arguments = [input]
                }
                let result = try XCTUnwrap(CanonicalBusinessEngine.callJSON(writer, arguments: arguments) as? [String: Any], "\(id): \(writer) did not answer")
                XCTAssertNotEqual(result["ok"] as? Bool, false, "\(id): \(writer) refused its sample")
                var fields = (result["fields"] as? [String: Any]) ?? (result["set"] as? [String: Any]) ?? result
                for key in builder["timestampKeys"] as? [String] ?? [] {
                    guard let ms = (fields[key] as? NSNumber)?.int64Value else { continue }
                    let seconds = Int64((Double(ms) / 1000).rounded(.down))
                    fields[key] = ["seconds": seconds, "nanoseconds": (ms - seconds * 1000) * 1_000_000]
                }
                for (key, value) in builder["appAdds"] as? [String: Any] ?? [:] { fields[key] = value }
                XCTAssertEqual(canonicalJSON(fields), canonicalJSON(sample["data"] ?? [:]), "\(id) builder")
            }
        }
        XCTAssertGreaterThanOrEqual(built, 8, "the builder samples are in the contract")
    }

    /// 1.11.0: every booking sample carries `jobCollection`, and iOS labour and subcontractor builders pass it.
    func testBookingSamplesCarryJobCollection() throws {
        let contract = try loadContract()
        for id in ["bookings", "subcontractorBookings"] {
            for platform in ["web", "ios"] {
                for sample in samples(contract, collection: id, platform: platform) {
                    XCTAssertEqual((sample["data"] as? [String: Any])?["jobCollection"] as? String, "projects", "\(id) \(platform)")
                }
            }
        }
    }

    /// `orgMemberships`: iOS writes only through `orgMembershipWriteFields` from 1.10.0 (nested `permissions`). A create
    /// with the permissions the iOS sample reads as must read back to the same role flags.
    func testMembershipWriterRoundTripsThroughTheReader() throws {
        let contract = try loadContract()
        for sample in samples(contract, collection: "orgMemberships", platform: "ios") {
            let expected = try XCTUnwrap(sample["expected"] as? [String: Any])
            let permissions = try XCTUnwrap(expected["permissions"] as? [String: Any])
            let org = expected["organizationId"] as? String ?? "ORG-1"
            let write = try XCTUnwrap(CanonicalBusinessEngine.callJSON(
                "orgMembershipWriteFields",
                arguments: [[
                    "organizationId": org,
                    "stored": NSNull(),
                    "next": [
                        "role": expected["role"] ?? "member",
                        "isSuperAdmin": expected["isSuperAdmin"] ?? false,
                        "accountActive": expected["accountActive"] ?? true,
                        "permissions": permissions,
                    ],
                    "writer": "admin",
                    "now": 0,
                ]]
            ) as? [String: Any])
            XCTAssertEqual(write["mode"] as? String, "create")
            let fields = try XCTUnwrap(write["fields"] as? [String: Any])
            XCTAssertNotNil(fields["permissions"] as? [String: Any], "the nested shape")
            let read = try XCTUnwrap(FirebaseBackend.orgMembership(organizationId: org, data: fields))
            XCTAssertEqual(canonicalJSON(read.permissions), canonicalJSON(permissions))
            XCTAssertEqual(read.role, expected["role"] as? String)
        }
    }
}
