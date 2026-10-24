import Foundation

/// 构建标识：与 App 侧 `ClientIdentity` 同源，但刻意不依赖 UIKit/SwiftUI，
/// 以便在 Linux 上跑单测。
public enum ClientBuild {
    public static let name = "dafeiyu-dsh-client"

    /// `dafeiyu-dsh-client · build <n>`
    public static func stamp(build: String) -> String {
        "\(name) · build \(build)"
    }
}
