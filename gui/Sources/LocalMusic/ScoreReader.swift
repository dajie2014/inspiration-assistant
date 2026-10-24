import Foundation

// MARK: - 从 MusicXML 里读出来的东西

/// 一份谱子里「人看得见」的那几样 —— 标题、速度、拍号、调号、和弦、文字标记、歌词。
///
/// 为什么要有它：从 Dorico 导出的谱子里**本来就带着歌词**（`<lyric>`），
/// 而 Composer Step 以前只把谱子当"音符 + 和弦"用，词得让人**再打一遍**。
/// 这一个文件把词连同速度、拍号、调号一起读出来 —— 用户 2026-10-12 提的
/// 「让 Composer Step 也能看懂带词的谱子」。
///
/// 名字用 `reading` 而不是别的：全项目统一叫「读谱」（notation reading），
/// 免得跟别处 `score` = 「评分」那个意思撞车。
struct ScoreReading {

    /// 谱面上某一处的一个标记（速度、拍号、调号、文字）。
    /// `measure` 是它在第几小节 —— 中途变速／转调要能指出位置。
    struct Mark: Equatable {
        var measure: String = ""
        var text: String = ""
    }

    var title: String = ""
    var creators: [String] = []
    var tempoMarks: [Mark] = []
    var timeMarks: [Mark] = []
    var keyMarks: [Mark] = []
    var chords: [String] = []
    var cueMarks: [Mark] = []
    /// 歌词 —— **已经分好行**，可以直接倒进歌词框。
    var lyricLines: [String] = []
    /// 谱面上一共有多少个音（**休止符不算**）。
    ///
    /// 用户 2026-10-13 点名要看的四样之一（拍号、调号、歌词、音符）——
    /// 原话「导入乐谱的时候顺便读一下它的拍号调号歌词音符，不要导入之后还是空」。
    var noteCount: Int = 0

    var hasLyrics: Bool { !lyricLines.isEmpty }
    var lyricText: String { lyricLines.joined(separator: "\n") }
    var lyricCount: Int { lyricLines.reduce(0) { $0 + $1.count } }

    /// 音位比歌词多多少个 —— 多出来的格子模型会**自己编词**。
    ///
    /// 2026-10-24 实测：用 208 字的旧歌词配 238 音位的谱，模型在 30 个空格里
    /// 编出了原词没有的"房间"。这不是它乱来，是"有音位没词"。
    var missingLyricSlots: Int { max(0, noteCount - lyricCount) }

    /// 给人看的一句话 —— 导入之后显示在提示那行。
    var summary: String {
        var bits: [String] = []
        if let t = tempoMarks.first {
            bits.append(tempoMarks.count > 1
                        ? "速度 \(t.text)（中途变了 \(tempoMarks.count - 1) 次）"
                        : "速度 \(t.text)")
        }
        if let t = timeMarks.first {
            bits.append(timeMarks.count > 1
                        ? "\(t.text) 拍（变了 \(timeMarks.count - 1) 次）"
                        : "\(t.text) 拍")
        }
        if let k = keyMarks.first {
            bits.append(keyMarks.count > 1 ? "\(k.text) 调（转调 \(keyMarks.count - 1) 次）"
                                           : "\(k.text) 调")
        }
        if !chords.isEmpty { bits.append("和弦 \(chords.count) 个") }
        // ★ **数不出来就不报**：`.abc` 那条路不数音符（见 `readABC`），
        //   无条件写就成了「音符 0 个」—— 那是**假话**，比不写更坏
        //   （2026-10-13 第一次跑自检就撞上：ABC 的摘要里赫然写着「音符 0 个」）。
        if noteCount > 0 { bits.append("音符 \(noteCount) 个") }
        bits.append(hasLyrics ? "歌词 \(lyricCount) 字" : "没带歌词")
        return bits.joined(separator: " · ")
    }
}

// MARK: - 读

/// MusicXML 通读器。**只用 Foundation 自带的 XMLParser**：不依赖任何外部程序、
/// 不联网 —— 与整个程序「一个字节不出网」保持一致。
///
/// 认的是 Dorico / MuseScore 这些制谱软件导出的标准 MusicXML（partwise）。
enum ScoreReader {

    enum Failure: LocalizedError {
        case unreadable(String)
        case notMusicXML(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why):  return "这份谱子打不开：\(why)"
            case .notMusicXML(let why): return "这不像一份 MusicXML：\(why)"
            }
        }
    }

    /// 读一份谱子。**两种格式都认**：`MusicXML`（Dorico 导出的）与 `.abc`（模型的记谱）。
    ///
    /// ★ 为什么要认 `.abc`（2026-10-13 补）：用户的谱子有一半是 ABC ——
    ///   Dorico 导出的 MusicXML 先转成 `.abc` 才喂回模型（见 `abcxml`），
    ///   改完谱再转回来。**只认 MusicXML 就不叫"导入乐谱就读得懂"**。
    ///   用户原话：「导入乐谱的时候顺便读一下它的拍号调号歌词音符」——
    ///   这话对两种格式都成立。
    static func read(_ url: URL) throws -> ScoreReading {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.unreadable("找不到 \(url.lastPathComponent)")
        }
        if url.pathExtension.lowercased() == "abc" {
            return try readABC(url)
        }
        guard let parser = XMLParser(contentsOf: url) else {
            throw Failure.unreadable("\(url.lastPathComponent) 不是文本 XML")
        }
        let reader = MusicXMLReader()
        parser.delegate = reader
        guard parser.parse() else {
            let why = parser.parserError?.localizedDescription ?? "解析中断"
            throw Failure.notMusicXML(why)
        }
        guard reader.sawScorePartwise else {
            throw Failure.notMusicXML("里面没有 <score-partwise>")
        }
        return reader.finish()
    }

    // MARK: - ABC 那一种

    /// 读一份 ABC —— 只认界面上用得着的几行：标题、拍号、调号、速度、歌词。
    ///
    /// 不追求读懂整份记谱（那要写一个像样的 ABC 解析器，不值当）；
    /// 但这几样正是用户点名要看的，而且 ABC 里**都有**、位置也固定。
    ///
    /// ⚠️ **音符数不数**：ABC 把音符、和弦标注（`"Dmaj7"`）、第二条声部（`&`）、
    ///   休止（`z` / 无声高轨的 `x`）全堆在一行里，数准得先写记谱解析器。
    ///   **数错比不数更坏** —— 他是作曲家，一眼就看得出这个数字不对。
    ///   所以 ABC 这边**只报其它几样，音符数留给 MusicXML 那条**（那边是精确的）。
    static func readABC(_ url: URL) throws -> ScoreReading {
        let text: String
        if let t = try? String(contentsOf: url, encoding: .utf8) {
            text = t
        } else if let t = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = t
        } else {
            throw Failure.unreadable("\(url.lastPathComponent) 读不出文字")
        }

        var out = ScoreReading()
        var lyricLines: [String] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "T":
                if out.title.isEmpty { out.title = value }
            case "M":
                if !value.isEmpty { out.timeMarks.append(.init(text: value)) }
            case "K":
                if !value.isEmpty { out.keyMarks.append(.init(text: value)) }
            case "Q":
                // `Q:1/4=143` → 只要那个 143（界面上人看的是"多快"）
                if let eq = value.lastIndex(of: "=") {
                    out.tempoMarks.append(.init(text: String(value[value.index(after: eq)...])))
                } else if !value.isEmpty {
                    out.tempoMarks.append(.init(text: value))
                }
            case "w":
                let one = abcLyricLine(value)
                if !one.isEmpty { lyricLines.append(one) }
            default:
                break
            }
        }
        out.lyricLines = mergeShortLines(lyricLines)
        return out
    }

    /// 把**太短的行并进上一行**。
    ///
    /// ABC 的 `w:` 行是**每 4 小节**一条（那是 `I:linebreak $` 定的），
    /// 跟乐句的边界**不重合** —— 于是常出现"上一行最后一个字被切到下一行"：
    ///
    ///     蝉 鸣 在 耳 边     ← 「…在耳边」
    ///     响                ← 这一个字单独成行，很难看，也不像一句话
    ///
    /// ⇒ **两个字以内的行，并进上一行**。第一次跑自检（2026-10-13）读他那份谱，
    ///   20 行里有三行是这种孤字（「响」「服」「起」），并完就顺了。
    ///
    /// ⚠️ **这是尽力而为**：真要断得准，得像 MusicXML 那条路一样去读音符与休止
    ///   （ABC 的 `&` 多声部、和弦轨、`z`/`x` 混在一行，写起来不值当）。
    ///   **字一个不错，分行是尽力而为** —— 跟 MusicXML 那边一个分寸。
    private static func mergeShortLines(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            if line.count <= 2, let last = out.popLast() {
                out.append(last + line)
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// 把一条 `w:` 行还原成一行歌词。
    ///
    /// ABC 的 `w:` 长这样（用户那份、从 Dorico 转出来的真样子）：
    ///
    ///     w: |绿 意 晃 动|在 头 顶 刚 好|挡 住 烫 人 的 太 阳|
    ///
    /// `|` 是小节线、`_` 是延音占位（**不是字**）——
    /// 拿掉它们、把音节连起来，就是一小句歌词。
    ///
    /// ★ **中文直接连、西文按空格连**：中文歌词一个音节一个字，连起来才成句；
    ///   西文用空格分的是**词**（`hel-lo world` 那种连字符是音节），
    ///   一律连起来会连成 `helloworld`。按有没有汉字分开处理。
    private static func abcLyricLine(_ raw: String) -> String {
        var syllables: [String] = []
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "|" }) {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "_" || t == "*" { continue }
            if t.hasPrefix("%") { break }          // 行内注释，后面都不是歌词
            syllables.append(t)
        }
        guard !syllables.isEmpty else { return "" }
        let hasHanzi = syllables.contains { s in
            s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        return hasHanzi ? syllables.joined() : syllables.joined(separator: " ")
    }
}

// MARK: - 解析器本体

/// 流式（SAX）解析。**为什么不用 DOM**：谱子动辄上万行 ——
/// 用户那份 124 小节的分谱就有 11000 行，边读边丢最省事。
private final class MusicXMLReader: NSObject, XMLParserDelegate {

    /// 一个音符事件 —— 只留断句用得着的，音高一律不要。
    private struct Event {
        var part: Int
        var verse: Int          // 歌词行号（1 = 第一行）
        var order: Int          // 出场次序 —— 两个事件时间相同时靠它排先后
        var pos: Double         // 起点（四分音符为单位）
        var dur: Double         // 时值
        var lyric: String?      // 有字 = 这个字；nil = 这个音符没词（延音或器乐）
    }

    private var stack: [String] = []
    private var text = ""

    private(set) var sawScorePartwise = false
    private var partIndex = -1
    private var measure = ""

    // 每个声部自己的走针（换声部要归零）
    private var clock = 0.0
    private var divisions = 1.0

    private var events: [Event] = []
    /// 事件的出场编号。**为什么要它**：Swift 的 `sorted` 不保证稳定，
    /// 而"一个音符挂两个字"时两者时间完全相同 —— 没有它，先后来可能会被翻过来。
    private var orderSeed = 0
    private var title = ""
    private var creators: [String] = []
    private var tempoMarks: [ScoreReading.Mark] = []
    private var timeMarks: [ScoreReading.Mark] = []
    private var keyMarks: [ScoreReading.Mark] = []
    private var chords: [String] = []
    private var cueMarks: [ScoreReading.Mark] = []
    /// 一共数到多少个音（休止符不算，和弦的附随音算 —— 它们都是谱面上真响的音）。
    private var noteCount = 0

    // 当前这个 <note> 的临时状态
    private var noteIsRest = false
    private var noteIsChord = false
    private var noteDuration: Double = 0
    /// 一个音符上能挂**好几个** `<lyric>` —— 谱面上"一个字挤不下"时，
    /// 制谱软件会把两个字搁在同一个音符上（用户那份里就有 4 处，
    /// 例如第 100 小节那个全音符上挂着「答」和「一」）。
    /// ⇒ 收成一个数组，少一个都会丢字（2026-10-12 实测：只留最后一个，359 字变 355）。
    private var noteLyrics: [String] = []
    private var lyricBuffer: String?
    private var noteVerse = 1

    // 当前这个 <harmony> 的临时状态
    private var harmonyRoot = ""
    private var harmonyRootAlter = 0
    private var harmonyKind = ""
    private var harmonyKindText: String?
    private var harmonyBass: String?
    private var harmonyBassAlter = 0

    private var pendingKeyFifths: Int?
    private var pendingKeyMode = "major"
    private var pendingBeats = ""
    private var pendingBeatType = ""

    private static let majorKeys = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C",
                                    "G", "D", "A", "E", "B", "F#", "C#"]
    private static let minorKeys = ["Abm", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm", "Am",
                                    "Em", "Bm", "F#m", "C#m", "G#m", "D#m", "A#m"]

    private var currentParent: String? {
        stack.count >= 2 ? stack[stack.count - 2] : nil
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: 开标签

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String]) {
        stack.append(name)
        text = ""

        switch name {
        case "score-partwise":
            sawScorePartwise = true
        case "part":
            partIndex += 1
            clock = 0
        case "measure":
            measure = attrs["number"] ?? ""
        case "note":
            noteIsRest = false
            noteIsChord = false
            noteDuration = 0
            noteLyrics = []
            lyricBuffer = nil
            noteVerse = 1
        case "rest":
            noteIsRest = true
        case "chord":
            noteIsChord = true
        case "lyric":
            // <lyric number="1" name="verse"> —— 第几行歌词
            noteVerse = Int(attrs["number"] ?? "1") ?? 1
            lyricBuffer = nil
        case "harmony":
            harmonyRoot = ""
            harmonyRootAlter = 0
            harmonyKind = ""
            harmonyKindText = nil
            harmonyBass = nil
            harmonyBassAlter = 0
        case "kind":
            harmonyKind = ""
            harmonyKindText = attrs["text"]
        case "key":
            pendingKeyFifths = nil
            pendingKeyMode = "major"
        case "time":
            pendingBeats = ""
            pendingBeatType = ""
        case "sound":
            // <sound tempo="158"/> —— 速度就在这儿，中途变速也走这条
            if let t = attrs["tempo"], let v = Double(t) {
                tempoMarks.append(.init(measure: measure, text: Self.formatNumber(v)))
            }
        default:
            break
        }
    }

    // MARK: 标签之间

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    // MARK: 闭标签

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let parent = currentParent
        let value = trimmed

        switch name {
        case "work-title", "movement-title":
            if title.isEmpty { title = value }
        case "creator":
            if !value.isEmpty { creators.append(value) }
        case "divisions":
            if parent == "attributes", let d = Double(value), d > 0 { divisions = d }
        case "duration":
            switch parent {
            case "note":    noteDuration = (Double(value) ?? 0) / divisions
            case "backup":  clock -= (Double(value) ?? 0) / divisions
            case "forward": clock += (Double(value) ?? 0) / divisions
            default:        break
            }
        case "root-step":
            harmonyRoot = value
        case "root-alter":
            harmonyRootAlter = Int(value) ?? 0
        case "bass-step":
            harmonyBass = value
        case "bass-alter":
            harmonyBassAlter = Int(value) ?? 0
        case "kind":
            harmonyKind = value
        case "fifths":
            if parent == "key" { pendingKeyFifths = Int(value) }
        case "mode":
            if parent == "key" { pendingKeyMode = value }
        case "beats":
            if parent == "time" { pendingBeats = value }
        case "beat-type":
            if parent == "time" { pendingBeatType = value }
        case "text":
            if parent == "lyric" {
                // Dorico 用「ー」标"一个字拖到下一个音"。它跟汉字「一」长得太像，
                // 界面上一律显示成下划线 `_`（用户 2026-10-24 定的）。
                // 送进引擎前会再剔掉 —— YuE2 只认字，见 `lyricsForEngine`。
                lyricBuffer = value
                    .replacingOccurrences(of: "ー", with: "_")
                    .replacingOccurrences(of: "〜", with: "_")
                    .replacingOccurrences(of: "～", with: "_")
            }
        case "lyric":
            // 一个音符上的每一段歌词各收一份 —— 别只留最后一个字
            if let t = lyricBuffer, !t.isEmpty { noteLyrics.append(t) }
        case "words":
            if !value.isEmpty { cueMarks.append(.init(measure: measure, text: value)) }
        case "key":
            if let f = pendingKeyFifths {
                let table = pendingKeyMode == "minor" ? Self.minorKeys : Self.majorKeys
                let idx = f + 7
                let key = (idx >= 0 && idx < table.count) ? table[idx] : "fifths=\(f)"
                keyMarks.append(.init(measure: measure, text: key))
            }
        case "time":
            if !pendingBeats.isEmpty, !pendingBeatType.isEmpty {
                timeMarks.append(.init(measure: measure, text: "\(pendingBeats)/\(pendingBeatType)"))
            }
        case "harmony":
            let name = harmonyName()
            if !name.isEmpty { chords.append(name) }
        case "note":
            if !noteIsRest { noteCount += 1 }
            if noteIsRest {
                clock += noteDuration
            } else if !noteIsChord {
                // 一个音符挂几个字，就出几个事件：时间相同、次序按谱面先后。
                // clock **只推一次** —— 它们共用这一个音符的时值。
                let words = Self.squeezeRepeats(noteLyrics)
                if words.isEmpty {
                    events.append(Event(part: partIndex, verse: noteVerse, order: orderSeed,
                                        pos: clock, dur: noteDuration, lyric: nil))
                    orderSeed += 1
                } else {
                    for word in words {
                        events.append(Event(part: partIndex, verse: noteVerse, order: orderSeed,
                                            pos: clock, dur: noteDuration, lyric: word))
                        orderSeed += 1
                    }
                }
                clock += noteDuration
            }
            // 和弦的附随音（<chord/>）既不推进走针，也不另算一个事件
        default:
            break
        }

        stack.removeLast()
        text = ""
    }

    // MARK: 收尾

    func finish() -> ScoreReading {
        var out = ScoreReading()
        out.title = title
        out.creators = creators
        out.tempoMarks = tempoMarks
        out.timeMarks = timeMarks
        out.keyMarks = keyMarks
        out.chords = chords
        out.cueMarks = cueMarks
        out.noteCount = noteCount
        out.lyricLines = Self.lineBreaks(from: events)
        return out
    }

    /// 把和弦拼成 `C9sus4/E` 这种人读的样子。
    ///
    /// ★ 优先用 Dorico 写在 `<kind text="9sus4">` 里的显示名 ——
    ///   它有就别自己去拼 degree，否则会拼出 `C9sus4+7+9` 这种重复的怪名字
    ///   （原型阶段实测踩到过）。
    private func harmonyName() -> String {
        guard !harmonyRoot.isEmpty else { return harmonyKind }
        var name = harmonyRoot + Self.alterSuffix(harmonyRootAlter)
        if let t = harmonyKindText {
            name += t
        } else {
            name += Self.kindSuffix(harmonyKind)
        }
        if let b = harmonyBass, !b.isEmpty {
            name += "/" + b + Self.alterSuffix(harmonyBassAlter)
        }
        return name
    }

    private static func alterSuffix(_ n: Int) -> String {
        switch n {
        case 1:  return "#"
        case 2:  return "##"
        case -1: return "b"
        case -2: return "bb"
        default: return ""
        }
    }

    private static func kindSuffix(_ kind: String) -> String {
        switch kind {
        case "major": return ""
        case "minor": return "m"
        case "dominant": return "7"
        case "major-seventh": return "maj7"
        case "minor-seventh": return "m7"
        case "diminished": return "dim"
        case "augmented": return "aug"
        case "half-diminished": return "m7b5"
        case "major-sixth": return "6"
        case "minor-sixth": return "m6"
        case "dominant-ninth": return "9"
        case "major-ninth": return "maj9"
        case "minor-ninth": return "m9"
        case "suspended-fourth": return "sus4"
        case "suspended-second": return "sus2"
        case "power": return "5"
        case "none": return ""
        default: return kind
        }
    }

    static func formatNumber(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// 同一个音符上**相邻的同一个字**只留一个。
    ///
    /// 为什么：Dorico 在个别音符上会把同一段歌词写两遍 —— 用户那份里第 83 小节
    /// 是「新」＋「新」、「是」＋「是」，第 102 小节是「长」＋「长」。
    /// 那不是"唱两遍"，是导出重复，照读会在歌词里留下「新新是是」。
    ///
    /// ⚠️ **只去相邻的同一个字** —— **不同的字要留住**：同一份谱第 100 小节那个
    ///    全音符上真的是「答」和「一」两个字（一音两字），去重过头就把词吃掉了。
    private static func squeezeRepeats(_ words: [String]) -> [String] {
        var out: [String] = []
        for w in words where !w.isEmpty && out.last != w {
            out.append(w)
        }
        return out
    }

    // MARK: 断句

    /// 把一串字按「哪儿在呼吸」分成行。
    ///
    /// ★ 规则是拿用户那份用户那份合唱谱量出来的（2026-10-12）：
    ///
    /// · **一个「字块」＝ 这个字的音符，加上它后面所有不停顿的音符**
    ///   （`<extend/>` 延音算，人声歇口气、乐器接着走的那几个音也算）。
    /// · **两个字块之间真正的休止**才是呼吸点，门槛取 **半拍**。
    /// · 本行已经有 **4 个字**才准断 —— 否则「赣江」这种两字一断会碎得没法看。
    /// · 一整段都没休止的（副歌里字挤在一起）由 **16 字**兜底硬断。
    ///
    /// 试过的另一种写法（把"无词的器乐音"也当间隔）会把「红色旗帜指向强国」
    /// 切成「…指 / 向强国…」，更差，所以没那么写。
    ///
    /// ⚠️ 它**不可能百分之百等于作词人的句读** —— MusicXML 里只有一个个孤字，
    ///    没有标点。所以这是"尽量合理"，不是"准确还原"；
    ///    用户在歌词框里顺手改两下就行。
    private static func lineBreaks(from events: [Event]) -> [String] {
        // 先挑一组歌词：行号最小的那一行（verse 1），再挑其中词最多的那个声部。
        guard let verse = events.compactMap({ $0.lyric != nil ? $0.verse : nil }).min() else {
            return []
        }
        var perPart: [Int: Int] = [:]
        for e in events where e.verse == verse && e.lyric != nil {
            perPart[e.part, default: 0] += 1
        }
        guard let part = perPart.max(by: { $0.value < $1.value })?.key else { return [] }

        let mine = events.filter { $0.part == part && $0.verse == verse }
                         .sorted { ($0.pos, $0.order) < ($1.pos, $1.order) }

        let minGap = 0.5, minLine = 4, cap = 16
        var lines: [String] = []
        var current = ""
        var blockEnd: Double?

        for e in mine {
            guard let word = e.lyric, !word.isEmpty else {
                blockEnd = e.pos + e.dur          // 延音 / 器乐音：这个字块还在走
                continue
            }
            if let end = blockEnd {
                let gap = e.pos - end
                if gap >= 8 {
                    // 大间奏：把这段词收掉，中间空一行
                    if !current.isEmpty { lines.append(current); current = "" }
                    if lines.last != "" { lines.append("") }
                } else if gap >= minGap, current.count >= minLine {
                    lines.append(current)
                    current = ""
                }
            }
            current += word
            if current.count >= cap {
                lines.append(current)
                current = ""
            }
            blockEnd = e.pos + e.dur
        }
        if !current.isEmpty { lines.append(current) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
