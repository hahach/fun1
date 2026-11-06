import Observation
import SwiftUI
import UIKit

/// 会话页滚动容器的像素事实。
///
/// 落底只写 `contentOffset`；判「在底部」只读 `contentOffset`／`contentSize`／`bounds`；
/// 翻页补位只读锚点行实测到的像素位移。`scrollTo(id:)` 给的是布局估算落点，
/// 落不准也没有完成判据，所以这里不拿它当位置来源。
@Observable
final class TranscriptScroller {
    /// 「在底部」的容差：与滚动视图最大偏移相差的像素数。
    static let bottomSlack: CGFloat = 1

    /// 「长高」这一类落底的日志标签：它同时是节流的判据，调用方用这个常量，别写字面量。
    static let growthReason = "长高"
    /// 「长高」落底日志的节流窗口：流式期间每个内容变化都落一次，一秒一条够看，也不冲掉日志环。
    private static let growthLogWindow: TimeInterval = 1
    /// 翻页持锁的静默窗：这么长时间没有新的内容高度变化，就算这一页量完了。
    private static let holdQuietWindow: UInt64 = 150_000_000
    /// 翻页持锁的硬上限：异常路径下也不能把滚动锁死。
    private static let holdLimit: TimeInterval = 4
    /// 一直收不到锚点测量时最多再等多久：等满了就记一条收尾，不把持锁挂死。
    private static let holdFirstMeasureLimit: UInt64 = 1_000_000_000

    /// 视口此刻是否到底。
    private(set) var isAtBottom = true
    /// 内容总高（`contentSize.height`）。
    private(set) var contentHeight: CGFloat = 0
    /// 当前纵向偏移（`contentOffset.y`）。
    private(set) var offsetY: CGFloat = 0
    /// 视口高度（`bounds.height`）。
    @ObservationIgnored private(set) var viewportHeight: CGFloat = 0
    /// 最近一次手指驱动滚动的时刻（系统开机计时，不受改系统时间影响）。
    @ObservationIgnored private(set) var lastUserScrollAt: TimeInterval = 0

    /// 内容长高的那一拍通知一次。跟不跟随由视图决定：过程块长高不落底（B-139）。
    @ObservationIgnored var onContentGrowth: (() -> Void)?

    /// 所在滚动视图。桥接件找到它之后由 KVO 一直盯着。
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// 翻页持锁：这一页内容量完之前，视口坐标钉在开始那一刻。
    @ObservationIgnored private var hold: Hold?
    /// 这一页到底插进来没有：兜底跳转只在「确实插了内容、却一次也没补上」时发生。
    @ObservationIgnored private(set) var holdInserted = false
    /// 持锁期间最后一次收到锚点测量的时刻：静默窗就是等它不再变。
    @ObservationIgnored private var lastHoldInputAt: TimeInterval = 0
    /// 持锁期间补了几次位（日志与兜底判据用）。
    @ObservationIgnored private var holdCompensations = 0
    /// 补偿被最大偏移夹住时，锚点位移真正要求的位置：等内容量出、上限抬起来之后补齐一次。
    @ObservationIgnored private var holdDesired: CGFloat?
    /// 持锁开始那一刻的内容总高度：只用于结束日志，补偿不读它。
    @ObservationIgnored private var holdStartContentHeight: CGFloat = 0
    /// 内容量出之后落一次底。
    @ObservationIgnored private var landsOnNextLayout = false
    /// 挂着的落底是哪个调用方要的：补落时按同一个标签记日志。
    @ObservationIgnored private var landingReason = "未标注"
    /// 上一次真的记下「长高」落底日志的时刻（系统开机计时）。
    @ObservationIgnored private var growthLogAt: TimeInterval = 0
    /// 节流窗口里被吞掉的「长高」落底次数，攒到下一次记录时并进那条日志。
    @ObservationIgnored private var growthLogPending = 0

    /// 持锁开始那一刻的偏移与时刻。补偿始终以这个偏移为基准，不逐次累加。
    private struct Hold {
        let offsetY: CGFloat
        let startedAt: TimeInterval
    }

    /// 翻页持锁中：这一页还在往上插，位置不许动。
    var isHolding: Bool { hold != nil }

    /// 持锁代数：每次 beginHold 加一，并进锚点探针的 preference 值。
    /// 探针位置没变时也靠它变一次，逼出一次回调——y0 必须在插入之前到手。
    private(set) var holdNonce = 0

    /// 手指正驱动滚动：拖动中或惯性滑行中。
    var isUserScrolling: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating
    }

    // MARK: - 挂接

    /// 从视图树里向上找滚动容器。桥接件挂上／移动时调一次，重复调没有副作用。
    func adopt(_ view: UIView) {
        var node: UIView? = view.superview
        while let current = node {
            if let scroll = current as? UIScrollView {
                attach(scroll)
                return
            }
            node = current.superview
        }
    }

    private func attach(_ scroll: UIScrollView) {
        guard scroll !== scrollView else { return }
        observations.forEach { $0.invalidate() }
        scrollView = scroll
        // 换了容器，上一份持锁不再对应当前内容。
        hold = nil
        observations = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.offsetChanged()
            },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.contentSizeChanged()
            },
            // 滚动视图的 bounds.origin 就是 contentOffset，位移也会叫醒这里；
            // 只有高度变了才算视口变了（见 boundsChanged）。
            scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.boundsChanged()
            },
        ]
        Diagnostics.shared.log(
            .info, "会话页",
            "滚动容器已接管 contentSize=\(Int(scroll.contentSize.height)) bounds=\(Int(scroll.bounds.height))"
        )
        // 桥接件可能晚于首次布局才认出滚动视图：这一拍就把像素事实读进来，
        // 并把挂着的落底就地消费掉——此后未必再有一次内容变化来叫醒它。
        refresh()
        if landsOnNextLayout {
            landsOnNextLayout = false
            scrollToBottom(landingReason)
        }
    }

    // MARK: - 落底

    /// 落到底：最大偏移是滚动视图自己的事实，一次写完，不猜行高。
    /// 内容还没量出时，排到第一次量出之后再落。`reason` 只进日志，用来分辨是哪条路径写的偏移。
    func scrollToBottom(_ reason: String = "未标注") {
        // 持锁期间一律不落底：这一页还在往上插，落底会把钉住的位置顶掉。
        guard !isHolding else { return }
        guard let scrollView, scrollView.bounds.height > 0, scrollView.contentSize.height > 0 else {
            landsOnNextLayout = true
            landingReason = reason
            return
        }
        let target = maxOffsetY(scrollView)
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: target),
            animated: false
        )
        logLanding(reason, offset: target, content: scrollView.contentSize.height, viewport: scrollView.bounds.height)
    }

    /// 落底日志：「长高」一秒最多一条，其它路径照常每条都记。
    /// 被吞掉的次数攒着，并进下一条——记下的那条代表了多少次落底。
    private func logLanding(_ reason: String, offset: CGFloat, content: CGFloat, viewport: CGFloat) {
        var label = reason
        if reason == Self.growthReason {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - growthLogAt >= Self.growthLogWindow else {
                growthLogPending += 1
                return
            }
            growthLogAt = now
            if growthLogPending > 0 {
                label = "\(reason)×\(growthLogPending + 1)"
                growthLogPending = 0
            }
        }
        Diagnostics.shared.log(
            .info, "会话页",
            "落底(\(label)) offset=\(Int(offset)) 内容=\(Int(content)) 视口=\(Int(viewport))"
        )
    }

    /// 落到底，并在下一次内容量出之后再落一次。
    /// 「这一拍的 contentSize 还是旧的」场合用：刚进场、刚发送、刚从很远处跳回底部。
    func scrollToBottomSettling(_ reason: String = "未标注") {
        // 持锁期间连「挂起的落底」都不留：解锁后不该莫名跳一下。
        guard !isHolding else { return }
        landsOnNextLayout = true
        landingReason = reason
        scrollToBottom(reason)
    }

    // MARK: - 翻页持锁

    /// 按锚点行的位移补位：offset = 持锁那一刻的 offset + (y1 − y0)。
    ///
    /// 只认这一行在内容坐标里的位移，与内容总高度无关——视口下方（底部文案、还在流式的
    /// 输出）长了多少都不参与计算，所以不会把「下方的增长」误算成阅读位置的变化。
    func applyHoldCompensation(y0: CGFloat, y1: CGFloat) {
        guard let hold, let scrollView else { return }
        let delta = y1 - y0
        let lowest = -scrollView.adjustedContentInset.top
        let desired = hold.offsetY + delta
        let highest = maxOffsetY(scrollView)
        let target = min(max(desired, lowest), highest)
        // 内容还没量完时上限还是旧的，期望位置会被夹掉：记下来，等 contentSize 追上来再补齐。
        if desired > highest {
            holdDesired = desired
            Diagnostics.shared.log(
                .info, "会话页",
                "翻页补偿被夹取 期望=\(Int(desired)) 实际=\(Int(target)) 上限=\(Int(highest))"
            )
        } else {
            holdDesired = nil
        }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: target),
            animated: false
        )
        holdCompensations += 1
        lastHoldInputAt = ProcessInfo.processInfo.systemUptime
        Diagnostics.shared.log(
            .info, "会话页",
            "翻页补偿 y0=\(Int(y0)) y1=\(Int(y1)) 位移=\(Int(delta)) offset=\(Int(target))"
        )
        refresh()
    }

    /// 标记这一页已经插进来；空页或失败路径撤回。
    func noteHoldInserted(_ inserted: Bool) {
        holdInserted = inserted
    }

    /// 收到一次锚点测量（不论这一拍是否据此补位）：静默窗与「还没测量过」都靠它判。
    func noteHoldMeasurement() {
        lastHoldInputAt = ProcessInfo.processInfo.systemUptime
    }

    /// 开始持锁：记下这一刻的偏移，关掉手指滚动、压住落底，直到锚点行不再动。
    ///
    /// 起点只有这一个偏移；此后每次补偿都是「这个偏移 + 锚点行相对 y0 的位移」，
    /// 不是在上一次结果上再加一次差，所以反复收敛不会越补越多。
    func beginHold() {
        guard hold == nil else { return }
        guard let scrollView else {
            Diagnostics.shared.log(.info, "会话页", "翻页持锁跳过：滚动容器还没挂上")
            return
        }
        hold = Hold(
            offsetY: scrollView.contentOffset.y,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        holdCompensations = 0
        holdInserted = false
        holdDesired = nil
        lastHoldInputAt = 0
        holdStartContentHeight = scrollView.contentSize.height
        // 持锁期间不落底，也不留挂起的落底。
        landsOnNextLayout = false
        scrollView.isScrollEnabled = false
        // 代数加一：锚点探针的 preference 值随之变一次，插入之前必定拿到一次回调。
        holdNonce += 1
        Diagnostics.shared.log(
            .info, "会话页",
            "翻页持锁开始 offset=\(Int(scrollView.contentOffset.y)) 内容=\(Int(scrollView.contentSize.height))"
            + " 视口=\(Int(scrollView.bounds.height))"
            + " 内边距上=\(Int(scrollView.adjustedContentInset.top)) 下=\(Int(scrollView.adjustedContentInset.bottom))"
            + " 代数=\(holdNonce)"
        )
    }

    /// 解锁：手指滚动还回去。解锁之后不再补任何滚动，人停在哪儿就是哪儿。
    func endHold() {
        guard let hold else { return }
        self.hold = nil
        scrollView?.isScrollEnabled = true
        let grown = (scrollView?.contentSize.height ?? holdStartContentHeight) - holdStartContentHeight
        // 确实插进来了、却一次都没补上：说明这条位移没被量到。与其把人留在上方不上不下，
        // 不如落到内容顶端——刚加载出来的那几屏立刻看得见。
        if holdCompensations == 0, holdInserted, grown > 0, let scrollView {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                animated: false
            )
            Diagnostics.shared.log(.info, "会话页", "翻页补偿未发生：落到内容顶端")
            refresh()
        }
        let moved = (scrollView?.contentOffset.y ?? hold.offsetY) - hold.offsetY
        Diagnostics.shared.log(
            .info, "会话页",
            "翻页持锁结束 补偿次数=\(holdCompensations) 总高度变化=\(Int(grown)) 最终位移=\(Int(moved))"
        )
    }

    /// 等这一页量完再解锁：锚点行位置连续一个静默窗不变就算量完。
    /// 必须先等到至少一次测量才允许收尾：一直没有测量就再等，最多等满 1 秒并记一条。
    /// 硬上限 4 秒到点同样解锁。返回时一定已经解锁（失败/取消路径靠调用方的 defer 兜）。
    @MainActor
    func settleHold() async {
        guard let startedAt = hold?.startedAt else { return }
        var waitedForFirstMeasure: UInt64 = 0
        while isHolding {
            if Task.isCancelled { endHold(); return }
            if ProcessInfo.processInfo.systemUptime - startedAt >= Self.holdLimit { break }
            let mark = lastHoldInputAt
            try? await Task.sleep(nanoseconds: Self.holdQuietWindow)
            if Task.isCancelled { endHold(); return }
            // 静默窗里锚点又动过：这一页还在量行，重新计时。
            if isHolding, lastHoldInputAt != mark { continue }
            // 一次测量都还没到：再等一个窗，等满上限才认输。
            if lastHoldInputAt == 0 {
                waitedForFirstMeasure += Self.holdQuietWindow
                if waitedForFirstMeasure < Self.holdFirstMeasureLimit { continue }
                Diagnostics.shared.log(.info, "会话页", "翻页测量未到达")
                break
            }
            // 还有被夹掉的期望位置没补齐：这一页还没量完，等 contentSize 追上来。
            if holdDesired != nil { continue }
            break
        }
        endHold()
    }

    // MARK: - 观测

    private func offsetChanged() {
        guard let scrollView else { return }
        if scrollView.isDragging || scrollView.isDecelerating {
            lastUserScrollAt = ProcessInfo.processInfo.systemUptime
            // 手指一动，挂着的「下次量出就落底」就不作数了：人已经在读别处。
            landsOnNextLayout = false
        }
        refresh()
    }

    private func contentSizeChanged() {
        guard let scrollView else { return }
        // 持锁期间位置由锚点行的位移负责（applyHoldCompensation）：这里既不补偿也不落底。
        // 内容总高度里含着视口下方的增长（底部文案、还在流式的输出），拿它做差会多推。
        if isHolding {
            // 上一拍补偿被旧上限夹掉的，等这一拍上限抬起来补齐；仍然不落底、不触发 onContentGrowth。
            if let desired = holdDesired {
                let target = min(desired, maxOffsetY(scrollView))
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: target),
                    animated: false
                )
                Diagnostics.shared.log(
                    .info, "会话页",
                    "翻页补偿补齐 期望=\(Int(desired)) 实际=\(Int(target))"
                )
                if abs(desired - target) <= 1 { holdDesired = nil }
            }
            refresh()
            return
        }
        let grew = scrollView.contentSize.height > contentHeight
        if landsOnNextLayout {
            landsOnNextLayout = false
            scrollToBottom(landingReason)
        }
        refresh()
        if grew { onContentGrowth?() }
    }

    private func boundsChanged() {
        guard let scrollView else { return }
        // 滚动视图的 bounds.origin 就是 contentOffset：纯位移也会叫醒这里，只有高度变了才算视口变了。
        let previousHeight = viewportHeight
        guard scrollView.bounds.height != previousHeight else { return }
        let wasAtBottom = isAtBottom
        refresh()
        // 视口变高／变矮（键盘、转屏）而人原本在底部：保持在底部。
        // 视口还是零高（第一次布局前）时不算变过，落底由进场那次负责。
        if previousHeight > 0, wasAtBottom { scrollToBottom("视口变化") }
    }

    private func refresh() {
        guard let scrollView else { return }
        // 只在值真变了时写：@Observable 每写一次都会让读它的视图重算，滚动里每帧都写等于每帧重绘。
        let height = scrollView.contentSize.height
        if contentHeight != height { contentHeight = height }
        let offset = scrollView.contentOffset.y
        if offsetY != offset { offsetY = offset }
        let viewport = scrollView.bounds.height
        if viewportHeight != viewport { viewportHeight = viewport }
        let atBottom = offset >= maxOffsetY(scrollView) - Self.bottomSlack
        if isAtBottom != atBottom { isAtBottom = atBottom }
    }

    /// 滚动视图允许的最大纵向偏移：到底时 `contentOffset.y` 就是它。
    /// 顶部内边距定下限，底部内边距定上限（键盘弹出时由系统加在底部）。
    /// 两个内边距都为零时，判据即 `offset.y + bounds.height >= contentSize.height - ε`。
    private func maxOffsetY(_ scroll: UIScrollView) -> CGFloat {
        let lowest = -scroll.adjustedContentInset.top
        let highest = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        return max(lowest, highest)
    }
}

/// 把所在滚动容器交给 TranscriptScroller 的桥接件：零尺寸、不参与命中、不改布局。
///
/// 它只借自己的 superview 链：挂上或移动时向上找最近的 `UIScrollView`，找到就交给 scroller。
struct TranscriptScrollProbe: UIViewRepresentable {
    let scroller: TranscriptScroller

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onMove = { [weak scroller] host in scroller?.adopt(host) }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onMove = { [weak scroller] host in scroller?.adopt(host) }
        scroller.adopt(view)
    }

    /// 只用来回答「我在谁的里面」：不占布局、不吃触摸。
    final class ProbeView: UIView {
        var onMove: ((UIView) -> Void)?

        override var intrinsicContentSize: CGSize { .zero }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onMove?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMove?(self)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
}
