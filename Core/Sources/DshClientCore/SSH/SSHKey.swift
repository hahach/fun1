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
        do {
            return try Curve25519.Signing.PrivateKey(sshEd25519: trimmed)
        } catch {
            throw LoadError.notEd25519
        }
    }
}
