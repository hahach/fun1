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
            return "主机上找不到带 token 的启动 URL（dsh-web 没在跑？）"
        case .notAuthorized(let status):
            return "候选 token 全被拒（HTTP \(status)）"
        case .noCookie:
            return "换到了 token 但没拿到 dsh-auth cookie"
        case .tunnelUnreachable(let reason):
            return "隧道不通：\(reason)"
        }
    }
}

/// 凭据链路：SSH exec 取启动 URL → 隧道内取 \`dsh-auth-*\` cookie。
///
/// 候选按来源分级：主机自己认定的当前实例（\`dsh-web url\`）在最前，其次 journald、
/// 最后 \`~/.dsh/dsh-web.log\`；各来源内部按新到旧。旧 token 只会得到 401，
/// 因此 401 视为「这条候选过期」继续下一条；网络层失败计入总配额，不因单条超时就判隧道死。
public enum DshBootstrap {
    public static let cookiePrefix = "dsh-auth-"
    /// 日志里没有端口时的兜底（dsh-web 默认 3080）。
    public static let fallbackPort = 3080
    /// 最多试几条候选：权威源一条 + 两个来源各一条兜底。
    public static let maxCandidates = 3
    /// 全部候选合计最多容忍几次网络层失败：够「同一条重试一次 + 换下一条」，
    /// 又不至于在死隧道上把每条候选都等满超时。
    public static let maxNetworkFailures = 3

    /// 解析主机输出：端口取排最前的候选，候选按来源分级后新到旧、按 token 去重。
    public static func resolve(
        runner: CommandRunner,
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> DshTarget {
        let output = try await runner.run(DshCommands.launchURLCandidates)
        let all = LaunchURL.parseAll(from: output)
        guard !all.isEmpty else { throw BootstrapError.noLaunchURL }

        var seen = Set<String>()
        var picked: [LaunchURL] = []
        func take(_ urls: [LaunchURL]) {
            for url in urls where seen.insert(url.token).inserted {
                picked.append(url)
            }
        }
        // 来源内部按新到旧；来源之间按权威性。
        let authoritative = all.filter { $0.source == .authoritative }
        take(authoritative.reversed())
        take(all.filter { $0.source == .journal }.reversed())
        take(all.filter { $0.source == .logFile }.reversed())
        take(all.filter { $0.source == .unknown }.reversed())
        picked = Array(picked.prefix(maxCandidates))

        guard let newest = picked.first else { throw BootstrapError.noLaunchURL }
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
        var networkFailures = 0
        var lastReason = ""

        for (index, candidate) in candidates.enumerated() {
            let label = "候选 \(index + 1)（\(candidate.source == .unknown ? "未知来源" : sourceLabel(candidate.source))）"
            // 同一条候选最多两次：首次超时可能是隧道刚建好的抖动。
            for attempt in 1...2 {
                do {
                    let result = try await fetcher.get(candidate.tunnelled(localPort: localPort))
                    lastStatus = result.status
                    if (200..<400).contains(result.status), let credentials = cookie(from: result.setCookie) {
                        onAttempt("\(label)：成功")
                        return credentials
                    }
                    onAttempt("\(label)：HTTP \(result.status)\(result.status == 401 || result.status == 403 ? "（token 过期）" : "")")
                    break
                } catch {
                    networkFailures += 1
                    // 带上是哪一层失败：超时 / 连接被重置 / ATS 拦下，三种处置完全不同。
                    lastReason = describe(error)
                    onAttempt("\(label) 第 \(attempt) 次：无响应（\(lastReason)）")
                    if networkFailures >= maxNetworkFailures {
                        throw BootstrapError.tunnelUnreachable(reason: "连续 \(networkFailures) 次请求无响应，最后一次：\(lastReason)")
                    }
                    if attempt == 1 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }
        }
        if lastStatus == 401 || lastStatus == 403 {
            throw BootstrapError.notAuthorized(status: lastStatus)
        }
        if networkFailures > 0, lastStatus == 0 {
            throw BootstrapError.tunnelUnreachable(reason: "候选全部无响应，最后一次：\(lastReason)")
        }
        throw BootstrapError.noCookie
    }

    /// 失败原因带上错误域与码：iOS 上 ATS 拦截、连接被对端关闭、读超时的表现都是「没有响应」。
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription)（\(nsError.domain) \(nsError.code)）"
    }

    static func sourceLabel(_ source: LaunchURL.Source) -> String {
        switch source {
        case .authoritative: return "主机当前实例"
        case .journal: return "journald"
        case .logFile: return "dsh-web.log"
        case .unknown: return "未知来源"
        }
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