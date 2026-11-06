import Foundation

/// 列表页首屏的本地副本：`session/list` 与 `workspace/follow` 的 baseline。
///
/// 进 App 时先画上次的结果，「归档（0）→ 工作区」那半秒空窗就没了；网络回来整体替换。
/// 只存服务端原样返回的 JSON，不存任何派生态。
enum BoardCache {
    private static let sessionsName = "sessions.json"
    private static let workspacesName = "workspaces.json"

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("board", isDirectory: true)
    }

    static func saveSessions(_ value: JSONValue) { write(value, name: sessionsName) }
    static func saveWorkspaces(_ value: JSONValue) { write(value, name: workspacesName) }

    static func loadSessions() -> JSONValue? { read(name: sessionsName) }
    static func loadWorkspaces() -> JSONValue? { read(name: workspacesName) }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func write(_ value: JSONValue, name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value.toAny()) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func read(name: String) -> JSONValue? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(any: object)
    }
}
