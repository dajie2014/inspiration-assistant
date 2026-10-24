import Foundation

/// 生成结果放在哪 —— **只在这一处决定**。
///
/// 由头（用户 2026-10-12）：
/// 「他现在能不能把他所有生成的乐谱和音频放在用户指定的位置，而不是那个 output？」
/// ⇒ 加一个「输出文件夹」设置；**默认还是项目里的 `output/`**，
///   他没挑过的话，行为跟以前一模一样。
///
/// ★ 为什么单开一个文件、而不是在 `BackendClient` 里加个变量：
///   同一个路径原先**三处各算一遍** —— `BackendClient.outputRoot`、
///   `PreferencesView.shortOutputPath`、`PreferencesView.openOutputFolder`。
///   三处各写一遍，改一处必漏另外两处。这个项目已经为同一类毛病付过学费
///   （命名规则两份实现、进度 JSON 两份实现，都是撞见第三次才回头收口）。
///   所以趁这次收成一个来源。
enum OutputLocation {

    /// 用户挑的文件夹。**空串 = 没挑过，用默认那个**。
    /// 存的是完整路径；显示的时候才把家目录缩成 `~`。
    static let defaultsKey = "outputFolderPath"

    /// 改完发一声，主窗口收到就重扫列表。
    static let didChange = Notification.Name("ComposerStepOutputLocationChanged")

    /// 当前该往哪儿放。
    ///
    /// 先看自检开关 `CS_OUTPUT_DIR` —— 它让自动化验证把产物丢进临时目录，
    /// **不必去动用户的偏好设置**（改完还得记着改回来，迟早忘）。
    /// 没有它就按用户在偏好设置里挑的那个来；没挑过就是项目里的 `output/`。
    static func url(projectRoot: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["CS_OUTPUT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let custom = customPath
        guard !custom.isEmpty else {
            return projectRoot.appendingPathComponent("output")
        }
        return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
    }

    /// 给人看的样子（家目录缩成 `~`，长路径不至于把窗口撑开）。
    static func displayPath(projectRoot: URL) -> String {
        url(projectRoot: projectRoot).path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// 没挑过时给一句人话，免得界面上只有一行路径，看不出"默认"是什么意思。
    static var isCustom: Bool { !customPath.isEmpty }

    static var customPath: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    /// 挑一个新的（传空串 = 恢复默认）。**存完发通知**，主窗口据此重扫。
    static func setCustomPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
