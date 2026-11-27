/// The lock in front of the app.
///
/// iOS already locks the phone. This is the second lock, and it exists because
/// of what this app can do rather than what it holds: a paired phone can
/// approve a shell command on someone's Mac. The gap the system lock leaves is
/// an *unlocked* phone in the wrong hands — handed over, snatched at a table,
/// left on a desk — and in that gap Rowel is a remote shell with no further
/// challenge.
///
/// It cannot make the phone safe. What it can do is put a bound on the window:
/// after the idle timeout the app is useless to whoever is holding it, and the
/// owner has until then to run `bridle revoke`.
///
/// Two states, deliberately separate:
///
/// - **Covered** — the content is hidden but no authentication is owed. This is
///   for the app switcher, which photographs the screen the moment the app stops
///   being frontmost. A lock that only engages on `.background` shows the whole
///   transcript in that snapshot.
/// - **Locked** — authentication is owed before the content comes back.
///
/// Everything here is injectable, because the interesting cases are a clock
/// moving and biometry failing, and neither can be arranged on a simulator.

import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

// MARK: - Authentication

/// Why an authentication attempt did not succeed.
public enum AuthFailure: Equatable {
    /// The person cancelled, or biometry rejected them. They can try again.
    case refused
    /// This device cannot authenticate anyone — no passcode, no biometry.
    ///
    /// Distinct from `refused` because the remedy is the opposite: there is
    /// nothing to retry, and holding the door shut would lock the owner out of
    /// their own tool with no way back in.
    case unavailable
}

/// Whatever proves the person holding the phone is its owner.
public protocol Authenticator: Sendable {
    /// Whether an attempt could succeed at all.
    func isAvailable() -> Bool
    /// Ask. Returns nil on success.
    func authenticate(reason: String) async -> AuthFailure?
}

/// Face ID, Touch ID, or the device passcode.
public struct DeviceAuthenticator: Authenticator {
    public init() {}

    public func isAvailable() -> Bool {
        #if canImport(LocalAuthentication)
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        #else
        return false
        #endif
    }

    public func authenticate(reason: String) async -> AuthFailure? {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        // `.deviceOwnerAuthentication`, not the biometrics-only policy. A face
        // that stops being recognised — a mask, a bandage, a bad angle in the
        // dark — must not cost someone access to their own machine, and the
        // passcode fallback is what the system lock screen itself falls back to.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? nil : .refused
        } catch let failure as LAError where failure.code == .passcodeNotSet || failure.code == .biometryNotAvailable {
            return .unavailable
        } catch {
            return .refused
        }
        #else
        return .unavailable
        #endif
    }
}

// MARK: - Idle timeout

/// How long the app may sit in the background before it locks.
public enum LockDelay: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 minute"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        }
    }

    public var seconds: TimeInterval { TimeInterval(rawValue) }
}

// MARK: - The lock

@MainActor
@Observable
public final class AppLock {
    /// Hide the content. True whenever the app is not frontmost, and while locked.
    public private(set) var isCovered: Bool
    /// Authentication is owed.
    public private(set) var isLocked: Bool
    /// The last attempt was refused, so the screen can say so instead of looking broken.
    public private(set) var lastAttemptRefused = false
    /// An attempt is in flight; the button should not start a second one.
    public private(set) var authenticating = false

    /// Whether the lock is on at all.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            // Turning it off must take effect now. Leaving someone staring at a
            // lock screen after they switched the lock off would be a bug they
            // could not reason their way out of.
            if !isEnabled { unlockWithoutAuthenticating() }
        }
    }

    /// How long the app may be away before it locks.
    public var delay: LockDelay {
        didSet {
            guard delay != oldValue else { return }
            defaults.set(delay.rawValue, forKey: Keys.delay)
        }
    }

    /// Whether this device can authenticate at all. Drives the settings copy.
    public var canAuthenticate: Bool { authenticator.isAvailable() }

    private let authenticator: Authenticator
    private let defaults: UserDefaults
    private let now: () -> Date
    /// When the app stopped being frontmost. Nil while it is.
    private var leftAt: Date?

    private enum Keys {
        static let enabled = "rowel.lock.enabled.v1"
        static let delay = "rowel.lock.delay.v1"
    }

    /// - Parameter enabledByDefault: 未选择过时的默认值。单元测试宿主用 `false` 启动：
    ///   测试进程也会跑 App 的界面层，锁开着就会在启动时弹系统认证面板，
    ///   面板在模拟器里不会结束，整个测试进程都停在「认证中」。
    public init(
        authenticator: Authenticator = DeviceAuthenticator(),
        defaults: UserDefaults = .standard,
        enabledByDefault: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.defaults = defaults
        self.now = now

        // On by default, because the person who most needs this is the one who
        // would never go looking for it. Off — and unreachable — where the
        // device cannot authenticate, since enabling it there would produce a
        // lock screen with no key.
        // `object(forKey:)` to tell "never chosen" from "chosen off", then
        // `bool(forKey:)` to read it. Not `object(...) as? Bool`: a `-key NO`
        // launch argument arrives in the argument domain as the *string* "NO",
        // which fails that cast and silently reads as "never chosen" — so the
        // default wins and the setting appears not to work.
        let chosen = defaults.object(forKey: Keys.enabled) != nil
        let on = enabledByDefault && authenticator.isAvailable()
            && (chosen ? defaults.bool(forKey: Keys.enabled) : true)

        // A cold launch is an arrival from outside, so it starts locked. These
        // come first because `isEnabled` has a `didSet`, and a property with an
        // observer cannot be read until every stored property has a value.
        isLocked = on
        isCovered = on
        isEnabled = on
        // `integer(forKey:)` answers 0 for a key that was never set, and 0 is
        // `.immediately` — a real case, not a sentinel. So the `?? .oneMinute`
        // that used to be here never once ran, and every fresh install locked
        // on every departure instead of after a minute. Check for the key.
        delay = defaults.object(forKey: Keys.delay) == nil
            ? .oneMinute
            : LockDelay(rawValue: defaults.integer(forKey: Keys.delay)) ?? .oneMinute
    }

    // MARK: - Lifecycle

    /// The app stopped being frontmost — including the brief `.inactive` of a
    /// control-centre pull, which is also when the switcher takes its picture.
    public func willResignActive() {
        isCovered = true
        // Authenticating is not leaving. The system's Face ID and passcode
        // sheets make the app inactive while they are up, so counting that as a
        // departure means the act of unlocking re-locks — and at
        // `.immediately`, which was silently the default, that is an infinite
        // loop the only escape from which is force-quitting.
        // The same is true of a sheet the *other* gate raised: `SensitiveGate`
        // keeps its own flag, which this lock cannot see, so `AuthActivity` is
        // what tells it that the departure was not the owner's.
        if authenticating {
            Diagnostics.shared.log(.info, "认证", "离开前台：锁正在验证，不记离开")
            return
        }
        if AuthActivity.isActive {
            Diagnostics.shared.log(.info, "认证", "离开前台：别的面板在显示，不记离开")
            return
        }
        // Only the first real departure counts. `.inactive` then `.background`
        // fires twice, and restarting the clock on the second would hand back
        // the seconds already spent away.
        guard leftAt == nil else { return }
        leftAt = now()
        Diagnostics.shared.log(.info, "认证", "离开前台：锁开始计时")
    }

    /// The app is frontmost again.
    public func didBecomeActive() {
        // Coming back from the system's own prompt, mid-attempt. Leave every
        // piece of state alone: `unlock()` is still running and about to decide.
        guard !authenticating else {
            Diagnostics.shared.log(.info, "认证", "回前台：锁正在验证，保持状态")
            return
        }
        // Round trip through a sheet raised by the other gate, or by
        // `confirm(_:)` — not by this lock. That is not a departure and not an
        // arrival: drop the departure the sheet faked, take the cover down if
        // the content was legitimately showing, and leave the lock alone.
        if AuthActivity.isActive {
            leftAt = nil
            if !isLocked { isCovered = false }
            Diagnostics.shared.log(.info, "认证", "回前台：面板往返，收遮罩")
            return
        }
        defer { leftAt = nil }
        guard isEnabled else {
            isCovered = false
            isLocked = false
            Diagnostics.shared.log(.info, "认证", "回前台：锁未开启")
            return
        }
        if isLocked {
            isCovered = true
            Diagnostics.shared.log(.info, "认证", "回前台：已锁，保持锁屏")
            return
        }
        let away = leftAt.map { Int(now().timeIntervalSince($0)) } ?? 0
        if expired(since: leftAt) {
            isLocked = true
            isCovered = true
            Diagnostics.shared.log(.info, "认证", "回前台：离开 \(away) 秒，上锁")
        } else {
            isCovered = false
            Diagnostics.shared.log(.info, "认证", "回前台：离开 \(away) 秒，保持解锁")
        }
    }

    /// Whether an absence beginning at `departure` has outlasted the delay.
    private func expired(since departure: Date?) -> Bool {
        guard let departure else { return false }
        if delay == .immediately { return true }
        let elapsed = now().timeIntervalSince(departure)
        // A negative interval means the wall clock moved backwards while the app
        // was away. That is either a time-zone-sized accident or someone winding
        // the clock back to outrun the timeout; both are answered by locking.
        if elapsed < 0 { return true }
        return elapsed >= delay.seconds
    }

    // MARK: - Unlocking

    /// Ask for authentication and, if it is given, show the content.
    public func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        // Announce the sheet before it is up and withdraw it once it is gone,
        // so a scene-phase bounce in between is not read as leaving. Paired with
        // `end()` by `defer`, on every exit including the early returns below.
        AuthActivity.begin()
        defer { AuthActivity.end() }
        Diagnostics.shared.log(.info, "认证", "解锁：开始验证")

        switch await authenticator.authenticate(reason: "Rowel can approve commands on your Mac.") {
        case nil:
            lastAttemptRefused = false
            unlockWithoutAuthenticating()
            Diagnostics.shared.log(.info, "认证", "解锁：通过")
        case .refused:
            lastAttemptRefused = true
            Diagnostics.shared.log(.info, "认证", "解锁：拒绝，保持锁屏")
        case .unavailable:
            // The passcode was removed while the app was away, so there is no
            // longer anything to check. Open up and turn the setting off rather
            // than leave someone permanently outside their own paired machines.
            // This is not a way in: removing a passcode requires knowing it.
            lastAttemptRefused = false
            isEnabled = false
            Diagnostics.shared.log(.info, "认证", "解锁：设备不可用，关闭锁")
        }
    }

    /// Drop the lock without asking. For the two cases that have already been
    /// decided: the setting being switched off, and a successful attempt.
    private func unlockWithoutAuthenticating() {
        isLocked = false
        isCovered = false
        lastAttemptRefused = false
    }

    // MARK: - Guarding an action

    /// Require authentication before something irreversible.
    ///
    /// Used for the actions that cannot be undone from the phone — throwing away
    /// this device's key, forgetting a Mac. Approving a tool call is not one of
    /// them: the approval *is* the confirmation, and a Face ID prompt on every
    /// one would train people to authenticate without reading, which is worse
    /// than not asking.
    ///
    /// - Parameter reason: shown in the system prompt.
    /// - Returns: whether to proceed.
    public func confirm(_ reason: String) async -> Bool {
        guard isEnabled else { return true }
        // Same sheet, same problem: it makes the scene inactive, and `unlock`
        // and `SensitiveGate` both keep their own flag that cannot see it.
        AuthActivity.begin()
        defer { AuthActivity.end() }
        switch await authenticator.authenticate(reason: reason) {
        case nil: return true
        case .refused: return false
        // Consistent with `unlock`: a device that cannot authenticate must not
        // become a device whose owner cannot manage their own pairings.
        case .unavailable: return true
        }
    }
}
