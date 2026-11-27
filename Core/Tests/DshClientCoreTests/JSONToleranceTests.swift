import Foundation
import XCTest
@testable import DshClientCore

/// B-115：dsh 会话数据里存在未配对的 UTF-16 代理转义（模型流式输出截断残留）。
/// 浏览器宽容接受，iOS JSONSerialization 拒绝——一条坏转义毒死整个 session/list。
final class JSONToleranceTests: XCTestCase {
    func testLoneHighSurrogateIsReplaced() throws {
        let raw = Data(#"{"text":"置 \ud83d 完"}"#.utf8)
        let sanitized = JSONTolerance.sanitize(raw)
        let object = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let text = object?["text"] as? String
        XCTAssertEqual(text, "置 \u{FFFD} 完")
    }

    func testLoneLowSurrogateIsReplaced() throws {
        let raw = Data(#"{"text":"\ude42 尾"}"#.utf8)
        let sanitized = JSONTolerance.sanitize(raw)
        let object = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let text = object?["text"] as? String
        XCTAssertEqual(text, "\u{FFFD} 尾")
    }

    func testValidPairIsPreserved() throws {
        let raw = Data(#"{"text":"好 \ud83d\ude42 的"}"#.utf8)
        let sanitized = JSONTolerance.sanitize(raw)
        let object = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let text = object?["text"] as? String
        XCTAssertEqual(text, "好 \u{1F642} 的")
    }

    func testHighFollowedByPairKeepsThePair() throws {
        // 高位、高位、低位：第一个高位孤立被替换，后两个仍构成一对。
        let raw = Data(#"{"text":"\ud83d\ud83d\ude42"}"#.utf8)
        let sanitized = JSONTolerance.sanitize(raw)
        let object = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let text = object?["text"] as? String
        XCTAssertEqual(text, "\u{FFFD}\u{1F642}")
    }

    func testNoEscapesReturnsSameData() {
        let raw = Data(#"{"a":"普通正文 123"}"#.utf8)
        XCTAssertEqual(JSONTolerance.sanitize(raw), raw)
    }

    func testRPCParsesPoisonedResponse() async throws {
        // 端到端：unary 响应带孤立代理转义时，DshRPC.call 仍应成功返回。
        let rpc = DshRPC(
            baseURL: URL(string: "http://127.0.0.1:41000/")!,
            credentials: DshCredentials(cookieName: "dsh-auth-x", cookieValue: "secret"),
            poster: PoisonPoster()
        )
        let value = try await rpc.call("session/list")
        let object = value as? [String: Any]
        let items = object?["items"] as? [Any]
        XCTAssertEqual(items?.count, 1)
    }
}

/// 回显 rpcId 的中毒响应：一条 item 的正文里带 \ud83d。
private struct PoisonPoster: HTTPPosting {
    func post(_ url: URL, body: Data, cookie: DshCredentials?) async throws -> (status: Int, body: Data, headers: [String: String]) {
        let rpcId = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["rpcId"] as? String ?? ""
        let payload = #"{"type":"server-response","rpcId":"\#(rpcId)","result":{"ok":true,"value":{"items":[{"text":"置 \ud83d 完"}]}}}"#
        return (200, Data(payload.utf8), ["content-type": "application/json"])
    }
}
