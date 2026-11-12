/// The app's entry point.

import DshClientCore
import Foundation
import SwiftUI

@main
struct RowelApp: App {
    @State private var lock: AppLock
    @State private var health = Health()
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
