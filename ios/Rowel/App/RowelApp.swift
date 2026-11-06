/// The app's entry point.

import SwiftUI

@main
struct RowelApp: App {
    @State private var lock = AppLock()
    @State private var health = Health()
    // The one thing SwiftUI cannot see: `didRegisterForRemoteNotifications` is
    // an UIApplicationDelegate callback with no SwiftUI equivalent, and it is
    // how iOS hands back the token that lets a machine reach this phone when
    // the app is not running.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lock)
                .environment(health)
                .tint(Palette.accent)
                .task {
                    health.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                lock.didBecomeActive()
                Task { await SensitiveGate.shared.becameActive() }
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
