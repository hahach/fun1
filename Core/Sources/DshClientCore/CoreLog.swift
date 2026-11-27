import Foundation

/// Core 侧的日志出口。
///
/// Core 是平台中立层（Linux 上跑 `swift test`），不能引用 App 的 `Diagnostics`（那个类带 UIKit）。
/// 于是把「谁来记」做成一个可安装的 sink：App 启动时把 `Diagnostics.shared.log` 挂上来，
/// 标签与级别原样透传；没人挂时静默（单测与 `dsh-probe` 即此路径）。
///
/// 标签沿用现有三个：`连接` / `传输` / `终端`。App 侧一行：
///
/// ```swift
/// CoreLog.shared.install { level, source, text in
///     switch level {
///     case .info: Diagnostics.shared.log(.info, source, text)
///     case .warn: Diagnostics.shared.log(.warn, source, text)
///     case .fail: Diagnostics.shared.log(.fail, source, text)
///     }
/// }
/// ```
public final class CoreLog: @unchecked Sendable {
    public enum Level: Sendable, Equatable {
        case info
        case warn
        case fail
    }

    public static let shared = CoreLog()

    private let lock = NSLock()
    private var handler: (@Sendable (Level, String, String) -> Void)?

    private init() {}

    /// 装上日志出口。多次安装以最后一次为准。
    public func install(_ handler: @escaping @Sendable (Level, String, String) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// 卸下日志出口（回到静默）。
    public func uninstall() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    /// 记一条。没装出口时什么都不做：这条链路不能因为日志把连接流程拖住。
    public func log(_ level: Level, _ source: String, _ text: String) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(level, source, text)
    }
}
