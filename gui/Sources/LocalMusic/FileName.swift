import Foundation

// MARK: - 给生成结果起一个看得懂的名字
//
// 2026-10-11 用户提的：生成出来的东西在文件夹里叫 `5c81fffe-d44e-….wav`，
// 一串乱码，隔天谁也认不出哪首是哪首。现在**目录名和 wav 名**都取这里的名字。
//
// ★ 这个文件**刻意只依赖 Foundation**：它是一条纯粹的文字规则，不碰界面、
//   不碰文件系统，所以能脱离 App 单独编译验证（`gui/check-naming.sh`）。
//   同一个理由，它也没有和 Models.swift 混在一起 —— 那边一 import 就是 SwiftUI。

/// 把一段文字变成**能当文件名用**的样子。
///
/// 规则：
///   · 斜杠、冒号、反斜杠换成下划线 —— 斜杠是路径分隔符；冒号在访达里会显示成斜杠
///   · 换行、制表压成空格，连续空格并成一个
///   · 去掉首尾空白、去掉末尾的点（末尾带点看着像漏字）
///   · 太长就截断；截完可能是空的，那就叫「未命名」
///
/// ⚠️ **脚本那边有一份等价的实现**（`scripts/headless_generate.py` 的
///    `safe_file_stem`）——目录由界面创建、文件由脚本命名，两边都得会这一手。
///    **两份必须给出完全一样的结果**，这一点由 `gui/check-naming.sh` 焊住：
///    它把同一批用例同时喂给两边，逐条比对，不一样就报错。
///    改这里就跑一遍那个脚本，它会告诉你另一边要不要跟着改。
enum FileName {

    /// 名字最长多少字。够认出是哪首，又不至于把访达那一栏撑破。
    static let maxLength = 40

    static func safe(_ raw: String, maxLength: Int = FileName.maxLength) -> String {
        var text = ""
        for ch in raw {
            switch ch {
            case "/", ":", "\\": text.append("_")
            case "\n", "\r", "\t": text.append(" ")
            default: text.append(ch)
            }
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = trim(text)
        if text.count > maxLength {
            text = trim(truncate(text, to: maxLength))
        }
        return text.isEmpty ? "未命名" : text
    }

    /// 截到 `maxLength` 字。
    ///
    /// ★ 英文长标题**别切在半截词上**：硬截会切出
    /// 「Contemporary chamber music for string qu」这种，看着像写坏了。
    /// 所以退到最后一个空格 —— 但**退太多就得不偿失**（至少保住一半），
    /// 中文没有空格、退不动，那就原样截。
    ///
    /// ★ 反过来的一个坑（2026-10-11 自己踩的）：**正好切在词尾时不该退**。
    /// 原先不判这一下，「Slow-building orchestral post-minimalism extra」
    /// 会把已经完整拿到的 `post-minimalism` 又丢回去。
    private static func truncate(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let cut = String(text.prefix(maxLength))
        if text.dropFirst(maxLength).first == " " { return cut }   // 正好切在词尾
        guard let space = cut.lastIndex(of: " ") else { return cut }
        let head = String(cut[cut.startIndex..<space])
        return head.count >= maxLength / 2 ? head : cut
    }

    /// 去掉首尾空白，并把末尾的点也去掉（去完可能又冒出空白，所以来回走）。
    private static func trim(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}
