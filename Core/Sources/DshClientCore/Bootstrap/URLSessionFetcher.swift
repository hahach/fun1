import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 用 URLSession 走隧道请一次 URL，取回状态码与 \`dsh-auth-*\` cookie。
///
/// 不跟随跳转：dsh 用 \`303 Location: ./\` 下发 cookie，跟随会让第二次请求在
/// 无 cookie 的情况下打到首页，得到 401。凭据只认首个响应。
public struct URLSessionFetcher: HTTPFetching {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func get(_ url: URL) async throws -> HTTPResult {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (_, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        var lines: [String] = []
        if let header = http?.value(forHTTPHeaderField: "Set-Cookie") {
            lines.append(header)
        }
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] where cookie.name.hasPrefix(DshBootstrap.cookiePrefix) {
            lines.append("\(cookie.name)=\(cookie.value)")
        }
        return HTTPResult(status: status, setCookie: lines)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
