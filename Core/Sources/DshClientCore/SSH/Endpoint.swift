import Foundation

/// 用户输入的主机端点：`user@host:port`，端口省略时取 22。
public struct Endpoint: Equatable {
    public let user: String
    public let host: String
    public let port: Int

    public init(user: String, host: String, port: Int = 22) {
        self.user = user
        self.host = host
        self.port = port
    }

    public enum ParseError: Error, Equatable {
        case emptyUser
        case emptyHost
        case badPort
        case missingHost
    }

    /// 接受 `host`、`user@host`、`host:2222`、`user@host:2222`。
    /// `user` 缺省时用 `defaultUser`。
    public static func parse(_ raw: String, defaultUser: String = "root") throws -> Endpoint {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.missingHost }

        var rest = trimmed
        var user = defaultUser
        if let at = rest.firstIndex(of: "@") {
            user = String(rest[rest.startIndex..<at])
            rest = String(rest[rest.index(after: at)...])
            guard !user.isEmpty else { throw ParseError.emptyUser }
        }
        guard !rest.isEmpty else { throw ParseError.missingHost }

        var host = rest
        var port = 22
        // IPv6 字面量形如 [::1]:22；方括号内的冒号不算端口分隔。
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw ParseError.missingHost }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest.index(after: close)
            if after < rest.endIndex {
                guard rest[after] == ":" else { throw ParseError.missingHost }
                let digits = String(rest[rest.index(after: after)...])
                guard let value = Int(digits), (1...65535).contains(value) else { throw ParseError.badPort }
                port = value
            }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[rest.startIndex..<colon])
            let digits = String(rest[rest.index(after: colon)...])
            guard let value = Int(digits), (1...65535).contains(value) else { throw ParseError.badPort }
            port = value
        }

        guard !host.isEmpty else { throw ParseError.emptyHost }
        return Endpoint(user: user, host: host, port: port)
    }
}
