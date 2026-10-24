import Foundation
import DshClientCore

/// 把 rowel 的端点层直接架在 dsh 的 mux 上：不再经过 Bridle，也不做 Noise。
///
/// `call` 走 `POST /api/<endpoint>`，`open` 走 `/api/remote.mux` 的逻辑流；
/// 两者的线格式在 Core 里已有实现，这里只做 `JSONValue` 与 `Any` 的换算。
final class DshTransport: HarnessTransport, @unchecked Sendable {
    private var rpc: DshRPC
    /// 整栈重连后本地端口与凭据都会变，故不是常量。
    private var mux: DshMux
    /// 终端页复用同一条 SSH 连接。
    let dshSession: DshSession

    init(session: DshSession) {
        dshSession = session
        rpc = DshRPC(baseURL: session.baseURL, credentials: session.credentials)
        mux = DshMux(port: session.localPort, credentials: session.credentials)
    }

    /// 建立 mux 的物理连接；失败会让所有流立刻报错。
    func connect() async throws {
        try await mux.connect()
    }

    /// 凭据失效或流断开时重建。
    ///
    /// 先走轻量路径（重取 token/cookie + 重建 mux）。SSH 连接本身已死时（后台挂起后
    /// 回前台最常见，表现为 `creatingChannelAfterClosure` 与本地端口不再监听）这条路径
    /// 必然失败，此时整栈重建：SSH 连接、本地转发、token 全部重来。
    func refresh() async throws {
        Diagnostics.shared.log(.info, "传输", "重连：先试轻量路径（重取凭据 + 重建 mux）")
        do {
            let fresh = try await dshSession.refreshCredentials()
            rpc = DshRPC(baseURL: dshSession.baseURL, credentials: fresh)
            try await mux.reconnect()
            Diagnostics.shared.log(.info, "传输", "轻量重连成功")
        } catch {
            Diagnostics.shared.log(.warn, "传输", "轻量重连失败：\(DshBoard.message(error))，改为整栈重建")
            await mux.close()
            // 刚回前台时整栈重建本身也可能撞上还没散尽的旧套接字（io close channel）。
            // 重试一次，仍失败才把错误交给上层。
            do {
                try await rebuild()
                Diagnostics.shared.log(.info, "传输", "整栈重建成功")
            } catch {
                Diagnostics.shared.log(.warn, "传输", "整栈重建失败：\(DshBoard.message(error))，600ms 后重试")
                try await Task.sleep(nanoseconds: 600_000_000)
                try await rebuild()
                Diagnostics.shared.log(.info, "传输", "整栈重建重试成功")
            }
        }
    }

    /// 整栈重建：SSH 连接、本地转发、凭据、mux 全部换新。
    private func rebuild() async throws {
        try await dshSession.restart()
        rpc = DshRPC(baseURL: dshSession.baseURL, credentials: dshSession.credentials)
        let rebuilt = DshMux(port: dshSession.localPort, credentials: dshSession.credentials)
        try await rebuilt.connect()
        mux = rebuilt
    }

    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
        do {
            let value = try await rpc.call(endpoint, args: args.toAny())
            return JSONValue(any: value)
        } catch {
            Diagnostics.shared.log(.fail, "调用", "\(endpoint)：\(DshBoard.message(error))")
            throw error
        }
    }

    func open(_ endpoint: String, _ args: JSONValue) async -> TunnelStream {
        let sid = UUID().uuidString
        do {
            let stream = try mux.open(endpoint: endpoint, payload: ["args": args.toAny()])
            let items = AsyncThrowingStream<JSONValue, Error> { continuation in
                let task = Task {
                    do {
                        for try await item in stream {
                            continuation.yield(JSONValue(any: item))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return TunnelStream(sid: sid, items: items, cancel: {})
        } catch {
            let items = AsyncThrowingStream<JSONValue, Error> { $0.finish(throwing: error) }
            return TunnelStream(sid: sid, items: items, cancel: {})
        }
    }
}

extension JSONValue {
    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map { $0.toAny() }
        case .object(let fields): return fields.mapValues { $0.toAny() }
        }
    }
}
