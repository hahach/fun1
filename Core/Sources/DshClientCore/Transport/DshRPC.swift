import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// unary 调用的失败面。
public enum RPCError: Error, Equatable, LocalizedError {
    case transport(status: Int)
    case malformedResponse(status: Int, prefix: String)
    case rpcIdMismatch
    case remote(code: String, message: String)

    /// 界面上一行说完：dsh 的 `code` 与 `message` 比 NSError 桥接后的序号有用得多。
    public var errorDescription: String? {
        switch self {
        case .transport(let status):
            return "HTTP \(status)"
        case .malformedResponse(let status, let prefix):
            let head = prefix.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)
            return head.isEmpty
                ? "响应不是一个可识别的 dsh 回复（HTTP \(status)，正文为空）"
                : "响应不是一个可识别的 dsh 回复（HTTP \(status)，\(head)）"
        case .rpcIdMismatch:
            return "响应与请求的 rpcId 不一致"
        case .remote(let code, let message):
            return "\(code)：\(message)"
        }
    }
}

public protocol HTTPPosting {
    func post(_ url: URL, body: Data, cookie: DshCredentials?) async throws -> (status: Int, body: Data, headers: [String: String])
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
        let (status, data, headers) = try await poster.post(url, body: body, cookie: credentials)
        guard (200..<300).contains(status) else { throw RPCError.transport(status: status) }

        let sanitized = JSONTolerance.sanitize(data)
        guard let decoded = try? JSONSerialization.jsonObject(with: sanitized),
              let object = decoded as? [String: Any],
              object["type"] as? String == "server-response",
              object["rpcId"] as? String == rpcId,
              let result = object["result"] as? [String: Any]
        else {
            if object_has_rpcid_mismatch(sanitized, expected: rpcId) { throw RPCError.rpcIdMismatch }
            let parseError: String
            do { _ = try JSONSerialization.jsonObject(with: data); parseError = "结构不符" } catch { parseError = "JSON截断" }
            throw RPCError.malformedResponse(
                status: status,
                prefix: "\(data.count)B enc=\(headers["content-encoding"] ?? "none") \(parseError) " + String(decoding: data.prefix(60), as: UTF8.self)
            )
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
    /// 复用一条会话：压缩协商与连接复用回 URLSession 默认行为（B-115 定案为
    /// JSON 未配对代理问题、与压缩路径无关，诊断期的 identity/close 头已移除）。
    private static let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func post(_ url: URL, body: Data, cookie: DshCredentials?) async throws -> (status: Int, body: Data, headers: [String: String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let cookie {
            request.setValue("\(cookie.cookieName)=\(cookie.cookieValue)", forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        let (data, response) = try await Self.session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return (http?.statusCode ?? 0, data, headers)
    }
}