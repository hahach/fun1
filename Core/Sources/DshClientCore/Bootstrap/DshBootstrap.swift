import Foundation

/// 换到的 dsh 会话凭据：cookie 名与值。token 用完即弃，不落盘。
public struct DshCredentials: Equatable, Sendable {
    public let cookieName: String
    public let cookieValue: String

    public init(cookieName: String, cookieValue: String) {
        self.cookieName = cookieName
        self.cookieValue = cookieValue
    }
}

/// 一次解析的结果：隧道该指向哪个端口，以及按新到旧排好的候选 token。
public struct DshTarget: Equatable, Sendable {
    public let port: Int
    public let candidates: [LaunchURL]

    public init(port: Int, candidates: [LaunchURL]) {
        self.port = port
        self.candidates = candidates
    }
}

public enum BootstrapError: Error, Equatable {
    case noLaunchURL
    case notAuthorized(status: Int)
    case noCookie
    /// 网络层失败：换 token 无用，要重建隧道。
    case tunnelUnreachable(reason: String)

    public var isTunnelProblem: Bool {
        if case .tunnelUnreachable = self { return true }
        return false
    }
}

extension BootstrapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noLaunchURL:
            return "主机日志里找不到带 token 的启动 URL（dsh-web 没在跑？）"
        case .notAuthorized(let status):
            return "候选 token 全被拒（HTTP \(status)）"
        case .noCookie:
            return "换到了 token 但没拿到 dsh-auth cookie"
        case .tunnelUnreachable(let reason):
            return "隧道不通：\(reason)"
        }
    }
}

/// 凭据链路：SSH exec 取日志里的启动 URL → 隧道内取 `dsh-auth-*` cookie。
///
/// 只认日志里最新的那条（`dsh-web url` 的口径）。旧 token 只会得到 401，
/// 因此旧行仅作 401 时的后备；网络层失败一律立即上抛，不在十几个旧 token 上干等。
public enum DshBootstrap {
    public static let cookiePrefix = "dsh-auth-"
    /// 日志里没有端口时的兜底（dsh-web 默认 3080）。
    public static let fallbackPort = 3080
    /// 最多试几条候选：最新一条 + 两条后备。
    public static let maxCandidates = 3

    /// 解析主机日志：端口取最新一条 URL 的端口，候选按新到旧、按 token 去重。
    public static func resolve(
        runner: CommandRunner,
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> DshTarget {
        let output = try await runner.run(DshCommands.launchURLCandidates)
        let all = LaunchURL.parseAll(from: output)
        guard let newest = all.last else { throw BootstrapError.noLaunchURL }

        var seen = Set<String>()
        var picked: [LaunchURL] = []
        for url in all.reversed() where seen.insert(url.token).inserted {
            picked.append(url)
            if picked.count >= maxCandidates { break }
        }
        let port = newest.port > 0 ? newest.port : fallbackPort
        onAttempt("日志 \(all.count) 条启动 URL → 端口 \(port)，候选 \(picked.count) 条")
        return DshTarget(port: port, candidates: picked)
    }

    public static func run(
        runner: CommandRunner,
        fetcher: HTTPFetching,
        localPort: Int,
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> DshCredentials {
        let target = try await resolve(runner: runner, onAttempt: onAttempt)
        return try await run(
            fetcher: fetcher,
            localPort: localPort,
            candidates: target.candidates,
            onAttempt: onAttempt
        )
    }

    public static func run(
        fetcher: HTTPFetching,
        localPort: Int,
        candidates: [LaunchURL],
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> DshCredentials {
        guard !candidates.isEmpty else { throw BootstrapError.noLaunchURL }

        var lastStatus = 0
        for (index, candidate) in candidates.enumerated() {
            // 刚建好的隧道首个请求偶发超时，同一条候选再打一次；仍失败即判隧道不通。
            for attempt in 1...2 {
                do {
                    let result = try await fetcher.get(candidate.tunnelled(localPort: localPort))
                    lastStatus = result.status
                    if (200..<400).contains(result.status), let credentials = cookie(from: result.setCookie) {
                        onAttempt("候选 \(index + 1)：成功")
                        return credentials
                    }
                    onAttempt("候选 \(index + 1)：HTTP \(result.status)")
                    break
                } catch {
                    onAttempt("候选 \(index + 1)：\(error.localizedDescription)")
                    if attempt == 2 {
                        throw BootstrapError.tunnelUnreachable(reason: error.localizedDescription)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        if lastStatus == 401 || lastStatus == 403 {
            throw BootstrapError.notAuthorized(status: lastStatus)
        }
        throw BootstrapError.noCookie
    }

    static func cookie(from setCookie: [String]) -> DshCredentials? {
        for line in setCookie {
            let pair = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix(cookiePrefix), !value.isEmpty {
                return DshCredentials(cookieName: name, cookieValue: value)
            }
        }
        return nil
    }
}
