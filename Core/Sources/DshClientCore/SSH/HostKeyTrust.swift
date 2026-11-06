import Foundation
import Crypto
import NIOCore
import NIOSSH
import Citadel

/// 把 nio-ssh 交来的主机公钥折成 OpenSSH 公钥文本与 SHA256 指纹。
public enum HostKeyInspector {
    public static func openSSHString(_ key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key)
    }

    /// 指纹按「算法 base64」里的 base64 解码后的字节做 SHA256，与 ssh-keygen -lf 一致。
    public static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let text = openSSHString(key)
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return "SHA256:unknown"
        }
        return HostKeyFingerprint.sha256(of: [UInt8](blob))
    }
}

/// TOFU 主机信任：已知主机比对指纹；首次连接记录并放行；不匹配则拒绝。
/// 决策通过 `onDecision` 回传，供界面展示（首次连接的指纹、以及不匹配告警）。
public final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    public enum Decision: Equatable {
        case trusted
        case firstContact(fingerprint: String)
        case rejected(known: String, presented: String)
    }

    private let lock = NSLock()
    private var known: KnownHosts
    private let host: String
    private let port: Int
    private let onDecision: @Sendable (Decision) -> Void

    public init(known: KnownHosts, host: String, port: Int, onDecision: @escaping @Sendable (Decision) -> Void) {
        self.known = known
        self.host = host
        self.port = port
        self.onDecision = onDecision
    }

    public var snapshot: KnownHosts {
        lock.lock(); defer { lock.unlock() }
        return known
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKeyInspector.fingerprint(hostKey)
        lock.lock()
        let decision = known.decide(host: host, port: port, fingerprint: presented)
        switch decision {
        case .newHost:
            known.trust(host: host, port: port, fingerprint: presented)
        case .match, .mismatch:
            break
        }
        lock.unlock()

        switch decision {
        case .newHost:
            onDecision(.firstContact(fingerprint: presented))
            validationCompletePromise.succeed(())
        case .match:
            onDecision(.trusted)
            validationCompletePromise.succeed(())
        case .mismatch(let previous):
            onDecision(.rejected(known: previous, presented: presented))
            validationCompletePromise.fail(HostKeyRejected())
        }
    }
}

public struct HostKeyRejected: Error, Equatable {
    public init() {}
}
