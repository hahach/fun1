import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 隧道自检：在取 token 之前先打一次本地端口，把「隧道死了」和「token 不对」分开。
///
/// 两者在界面上都表现为「连不上」，但处置完全不同：前者要重建 SSH，
/// 后者只要换一条日志里的新 token。
public struct TunnelProbe: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// 本地端口应答了（状态码 401 也算通：说明隧道与实例都在）。
        case ok(status: Int)
        /// 端口接受连接但没有回任何字节：direct-tcpip 通道没通。
        case noResponse
        /// 连本地端口都失败：转发器没在监听或 SSH 连接已断。
        case unreachable(String)
    }

    public let outcome: Outcome
    public let milliseconds: Int

    public init(outcome: Outcome, milliseconds: Int) {
        self.outcome = outcome
        self.milliseconds = milliseconds
    }

    public var timedOut: Bool {
        if case .noResponse = outcome { return true }
        return false
    }

    public var isAlive: Bool {
        if case .ok = outcome { return true }
        return false
    }

    public var summary: String {
        switch outcome {
        case .ok(let status): return "HTTP \(status)，\(milliseconds) ms"
        case .noResponse: return "端口通但无响应（\(milliseconds) ms）"
        case .unreachable(let reason): return "连不上本地端口：\(reason)"
        }
    }

    public static func check(localPort: Int, timeout: TimeInterval = 3) async -> TunnelProbe {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/") else {
            return TunnelProbe(outcome: .unreachable("本地端口非法"), milliseconds: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return TunnelProbe(outcome: .ok(status: (response as? HTTPURLResponse)?.statusCode ?? 0), milliseconds: ms)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let urlError = error as? URLError, urlError.code == .timedOut {
                return TunnelProbe(outcome: .noResponse, milliseconds: ms)
            }
            return TunnelProbe(outcome: .unreachable(error.localizedDescription), milliseconds: ms)
        }
    }
}
