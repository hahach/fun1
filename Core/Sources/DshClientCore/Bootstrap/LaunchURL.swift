import Foundation

/// dsh 启动时打印的一次性 URL：`http://127.0.0.1:3080/?token=<token>`。
/// 它既是凭据来源，也是「实例是否重启」的判据。
public struct LaunchURL: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    public enum ParseError: Error, Equatable {
        case notAURL
        case noToken
    }

    /// 从多行输出里按出现顺序取全部可解析的 URL（重复的合并）。
    public static func parseAll(from output: String) -> [LaunchURL] {
        var seen = Set<String>()
        var result: [LaunchURL] = []
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let value = try? parse(String(line)) else { continue }
            let key = value.host + ":" + String(value.port) + "/" + value.token
            if seen.insert(key).inserted { result.append(value) }
        }
        return result
    }

    /// 从日志行或命令输出里取最后一条 URL。
    public static func parseLast(from output: String) throws -> LaunchURL {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for line in lines.reversed() {
            if let value = try? parse(String(line)) { return value }
        }
        throw ParseError.noToken
    }

    public static func parse(_ raw: String) throws -> LaunchURL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host,
              let port = components.port,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { throw ParseError.noToken }
        return LaunchURL(host: host, port: port, token: token)
    }

    /// 隧道内的等价 URL：主机换成 `127.0.0.1:localPort`，保留 token 查询。
    public func tunnelled(localPort: Int) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = localPort
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }
}
