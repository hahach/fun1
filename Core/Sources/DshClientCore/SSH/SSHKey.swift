import Foundation
import Crypto
import Citadel

/// 只支持未加密的 OpenSSH ed25519 私钥（用户裁决的认证方式）。
public enum SSHKey {
    public enum LoadError: Error, Equatable {
        case empty
        case notEd25519
        case encrypted
    }

    /// 输入是 `-----BEGIN OPENSSH PRIVATE KEY-----` 开头的整份文件内容。
    /// 公钥指纹（与 ssh-keygen -lf 同形），用于界面只展示摘要而非私钥。
    public static func fingerprint(of pem: String) -> String? {
        guard let key = try? loadEd25519(pem) else { return nil }
        let publicKey = key.publicKey.rawRepresentation
        return HostKeyFingerprint.sha256(of: [UInt8](publicKey))
    }

    public static func loadEd25519(_ pem: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoadError.empty }
        guard !trimmed.contains("ENCRYPTED") else { throw LoadError.encrypted }
        guard trimmed.contains("BEGIN OPENSSH PRIVATE KEY") else { throw LoadError.notEd25519 }
        // OpenSSH 容器的加密标记在 base64 体里（ciphername ≠ none），文本层看不出；
        // 提前识别，避免加密钥被误报成 notEd25519。
        if isOpenSSHEncrypted(trimmed) == true { throw LoadError.encrypted }
        do {
            return try Curve25519.Signing.PrivateKey(sshEd25519: trimmed)
        } catch {
            throw LoadError.notEd25519
        }
    }

    /// 解开 base64 体读容器头：openssh-key-v1 魔串（含结尾 NUL）之后第一个字段
    /// 是长度前缀的 ciphername，值不是 "none" 即加密钥。结构对不上（损坏/非该
    /// 格式）返回 nil，交给密钥解析器给最终判定。
    static func isOpenSSHEncrypted(_ pem: String) -> Bool? {
        let body = pem.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { return nil }
        let bytes = [UInt8](data)
        let magic: [UInt8] = Array("openssh-key-v1".utf8) + [0]
        let nameOffset = magic.count
        guard bytes.count > nameOffset + 4, Array(bytes.prefix(nameOffset)) == magic else { return nil }
        let nameLength = (Int(bytes[nameOffset]) << 24) | (Int(bytes[nameOffset + 1]) << 16)
            | (Int(bytes[nameOffset + 2]) << 8) | Int(bytes[nameOffset + 3])
        guard (1...64).contains(nameLength), bytes.count >= nameOffset + 4 + nameLength else { return nil }
        let cipher = String(decoding: bytes[(nameOffset + 4)...].prefix(nameLength), as: UTF8.self)
        return cipher != "none"
    }
}
