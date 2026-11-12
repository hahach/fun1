import Foundation

/// 最近一次主动选择的模型。
///
/// dsh 把「切模型」同时当作「保存新会话的默认」，但保存是后台异步的（成功后只记日志），
/// 于是刚切完就新建会话时，目录里的 default 还是旧的——界面上看就是「反应迟钝」。
/// 这里记住本机最后一次成功的选择，仅用于在目录还没刷新时把标签显示对；不参与任何请求。
enum ModelMemory {
    private static let key = "model.lastChosen"

    static func remember(_ option: ModelOption) {
        UserDefaults.standard.set([option.provider, option.model, option.name], forKey: key)
    }

    /// 只取显示名。
    static var name: String? {
        guard let stored = UserDefaults.standard.stringArray(forKey: key), stored.count == 3 else { return nil }
        return stored[2]
    }

    /// provider/model 对，用于在目录里找回完整条目。
    static var providerModel: (provider: String, model: String)? {
        guard let stored = UserDefaults.standard.stringArray(forKey: key), stored.count == 3 else { return nil }
        return (stored[0], stored[1])
    }
}
