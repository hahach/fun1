import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// unary 调用的失败面。
public enum RPCError: Error, Equatable, LocalizedError {
    case transport(status: Int)
    case malformedResponse
    case rpcIdMismatch
    case remote(code: String, message: String)

    /// 界面上一行说完：dsh 的 `code` 与 `message` 比 NSError 桥接后的序号有用得多。
    public var errorDescription: String? {
        switch self {
        case .transport(let status):
            return "HTTP \(status)"
        case .malformedResponse:
            return "响应不是一个可识别的 dsh 回复"
        case .rpcIdMismatch:
            return "响应与请求的 rpcId 不一致"
        case .remote(let code, let message):
            return "\(code)：\(message)"
        }
    }
}

public protocol HTTPPosting {
    func post(_ url: URL, body: Data, cookie: DshCredentials?) async throws -> (status: Int, body: Data)
}

/// 走隧道调 dsh 的 unary 端点。
///
/// 线上格式（来源：`@deepseek-ai/dsh-client-connection` 的 `createWebConnectionRpc`）：
/// 请求 `POST /api/<endpoint>`，体为 `{type:"client-request", rpcId, method, payload:{args}}`；
/// 响应 `{type:"server-response", rpcId, result:{ok,value}|{ok:false,error:{code,message,details}}}`。
public struct DshRPC: Sendable {
    public let baseURL: URL
    public let credentials: DshCredentials
    private let poster: any HTTPPosting

    public init(baseURL: URL, credentials: DshCredentials, poster: any HTTPPosting = URLSessionPoster()) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.poster = poster
    }

    public func call(_ endpoint: String, args: Any = [String: Any]()) async throws -> Any {
        let rpcId = UUID().uuidString
        let envelope: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcId,
            "method": endpoint,
            "payload": ["args": args],
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])

        let url = baseURL.appendingPathComponent("api/\(endpoint)")
        let (status, data) = try await poster.post(url, body: body, cookie: credentials)
        guard (200..<300).contains(status) else { throw RPCError.transport(status: status) }

        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any],
              object["type"] as? String == "server-response",
              object["rpcId"] as? String == rpcId,
              let result = object["result"] as? [String: Any]
        else {
            throw object_has_rpcid_mismatch(data, expected: rpcId) ? RPCError.rpcIdMismatch : RPCError.malformedResponse
        }

        if result["ok"] as? Bool == true {
            return result["value"] ?? NSNull()
        }
        let error = result["error"] as? [String: Any]
        throw RPCError.remote(
            code: error?["code"] as? String ?? "unknown",
            message: error?["message"] as? String ?? "dsh refused the call"
        )
    }
}

private func object_has_rpcid_mismatch(_ data: Data, expected: String) -> Bool {
    guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rpcId = decoded["rpcId"] as? String
    else { return false }
    return rpcId != expected
}

/// POST 一次 JSON，带 cookie。不跟随跳转（unary 不该有）。
public struct URLSessionPoster: HTTPPosting {
    public init() {}

    public func post(_ url: URL, body: Data, cookie: DshCredentials?) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let cookie {
            request.setValue("\(cookie.cookieName)=\(cookie.cookieValue)", forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
