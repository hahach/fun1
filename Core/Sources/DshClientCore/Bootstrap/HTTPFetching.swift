import Foundation

public struct HTTPResult: Equatable {
    public let status: Int
    /// 原始 Set-Cookie 行，可能多条。
    public let setCookie: [String]

    public init(status: Int, setCookie: [String] = []) {
        self.status = status
        self.setCookie = setCookie
    }
}

/// 一次 GET。iOS 用 URLSession 实现，测试用假实现；只暴露 bootstrap 需要的最小面。
public protocol HTTPFetching {
    func get(_ url: URL) async throws -> HTTPResult
}
