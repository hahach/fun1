import Foundation
import XCTest
@testable import DshClientCore

private struct FakeRunner: CommandRunner {
    let output: String
    func run(_ command: String) async throws -> String { output }
}

private struct FakeFetcher: HTTPFetching {
    let result: HTTPResult
    let onURL: @Sendable (URL) -> Void

    func get(_ url: URL) async throws -> HTTPResult {
        onURL(url)
        return result
    }
}

final class DshBootstrapTests: XCTestCase {
    func testHappyPathUsesTunnelledURLAndReturnsCookie() async throws {
        let seen = LockedBox<URL?>(nil)
        let credentials = try await DshBootstrap.run(
            runner: FakeRunner(output: "http://127.0.0.1:3080/?token=abc123\n"),
            fetcher: FakeFetcher(result: HTTPResult(status: 200, setCookie: ["dsh-auth-x=secret; Path=/; HttpOnly"])) { url in
                seen.set(url)
            },
            localPort: 41000
        )
        XCTAssertEqual(credentials, DshCredentials(cookieName: "dsh-auth-x", cookieValue: "secret"))
        XCTAssertEqual(seen.get()?.absoluteString, "http://127.0.0.1:41000/?token=abc123")
    }

    func testSkipsStaleTokenAndUsesTheNewOne() async throws {
        let runner = FakeRunner(output: """
        http://127.0.0.1:3080/?token=stale
        http://127.0.0.1:3080/?token=fresh
        """)
        let fetcher = StaleAwareFetcher(freshToken: "fresh")
        let credentials = try await DshBootstrap.run(runner: runner, fetcher: fetcher, localPort: 41000)
        XCTAssertEqual(credentials.cookieName, "dsh-auth-x")
    }

    /// 候选按新到旧：最新一条直接命中，不去碰旧 token。
    func testNewestTokenIsTriedFirst() async throws {
        let runner = FakeRunner(output: """
        http://127.0.0.1:3080/?token=stale
        http://127.0.0.1:3080/?token=fresh
        """)
        let fetcher = StaleAwareFetcher(freshToken: "fresh")
        _ = try await DshBootstrap.run(runner: runner, fetcher: fetcher, localPort: 41000)
        XCTAssertEqual(fetcher.attempts, 1)
    }

    /// 端口取日志里最新那条 URL 的端口；候选最多 3 条。
    func testResolveUsesNewestPortAndCapsCandidates() async throws {
        let runner = FakeRunner(output: """
        http://127.0.0.1:3080/?token=a
        http://127.0.0.1:3081/?token=b
        http://127.0.0.1:3082/?token=c
        http://127.0.0.1:3083/?token=d
        """)
        let target = try await DshBootstrap.resolve(runner: runner)
        XCTAssertEqual(target.port, 3083)
        XCTAssertEqual(target.candidates.map(\.token), ["d", "c", "b"])
    }

    /// 权威源压过「出现得更晚」的日志文件行：主机自认的当前实例才是最新的。
    func testAuthoritativeSourceWinsOverLaterLogLine() async throws {
        let runner = FakeRunner(output: """
        Ahttp://127.0.0.1:3080/?token=cur
        Jhttp://127.0.0.1:3080/?token=older
        Lhttp://127.0.0.1:3080/?token=old2
        """)
        let target = try await DshBootstrap.resolve(runner: runner)
        XCTAssertEqual(target.port, 3080)
        XCTAssertEqual(target.candidates.map(\.token), ["cur", "older", "old2"])
        XCTAssertEqual(target.candidates.first?.source, .authoritative)
    }

    /// 各来源内部按新到旧：journald 的最后一行才是最新的。
    func testEachSourceOrderedNewestFirst() async throws {
        let runner = FakeRunner(output: """
        Jhttp://127.0.0.1:3080/?token=j1
        Jhttp://127.0.0.1:3080/?token=j2
        Lhttp://127.0.0.1:3080/?token=l1
        """)
        let target = try await DshBootstrap.resolve(runner: runner)
        XCTAssertEqual(target.candidates.map(\.token), ["j2", "j1", "l1"])
    }

    func testMissingToken() async throws {
        do {
            _ = try await DshBootstrap.run(
                runner: FakeRunner(output: "nothing here"),
                fetcher: FakeFetcher(result: HTTPResult(status: 200)) { _ in },
                localPort: 41000
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? BootstrapError, .noLaunchURL)
        }
    }

    func testUnauthorized() async throws {
        do {
            _ = try await DshBootstrap.run(
                runner: FakeRunner(output: "http://127.0.0.1:3080/?token=abc123"),
                fetcher: FakeFetcher(result: HTTPResult(status: 401)) { _ in },
                localPort: 41000
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? BootstrapError, .notAuthorized(status: 401))
        }
    }

    func testMissingCookie() async throws {
        do {
            _ = try await DshBootstrap.run(
                runner: FakeRunner(output: "http://127.0.0.1:3080/?token=abc123"),
                fetcher: FakeFetcher(result: HTTPResult(status: 200, setCookie: ["other=1"])) { _ in },
                localPort: 41000
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? BootstrapError, .noCookie)
        }
    }

    /// 首个请求超时可能是隧道刚建好的抖动：同一条候选重试一次即可恢复。
    func testTimeoutOnFirstCandidateIsRetriedOnce() async throws {
        let runner = FakeRunner(output: "http://127.0.0.1:3080/?token=only")
        let fetcher = FlakyFetcher(failures: 1)

        let credentials = try await DshBootstrap.run(runner: runner, fetcher: fetcher, localPort: 41000)

        XCTAssertEqual(credentials.cookieValue, "secret")
        XCTAssertEqual(fetcher.attempts, 2)
    }

    /// 网络层失败与 token 无关：容忍额度用尽即判隧道不通，不在旧 token 上无限干等。
    func testNetworkFailureStopsAtBudget() async throws {
        let runner = FakeRunner(output: """
        http://127.0.0.1:3080/?token=old
        http://127.0.0.1:3080/?token=new
        """)
        let fetcher = FlakyFetcher(failures: 99)

        do {
            _ = try await DshBootstrap.run(runner: runner, fetcher: fetcher, localPort: 41000)
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertEqual((error as? BootstrapError)?.isTunnelProblem, true)
            XCTAssertEqual(fetcher.attempts, DshBootstrap.maxNetworkFailures)
        }
    }

    /// 单条候选超时两次不足以判隧道死：下一条候选仍然要试。
    func testTimeoutOnOneCandidateStillTriesNext() async throws {
        let candidates = [
            LaunchURL(host: "127.0.0.1", port: 3080, token: "dead"),
            LaunchURL(host: "127.0.0.1", port: 3080, token: "alive")
        ]
        let fetcher = SelectiveFetcher(failing: ["dead"])
        let credentials = try await DshBootstrap.run(fetcher: fetcher, localPort: 41000, candidates: candidates)
        XCTAssertEqual(credentials.cookieValue, "secret")
        XCTAssertEqual(fetcher.attempts, 3)
    }
}

private struct StaleAwareFetcher: HTTPFetching {
    let freshToken: String
    private let counter = Counter()

    var attempts: Int { counter.value }

    func get(_ url: URL) async throws -> HTTPResult {
        counter.bump()
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value
        if token == freshToken {
            return HTTPResult(status: 303, setCookie: ["dsh-auth-x=ok; Path=/"])
        }
        return HTTPResult(status: 401)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// 前 N 次请求超时，之后返回带 cookie 的 200。
private final class FlakyFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failures: Int

    init(failures: Int) { self.failures = failures }

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func get(_ url: URL) async throws -> HTTPResult {
        lock.lock()
        count += 1
        let attempt = count
        lock.unlock()
        if attempt <= failures { throw URLError(.timedOut) }
        return HTTPResult(status: 200, setCookie: ["dsh-auth-x=secret; Path=/; HttpOnly"])
    }
}

/// 指定 token 超时，其余返回带 cookie 的 303。
private final class SelectiveFetcher: HTTPFetching, @unchecked Sendable {
    private let failing: Set<String>
    private let lock = NSLock()
    private var count = 0

    init(failing: Set<String>) { self.failing = failing }

    var attempts: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func get(_ url: URL) async throws -> HTTPResult {
        lock.lock(); count += 1; lock.unlock()
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        if failing.contains(token) { throw URLError(.timedOut) }
        return HTTPResult(status: 303, setCookie: ["dsh-auth-x=secret; Path=/"])
    }
}