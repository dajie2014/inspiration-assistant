import Foundation

/// 把歌词里的中文结构标记换成 ACE-Step / YuE2 认的英文方括号标记。
///
/// 用户 2026-10-24 提的：豆包写词爱带【主歌1】【副歌】这类中文段标，
/// 直接送进引擎会被当歌词唱出来。转换放在**送引擎之前**，
/// 界面上的歌词框保持原文不变 —— 用户看到的是自己的词，送出去的是引擎认的标记。
///
/// ⚠️ 与 `scripts/fix_section_tags.py` 是同一套规则（那个是给剪贴板双击用的）。
///    改映射表时两处一起改，别让它们漂开。
enum SectionTags {
    /// (中文写法, 英文标记, 要不要保留末尾编号)
    ///
    /// 依据是 ACE-Step 官方教程列出的结构标记：
    /// `[Intro]` `[Verse] / [Verse 1]` `[Pre-Chorus]` `[Chorus]` `[Bridge]` `[Outro]`，
    /// 外加官方样例里标纯器乐段的 `[Instrumental]`。
    static let aliases: [(names: [String], tag: String, keepNumber: Bool)] = [
        (["前奏", "引子", "序曲", "开场"], "Intro", false),
        (["预副歌", "导歌", "副歌前"], "Pre-Chorus", false),
        (["主歌", "正歌"], "Verse", true),
        (["副歌", "叠句"], "Chorus", false),
        (["桥段", "过桥", "过渡段", "桥"], "Bridge", false),
        (["尾句", "结尾", "尾声", "尾奏", "收尾", "结束"], "Outro", false),
        (["间奏", "器乐间奏", "乐器间奏"], "Instrumental", false),
    ]

    private static let openers = "【[（(｛{"
    private static let closers = "】]）)｝}"
    private static let cjkNumbers: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// 逐行转换；**正文一行都不碰**。
    static func toEngine(_ lyrics: String) -> String {
        let lines = lyrics.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { convertLine(String($0)) }.joined(separator: "\n")
    }

    /// 只转「整行就是段标」的行；别的行原样返回。
    ///
    /// 认这些写法：【主歌1】【主歌 2】主歌三、[副歌]、## 副歌2、1. 主歌三、（间奏）……
    static func convertLine(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // 行首的数字序号 / markdown 井号 / 列表符号
        s = s.replacingOccurrences(of: #"^\d{1,2}[.、．)）]\s*"#,
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[#>*•·\-–—]+\s*"#,
                                   with: "", options: .regularExpression)
        // 括号（最多一层）
        if let first = s.first, openers.contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        if let last = s.last, closers.contains(last) {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        // 行尾冒号
        if let last = s.last, last == "：" || last == ":" {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return line }

        for (names, tag, keepNumber) in aliases {
            for name in names where s.hasPrefix(name) {
                let rest = String(s.dropFirst(name.count))
                    .trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { return "[\(tag)]" }
                if let num = number(rest) {
                    return keepNumber ? "[\(tag) \(num)]" : "[\(tag)]"
                }
            }
        }
        return line
    }

    /// 编号后缀：`1` / `一` / `A` 认；别的一律不认（那多半是正文，不是段标）。
    private static func number(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        while let last = t.last, ".．、".contains(last) {
            t.removeLast()
        }
        if t.isEmpty { return nil }
        // 注意：`Character("三").isNumber` 也是 true（Unicode 把中文数字算作 Number），
        // 所以这里必须限定 ASCII，否则「主歌三」会原样留下「三」。
        if t.allSatisfy({ $0.isASCII && $0.isNumber }) { return t }
        if t.count == 1, let ch = t.first, let value = cjkNumbers[ch] {
            return String(value)
        }
        if t.count == 1, let ch = t.first, ch.isASCII, ch.isLetter {
            return String(ch).uppercased()
        }
        return nil
    }
}
