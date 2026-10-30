import Foundation

/// 调试用：把诊断日志经现有 SSH 连接追加到主机的缓存目录。
///
/// 写入目标是 `$HOME/.cache/dsh-ios-debug`（由 shell 展开 $HOME，公开仓源码里不出现主机路径）；
/// 主机侧 `.tmp/ios-app/logs` 是指向它的软链，清理任一侧即可，软链由窗口重建。
final class RemoteLog {
    static let shared = RemoteLog()

    private let lock = NSLock()
    private var buffer: [String] = []
    private var sink: ((String) async -> Void)?
    private var timer: Task<Void, Never>?
    private let directory = "$HOME/.cache/dsh-ios-debug"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "debug.remoteLog") }

    func attach(_ sink: @escaping (String) async -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.flush()
            }
        }
    }

    func append(_ line: String) {
        guard isEnabled else { return }
        lock.lock()
        buffer.append(RemoteLog.stamp() + " " + RemoteLog.redact(line))
        let shouldFlush = buffer.count >= 20
        lock.unlock()
        if shouldFlush { Task { await self.flush() } }
    }

    func flush() async {
        lock.lock()
        guard !buffer.isEmpty, let sink else { lock.unlock(); return }
        let lines = buffer
        buffer.removeAll()
        lock.unlock()

        let payload = lines.joined(separator: "\n") + "\n"
        let encoded = Data(payload.utf8).base64EncodedString()
        let file = directory + "/app-" + RemoteLog.day() + ".log"
        await sink("mkdir -p \"\(directory)\" && printf %s '\(encoded)' | base64 -d >> \"\(file)\"")
    }

    /// token / cookie 一律打码。
    static func redact(_ text: String) -> String {
        var out = text
        for pattern in ["token=[^&\\s]+", "dsh-auth-[^=\\s]+=[^;\\s]+", "cookie[^;\\n]*"] {
            out = out.replacingOccurrences(of: pattern, with: "«redacted»", options: .regularExpression)
        }
        return out
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func stamp() -> String { stampFormatter.string(from: Date()) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func day() -> String { dayFormatter.string(from: Date()) }
}
