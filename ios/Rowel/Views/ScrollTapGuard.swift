import UIKit

/// 会话页「手还在滑」的信号：链接点击要等手停下来才算数（B-156）。
///
/// 判据取滚动容器自己的状态（`isDragging`／`isDecelerating`）与它最近一次
/// 手指驱动位移的时刻。手指驱动的滚动与跟随落底那种程序化滚动都在改
/// `contentOffset`，只有前者算「手在滑」。
final class ScrollTapGuard {
    /// 手指离开后这么久以内的点击仍按滑动余波处理。
    static let quietWindow: TimeInterval = 0.25

    /// 手指滚动的信号源：会话页的滚动容器。闸门只读它，不自己找滚动视图。
    weak var signal: TranscriptScroller?

    init(signal: TranscriptScroller? = nil) {
        self.signal = signal
    }

    /// 这一次点击能不能当真：正在拖、正在惯性滑行、或刚滑过都不算。
    func allowsTap() -> Bool {
        // 没有滚动容器（独立页、弹出层）就没有滑动的余波可言。
        guard let signal else { return true }
        if signal.isUserScrolling { return false }
        return ProcessInfo.processInfo.systemUptime - signal.lastUserScrollAt > Self.quietWindow
    }
}
