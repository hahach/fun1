import Foundation

/// 正文链接换算成本机绝对路径，供长按菜单「复制绝对路径」用。
///
/// 会话页点链接另有判定（`DshConversationView.localPath`）：那边按 `URL.path` 取路径、
/// 丢掉 `#L12-L30` 片段，因为片段进不了文件系统。这里要的是给人看的路径，
/// 片段原样保留，所以按原串切出片段、只对路径部分做补全与标准化。
enum LinkTargetPath {
    /// 认不出本机路径时返回 nil：http(s) 等外链、空链接、以及缺工作目录的相对路径。
    ///
    /// `cwd` 为会话的工作目录（`SessionSummary.cwd`），只用于补全相对路径。
    static func absolute(from url: URL, cwd: String?) -> String? {
        if url.isFileURL {
            return (url.path as NSString).standardizingPath + suffix(of: url.fragment)
        }
        guard url.scheme == nil else { return nil }
        let (raw, fragment) = split(url.absoluteString)
        guard let path = expand(raw, cwd: cwd) else { return nil }
        return path + suffix(of: fragment)
    }

    /// 拆出片段：`docs/a.md#L12-L30` → 路径与片段各自解码，拼接时只接回后缀。
    ///
    /// 先按 `#` 切再解码，路径里转义过的 `%23` 才不会被当成片段分隔符。
    private static func split(_ raw: String) -> (path: String, fragment: String?) {
        let path: String
        let fragment: String?
        if let hash = raw.firstIndex(of: "#") {
            path = String(raw[raw.startIndex..<hash])
            fragment = String(raw[raw.index(after: hash)...])
        } else {
            path = raw
            fragment = nil
        }
        return (path.removingPercentEncoding ?? path, fragment?.removingPercentEncoding ?? fragment)
    }

    private static func suffix(of fragment: String?) -> String {
        guard let fragment, !fragment.isEmpty else { return "" }
        return "#" + fragment
    }

    /// 绝对路径原样、`~/` 展开到家目录、其余按工作目录补全；三路都做标准化。
    private static func expand(_ path: String, cwd: String?) -> String? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        if path == "~" || path.hasPrefix("~/") {
            return ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        guard let cwd, !cwd.isEmpty else { return nil }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
}
