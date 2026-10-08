import XCTest
#if SWIFT_PACKAGE
@testable import GPMCCore
#else
@testable import PhotosBackup
#endif

/// Literal wire fixtures keep the encoder and decoder from hiding each other's
/// mistakes. This suite runs on macOS through SwiftPM and in the iOS app suite.
final class ProtobufTests: XCTestCase {
    func testVarintEncodingMatchesWireFixtures() {
        let fixtures: [(UInt64, [UInt8])] = [
            (0, [0x00]),
            (127, [0x7f]),
            (128, [0x80, 0x01]),
            (300, [0xac, 0x02]),
            (.max, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]),
        ]
        for (value, bytes) in fixtures {
            XCTAssertEqual(Proto.varint(value), Data(bytes), "value: \(value)")
            XCTAssertEqual(try Proto.number(1, in: Data([0x08] + bytes)), value)
        }
    }

    func testFieldEncodingMatchesWireFixtures() {
        XCTAssertEqual(Proto.int(1, 300), Data([0x08, 0xac, 0x02]))
        XCTAssertEqual(Proto.string(2, "hi"), Data([0x12, 0x02, 0x68, 0x69]))
        XCTAssertEqual(Proto.bytes(3, Data()), Data([0x1a, 0x00]))
        // Largest legal field number, independent of the encoder's tag logic.
        let lastField = Data([0xf8, 0xff, 0xff, 0xff, 0x0f, 0x01])
        XCTAssertEqual(Proto.int(536_870_911, 1), lastField)
        XCTAssertEqual(try Proto.number(536_870_911, in: lastField), 1)
    }

    func testRepeatedPayloadsRetainOrderAndNestedPathsAreReadable() throws {
        // field 1 = { field 2 = "hi" }, field 1 = { field 2 = "!" }
        let body = Data([0x0a, 0x04, 0x12, 0x02, 0x68, 0x69,
                         0x0a, 0x03, 0x12, 0x01, 0x21])
        XCTAssertEqual(try Proto.fields(body)[1], [
            Data([0x12, 0x02, 0x68, 0x69]), Data([0x12, 0x01, 0x21]),
        ])
        XCTAssertEqual(try Proto.string(at: [1, 2], in: body), "hi")
        XCTAssertNil(try Proto.string(at: [1, 3], in: body))
    }

    func testUnknownFixedWidthFieldsDoNotHideLaterKnownFields() throws {
        let body = Data([
            0x09, 0, 0, 0, 0, 0, 0, 0, 0, // field 1, fixed64
            0x15, 0, 0, 0, 0,             // field 2, fixed32
            0x18, 0x2a,                   // field 3 = 42
            0x22, 0x01, 0x61,             // field 4 = "a"
        ])
        XCTAssertEqual(try Proto.number(3, in: body), 42)
        XCTAssertEqual(try Proto.fields(body), [4: [Data([0x61])]])
    }

    func testMalformedWireDataIsRejectedByBothReaders() {
        let malformed: [[UInt8]] = [
            [0x00],                            // zero field number
            [0x80],                            // incomplete tag
            [0x80, 0x80, 0x80, 0x80, 0x10, 0], // field number exceeds wire limit
            [0x08, 0x80],                      // incomplete value
            [0x08] + Array(repeating: 0xff, count: 9) + [0x02], // UInt64 overflow
            [0x08] + Array(repeating: 0x80, count: 10),         // too long
            [0x0a, 0x80],                      // incomplete length
            [0x0a, 0x02, 0x61],                // payload shorter than length
            [0x09, 0, 0, 0],                   // incomplete fixed64
            [0x0d, 0, 0, 0],                   // incomplete fixed32
            [0x0b], [0x0c], [0x0e], [0x0f],   // unsupported wire types
        ]
        for bytes in malformed {
            let data = Data(bytes)
            XCTAssertThrowsError(try Proto.fields(data), "bytes: \(bytes)")
            XCTAssertThrowsError(try Proto.number(1, in: data), "bytes: \(bytes)")
        }
    }

    func testValidPrefixDoesNotMaskATruncatedResponse() {
        let body = Data([0x08, 0x08, 0x12, 0x03, 0x61])
        XCTAssertThrowsError(try Proto.number(1, in: body))
        XCTAssertNil(GoogleStatus(body), "a partial status must not classify an error")
    }

    func testEmptyAndInvalidUTF8StringsDoNotBecomeMessages() throws {
        XCTAssertNil(try Proto.string(at: [1], in: Data([0x0a, 0x00])))
        XCTAssertNil(try Proto.string(at: [1], in: Data([0x0a, 0x01, 0xff])))
        XCTAssertEqual(try Proto.fields(Data()), [:])
        XCTAssertNil(try Proto.number(1, in: Data()))
    }

    func testGoogleStatusDistinguishesQuotaFromRateLimiting() {
        // google.rpc.Status { code: RESOURCE_EXHAUSTED, message: "Full" }
        let status = GoogleStatus(Data([0x08, 0x08, 0x12, 0x04, 0x46, 0x75, 0x6c, 0x6c]))
        XCTAssertEqual(status?.message, "Full")
        XCTAssertEqual(status?.kind(httpStatus: 403), .storageFull)
        XCTAssertNil(status?.kind(httpStatus: 429))
        XCTAssertFalse(GPMCError(kind: .storageFull, message: "Full").isRetryable)
        XCTAssertTrue(GPMCError(kind: .server(429), message: "Slow down").isRetryable)
    }
}
