import Foundation

/// 在主机上执行只读命令并取 stdout。SSH 实现见 `SSHClientConnection`，测试用假实现。
public protocol CommandRunner {
    func run(_ command: String) async throws -> String
}

public enum DshCommands {
    /// 取最近若干条带 token 的启动 URL（旧 → 新）。
    ///
    /// 实例可能由 systemd 用户服务托管（日志在 journald），也可能由 `dsh-web` 脚本托管
    /// （日志在 `~/.dsh/dsh-web.log`）；token 每次启动随机且不落盘，两个来源都取。
    /// 两侧都限量读取：全量 journal 会让这条 exec 的输出无限增长，隧道建立期间白白拖慢。
    public static let launchURLCandidates = "{ journalctl --user -u dsh-web -n 200 -o cat --no-pager 2>/dev/null; tail -c 65536 \"$HOME/.dsh/dsh-web.log\" 2>/dev/null; } | grep -o 'http://[^ ]*token=[^ ]*' | tail -6"
}
