import Foundation
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
