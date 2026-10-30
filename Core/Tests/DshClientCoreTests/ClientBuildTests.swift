import XCTest
@testable import DshClientCore

final class ClientBuildTests: XCTestCase {
    func testStampCarriesNameAndBuild() {
        XCTAssertEqual(ClientBuild.stamp(build: "42"), "dafeiyu-dsh-client · build 42")
    }
}
