import Foundation

/// 本客户端（dafeiyu-dsh-client）的身份标识。
///
/// UI 底座是上游 rowel，这里只标注「装的是哪一个构建」，让侧载后的包能追到
/// 具体的 CI run：CI 用 `CURRENT_PROJECT_VERSION=<run_number>` 打 build 号。
enum ClientIdentity {
    static let name = "dafeiyu-dsh-client"

    static var buildStamp: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(name) · build \(build)"
    }
}
