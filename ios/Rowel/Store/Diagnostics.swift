import Foundation
import Combine
import UIKit

/// 一条可复制的运行日志。
///
/// 存在的唯一理由：真机出错时，能把原文交出去，而不是靠截图与手打。
/// 只在内存里（上限 400 条），不落盘。
struct DiagEntry: Identifiable, Equatable {
    enum Level: String {
        case info = "·"
        case warn = "!"
        case fail = "×"
    }

    let id = UUID()
    let at: Date
    let level: Level
    /// 谁记的：连接、传输、审批、终端……
    let source: String
    let text: String

    var line: String {
        let stamp = DiagEntry.formatter.string(from: at)
        return "\(stamp) \(level.rawValue) [\(source)] \(text)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// 客户端侧的日志环：各层打点，界面里整份复制或分享出去。
final class Diagnostics: ObservableObject, @unchecked Sendable {
    static let shared = Diagnostics()

    /// 保留多少条。
    private static let limit = 400

    private let lock = NSLock()
    private var storage: [DiagEntry] = []

    private init() {}

    var entries: [DiagEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 整份日志（最新的在最后），用于复制与分享。
    var transcript: String {
        entries.map(\.line).joined(separator: "\n")
    }

    func log(_ level: DiagEntry.Level = .info, _ source: String, _ text: String) {
        // 入口统一脱敏：内存 transcript 与剪贴板导出和远程日志同口径。
        let text = RemoteLog.redact(text)
        lock.lock()
        storage.append(DiagEntry(at: Date(), level: level, source: source, text: text))
        if storage.count > Self.limit { storage.removeFirst(storage.count - Self.limit) }
        lock.unlock()
        RemoteLog.shared.append("[\(level)] \(source) \(text)")
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    func log(_ source: String, _ error: Error) {
        log(.fail, source, DshBoard.message(error))
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        objectWillChange.send()
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = transcript
    }
}
