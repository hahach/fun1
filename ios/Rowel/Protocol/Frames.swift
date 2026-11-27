/// Wire types the app shares with the Bridle.
///
/// Three of them, and each is a value the app states or is told: `CallError`,
/// the failure shape both ends report; `ReadyFrame`, what a machine says about
/// itself when it comes up; and `HarnessInfo`, which harness a Bridle identity
/// fronts and where that identity lives.

import Foundation

/// A harness call that failed, or a tunnel that could not carry it.
public struct CallError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue

    public init(code: String, message: String, details: JSONValue = .null) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// The connection went away — before the call was sent (`disconnected`) or
    /// after, while its answer was on the way (`interrupted`). A reconnect is
    /// coming either way, so a read can simply be asked again then.
    public var isConnectionLoss: Bool {
        code == "disconnected" || code == "interrupted"
    }

    /// The call left this device and its answer did not come back, so whether
    /// it took effect is unknown. A write in this state must not be reported as
    /// "didn't send": it may well have, and sending it again would do it twice.
    public var outcomeUnknown: Bool {
        code == "interrupted" || code == "timeout"
    }
}

extension CallError: LocalizedError {
    public var errorDescription: String? { message }
}

extension CallError {
    /// A failure in dsh's shape, `{code, message, details}`.
    init(_ error: JSONValue?, fallback: String) {
        self.init(
            code: error?["code"]?.stringValue ?? "internal",
            message: error?["message"]?.stringValue ?? fallback,
            details: error?["details"] ?? .null
        )
    }
}

/// Which harness a Bridle identity fronts, and where the identity lives.
///
/// One Mac can run several Bridles; until the app knows which one it is
/// talking to, every offline screen says the same name and every rescue
/// command defaults to the wrong home. Optional end to end: a Bridle too old
/// to send it costs the app a label, nothing more.
public struct HarnessInfo: Equatable, Sendable {
    /// The dsh address this identity points at, e.g. `http://127.0.0.1:3081`.
    public let url: String
    /// The `ROWEL_HOME` the identity lives in on the Mac.
    public let home: String

    public init(url: String, home: String) {
        self.url = url
        self.home = home
    }

    /// The port, which is how a person tells instances apart.
    public var port: String? {
        guard let colon = url.lastIndex(of: ":"), colon != url.startIndex else { return nil }
        let digits = url[url.index(after: colon)...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }
}

/// Connection is live; describes the machine and its harness.
public struct ReadyFrame: Sendable {
    public let version: Int
    public let bridle: String
    public let machine: String
    /// Whether the Bridle holds a signed-in connection to dsh right now.
    public let dshReachable: Bool
    /// Why not, in words a person can act on, when it does not.
    public var detail: String? = nil
    /// dsh's version, when the Bridle knows it.
    public var dsh: String? = nil
    /// Which harness, and where the identity lives.
    public let harness: HarnessInfo?
    /// The Mac account's home directory: where the folder picker starts.
    /// dsh 0.2 no longer describes the machine through a method, so the Bridle
    /// says it here.
    public var home: String? = nil
    /// Where this machine can be dialled directly right now, best first.
    ///
    /// `nil` from a Bridle too old to send it — which must leave the app's
    /// stored addresses alone. `[]` is different and deliberate: it means the
    /// direct listener is off, and keeping stale addresses around would have
    /// the app dialling a listener the operator turned off.
    public let direct: [String]?
}
