import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import DshClientCore

/// 端到端探针：在 Linux 上把 SSH → 本地转发 → 取 token → 换 cookie 跑一遍。
///
///   swift run dsh-probe --user root --host 127.0.0.1 --port 22 --key ~/.ssh/id_ed25519
@main
struct Probe {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }

        let user = value("--user") ?? ProcessInfo.processInfo.environment["USER"] ?? "root"
        let host = value("--host") ?? "127.0.0.1"
        let port = Int(value("--port") ?? "22") ?? 22
        let keyPath = value("--key") ?? "\(NSHomeDirectory())/.ssh/id_ed25519"

        let globalDeadline = Task {
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            FileHandle.standardError.write(Data("probe: global timeout\n".utf8))
            print("{\"status\":\"timeout\"}")
            exit(4)
        }
        _ = globalDeadline

        do {
            let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
            let key = try SSHKey.loadEd25519(pem)
            let endpoint = Endpoint(user: user, host: host, port: port)

            if args.contains("--debug") {
                let debug = SSHClientConnection(endpoint: endpoint, key: key, knownHosts: KnownHosts()) { _ in }
                _ = try await debug.connect()
                let raw = try await debug.run(DshCommands.launchURLCandidates)
                FileHandle.standardError.write(Data("raw=\(raw.debugDescription)\n".utf8))
                FileHandle.standardError.write(Data("env=\(try await debug.run("echo HOME=$HOME; id -un"))\n".utf8))
                let candidates = LaunchURL.parseAll(from: raw)
                FileHandle.standardError.write(Data("candidates=\(candidates.count) lengths=\(candidates.map { $0.token.count })\n".utf8))
                await debug.close()
            }

            if let roundsText = value("--forward-stress") {
                let rounds = Int(roundsText) ?? 10
                // 转发器压测：一条连接保持打开（模拟被连接池留住的探针连接），
                // 同时在同一条 SSH 会话上开第二条 direct-tcpip 通道。
                let openedForward = SSHClientConnection(
                    endpoint: endpoint, key: key, knownHosts: KnownHosts()
                ) { _ in }
                _ = try await openedForward.connect()
                let started = try await openedForward.startForwarder(targetHost: "127.0.0.1", targetPort: 3080)
                let result = await ForwardStress.run(localPort: started.localPort, rounds: rounds)
                for failure in result.failures {
                    FileHandle.standardError.write(Data("stress \(failure)\n".utf8))
                }
                await started.forwarder.stop()
                await openedForward.close()
                print("{\"status\":\"stress\",\"rounds\":\(result.rounds),\"failures\":\(result.failures.count)}")
                exit(result.failed ? 6 : 0)
            }

            let opened = try await DshSession.open(
                endpoint: endpoint,
                key: key,
                fetcher: URLSessionFetcher(),
                onStage: { stage in FileHandle.standardError.write(Data("stage: \(stage)\n".utf8)) },
                onHostKey: { decision in FileHandle.standardError.write(Data("hostkey: \(decision)\n".utf8)) }
            )

            FileHandle.standardError.write(Data("probe: entering blocks\n".utf8))
            if args.contains("--reconnect") {
                let rpc = DshRPC(baseURL: opened.session.baseURL, credentials: opened.session.credentials)
                _ = try await rpc.call("session/list")
                FileHandle.standardError.write(Data("reconnect: first call ok\n".utf8))
                try await Task.sleep(nanoseconds: 4_000_000_000)

                var sawStale = false
                do {
                    _ = try await rpc.call("session/list")
                } catch {
                    sawStale = true
                    FileHandle.standardError.write(Data("reconnect: stale rejected (\(error))\n".utf8))
                }

                let fresh = try await opened.session.refreshCredentials()
                let rpc2 = DshRPC(baseURL: opened.session.baseURL, credentials: fresh)
                _ = try await rpc2.call("session/list")

                let mux = DshMux(port: opened.session.localPort, credentials: fresh)
                try await mux.connect()
                await mux.close()
                try await mux.reconnect()
                var muxItems = 0
                for try await _ in try mux.open(endpoint: "session/follow") { muxItems += 1 }
                await mux.close()

                FileHandle.standardError.write(Data("reconnect: refreshed=true sawStale=\(sawStale) muxItems=\(muxItems)\n".utf8))
            }

            if args.contains("--restart") {
                let beforePort = opened.session.localPort
                let rpcBefore = DshRPC(baseURL: opened.session.baseURL, credentials: opened.session.credentials)
                _ = try await rpcBefore.call("session/list")

                _ = try await opened.session.restart()

                let rpcAfter = DshRPC(baseURL: opened.session.baseURL, credentials: opened.session.credentials)
                _ = try await rpcAfter.call("session/list")

                let mux = DshMux(port: opened.session.localPort, credentials: opened.session.credentials)
                try await mux.connect()
                var items = 0
                for try await _ in try mux.open(endpoint: "session/follow") {
                    items += 1
                    break
                }
                await mux.close()

                FileHandle.standardError.write(Data("restart: oldPort=\(beforePort) newPort=\(opened.session.localPort) muxItems=\(items)\n".utf8))
            }

            FileHandle.standardError.write(Data("probe: reconnect done\n".utf8))
            if args.contains("--tty") {
                let tty = try await opened.session.openTTY(cols: 100, rows: 30)
                try await tty.send("echo probe-hello; stty size\n")
                var collected = Data()
                let deadline = Task {
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    FileHandle.standardError.write(Data("tty: timeout\n".utf8))
                    exit(3)
                }
                do {
                    for try await chunk in tty.output {
                        collected.append(chunk)
                        // 输入行本身也会回显 "probe-hello"，所以等 stty 的「行 列」输出再收手。
                        if String(decoding: collected, as: UTF8.self).contains("30 100") { break }
                    }
                } catch {
                    FileHandle.standardError.write(Data("tty: error \(error)\n".utf8))
                }
                deadline.cancel()
                tty.close()
                let text = String(decoding: collected, as: UTF8.self)
                FileHandle.standardError.write(Data("tty: bytes=\(collected.count) hasEcho=\(text.contains("probe-hello")) hasSize=\(text.contains("30 100"))\n".utf8))
            }

            FileHandle.standardError.write(Data("probe: tty done\n".utf8))
            if let streamEndpoint = value("--stream") {
                let mux = DshMux(port: opened.session.localPort, credentials: opened.session.credentials)
                try await mux.connect()
                FileHandle.standardError.write(Data("mux: connected\n".utf8))
                let deadline = Task {
                    do {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                    } catch {
                        return
                    }
                    FileHandle.standardError.write(Data("mux: timeout\n".utf8))
                    exit(2)
                }
                for try await item in try mux.open(endpoint: streamEndpoint) {
                    let data = try JSONSerialization.data(withJSONObject: ["stream": streamEndpoint, "item": item], options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                }
                deadline.cancel()
                FileHandle.standardError.write(Data("mux: stream ended\n".utf8))
                await mux.close()
            }

            // exec 与数据通道并发：复刻 App 的 RemoteLog（runRemote 每 5 秒/20 行刷日志）
            // 与 session/list 大响应共用一条 SSH 连接的场景。任一轮解析失败即非零退出。
            if args.contains("--exec-race") {
                let stop = ProbeFlag()
                let spammer = Task {
                    var rounds = 0
                    while !stop.isSet {
                        _ = try? await opened.session.runRemote("echo ping")
                        rounds += 1
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    FileHandle.standardError.write(Data("exec-race: exec rounds=\(rounds)\n".utf8))
                }
                defer {
                    stop.set(true)
                    spammer.cancel()
                }
                for round in 1...5 {
                    let started = Date()
                    do {
                        let value = try await DshRPC(
                            baseURL: opened.session.baseURL,
                            credentials: opened.session.credentials
                        ).call("session/big")
                        let items = (value as? [String: Any])?["items"] as? [Any] ?? []
                        guard items.count == 2000 else {
                            FileHandle.standardError.write(Data("exec-race: round \(round): items=\(items.count)\n".utf8))
                            exit(7)
                        }
                        FileHandle.standardError.write(Data("exec-race: round \(round) ok (\(Int(Date().timeIntervalSince(started) * 1000)) ms)\n".utf8))
                    } catch {
                        stop.set(true)
                        FileHandle.standardError.write(Data("exec-race: round \(round) failed: \(error)\n".utf8))
                        exit(7)
                    }
                }
            }

            if let endpoint = value("--call") {
                let rpc = DshRPC(baseURL: opened.session.baseURL, credentials: opened.session.credentials)
                let result = try await rpc.call(endpoint)
                let data = try JSONSerialization.data(withJSONObject: ["call": endpoint, "value": result], options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }

            print("{\"status\":\"ready\",\"localPort\":\(opened.session.localPort),\"cookie\":\"\(opened.session.credentials.cookieName)\"}")
            await opened.session.close()
        } catch {
            print("{\"status\":\"failed\",\"error\":\"\(error)\"}")
            exit(1)
        }
    }
}

/// 探针内部用的线程安全布尔（exec-race 的停止开关）。
final class ProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}