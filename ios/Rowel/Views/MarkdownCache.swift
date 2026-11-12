import Foundation

/// Markdown 的进程内缓存：分块与行内属性串各一份。
///
/// `Markdown.parse` 与 `Markdown.inline` 都是纯函数，同一份输入永远给出同一份输出，
/// 所以键就是输入本身：流式文本改一个字就是新键，旧条目由 `NSCache` 自己淘汰，
/// 这里不做失效判断。`NSCache` 本身线程安全，两个入口可以从后台预热任务里调。
enum MarkdownCache {
    /// 一份缓存载荷。`NSCache` 只收类，所以套一层盒子。
    ///
    /// 分块与行内各用一份缓存：同一份字符串既可能是某条消息的分块键，
    /// 也可能是某个段落的行内键，混在一份里会取到错的那一种。
    final class Box {
        let blocks: [MarkdownBlock]?
        let inline: AttributedString?

        init(blocks: [MarkdownBlock]) {
            self.blocks = blocks
            self.inline = nil
        }

        init(inline: AttributedString) {
            self.blocks = nil
            self.inline = inline
        }
    }

    /// 每份缓存最多留多少条。
    private static let countLimit = 400

    private static let blocksCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = countLimit
        return cache
    }()

    private static let inlineCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = countLimit
        return cache
    }()

    /// 命中与未命中的计数。
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var hits = 0
        private var misses = 0

        func hit() {
            lock.lock()
            hits += 1
            lock.unlock()
        }

        func miss() {
            lock.lock()
            misses += 1
            lock.unlock()
        }

        var counts: (hits: Int, misses: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (hits, misses)
        }
    }

    private static let tally = Tally()

    /// 一份 Markdown 源的分块结果。键＝源：`parse` 只读这一份字符串。
    static func blocks(for source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let cached = blocksCache.object(forKey: key)?.blocks {
            tally.hit()
            return cached
        }
        tally.miss()
        let blocks = Markdown.parse(source)
        blocksCache.setObject(Box(blocks: blocks), forKey: key)
        return blocks
    }

    /// 一段行内 Markdown 的属性串。键＝原文。
    ///
    /// 字号、字重、颜色不进键：它们由 `SelectableText` 在渲染时按 run 加到
    /// `NSAttributedString` 上，属性串本身与它们无关。
    static func inline(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = inlineCache.object(forKey: key)?.inline {
            tally.hit()
            return cached
        }
        tally.miss()
        let inline = Markdown.inline(text)
        inlineCache.setObject(Box(inline: inline), forKey: key)
        return inline
    }

    /// 一次读缓存的结果，形如「命中=12 未命中=3」。
    static func stats() -> String {
        let counts = tally.counts
        return "命中=\(counts.hits) 未命中=\(counts.misses)"
    }
}
