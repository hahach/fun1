import Foundation
import DshClientCore

/// URLSession 版 HTTPFetching：请求隧道内的 dsh 首页后，从共享 cookie 存储取 `dsh-auth-*`。
struct DshHTTPFetcher: HTTPFetching {
    func get(_ url: URL) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let setCookie = cookies
            .filter { $0.name.hasPrefix(DshBootstrap.cookiePrefix) }
            .map { "\($0.name)=\($0.value)" }
        return HTTPResult(status: status, setCookie: setCookie)
    }
}
