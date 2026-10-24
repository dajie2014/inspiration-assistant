import AppKit

// MARK: - 「帮助」菜单里那一条：打开随 app 分发的《使用手册》

/// 为什么要自己做这一条，而不是用系统默认的那条：
///
/// macOS 给每个程序一个「帮助」菜单，默认在里面摆一条
/// **「Composer Step 帮助」**。它指向的是系统的"帮助书"，而本程序没有那份
/// 东西 —— 于是那条**永远是灰的 / 点开说"没有可用帮助"**。
/// 使用者 2026-10-11 指的就是它：
/// 「就是 Composer Step 自己的帮助下的菜单，现在显示 not available」。
///
/// ⇒ 做法：在 `LocalMusicApp` 里用 `CommandGroup(replacing: .help)`
///   把那一组**整组换掉**，换成能打开的这一条（那条死路就不摆了）。
///   手册是真的在 app 里（`Contents/Resources/`，由 `gui/build.sh`
///   从项目根拷进来），不是去网上找 —— 本程序全程不出这台机器。
///
/// 找不到时**如实弹窗**、并说清去哪儿生成，而不是点了一下什么都不发生：
/// 静默失败会让人以为菜单坏了（这毛病在隔壁 Composer Assistant 上真踩过）。
enum UserGuide {

    /// 装进 app 的文件名（不带 `.pdf`）。
    ///
    /// ⚠️ 名字由 Composer Step 的 `Tools/update_doc.sh` 定，**不是这边起的**。
    /// 真改要三处一起：那个脚本、磁盘上的文件、这里。
    /// `gui/build.sh` 每次构建都会确认它真的装进了 app。
    static let resourceName = "灵感助手-使用手册"

    /// 菜单上写什么。
    ///
    /// 在**本程序自己的**帮助菜单里，不必再重复程序名：菜单标题已经写着
    /// 「帮助」了。写成「Composer Step 使用手册」反倒像别人的文档。
    static let menuTitle = "使用手册"

    /// 打开手册；找不到就把话说清楚。
    static func open() {
        if let url = Bundle.main.url(forResource: resourceName,
                                     withExtension: "pdf") {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "这个构建没有附带《\(menuTitle)》"
        alert.informativeText = "在项目根目录跑 Tools/update_doc.sh 生成它，"
            + "然后重新跑 gui/build.sh。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
