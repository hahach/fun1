import Foundation

/// 还没发出去的一张图：base64 直接塞进 `session/prompt` 的 content，不需要先上传。
struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mediaType: String
    let name: String?

    var base64: String { data.base64EncodedString() }
}

