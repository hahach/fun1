import Foundation

/// 在主机上执行只读命令并取 stdout。SSH 实现见 \`SSHClientConnection\`，测试用假实现。
public protocol CommandRunner {
    func run(_ command: String) async throws -> String
}

public enum DshCommands {
    /// 取带 token 的启动 URL，每行前缀标来源：\`A\`＝权威源（\`dsh-web url\`）、
    /// \`J\`＝journald、\`L\`＝\`~/.dsh/dsh-web.log\`。
    ///
    /// 实例可能由 systemd 用户服务托管（日志在 journald），也可能由 \`dsh-web\` 脚本托管
    /// （日志在 \`~/.dsh/dsh-web.log\`）；token 每次启动随机且不落盘，三个来源都取。
    /// 各来源内部按时间旧→新，来源之间不保证先后：顺序由客户端按来源语义重排。
    /// 每源限量读取：全量 journal 会让这条 exec 的输出无限增长，隧道建立期间白白拖慢。
    public static let launchURLCandidates = "{ dsh-web url 2>/dev/null || \"$HOME/.local/bin/dsh-web\" url 2>/dev/null; } | grep -o 'http://[^ ]*token=[^ ]*' | tail -1 | sed 's/^/A/'; { journalctl --user -u dsh-web -n 200 -o cat --no-pager 2>/dev/null | grep -o 'http://[^ ]*token=[^ ]*' | tail -3 | sed 's/^/J/'; }; { tail -c 65536 \"$HOME/.dsh/dsh-web.log\" 2>/dev/null | grep -o 'http://[^ ]*token=[^ ]*' | tail -3 | sed 's/^/L/'; }; true"
}
