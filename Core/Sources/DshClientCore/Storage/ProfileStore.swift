import Foundation

/// 一台主机的连接档案：地址、私钥、已知主机指纹。
/// 私钥是明文（LiveContainer 下 Keychain 不可依赖），文件权限收到 0600；口令加密留待后续。
public struct Profile: Codable, Equatable {
    public var user: String
    public var host: String
    public var port: Int
    public var privateKeyPEM: String
    public var knownHosts: [String: String]

    public init(user: String, host: String, port: Int, privateKeyPEM: String, knownHosts: [String: String] = [:]) {
        self.user = user
        self.host = host
        self.port = port
        self.privateKeyPEM = privateKeyPEM
        self.knownHosts = knownHosts
    }

    /// `user@host:port`，档案的选择与去重都用它。
    public var address: String {
        "\(user)@\(host):\(port)"
    }

    public var endpoint: Endpoint {
        Endpoint(user: user, host: host, port: port)
    }

    public var hosts: KnownHosts {
        KnownHosts(rawEntries: knownHosts)
    }
}

public enum ProfileStoreError: Error, Equatable {
    case corrupt
}

/// 单档案存储：`<directory>/profile.json`。目录由调用方给（iOS 用 Application Support）。
public struct ProfileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL {
        directory.appendingPathComponent("profile.json")
    }

    public func load() throws -> Profile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { throw ProfileStoreError.corrupt }
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else { throw ProfileStoreError.corrupt }
        return profile
    }

    public func save(_ profile: Profile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

extension ProfileStore {
    /// 多档案文件：`profiles.json`（`profile.json` 是它的前一代，读得到、不再写）。
    public var listURL: URL {
        directory.appendingPathComponent("profiles.json")
    }

    /// 全部档案。旧版只有一个 `profile.json` 时，把它当作唯一一条读出来。
    public func loadAll() throws -> [Profile] {
        if FileManager.default.fileExists(atPath: listURL.path) {
            guard let data = try? Data(contentsOf: listURL),
                  let list = try? JSONDecoder().decode([Profile].self, from: data) else {
                throw ProfileStoreError.corrupt
            }
            return list
        }
        return (try load()).map { [$0] } ?? []
    }

    /// 写全部档案。目录与权限同单档案：0600。
    public func saveAll(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: listURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listURL.path)
    }

    /// 按 `user@host:port` 覆盖或追加一条，返回整个列表。
    @discardableResult
    public func upsert(_ profile: Profile) throws -> [Profile] {
        var list = try loadAll()
        if let index = list.firstIndex(where: { $0.endpoint == profile.endpoint }) {
            list[index] = profile
        } else {
            list.append(profile)
        }
        try saveAll(list)
        return list
    }

    /// 删掉一条（地址相同的都算），返回剩下的。
    @discardableResult
    public func remove(_ profile: Profile) throws -> [Profile] {
        var list = try loadAll()
        list.removeAll { $0.endpoint == profile.endpoint }
        try saveAll(list)
        return list
    }
}
