/// What the window shows.
///
/// One shell, no pairing state: the dsh connect screen, with the lock cover
/// over it. Everything past connecting lives in the full-screen cover
/// `OnboardingView` presents, so the root never has to know which host is on
/// screen.

import SwiftUI

public struct RootView: View {
    @Environment(AppLock.self) private var lock

    public init() {}

    public var body: some View {
        OnboardingView()
            .background(Palette.paper)
            // Over everything, including the sheets — a settings sheet left open
            // when the app went away would otherwise be on top of the cover.
            // No animation: a cover that fades in is a cover that is transparent
            // during the frame the app switcher takes its picture.
            .overlay {
                if lock.isCovered {
                    LockScreen()
                        .transition(.identity)
                }
            }
    }
}
