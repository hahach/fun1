import Foundation
import NIOCore
import XCTest
@testable import DshClientCore

final class WebSocketFrameTests: XCTestCase {
    func testDecodeUnmaskedTextFrame() {
        var buffer = ByteBuffer()
        let payload = Array("hello".utf8)
        buffer.writeBytes([0x81, UInt8(payload.count)])
        buffer.writeBytes(payload)

        let frame = WebSocketFrame.decode(&buffer)
        XCTAssertEqual(frame?.opcode, 0x1)
        XCTAssertEqual(frame?.fin, true)
        XCTAssertEqual(frame?.payload.getString(at: 0, length: frame?.payload.readableBytes ?? 0), "hello")
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testDecodeTwoFramesBackToBack() {
        var buffer = ByteBuffer()
        for text in ["one", "two"] {
            let payload = Array(text.utf8)
            buffer.writeBytes([0x81, UInt8(payload.count)])
            buffer.writeBytes(payload)
        }
        XCTAssertEqual(WebSocketFrame.decode(&buffer)?.payload.getString(at: 0, length: 3), "one")
        XCTAssertEqual(WebSocketFrame.decode(&buffer)?.payload.getString(at: 0, length: 3), "two")
    }

    func testDecodeMaskedFrame() {
        var buffer = ByteBuffer()
        let mask: [UInt8] = [1, 2, 3, 4]
        let payload = Array("masked".utf8)
        buffer.writeBytes([0x81, 0x80 | UInt8(payload.count)])
        buffer.writeBytes(mask)
        buffer.writeBytes(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })

        let frame = WebSocketFrame.decode(&buffer)
        XCTAssertEqual(frame?.payload.getString(at: 0, length: frame?.payload.readableBytes ?? 0), "masked")
    }

    func testDecodeIncompleteFrameReturnsNil() {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x81, 0x05, 0x68, 0x65])
        XCTAssertNil(WebSocketFrame.decode(&buffer))
    }
}
