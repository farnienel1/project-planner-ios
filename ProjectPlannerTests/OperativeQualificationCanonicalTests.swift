import XCTest
@testable import Project_Planner

@MainActor
final class OperativeQualificationCanonicalTests: XCTestCase {
    func testAssignedWriteKeepsTheOperativeFields() {
        let created = "2026-01-02T00:00:00.000Z"
        let write = CanonicalBusinessEngine.assignedQualificationWriteFields(
            CanonicalBusinessEngine.CanonicalAssignedQualificationRow(
                id: "EL-ECS-IE",
                name: "ECS Gold Card",
                hasEndDate: false,
                createdAtIso: created,
                updatedAtIso: created
            )
        )
        XCTAssertEqual(write?.id, "EL-ECS-IE")
        XCTAssertEqual(write?.name, "ECS Gold Card")
        XCTAssertEqual(write?.hasEndDate, false)
        XCTAssertEqual(write?.createdAtIso, created)
        XCTAssertEqual(write?.updatedAtIso, created)
        XCTAssertNil(write?.endDateIso)
        XCTAssertNil(
            CanonicalBusinessEngine.assignedQualificationWriteFields(
                CanonicalBusinessEngine.CanonicalAssignedQualificationRow(
                    id: "",
                    name: "CSCS",
                    hasEndDate: false,
                    createdAtIso: created,
                    updatedAtIso: created
                )
            )
        )
        XCTAssertNil(
            CanonicalBusinessEngine.assignedQualificationWriteFields(
                CanonicalBusinessEngine.CanonicalAssignedQualificationRow(
                    id: "Q1",
                    name: " ",
                    hasEndDate: false,
                    createdAtIso: created,
                    updatedAtIso: created
                )
            )
        )
    }

    func testMergeKeepsOtherQualificationsAndCertificateUrls() {
        let created = "2026-01-02T00:00:00.000Z"
        let merged = CanonicalBusinessEngine.mergeOperativeQualificationWrite(
            CanonicalBusinessEngine.CanonicalOperativeQualificationMergeInput(
                previous: CanonicalBusinessEngine.CanonicalOperativeQualificationMaps(
                    qualifications: [
                        CanonicalBusinessEngine.CanonicalAssignedQualificationRow(
                            id: "Q-OLD",
                            name: "CSCS",
                            hasEndDate: false,
                            createdAtIso: created,
                            updatedAtIso: created
                        ),
                    ],
                    qualificationExpiryDates: ["Q-OLD": "2026-09-01T00:00:00.000Z"],
                    qualificationCertificateURLs: ["Q-OLD": "https://files.example/cscs.pdf"]
                ),
                next: CanonicalBusinessEngine.CanonicalOperativeQualificationNext(
                    qualifications: [
                        CanonicalBusinessEngine.CanonicalAssignedQualificationRow(
                            id: "Q-NEW",
                            name: "First aid",
                            hasEndDate: false,
                            createdAtIso: created,
                            updatedAtIso: created
                        ),
                    ],
                    qualificationExpiryDates: ["Q-NEW": "2027-03-01T00:00:00.000Z"],
                    qualificationCertificateURLs: ["Q-NEW": "https://files.example/first-aid.pdf"],
                    removedCertificateIds: []
                )
            )
        )
        XCTAssertEqual(Set(merged?.qualifications.map(\.id) ?? []), ["Q-OLD", "Q-NEW"])
        XCTAssertEqual(merged?.qualifications.first { $0.id == "Q-OLD" }?.name, "CSCS")
        XCTAssertEqual(merged?.qualificationExpiryDates["Q-OLD"], "2026-09-01T00:00:00.000Z")
        XCTAssertEqual(merged?.qualificationExpiryDates["Q-NEW"], "2027-03-01T00:00:00.000Z")
        XCTAssertEqual(merged?.qualificationCertificateURLs["Q-OLD"], "https://files.example/cscs.pdf")
        XCTAssertEqual(merged?.qualificationCertificateURLs["Q-NEW"], "https://files.example/first-aid.pdf")
    }

    func testCertificateMergeKeepsPriorFilesAndDropsOnlyAClearedId() {
        XCTAssertEqual(
            CanonicalBusinessEngine.mergeQualificationCertificateUrls(
                existing: ["q1": "a", "q2": "b"],
                uploaded: ["q3": "c"]
            ),
            ["q1": "a", "q2": "b", "q3": "c"] as [String: String]?
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.mergeQualificationCertificateUrls(
                existing: ["q1": "a", "q2": "b"],
                uploaded: [:],
                removedIds: ["q2"]
            ),
            ["q1": "a"] as [String: String]?
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.qualificationCertificateUrl(
                urls: ["ABC-1": "https://files.example/old.pdf"],
                qualificationId: "abc-1"
            ),
            "https://files.example/old.pdf"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.removedQualificationCertificateIds(
                previousUrls: ["q1": "a", "q2": "b"],
                nextUrls: ["q1": "a"],
                assignedIds: ["q1", "q2"]
            ),
            ["q2"] as [String]?
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.removedQualificationCertificateIds(
                previousUrls: ["q1": "a", "OTHER": "keep"],
                nextUrls: ["q1": "a"],
                assignedIds: ["q1"]
            ),
            [] as [String]?
        )
    }

    func testCertificateStoragePathUsesTheSharedPrefix() {
        XCTAssertEqual(
            CanonicalBusinessEngine.qualificationCertificateStoragePath(
                organizationId: "ORG1",
                operativeId: "OP1",
                qualificationId: "Q1",
                fileName: "uid_1_cscs.pdf"
            ),
            "organizations/ORG1/operatives/OP1/qualifications/Q1/certificates/uid_1_cscs.pdf"
        )
        XCTAssertNil(
            CanonicalBusinessEngine.qualificationCertificateStoragePath(
                organizationId: "",
                operativeId: "OP1",
                qualificationId: "Q1",
                fileName: "a.pdf"
            )
        )
    }

    func testEditorSaveKeepsAnUnloadedQualificationAndDropsOneItRemoved() {
        let created = Date(timeIntervalSince1970: 1_767_312_000)
        let old = Qualification(id: "Q-OLD", name: "CSCS", hasEndDate: false, createdAt: created, updatedAt: created)
        let hidden = Qualification(id: "Q-HIDDEN", name: "IPAF", hasEndDate: false, createdAt: created, updatedAt: created)
        let added = Qualification(id: "Q-NEW", name: "First aid", hasEndDate: false, createdAt: created, updatedAt: created)
        let merged = OperativeQualificationPatch.mergedWrite(
            stored: OperativeQualificationPatch.Maps(
                qualifications: [old, hidden],
                expiryDates: ["Q-OLD": created, "Q-HIDDEN": created],
                certificateURLs: [
                    "Q-OLD": "https://files.example/cscs.pdf",
                    "Q-HIDDEN": "https://files.example/ipaf.pdf",
                ]
            ),
            baselineIds: ["Q-OLD"],
            editor: OperativeQualificationPatch.Maps(
                qualifications: [added],
                expiryDates: ["Q-NEW": created],
                certificateURLs: ["Q-NEW": "https://files.example/first-aid.pdf"]
            )
        )
        XCTAssertEqual(Set(merged?.qualifications.map(\.id) ?? []), ["Q-HIDDEN", "Q-NEW"])
        XCTAssertEqual(merged?.qualificationCertificateURLs["Q-HIDDEN"], "https://files.example/ipaf.pdf")
        XCTAssertEqual(merged?.qualificationCertificateURLs["Q-NEW"], "https://files.example/first-aid.pdf")
        XCTAssertNil(merged?.qualificationCertificateURLs["Q-OLD"])
        XCTAssertNotNil(merged?.qualificationExpiryDates["Q-HIDDEN"])
        XCTAssertNil(merged?.qualificationExpiryDates["Q-OLD"])
    }
}
