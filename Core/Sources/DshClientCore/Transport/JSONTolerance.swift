import Foundation

/// dsh 会把模型输出原样存进会话数据；流式截断可能留下未配对的 UTF-16 代理转义
/// （如 `\ud83d`）。浏览器的 JSON.parse 宽容接受，iOS 的 JSONSerialization 会拒绝，
/// 一条坏转义就让整个 session/list / session/page 解析失败（B-115）。
/// 解析前把未配对代理转义替换成 `\ufffd`，与浏览器口径对齐。
public enum JSONTolerance {
    public static func sanitize(_ data: Data) -> Data {
        // 快路径：没有反斜杠就没有转义（只做一遍字节扫描）。
        guard data.contains(0x5C) else { return data }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("\\u") else { return data }
        var out = text
        // 高位代理后面没跟着低位代理 → 坏。
        out = out.replacingOccurrences(
            of: "\\\\ud[89ab][0-9a-f]{2}(?!\\\\ud[c-f][0-9a-f]{2})",
            with: "\\\\ufffd",
            options: [.regularExpression, .caseInsensitive]
        )
        // 低位代理前面没有高位代理 → 坏。
        out = out.replacingOccurrences(
            of: "(?<!\\\\ud[89ab][0-9a-f]{2})\\\\ud[c-f][0-9a-f]{2}",
            with: "\\\\ufffd",
            options: [.regularExpression, .caseInsensitive]
        )
        guard out != text else { return data }
        return Data(out.utf8)
    }
}
