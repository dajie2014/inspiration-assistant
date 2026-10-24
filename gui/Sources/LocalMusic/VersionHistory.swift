import SwiftUI
import AppKit

// MARK: - 《版本历史》

/// 《版本历史》的**正文不在代码里** —— 真源是项目根的 `CHANGELOG.md`，
/// 由 `gui/build.sh` 拷进 app 的 `Contents/Resources/`。这边只负责**排版**。
///
/// 抄一份在代码里就等于同一件事有两份说法，改一头忘一头；
/// 而这个程序会一直长（2026-10-12 一天里从一台引擎变成两台），
/// 使用者需要一个能自己看到「我这版多了什么」的地方，不必每次来问。
///
/// 版本号也从同一处来：`build.sh` 读 `CHANGELOG.md` 顶上那一版的号写进
/// Info.plist，这里再从 Info.plist 读回来 —— 显示的版本和写成历史的版本
/// 不可能对不上。
///
/// 放两个入口（同一个窗口）：**帮助 → 版本历史**，以及程序菜单里的
/// **关于 My Songwriter** —— 后者是 macOS 上的习惯位置，找的人常去那儿。
enum VersionHistory {

    /// 装进 app 的文件名（不带 `.md`）。
    /// ⚠️ `gui/build.sh` 里拷贝用的就是这个名字，改要两头一起改。
    static let resourceName = "CHANGELOG"

    /// 从 app 里读正文；读不到返回 nil，由调用方如实弹窗。
    static func markdown() -> String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    /// 程序当前版本号（构建时从 `CHANGELOG.md` 读出来写进 Info.plist 的）。
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "未知"
    }

    // MARK: 正文解析

    enum Block {
        case version(String)   // ## 0.2.0 · 2026-10-12
        case heading(String)   // ### xxx
        case note(String)      // > xxx
        case bullet(String)    // - xxx
        case para(String)
        case rule
    }

    /// 只认《版本历史》里真正用到的那几种记号，多余的语法一概不猜。
    ///
    /// 正文在 `.md` 里为了好读折了行：**行首缩进 = 上一条的续行**，
    /// 显示时并成一段（不缩进的行就是新的一段）。
    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("---") { blocks.append(.rule); continue }
            if trimmed.hasPrefix("## ") {
                blocks.append(.version(String(trimmed.dropFirst(3)))); continue
            }
            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(String(trimmed.dropFirst(4)))); continue
            }
            // 文档大标题不进窗口：窗口标题里已经写着「版本历史」了。
            if trimmed.hasPrefix("# ") { continue }
            if trimmed.hasPrefix("> ") {
                blocks.append(.note(String(trimmed.dropFirst(2)))); continue
            }
            if trimmed.hasPrefix("- ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2)))); continue
            }

            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if case .bullet(let prev)? = blocks.last {
                    blocks[blocks.count - 1] = .bullet(prev + " " + trimmed)
                } else if case .note(let prev)? = blocks.last {
                    blocks[blocks.count - 1] = .note(prev + " " + trimmed)
                } else if case .para(let prev)? = blocks.last {
                    blocks[blocks.count - 1] = .para(prev + " " + trimmed)
                } else {
                    blocks.append(.para(trimmed))
                }
                continue
            }
            blocks.append(.para(trimmed))
        }
        return blocks
    }

    /// 行内排版：认 `**粗体**` 与 `` `等宽` `` 两种记号。
    ///
    /// 为什么不直接用 `AttributedString(markdown:)`：正文里有
    /// `output/<时间戳> <名字>/` 这种尖括号，被当成 HTML 标签的话，
    /// 中间那几个字会被**悄悄吃掉** —— 自己切就不会有这种意外。
    static func inline(_ raw: String, size: CGFloat, color: Color) -> Text {
        var out = Text("")
        var buffer = ""
        var bold = false
        var monospaced = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = Text(buffer)
            if monospaced {
                piece = piece.font(.system(size: size - 0.5, design: .monospaced))
            } else if bold {
                piece = piece.font(.system(size: size, weight: .semibold))
            } else {
                piece = piece.font(.system(size: size))
            }
            out = out + piece.foregroundColor(color)
            buffer = ""
        }

        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i...].hasPrefix("**") {
                flush(); bold.toggle(); i = raw.index(i, offsetBy: 2); continue
            }
            if raw[i] == "`" {
                flush(); monospaced.toggle(); i = raw.index(after: i); continue
            }
            buffer.append(raw[i]); i = raw.index(after: i)
        }
        flush()
        return out
    }
}

// MARK: - 窗口

/// 自己造窗口（不走 SwiftUI 的 `Window` scene）：
/// 菜单里的按钮要能直接开它，自检开关 `CS_OPEN_HISTORY=1` 也要能直接开它，
/// 两边都不该去依赖某个 View 的 environment。
final class VersionHistoryWindow {

    static let shared = VersionHistoryWindow()
    private var window: NSWindow?

    /// 窗口宽度。正文一行三十来字，这个宽度读着不费眼。
    private static let width: CGFloat = 620
    /// 底部那一条状态栏占的高度（含分隔线，实测够用）。
    private static let footerHeight: CGFloat = 34

    func open() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let markdown = VersionHistory.markdown() else {
            let alert = NSAlert()
            alert.messageText = "这个构建没有附带《版本历史》"
            alert.informativeText = "在项目根目录跑 gui/build.sh —— "
                + "它会把 CHANGELOG.md 装进程序里。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        let blocks = VersionHistory.parse(markdown)
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        created.title = "灵感助手 · 版本历史"
        created.contentView = NSHostingView(rootView: VersionHistoryView(blocks: blocks))
        created.minSize = NSSize(width: 460, height: 380)
        // 关掉不销毁 —— 否则再点一次菜单会开到一个已经被释放的窗口上。
        created.isReleasedWhenClosed = false

        created.setContentSize(NSSize(width: Self.width,
                                      height: Self.preferredHeight(for: blocks)))
        created.center()
        window = created

        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口该开多高：**先量正文的真实高度**，再夹进屏幕里。
    ///
    /// ⚠️ 别去问那个带 `ScrollView` 的整窗口视图要多高 —— 它回的是被压缩过的值
    /// （2026-10-12 就是这么少显示了最后两条的）。所以另取一份**不带滚动**的正文
    /// （`VersionHistoryBody`，宽度钉成窗口宽）单独量，那才是正文真正需要的高度。
    ///
    /// 版数少时一屏全看见，不必先滚一下；长过屏幕就按屏幕的八成五开，其余靠滚。
    private static func preferredHeight(for blocks: [VersionHistory.Block]) -> CGFloat {
        let probe = NSHostingView(
            rootView: VersionHistoryBody(blocks: blocks, fixedWidth: width))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        let content = probe.fittingSize.height

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let wanted = (content > 120 ? content : 640) + footerHeight
        return max(420, min(wanted, screenHeight * 0.85))
    }
}

// MARK: - 正文（可单独量高，因此和外壳分开）

struct VersionHistoryBody: View {

    let blocks: [VersionHistory.Block]

    /// 量高度时把宽度钉死；真正显示时留空，由外面撑满。
    var fixedWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: fixedWidth, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ block: VersionHistory.Block) -> some View {
        switch block {
        case .version(let title):
            // 「0.2.0 · 2026-10-12」→ 号做成小徽章，日期跟在后面
            let parts = title.components(separatedBy: "·")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(parts.first ?? title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Palette.accent.opacity(0.16)))
                if parts.count > 1 {
                    Text(parts.dropFirst().joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)

        case .heading(let text):
            VersionHistory.inline(text, size: 13, color: Palette.textPrimary)
                .padding(.top, 4)

        case .note(let text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(Palette.stroke)
                    .frame(width: 2)
                VersionHistory.inline(text, size: 12, color: Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .bullet(let text):
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(Palette.accent.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
                VersionHistory.inline(text, size: 13, color: Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

        case .para(let text):
            VersionHistory.inline(text, size: 13, color: Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - 外壳（正文 + 底下一条状态栏）

struct VersionHistoryView: View {

    let blocks: [VersionHistory.Block]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VersionHistoryBody(blocks: blocks)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 正文只在滚动区里画。少了这两条，滚到底时最后几行会画到
            // 下面那条状态栏上去（2026-10-12 抓图时看见两行字叠在一起）。
            .frame(maxHeight: .infinity)
            .clipped()

            Rectangle().fill(Palette.stroke).frame(height: 1)

            HStack(spacing: 7) {
                Text("当前版本")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Text(VersionHistory.currentVersion)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Spacer()
                Text("最新的在最上面")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.windowBG)
        }
        .frame(minWidth: 460, minHeight: 380)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
    }
}
