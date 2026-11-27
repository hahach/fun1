/// The app's entry point.

import DshClientCore
import Foundation
import SwiftUI

@main
struct RowelApp: App {
    @State private var lock: AppLock
    @State private var health = Health()
    /// 本地通知的持有者：前台标志由 scenePhase 驱动，下游通过环境读同一个实例。
    @State private var notifier = Notifier()
    // The one thing SwiftUI cannot see: `didRegisterForRemoteNotifications` is
    // an UIApplicationDelegate callback with no SwiftUI equivalent, and it is
    // how iOS hands back the token that lets a machine reach this phone when
    // the app is not running.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 单元测试宿主也会跑这一层：锁开着会在启动时弹系统认证面板，
        // 模拟器里那块面板不会结束，测试进程就一直停在「认证中」。
        _lock = State(initialValue: AppLock(enabledByDefault: !RowelApp.isRunningTests))
        // Core 是平台中立层，不能引用这里的 Diagnostics：日志出口由 App 挂上去。
        // 降级（SSH 通、dsh 未就绪）、复用 SSH 重试、开 shell 三条都记进同一个日志环。
        CoreLog.shared.install { level, source, text in
            switch level {
            case .info: Diagnostics.shared.log(.info, source, text)
            case .warn: Diagnostics.shared.log(.warn, source, text)
            case .fail: Diagnostics.shared.log(.fail, source, text)
            }
        }
    }

    /// XCTest 在自己进程里会设这个环境变量；正常启动没有。
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lock)
                .environment(health)
                .environment(\.notifier, notifier)
                .tint(Palette.accent)
                .task {
                    health.start()
                    // 权限设置失败以前是静默的：接到诊断日志里，人能看见。
                    ProfileStore.permissionWarning = { message in
                        Diagnostics.shared.log(.warn, "存储", message)
                    }
                    // 报告列表在后台读：进页面时先空着，读完补上。
                    await health.load()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // 前台静默：其它状态（含未知态）都放开，Notifier 自己还会挡一层。
            notifier.foreground = (phase == .active)
            switch phase {
            case .active:
                lock.didBecomeActive()
                // 锁开着时「回前台验证」由锁屏独占，闸门不再按 idle 阈值弹第二次。
                // 先把开关取成常量再进 Task，闭包只捕获 Bool。
                let lockEnabled = lock.isEnabled
                Task { await SensitiveGate.shared.becameActive(lockEnabled: lockEnabled) }
            case .background, .inactive:
                SensitiveGate.shared.resignedActive()
                // `.inactive` and not only `.background`: iOS photographs the
                // window for the app switcher while the scene is merely
                // inactive, so a cover raised on `.background` is raised after
                // the picture has already been taken.
                lock.willResignActive()
            @unknown default:
                break
            }
        }
    }
}

/// Notifier 不是 @Observable，走自定义环境键把同一个实例传下去。
private struct NotifierKey: EnvironmentKey {
    // nil 作默认值：Notifier 的初始化是 MainActor 隔离的，静态默认值不能构造它。
    static let defaultValue: Notifier? = nil
}

extension EnvironmentValues {
    var notifier: Notifier? {
        get { self[NotifierKey.self] }
        set { self[NotifierKey.self] = newValue }
    }
}
