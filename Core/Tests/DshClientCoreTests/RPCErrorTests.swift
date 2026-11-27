import XCTest
@testable import DshClientCore

final class RPCErrorTests: XCTestCase {

    func testRemoteErrorDescribesCodeAndMessage() {
        let error = RPCError.remote(code: "gateway/arguments-invalid", message: "missing request")

        XCTAssertEqual(error.errorDescription, "gateway/arguments-invalid：missing request")
    }
}
