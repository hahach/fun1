import Foundation
import Crypto

/// SSH 主机公钥指纹：`SHA256:<base64 无填充>`，与 `ssh-keygen -lf` 的 SHA256 形式一致。
public enum HostKeyFingerprint {
    public static func sha256(of keyBlob: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(keyBlob))
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
    }

    /// 指纹比对：忽略用户粘贴时的空白与换行。
    public static func matches(_ expected: String, _ actual: String) -> Bool {
        func normalise(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalise(expected) == normalise(actual)
    }
}

/// TOFU 记录：已知主机 → 指纹。
public struct KnownHosts {
    public enum Decision: Equatable {
        case newHost
        case match
        case mismatch(known: String)
    }

    private var entries: [String: String]

    public init(entries: [String: String] = [:]) {
        self.entries = entries
    }

    /// 供档案存储来回转换。
    public init(rawEntries: [String: String]) {
        self.entries = rawEntries
    }

    public var rawEntries: [String: String] {
        entries
    }

    /// `host:port` 作为键，同一主机换端口视为不同端点。
    public static func key(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    public func decide(host: String, port: Int, fingerprint: String) -> Decision {
        guard let known = entries[Self.key(host: host, port: port)] else { return .newHost }
        return known == fingerprint ? .match : .mismatch(known: known)
    }

    public mutating func trust(host: String, port: Int, fingerprint: String) {
        entries[Self.key(host: host, port: port)] = fingerprint
    }

    public var serialised: String {
        entries.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: "\n")
    }

    public static func parse(_ text: String) -> KnownHosts {
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            entries[String(parts[0])] = String(parts[1])
        }
        return KnownHosts(entries: entries)
    }
}
