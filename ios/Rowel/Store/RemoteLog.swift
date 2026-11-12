import Foundation

/// 调试用：把诊断日志经现有 SSH 连接追加到主机的缓存目录。
///
/// 写入目标是 `$HOME/.cache/dsh-ios-debug`（由 shell 展开 $HOME，公开仓源码里不出现主机路径）；
/// 主机侧 `.tmp/ios-app/logs` 是指向它的软链，清理任一侧即可，软链由窗口重建。
///
/// 保留策略：进程内首次写入前删掉 14 天前的 `app-*.log`；当天文件超过 8 MB 时先转存为 `.1`（覆盖旧的 `.1`）。
final class RemoteLog {
    static let shared = RemoteLog()

    /// 保留天数：更早的按天文件在首次写入前删掉。
    private static let keepDays = 14
    /// 单文件上限（字节）：超过就转存为 `.1`。
    private static let sizeLimit = 8 * 1024 * 1024

    private let lock = NSLock()
    private var buffer: [String] = []
    /// 一条主机命令。可抛错：清理与轮转失败只记 warn，不影响写日志。
    private var sink: ((String) async throws -> Void)?
    private var timer: Task<Void, Never>?
    private let directory = "$HOME/.cache/dsh-ios-debug"
    /// 本进程是否已做过按天清理。
    private var didSweep = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "debug.remoteLog") }

    func attach(_ sink: @escaping (String) async throws -> Void) {
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

    /// 断开 sink 并停掉定时器：关掉开关后不再持有旧连接。
    func detach() {
        lock.lock()
        sink = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
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
        let sweepNow = !didSweep
        didSweep = true
        lock.unlock()

        let file = directory + "/app-" + RemoteLog.day() + ".log"
        if sweepNow { await sweep(sink) }
        await rotate(sink, file: file)

        let payload = lines.joined(separator: "\n") + "\n"
        let encoded = Data(payload.utf8).base64EncodedString()
        try? await sink("mkdir -p \"\(directory)\" && printf %s '\(encoded)' | base64 -d >> \"\(file)\"")
    }

    /// 按天清理：删掉超过保留天数的按天文件。目录不存在时什么也不做；失败只记一条 warn。
    private func sweep(_ sink: (String) async throws -> Void) async {
        let command = "if [ -d \"\(directory)\" ]; then "
            + "find \"\(directory)\" -name 'app-*.log' -type f -mtime +\(RemoteLog.keepDays) -delete"
            + "; fi"
        do {
            try await sink(command)
        } catch {
            Diagnostics.shared.log(.warn, "调试", "远端日志 清理失败")
        }
    }

    /// 单文件上限：当天文件超过上限时先转存为 `.1`（覆盖旧的 `.1`）。文件或目录不存在时什么也不做；失败只记一条 warn。
    private func rotate(_ sink: (String) async throws -> Void, file: String) async {
        let command = "if [ \"$(stat -c%s \"\(file)\" 2>/dev/null || echo 0)\" -gt \(RemoteLog.sizeLimit) ]; then "
            + "mv -f \"\(file)\" \"\(file).1\""
            + "; fi"
        do {
            try await sink(command)
        } catch {
            Diagnostics.shared.log(.warn, "调试", "远端日志 轮转失败")
        }
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
