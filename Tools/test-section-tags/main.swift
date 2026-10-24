import Foundation

// 用 Swift 跑一遍转换规则，用例与 scripts/fix_section_tags.py 对齐。
// 跑法：见同目录的 check-section-tags.sh

let singleCases: [(String, String)] = [
    ("【主歌1】", "[Verse 1]"),
    ("【主歌 2】", "[Verse 2]"),
    ("主歌三", "[Verse 3]"),
    ("[主歌]", "[Verse]"),
    ("## 副歌2", "[Chorus]"),
    ("副歌", "[Chorus]"),
    ("【预副歌】", "[Pre-Chorus]"),
    ("【桥段】", "[Bridge]"),
    ("【尾句】", "[Outro]"),
    ("【收尾】", "[Outro]"),
    ("【间奏】", "[Instrumental]"),
    ("（间奏）", "[Instrumental]"),
    ("前奏", "[Intro]"),
    ("1. 主歌三", "[Verse 3]"),
    // 不该动的
    ("示例歌名", "示例歌名"),
    ("（轻快民谣，直接可用）", "（轻快民谣，直接可用）"),
    ("主歌部分很动人，这句不能被转", "主歌部分很动人，这句不能被转"),
    ("[Verse]", "[Verse]"),
    ("[Instrumental]", "[Instrumental]"),
    ("铃声刚擦过窗沿", "铃声刚擦过窗沿"),
    ("", ""),
]

var failures = 0
var checks = 0

func check(_ label: String, _ got: String, _ expected: String) {
    checks += 1
    if got != expected {
        failures += 1
        print("FAIL \(label)：得到 \(got.debugDescription)，应为 \(expected.debugDescription)")
    }
}

for (input, expected) in singleCases {
    check("行", SectionTags.convertLine(input), expected)
}

// 整段：空行、标题、风格说明、正文都不该动
let sample = """
示例歌名
（轻快民谣，直接可用）

【主歌1】
铃声刚擦过窗沿
草稿纸画满歪线

【副歌】
一页一页 平平淡淡的校园

【尾句】
琐碎的日子 刚好新鲜
"""
let converted = SectionTags.toEngine(sample)
let expectedLines = [
    "示例歌名", "（轻快民谣，直接可用）", "",
    "[Verse 1]", "铃声刚擦过窗沿", "草稿纸画满歪线", "",
    "[Chorus]", "一页一页 平平淡淡的校园", "",
    "[Outro]", "琐碎的日子 刚好新鲜",
]
let gotLines = converted.components(separatedBy: "\n")
check("整段行数", "\(gotLines.count)", "\(expectedLines.count)")
for (i, expected) in expectedLines.enumerated() where i < gotLines.count {
    check("整段第 \(i + 1) 行", gotLines[i], expected)
}

// 幂等：转换过的再转一遍不变
check("幂等", SectionTags.toEngine(converted), converted)

if failures == 0 {
    print("全部通过（\(checks) 项）")
    exit(0)
} else {
    print("有 \(failures) 项失败")
    exit(1)
}
