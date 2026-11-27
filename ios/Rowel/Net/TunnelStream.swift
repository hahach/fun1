/// 分叉 B2：以下两个类型原本定义在 `Net/Tunnel.swift`，随上游隧道删除前原样搬来。
///
/// `TunnelStream` 是 `HarnessTransport.open` 的返回类型（`Net/Harness.swift`、
/// `Net/DshTransport.swift` 都在用）；`ConnectionNote` 是诊断界面的一行连接日志。

import Foundation

/// One dsh stream through the tunnel.
///
/// `items` ends when dsh ends the stream and throws when it fails; see
/// `Tunnel.open`. Iterate it from one task. `cancel` stops the stream at dsh —
/// as does cancelling the task that iterates it.
public struct TunnelStream: Sendable {
    public let sid: String
    public let items: AsyncThrowingStream<JSONValue, Error>
    public let cancel: @Sendable () -> Void
}

/// One line in the connection log.
///
/// This exists because of a bug that took forty minutes to find and would have
/// taken ten seconds to read: the app had shipped pointing at a relay hostname
/// that had moved, and every screen it could show said "Reaching…". There was
/// no way, from the phone, to learn which address it was dialling or what came
/// back — and the phone is the only place the failing network exists. A Mac
/// cannot reproduce a carrier's route to Cloudflare.
///
/// **Never contains a key, a token, a path, or anything from a conversation.**
/// Host and port, a verdict, and a duration. That bound is what lets this be
/// always-on and screenshot-safe rather than a debug mode someone has to have
/// enabled *before* the thing they need to diagnose.
public struct ConnectionNote: Identifiable, Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// Starting something.
        case attempt
        /// It worked.
        case ok
        /// It did not.
        case fail
    }

    public let id: Int
    public let at: Date
    public let level: Level
    public let text: String
}
