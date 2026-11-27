import XCTest
@testable import DshClientCore

final class EndpointTests: XCTestCase {
    func testHostOnlyUsesDefaultUserAndPort() throws {
        let endpoint = try Endpoint.parse("example.com", defaultUser: "tester")
        XCTAssertEqual(endpoint, Endpoint(user: "tester", host: "example.com", port: 22))
    }

    func testUserAndPort() throws {
        let endpoint = try Endpoint.parse("tester@example.com:2222")
        XCTAssertEqual(endpoint, Endpoint(user: "tester", host: "example.com", port: 2222))
    }

    func testIPv6Literal() throws {
        let endpoint = try Endpoint.parse("tester@[::1]:2200")
        XCTAssertEqual(endpoint, Endpoint(user: "tester", host: "::1", port: 2200))
    }

    func testIPv6LiteralWithoutPort() throws {
        let endpoint = try Endpoint.parse("tester@[::1]")
        XCTAssertEqual(endpoint, Endpoint(user: "tester", host: "::1", port: 22))
    }

    func testTrimsWhitespace() throws {
        XCTAssertEqual(try Endpoint.parse("  tester@example.com  ").host, "example.com")
    }

    func testRejectsBadPort() {
        XCTAssertThrowsError(try Endpoint.parse("example.com:0")) { error in
            XCTAssertEqual(error as? Endpoint.ParseError, .badPort)
        }
        XCTAssertThrowsError(try Endpoint.parse("example.com:70000")) { error in
            XCTAssertEqual(error as? Endpoint.ParseError, .badPort)
        }
    }

    func testRejectsEmptyPieces() {
        XCTAssertThrowsError(try Endpoint.parse("@example.com"))
        XCTAssertThrowsError(try Endpoint.parse("tester@"))
        XCTAssertThrowsError(try Endpoint.parse("   "))
    }
}
