import XCTest
@testable import DshClientCore

final class LaunchURLTests: XCTestCase {
    func testParsesTokenAndPort() throws {
        let launch = try LaunchURL.parse("http://127.0.0.1:3080/?token=abc123")
        XCTAssertEqual(launch.host, "127.0.0.1")
        XCTAssertEqual(launch.port, 3080)
        XCTAssertEqual(launch.token, "abc123")
    }

    func testTakesLastLine() throws {
        let output = """
        noise before
        http://127.0.0.1:3080/?token=old
        http://127.0.0.1:3080/?token=new
        """
        XCTAssertEqual(try LaunchURL.parseLast(from: output).token, "new")
    }

    func testRejectsMissingToken() {
        XCTAssertThrowsError(try LaunchURL.parse("http://127.0.0.1:3080/")) { error in
            XCTAssertEqual(error as? LaunchURL.ParseError, .noToken)
        }
        XCTAssertThrowsError(try LaunchURL.parseLast(from: "no url here")) { error in
            XCTAssertEqual(error as? LaunchURL.ParseError, .noToken)
        }
    }

    func testTunnelledURLKeepsToken() throws {
        let launch = try LaunchURL.parse("http://127.0.0.1:3080/?token=abc123")
        let url = launch.tunnelled(localPort: 41000)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:41000/?token=abc123")
    }
}
