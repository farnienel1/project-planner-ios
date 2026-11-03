import XCTest
@testable import Project_Planner

/// Launch checklist 3.1: material quote / order email through `sendEmail` (`material_request`), one message per
/// recipient with the sender in CC — the shape web's `/api/materials/send-request-email` asks the function for.
@MainActor
final class MaterialRequestEmailPayloadTests: XCTestCase {
    private let projectId = UUID()

    private func item(
        _ name: String,
        quantity: Int = 2,
        unit: MaterialUnit = .box,
        brand: String? = nil,
        productCode: String? = nil,
        notes: String? = nil,
        length: String? = nil,
        lengthUnit: MaterialLengthUnit? = nil
    ) -> MaterialItem {
        var row = MaterialItem(quantity: quantity, unit: unit, material: name, addedBy: "TEST-User", projectId: projectId, date: Date())
        row.brand = brand
        row.productCode = productCode
        row.notes = notes
        row.length = length
        row.lengthUnit = lengthUnit
        return row
    }

    private func request(
        type: MaterialOrderRequest.RequestType,
        contacts: [WholesalerContact],
        materials: [MaterialItem]? = nil,
        delivery: Date? = nil,
        phone: String? = "07700 900123"
    ) -> MaterialOrderRequest {
        MaterialOrderRequest(
            projectId: projectId,
            projectNumber: "TEST-J101",
            projectName: "TEST-Kitchen refit",
            siteAddress: "1 Test Street, Testville",
            materials: materials ?? [item("Plasterboard 12.5mm", brand: "Gyproc", productCode: "GB125", notes: "Tapered edge")],
            requestType: type,
            sentBy: "TEST User",
            recipientContacts: contacts,
            senderName: "TEST User",
            senderEmail: "Sender@Example.com",
            senderPhone: phone,
            senderCompany: "TEST Co",
            sendAsPlainText: false,
            requiredDeliveryDate: delivery
        )
    }

    private let supplier = WholesalerContact(name: "Sam Supplier", email: " Sam@Wholesale.Example ")
    private let sender = WholesalerContact(name: "Me", email: "sender@example.com")

    // MARK: - to / cc / from / reply-to

    func testToIsEachRecipientOnceAndNeverTheSender() {
        let duplicate = WholesalerContact(name: "Sam again", email: "sam@wholesale.example")
        let other = WholesalerContact(name: "Pat", email: "pat@other.example")
        let emails = MaterialRequestEmailPayload.recipientEmails(
            contacts: [supplier, sender, duplicate, other],
            senderEmail: " SENDER@example.com "
        )
        XCTAssertEqual(emails, ["sam@wholesale.example", "pat@other.example"])
    }

    func testBodyAsksForOneEmailWithTheSenderInCcAndCallerDisplayName() throws {
        let body = MaterialRequestEmailPayload.body(
            organizationId: "org-test",
            request: request(type: .quote, contacts: [supplier, sender]),
            senderEmail: "sender@example.com",
            includesDeliveryRequired: false
        )
        XCTAssertEqual(body["orgId"] as? String, "org-test")
        XCTAssertEqual(body["template"] as? String, "material_request")
        XCTAssertEqual(body["to"] as? [String], ["sam@wholesale.example"])
        let data = try XCTUnwrap(body["data"] as? [String: Any])
        // The function copies the verified caller (CC) and names them "<user> via Project Planner"; Reply-To is the
        // caller for this template. The phone never sends its own From name, Reply-To, CC address, subject or HTML.
        XCTAssertEqual(data["ccCaller"] as? Bool, true)
        XCTAssertEqual(data["fromCaller"] as? Bool, true)
        for key in ["cc", "replyTo", "fromName", "subject", "html", "senderEmail", "senderName", "senderCompany"] {
            XCTAssertNil(data[key], key)
            XCTAssertNil(body[key], key)
        }
    }

    // MARK: - Subject inputs

    func testQuoteDataCarriesTheSubjectInputsAndNoDeliveryInstant() throws {
        let data = MaterialRequestEmailPayload.data(
            for: request(type: .quote, contacts: [supplier], delivery: Date(timeIntervalSince1970: 1_800_000_000)),
            includesDeliveryRequired: false
        )
        // Subject "Quote request — TEST-J101 — <organisation>" is rendered by the function from these fields.
        XCTAssertEqual(data["requestType"] as? String, "quote")
        XCTAssertEqual(data["jobNumber"] as? String, "TEST-J101")
        XCTAssertEqual(data["siteName"] as? String, "TEST-Kitchen refit")
        XCTAssertEqual(data["siteAddress"] as? String, "1 Test Street, Testville")
        XCTAssertEqual(data["sendAsPlainText"] as? Bool, false)
        XCTAssertEqual(data["senderPhone"] as? String, "07700 900123")
        XCTAssertNil(data["deliveryRequiredAt"])
    }

    func testOrderDataCarriesTheDeliveryInstantAsISO() throws {
        let data = MaterialRequestEmailPayload.data(
            for: request(type: .order, contacts: [supplier], delivery: Date(timeIntervalSince1970: 1_800_000_000), phone: "  "),
            includesDeliveryRequired: true
        )
        XCTAssertEqual(data["requestType"] as? String, "order")
        XCTAssertEqual(data["deliveryRequiredAt"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertNil(data["senderPhone"])
    }

    func testRequestTypeFollowsTheRulebookForDeliveryInstant() {
        XCTAssertEqual(CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired(
            MaterialRequestEmailPayload.requestTypeValue(.order)), true)
        XCTAssertEqual(CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired(
            MaterialRequestEmailPayload.requestTypeValue(.quote)), false)
    }

    // MARK: - Line items

    func testLineItemsUseWebKeysAndDropBlankOptionalFields() throws {
        let lines = MaterialRequestEmailPayload.materialLines([
            item("Plasterboard 12.5mm", quantity: 4, unit: .box, brand: " Gyproc ", productCode: "GB125", notes: "Tapered edge"),
            item("Timber batten", quantity: 1, unit: .length, brand: "  ", length: "3", lengthUnit: .metres),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["material"] as? String, "Plasterboard 12.5mm")
        XCTAssertEqual(lines[0]["quantity"] as? Int, 4)
        XCTAssertEqual(lines[0]["unit"] as? String, "Box")
        XCTAssertEqual(lines[0]["brand"] as? String, "Gyproc")
        XCTAssertEqual(lines[0]["productCode"] as? String, "GB125")
        XCTAssertEqual(lines[0]["notes"] as? String, "Tapered edge")
        XCTAssertNil(lines[0]["lengthDisplay"])
        XCTAssertEqual(lines[1]["unit"] as? String, "Length")
        XCTAssertNil(lines[1]["brand"])
        XCTAssertNil(lines[1]["productCode"])
        XCTAssertNil(lines[1]["notes"])
        XCTAssertEqual(lines[1]["lengthDisplay"] as? String, item("x", length: "3", lengthUnit: .metres).formattedLengthSpecification)
        let allowed: Set<String> = ["material", "quantity", "unit", "brand", "productCode", "notes", "lengthDisplay"]
        for line in lines { XCTAssertTrue(Set(line.keys).isSubset(of: allowed), "\(line.keys)") }
    }

    // MARK: - Request and response

    func testURLRequestUsesSendEmailWithIdTokenAndAppCheckButNoServerKey() throws {
        let url = try XCTUnwrap(MaterialRequestEmailPayload.functionURL(projectId: "project-planner-test"))
        XCTAssertEqual(url.absoluteString, "https://us-central1-project-planner-test.cloudfunctions.net/sendEmail")
        let urlRequest = try MaterialRequestEmailPayload.urlRequest(
            url: url,
            body: ["template": "material_request"],
            idToken: "id-token",
            appCheckToken: "app-check"
        )
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "X-Project-Planner-Server-Key"))
        let withoutAppCheck = try MaterialRequestEmailPayload.urlRequest(url: url, body: [:], idToken: "t", appCheckToken: nil)
        XCTAssertNil(withoutAppCheck.value(forHTTPHeaderField: "X-Firebase-AppCheck"))
    }

    func testSuccessReturnsMessageIdsAndCc() throws {
        let body = Data(#"{"sent":true,"sentCount":1,"failed":[],"results":[{"to":"sam@wholesale.example","id":"re_1","cc":["sender@example.com"]}],"ccSupported":true}"#.utf8)
        let result = try MaterialRequestEmailPayload.parseResponse(statusCode: 200, data: body).get()
        XCTAssertEqual(result.messageIds, ["re_1"])
        XCTAssertEqual(result.cc, ["sender@example.com"])
        XCTAssertTrue(result.ccSupported)
        XCTAssertEqual(result.sentCount, 1)
    }

    func testPartialSendKeepsFailedRecipients() throws {
        let body = Data(#"{"sent":false,"sentCount":1,"failed":["pat@other.example"],"results":[{"to":"sam@wholesale.example","id":"re_2"}]}"#.utf8)
        let result = try MaterialRequestEmailPayload.parseResponse(statusCode: 200, data: body).get()
        XCTAssertEqual(result.failed, ["pat@other.example"])
        XCTAssertEqual(result.cc, [])
        XCTAssertFalse(result.ccSupported)
    }

    func testRefusalShowsTheFunctionReason() {
        let body = Data(#"{"sent":false,"error":"Only admins and managers can send material orders."}"#.utf8)
        let result = MaterialRequestEmailPayload.parseResponse(statusCode: 403, data: body)
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error.errorDescription, "Email not sent: Only admins and managers can send material orders.")
        let empty = MaterialRequestEmailPayload.parseResponse(statusCode: 502, data: Data())
        guard case .failure(let emptyError) = empty else { return XCTFail("expected a failure") }
        XCTAssertEqual(emptyError.errorDescription, "Email not sent: the email service answered 502")
    }

    func testOfflineTransportErrorIsRethrownSoTheSendIsQueued() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/sendEmail"))
        do {
            _ = try await MaterialRequestEmailClient.perform(URLRequest(url: url), transport: FailingTransport(code: .notConnectedToInternet))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(OfflineWriteSupport.shouldQueue(error: error, isOnline: true))
        }
        do {
            _ = try await MaterialRequestEmailClient.perform(URLRequest(url: url), transport: FailingTransport(code: .timedOut))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MaterialRequestEmailError, .timedOut)
            XCTAssertFalse(OfflineWriteSupport.shouldQueue(error: error, isOnline: true))
        }
    }
}

private struct FailingTransport: MaterialRequestEmailTransport {
    let code: URLError.Code
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(code)
    }
}
