import XCTest
@testable import YentlShared

final class PaymentServiceTests: XCTestCase {
    /// is_match_paid's single argument must be named `match` — PostgREST
    /// resolves the function by named arguments, so a drifted key 404s.
    func testIsPaidParamsEncodesMatchKey() throws {
        let matchID = UUID()
        let json = try encodeToJSON(PaymentService.IsPaidParams(match: matchID))
        XCTAssertEqual(Set(json.keys), ["match"])
        XCTAssertEqual(json["match"] as? String, matchID.uuidString)
    }

    /// record-payment's body: exact snake_case keys, and the match id
    /// lowercased (the function lowercases its side too, but the ledger and
    /// Stream ids are lowercase by convention throughout).
    func testRecordParamsEncodesSnakeCaseKeys() throws {
        let json = try encodeToJSON(PaymentService.RecordParams(
            matchID: "b477963c-87bb-46bf-99ca-bcbd9febf734",
            storeTransactionID: "txn_123"
        ))
        XCTAssertEqual(Set(json.keys), ["match_id", "store_transaction_id"])
        XCTAssertEqual(json["match_id"] as? String, "b477963c-87bb-46bf-99ca-bcbd9febf734")
        XCTAssertEqual(json["store_transaction_id"] as? String, "txn_123")
    }

    /// The success payload decodes from record-payment's exact wire shape
    /// (publicRow + match_paid). Extra fields (created_at) must be ignored.
    func testRecordPaymentResponseDecodesWireShape() throws {
        let json = """
        {
          "payment": {
            "id": "0e0e0e0e-1111-2222-3333-444444444444",
            "match_id": "b477963c-87bb-46bf-99ca-bcbd9febf734",
            "user_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "product_id": "match_unlock",
            "store_transaction_id": "txn_123",
            "status": "paid",
            "created_at": "2026-07-22T12:00:00.000Z"
          },
          "match_paid": true
        }
        """
        let response = try JSONDecoder().decode(
            RecordPaymentResponse.self, from: Data(json.utf8)
        )
        XCTAssertTrue(response.matchPaid)
        XCTAssertEqual(response.payment.status, "paid")
        XCTAssertEqual(response.payment.storeTransactionID, "txn_123")
        XCTAssertEqual(
            response.payment.matchID.uuidString.lowercased(),
            "b477963c-87bb-46bf-99ca-bcbd9febf734"
        )
        XCTAssertEqual(response.payment.productID, "match_unlock")
    }

    /// A null product_id (nullable column) must not fail decoding.
    func testPaymentRecordDecodesNullProductID() throws {
        let json = """
        {
          "id": "0e0e0e0e-1111-2222-3333-444444444444",
          "match_id": "b477963c-87bb-46bf-99ca-bcbd9febf734",
          "user_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "product_id": null,
          "store_transaction_id": "txn_123",
          "status": "paid"
        }
        """
        let record = try JSONDecoder().decode(PaymentRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.productID)
    }

    /// Server failure bodies ({"error": "..."}) surface their message; junk
    /// bodies fall back to a generic status-code message.
    func testServerMessageExtraction() {
        XCTAssertEqual(
            PaymentService.serverMessage(
                from: Data(#"{"error":"no matching purchase found"}"#.utf8), status: 402
            ),
            "no matching purchase found"
        )
        XCTAssertEqual(
            PaymentService.serverMessage(from: Data("<html>".utf8), status: 500),
            "Payment could not be recorded (HTTP 500)."
        )
    }

    private func encodeToJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
