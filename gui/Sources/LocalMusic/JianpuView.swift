import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - 数据

/// 括号里补进来的器乐音（人声休止时用下面那行填）。
struct JianpuFill {
    var start: Double = 0
    var dur: Double = 0
    var step: String = "C"
    var alter: Int = 0
    var octave: Int = 4
}

/// 一个音（或休止）。时间以四分音符为 1 拍。
struct JianpuNote {
    var start: Double = 0
    var dur: Double = 0
    var step: String = "C"
    var alter: Int = 0
    var octave: Int = 4
    var isRest: Bool = false
    var dots: Int = 0
    var tieStart: Bool = false
    var tieStop: Bool = false
    /// 这个音是前一个音跨小节延过来的：不画数字，只画延音线。
    var tieContinuation: Bool = false
    /// 延音线延伸到哪（全谱绝对拍）。
    var tieLineTo: Double? = nil
    /// 延音弧拉到后一个音的哪个位置（后一个音中心的绝对拍）。
    var tieArcTo: Double? = nil
    var lyric: String = ""
    var fill: [JianpuFill] = []
}

struct JianpuMeasure {
    var number: Int = 0
    var beats: Double = 4
    var notes: [JianpuNote] = []
    var tonicPC: Int = 0
    var keyAlters: [String: Int] = [:]
    var timeNum: Int = 4
    var timeDen: Int = 4
    /// 本小节在整首谱里的起始拍（跨小节延音用）。
    var startAbs: Double = 0
}

struct JianpuScore {
    var title: String = ""
    var lyricist: String = ""
    var composer: String = ""
    var measures: [JianpuMeasure] = []
    var tonicPC: Int = 0
    var timeNum: Int = 4
    var timeDen: Int = 4
}

// MARK: - 读 MusicXML

/// 只读简谱要用的东西：音高、时值、歌词、调号、拍号。
/// 项目里另有一个 `ScoreReader`，那个是给"照谱子唱"用的、**故意不留音高**；
/// 简谱必须知道每个音多高，所以单独写一个，不搅在一起。
final class JianpuXMLParser: NSObject, XMLParserDelegate {

    private var stack: [String] = []
    private var text = ""

    private var divisions: Double = 1
    private var clock: Double = 0
    private var measureNumber = 1
    private var timeNum = 4
    private var timeDen = 4
    private var fifths = 0
    private var mode = "major"
    private var tonicPC = 0
    private var keyAlters: [String: Int] = [:]

    private var partMeasures: [[JianpuMeasure]] = []
    private var currentPart: [JianpuMeasure] = []
    private var current: [JianpuNote] = []

    // 当前 note 的临时状态
    private var nRest = false
    private var nChord = false
    private var nDur: Double = 0
    private var nStep = "C"
    private var nAlter = 0
    private var nOctave = 4
    private var nDots = 0
    private var nTieStart = false
    private var nTieStop = false
    private var nLyric = ""
    private var nLyricBuffer: String?
    private var lastStart: Double = 0

    private var title = ""
    private var lyricist = ""
    private var composer = ""
    private var creatorType = ""

    private static let stepSemi: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    static func parse(url: URL) throws -> JianpuScore {
        let parser = JianpuXMLParser()
        guard let xml = XMLParser(contentsOf: url) else {
            throw NSError(domain: "Jianpu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "这个文件打不开，不像是 MusicXML。"])
        }
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse() else {
            throw NSError(domain: "Jianpu", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "MusicXML 读到一半停了：\(xml.parserError?.localizedDescription ?? "格式不对")"])
        }
        return parser.finish()
    }

    private var parent: String? { stack.count >= 2 ? stack[stack.count - 2] : nil }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String]) {
        stack.append(name)
        text = ""
        switch name {
        case "part":
            clock = 0
            currentPart = []
            divisions = 1
            fifths = 0
            mode = "major"
            timeNum = 4
            timeDen = 4
        case "measure":
            measureNumber = Int(attrs["number"] ?? "") ?? (currentPart.count + 1)
            current = []
            clock = 0
        case "note":
            nRest = false; nChord = false; nDur = 0
            nStep = "C"; nAlter = 0; nOctave = 4
            nDots = 0; nTieStart = false; nTieStop = false
            nLyric = ""; nLyricBuffer = nil
        case "rest":
            nRest = true
        case "chord":
            nChord = true
        case "dot":
            nDots += 1
        case "tie", "tied":
            // MusicXML 有两种写法：<tie> 和 <notations><tied>。两种都认，
            // 免得碰上只写后一种的谱子就漏掉延音线。
            let t = attrs["type"] ?? ""
            if t == "start" { nTieStart = true }
            if t == "stop" { nTieStop = true }
        case "creator":
            creatorType = attrs["type"] ?? ""
        case "key":
            fifths = 0
            mode = "major"
        case "time":
            timeNum = 4; timeDen = 4
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let p = parent
        let value = trimmed

        switch name {
        case "work-title", "movement-title":
            if title.isEmpty { title = value }
        case "creator":
            if !value.isEmpty {
                if creatorType == "lyricist" { lyricist = value }
                else if creatorType == "composer" { composer = value }
            }
        case "divisions":
            if let d = Double(value), d > 0 { divisions = d }
        case "fifths":
            if p == "key", let f = Int(value) { fifths = f }
        case "mode":
            if p == "key", !value.isEmpty { mode = value }
        case "beats":
            if p == "time", let b = Int(value) { timeNum = b }
        case "beat-type":
            if p == "beat", let b = Int(value) { timeDen = b }
        case "beat-type" where p == "time":
            if let b = Int(value) { timeDen = b }
        case "backup":
            if let d = Double(value) { clock -= d }
        case "forward":
            if let d = Double(value) { clock += d }
        case "step":
            if p == "pitch" { nStep = value.isEmpty ? "C" : value }
        case "alter":
            if p == "pitch", let a = Double(value) { nAlter = Int(a.rounded()) }
        case "octave":
            if p == "pitch", let o = Int(value) { nOctave = o }
        case "duration":
            if p == "note", let d = Double(value) { nDur = d }
        case "text":
            if p == "lyric" { nLyricBuffer = value }
        case "note":
            commitNote()
        case "measure":
            commitMeasure()
        case "part":
            partMeasures.append(currentPart)
        default:
            break
        }
        if !stack.isEmpty { stack.removeLast() }
    }

    private func commitNote() {
        let durBeats = nDur / divisions
        var start: Double
        if nChord {
            start = lastStart
        } else {
            start = clock / divisions
            lastStart = start
            clock += nDur
        }

        var note = JianpuNote()
        note.start = start
        note.dur = durBeats
        note.isRest = nRest
        note.step = nStep
        note.alter = nAlter
        note.octave = nOctave
        note.dots = nDots
        note.tieStart = nTieStart
        note.tieStop = nTieStop
        note.lyric = nLyricBuffer ?? ""

        // 和弦：只留最高音（简谱单声部）
        if nChord, let last = current.last, !last.isRest, !note.isRest {
            if midi(note) > midi(last) {
                var replacement = note
                if replacement.lyric.isEmpty { replacement.lyric = last.lyric }
                current[current.count - 1] = replacement
            }
            return
        }

        current.append(note)
    }

    private func commitMeasure() {
        guard !current.isEmpty || measureNumber > 0 else { return }
        var m = JianpuMeasure()
        m.number = measureNumber
        m.beats = Double(timeNum) * 4.0 / Double(timeDen)
        m.notes = current.sorted { a, b in
            if abs(a.start - b.start) > 0.0001 { return a.start < b.start }
            return (a.isRest ? 0 : midi(a)) > (b.isRest ? 0 : midi(b))
        }
        let (pc, alters) = Self.keyFromFifths(fifths, mode: mode)
        m.tonicPC = pc
        m.keyAlters = alters
        m.timeNum = timeNum
        m.timeDen = timeDen
        currentPart.append(m)
    }

    private func midi(_ n: JianpuNote) -> Int {
        let semi = Self.stepSemi[n.step] ?? 0
        return 12 * (n.octave + 1) + semi + n.alter
    }

    private func finish() -> JianpuScore {
        let melody = partMeasures.first ?? []
        let acc = partMeasures.count > 1 ? partMeasures[1] : []
        var merged = merge(melody: melody, accompaniment: acc)
        var running = 0.0
        for i in merged.indices {
            merged[i].startAbs = running
            running += merged[i].beats
        }
        merged = mergeTies(merged)
        var s = JianpuScore()
        s.title = title
        s.measures = merged
        s.tonicPC = merged.first?.tonicPC ?? 0
        s.timeNum = merged.first?.timeNum ?? 4
        s.timeDen = merged.first?.timeDen ?? 4
        s.lyricist = lyricist
        s.composer = composer
        return s
    }

    /// 人声休止的地方，用第二行（器乐旋律）的音补上，放进括号。
    private func merge(melody: [JianpuMeasure], accompaniment: [JianpuMeasure]) -> [JianpuMeasure] {
        guard !accompaniment.isEmpty else { return melody }
        var out = melody
        for i in out.indices {
            guard let acc = accompaniment.first(where: { $0.number == out[i].number }) else { continue }
            for j in out[i].notes.indices where out[i].notes[j].isRest {
                let r = out[i].notes[j]
                var fills: [JianpuFill] = []
                for note in acc.notes where !note.isRest
                    && note.start >= r.start - 0.001
                    && note.start < r.start + r.dur - 0.001 {
                    // 器乐声部自己的 tie：后一个音并进前一个，不再单独写一个数字。
                    if note.tieStop, var last = fills.last,
                       last.step == note.step, last.octave == note.octave,
                       last.alter == note.alter {
                        last.dur += note.dur
                        fills[fills.count - 1] = last
                    } else {
                        fills.append(JianpuFill(start: note.start, dur: note.dur,
                                                step: note.step, alter: note.alter,
                                                octave: note.octave))
                    }
                }
                out[i].notes[j].fill = fills
            }
        }
        return out
    }

    /// 同音连线（tie）：后一个音不再画数字，前一个音的延音线画到它结束。
    /// 用户 2026-10-19 点名：legato 可以不认，tie 必须认 —— 它管跨小节时值。
    private func mergeTies(_ measures: [JianpuMeasure]) -> [JianpuMeasure] {
        var out = measures
        var pending: (Int, Int)? = nil
        for mi in out.indices {
            for ni in out[mi].notes.indices {
                let n = out[mi].notes[ni]
                if n.tieStop, let p = pending {
                    let a = out[p.0].notes[p.1]
                    let aEnd = out[p.0].startAbs + a.start + a.dur
                    let nStart = out[mi].startAbs + n.start
                    if a.step == n.step, a.octave == n.octave, a.alter == n.alter,
                       out[p.0].tonicPC == out[mi].tonicPC,
                       abs(aEnd - nStart) < 0.01 {
                        out[mi].notes[ni].tieContinuation = true
                        out[p.0].notes[p.1].tieLineTo = out[mi].startAbs + n.start + n.dur
                        out[p.0].notes[p.1].tieArcTo = out[mi].startAbs + n.start + n.dur / 2
                        pending = nil
                    }
                }
                if n.tieStart {
                    pending = (mi, ni)
                }
            }
        }
        return out
    }

    static func keyFromFifths(_ fifths: Int, mode: String) -> (Int, [String: Int]) {
        var alters: [String: Int] = ["C": 0, "D": 0, "E": 0, "F": 0, "G": 0, "A": 0, "B": 0]
        let sharps = ["F", "C", "G", "D", "A", "E", "B"]
        let flats = ["B", "E", "A", "D", "G", "C", "F"]
        if fifths > 0 {
            for s in sharps.prefix(min(fifths, 7)) { alters[s] = 1 }
        } else if fifths < 0 {
            for s in flats.prefix(min(-fifths, 7)) { alters[s] = -1 }
        }
        var pc = ((fifths * 7) % 12 + 12) % 12
        if mode == "minor" { pc = (pc + 9) % 12 }
        return (pc, alters)
    }
}

// MARK: - 简谱规则

enum JianpuTheory {
    static let stepOrder: [String: Int] = ["C": 0, "D": 1, "E": 2, "F": 3, "G": 4, "A": 5, "B": 6]
    static let stepSemi: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    static let pitchNames: [(String, Int)] = [
        ("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0), ("F", 0),
        ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0)
    ]
    static let naturalDegree: [Int: Int] = [0: 1, 2: 2, 4: 3, 5: 4, 7: 5, 9: 6, 11: 7]

    static func pc(_ step: String, _ alter: Int) -> Int {
        ((stepSemi[step] ?? 0) + alter) % 12
    }

    static func diatonic(_ step: String, _ octave: Int) -> Int {
        octave * 7 + (stepOrder[step] ?? 0)
    }

    static func keyName(_ pc: Int) -> String {
        let names = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return names[((pc % 12) + 12) % 12]
    }

    static func tonicStep(_ pc: Int) -> String {
        for (s, a) in pitchNames where self.pc(s, a) == pc { return s }
        return "C"
    }

    /// 返回（数字，升降号，八度位移）
    static func degree(step: String, alter: Int, octave: Int,
                       tonicPC: Int, keyAlters: [String: Int], tonicDI: Int) -> (String, String, Int) {
        let rel = ((pc(step, alter) - tonicPC) % 12 + 12) % 12
        let di = diatonic(step, octave)
        let shift = Int(floor(Double(di - tonicDI) / 7.0))
        if let d = naturalDegree[rel] {
            return ("\(d)", "", shift)
        }
        let expected = keyAlters[step] ?? 0
        if alter > expected {
            let base = ((rel - 1) % 12 + 12) % 12
            if let d = naturalDegree[base] { return ("\(d)", "♯", shift) }
        } else {
            let base = ((rel + 1) % 12 + 12) % 12
            if let d = naturalDegree[base] { return ("\(d)", "♭", shift) }
        }
        return ("1", "", shift)
    }

    /// 把 1 的八度放在音域中间
    static func tonicDI(_ score: JianpuScore) -> Int {
        var dis: [Int] = []
        for m in score.measures {
            for n in m.notes where !n.isRest {
                dis.append(diatonic(n.step, n.octave))
            }
        }
        guard let lo = dis.min(), let hi = dis.max() else {
            return diatonic("C", 4)
        }
        let med = Double(lo + hi) / 2.0
        let step = tonicStep(score.tonicPC)
        let est = Int((med / 7.0).rounded())
        var best = diatonic(step, est)
        var bestDist = Double.greatestFiniteMagnitude
        for o in (est - 2)...(est + 2) {
            let v = diatonic(step, o)
            let d = abs(Double(v) - med)
            if d < bestDist { best = v; bestDist = d }
        }
        return best
    }
}

// MARK: - 分页与布局

struct JianpuLine {
    var measures: [JianpuMeasure]
}

struct JianpuPage {
    var lines: [JianpuLine]
    var showHeader: Bool
}

enum JianpuLayout {
    static let pageW: CGFloat = 595.28
    static let pageH: CGFloat = 841.89
    static let margin: CGFloat = 44
    static let lineH: CGFloat = 76
    static let digitSize: CGFloat = 17
    static let lyricSize: CGFloat = 10

    static func beatWidth(perLine: Int) -> CGFloat {
        (pageW - margin * 2) / CGFloat(perLine * 4)
    }

    static func paginate(_ score: JianpuScore, perLine: Int) -> [JianpuPage] {
        var lines: [JianpuLine] = []
        var cur: [JianpuMeasure] = []
        var beats = 0.0
        let cap = Double(perLine) * 4.0
        for m in score.measures {
            if !cur.isEmpty, Double(cur.count) >= Double(perLine) || beats + m.beats > cap + 0.01 {
                lines.append(JianpuLine(measures: cur))
                cur = []
                beats = 0
            }
            cur.append(m)
            beats += m.beats
        }
        if !cur.isEmpty { lines.append(JianpuLine(measures: cur)) }

        var pages: [JianpuPage] = []
        var idx = 0
        var first = true
        while idx < lines.count {
            let capacity = first ? 8 : 9
            let end = min(idx + capacity, lines.count)
            pages.append(JianpuPage(lines: Array(lines[idx..<end]), showHeader: first))
            idx = end
            first = false
        }
        if pages.isEmpty { pages.append(JianpuPage(lines: [], showHeader: true)) }
        return pages
    }
}

// MARK: - 画一页

struct JianpuPageView: View {
    let score: JianpuScore
    let page: JianpuPage
    let pageIndex: Int
    let pageCount: Int
    let perLine: Int

    private enum Align { case leading, center, trailing }

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / JianpuLayout.pageW
            ctx.scaleBy(x: s, y: s)
            draw(ctx)
        }
        .background(Color.white)
    }

    private func draw(_ ctx: GraphicsContext) {
        let beatW = JianpuLayout.beatWidth(perLine: perLine)
        var y: CGFloat = 0

        if page.showHeader {
            drawText(ctx, score.title.isEmpty ? "简谱" : score.title,
                     at: CGPoint(x: JianpuLayout.pageW / 2, y: 30), size: 21, weight: .bold)
            var sub: [String] = []
            if !score.lyricist.isEmpty { sub.append("词 \(score.lyricist)") }
            if !score.composer.isEmpty { sub.append("曲 \(score.composer)") }
            if !sub.isEmpty {
                drawText(ctx, sub.joined(separator: "　"),
                         at: CGPoint(x: JianpuLayout.pageW / 2, y: 50), size: 9, color: .gray)
            }
            drawText(ctx, "1=\(JianpuTheory.keyName(score.tonicPC))　\(score.timeNum)/\(score.timeDen)",
                     at: CGPoint(x: JianpuLayout.margin, y: 80), size: 11, color: Color(red: 0.6, green: 0.2, blue: 0.07), align: .leading)
            y = 108
        } else {
            y = 68
        }

        let tonicDI = JianpuTheory.tonicDI(score)
        let lineCap = page.showHeader ? 8 : 9
        for (li, line) in page.lines.prefix(lineCap).enumerated() {
            let baseY = y + CGFloat(li) * JianpuLayout.lineH
            drawLine(ctx, line: line, baseY: baseY, beatW: beatW, tonicDI: tonicDI,
                     showNumber: !page.showHeader || li > 0)
        }

        // 页码
        drawText(ctx, "\(pageIndex + 1) / \(pageCount)",
                 at: CGPoint(x: JianpuLayout.pageW / 2, y: JianpuLayout.pageH - 20), size: 8, color: .gray)
    }

    private func drawLine(_ ctx: GraphicsContext, line: JianpuLine,
                          baseY: CGFloat, beatW: CGFloat, tonicDI: Int,
                          showNumber: Bool) {
        var x = JianpuLayout.margin
        for m in line.measures {
            let mw = CGFloat(m.beats) * beatW
            let mx0 = x
            if showNumber {
                drawText(ctx, "\(m.number)", at: CGPoint(x: mx0 + 2, y: baseY - 30),
                         size: 7, color: Color(white: 0.65), align: .leading)
            }

            if m.notes.isEmpty {
                drawText(ctx, "0", at: CGPoint(x: mx0 + mw / 2, y: baseY),
                         size: JianpuLayout.digitSize, color: Color(white: 0.72))
            }

            for n in m.notes {
                if n.start >= m.beats - 0.0001 { continue }
                let cell = CGFloat(max(n.dur, 0.0625)) * beatW
                let cx = mx0 + CGFloat(n.start) * beatW + cell / 2
                if n.isRest {
                    if n.fill.isEmpty {
                        let count = max(1, Int(n.dur.rounded()))
                        for k in 0..<count {
                            let rx = mx0 + (CGFloat(n.start) + CGFloat(k) + 0.5) * beatW
                            drawText(ctx, "0", at: CGPoint(x: rx, y: baseY),
                                     size: JianpuLayout.digitSize, color: Color(white: 0.72))
                        }
                    } else {
                        let firstF = n.fill.first!
                        let lastF = n.fill.last!
                        let firstCx = mx0 + CGFloat(firstF.start) * beatW
                            + CGFloat(max(firstF.dur, 0.0625)) * beatW / 2
                        let lastCx = mx0 + CGFloat(lastF.start) * beatW
                            + CGFloat(max(lastF.dur, 0.0625)) * beatW / 2
                        let leftX = firstCx - 8
                        let rightX = min(lastCx + 9, mx0 + mw - 4)
                        drawText(ctx, "(", at: CGPoint(x: leftX, y: baseY), size: 13, color: .black, baseline: true)
                        drawText(ctx, ")", at: CGPoint(x: rightX, y: baseY), size: 13, color: .black, baseline: true)
                        for f in n.fill {
                            let fcell = CGFloat(max(f.dur, 0.0625)) * beatW
                            let fcx = mx0 + CGFloat(f.start) * beatW + fcell / 2
                            // 用户 2026-10-19：括号里的数字不要变小 —— 和唱的音一样大，
                            // 免得 tie 弧跨过去时看起来像连了一个小字。
                            let ffs = min(JianpuLayout.digitSize, max(10, fcell * 1.05))
                            let (fd, facc, fshift) = JianpuTheory.degree(
                                step: f.step, alter: f.alter, octave: f.octave,
                                tonicPC: m.tonicPC, keyAlters: m.keyAlters, tonicDI: tonicDI)
                            drawText(ctx, facc + fd, at: CGPoint(x: fcx, y: baseY),
                                     size: ffs, weight: .medium, color: Color(white: 0.12),
                                     baseline: true)
                            if fshift != 0 {
                                for k in 0..<min(abs(fshift), 2) {
                                    let py = fshift > 0 ? baseY - ffs / 2 - 5 - CGFloat(k) * 4.5
                                                        : baseY + ffs / 2 + 2 + CGFloat(k) * 4.5
                                    ctx.fill(Path(ellipseIn: CGRect(x: fcx - 1.3, y: py - 1.3,
                                                                    width: 2.6, height: 2.6)),
                                             with: .color(.black))
                                }
                            }
                        }
                    }
                    continue
                }

                if n.tieContinuation, n.start < 0.001 {
                    // 跨小节接过来的：从行首画一小段弧到数字
                    let x1 = mx0 + 2
                    let x2 = mx0 + CGFloat(n.start + n.dur / 2) * beatW
                    if x2 > x1 + 2 {
                        var path = Path()
                        let y = baseY - 16
                        path.move(to: CGPoint(x: x1, y: y))
                        path.addQuadCurve(to: CGPoint(x: x2, y: y),
                                          control: CGPoint(x: (x1 + x2) / 2, y: y - 6))
                        ctx.stroke(path, with: .color(.black), lineWidth: 1.1)
                    }
                }

                let fs = min(JianpuLayout.digitSize, max(10, cell * 1.05))
                let (digit, acc, shift) = number(for: n, m: m, tonicDI: tonicDI)
                drawText(ctx, acc + digit, at: CGPoint(x: cx, y: baseY),
                         size: fs, weight: .semibold, align: .center, baseline: true)

                if n.tieStart, let arcTo = n.tieArcTo {
                    let x1 = cx + 4
                    let x2: CGFloat
                    if arcTo > m.startAbs + m.beats - 0.001 {
                        x2 = mx0 + CGFloat(m.beats) * beatW - 4
                    } else {
                        x2 = mx0 + CGFloat(arcTo - m.startAbs) * beatW - 3
                    }
                    if x2 > x1 + 3 {
                        var path = Path()
                        let y = baseY - 16
                        path.move(to: CGPoint(x: x1, y: y))
                        path.addQuadCurve(to: CGPoint(x: x2, y: y),
                                          control: CGPoint(x: (x1 + x2) / 2, y: y - 6))
                        ctx.stroke(path, with: .color(.black), lineWidth: 1.1)
                    }
                }

                if n.dots > 0 && !n.isRest {
                    for k in 0..<n.dots {
                        let dcx = cx + fs * 0.62 + CGFloat(k) * 6
                        ctx.fill(Path(ellipseIn: CGRect(x: dcx - 1.6, y: baseY - 6.4, width: 3.2, height: 3.2)),
                                 with: .color(.black))
                    }
                }

                if !n.isRest && shift != 0 {
                    for k in 0..<min(abs(shift), 2) {
                        let py = shift > 0 ? baseY - fs - 4 - CGFloat(k) * 6
                                           : baseY + 7 + CGFloat(k) * 6
                        ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.8, y: py - 1.8, width: 3.6, height: 3.6)),
                                 with: .color(.black))
                    }
                }

                let (bars, underline) = durationMarks(n.dur, dots: n.dots)
                if underline > 0 {
                    var ux1 = cx - cell / 2
                    var ux2 = cx + cell / 2
                    if onBeat(n.start) { ux1 += 2 }
                    if onBeat(n.start + n.dur) { ux2 -= 2 }
                    for k in 0..<underline {
                        let uy = baseY + 12 + CGFloat(k) * 3.4
                        var path = Path()
                        path.move(to: CGPoint(x: ux1, y: uy))
                        path.addLine(to: CGPoint(x: ux2, y: uy))
                        ctx.stroke(path, with: .color(.black), lineWidth: 1.1)
                    }
                }

                if bars > 0 {
                    for k in 0..<bars {
                        let lx = mx0 + CGFloat(n.start + 1 + Double(k)) * beatW
                        var path = Path()
                        path.move(to: CGPoint(x: lx + 5, y: baseY - 6))
                        path.addLine(to: CGPoint(x: lx + beatW - 5, y: baseY - 6))
                        ctx.stroke(path, with: .color(.black), lineWidth: 1)
                    }
                }

                if !n.lyric.isEmpty {
                    drawText(ctx, n.lyric, at: CGPoint(x: cx, y: baseY + 25),
                             size: JianpuLayout.lyricSize, color: Color(white: 0.2))
                }
            }

            // 小节线
            var bar = Path()
            bar.move(to: CGPoint(x: mx0 + mw, y: baseY - 30))
            bar.addLine(to: CGPoint(x: mx0 + mw, y: baseY + 34))
            ctx.stroke(bar, with: .color(Color(white: 0.45)), lineWidth: 0.7)
            x += mw
        }
        var left = Path()
        left.move(to: CGPoint(x: JianpuLayout.margin, y: baseY - 30))
        left.addLine(to: CGPoint(x: JianpuLayout.margin, y: baseY + 34))
        ctx.stroke(left, with: .color(Color(white: 0.45)), lineWidth: 0.7)
    }

    private func number(for n: JianpuNote, m: JianpuMeasure,
                        tonicDI: Int) -> (String, String, Int) {
        if n.isRest { return ("0", "", 0) }
        return JianpuTheory.degree(step: n.step, alter: n.alter, octave: n.octave,
                                   tonicPC: m.tonicPC, keyAlters: m.keyAlters,
                                   tonicDI: tonicDI)
    }

    private func onBeat(_ v: Double) -> Bool {
        let r = v.truncatingRemainder(dividingBy: 1)
        return min(r, 1 - r) < 0.001
    }

    /// (延音横线数, 减时线层数)
    private func durationMarks(_ beats: Double, dots: Int) -> (Int, Int) {
        if beats >= 0.99 {
            let full = Int(beats.rounded(.down) + 0.0001)
            return (max(0, full - 1), 0)
        }
        if beats >= 0.49 { return (0, 1) }
        if beats >= 0.24 { return (0, 2) }
        return (0, 3)
    }

    private func drawText(_ ctx: GraphicsContext, _ s: String, at point: CGPoint,
                          size: CGFloat, weight: Font.Weight = .regular,
                          color: Color = .black,
                          align: Align = .center,
                          baseline: Bool = false) {
        let font = Font.system(size: size, weight: weight)
        var t = Text(s).font(font).foregroundStyle(color)
        if !baseline {
            // 以中心对齐；用 resolved text 的尺寸做垂直居中
            let resolved = ctx.resolve(t)
            let h = resolved.measure(in: CGSize(width: 500, height: 100)).height
            let anchor: UnitPoint = align == .leading ? UnitPoint(x: 0, y: 0.5)
                : (align == .trailing ? UnitPoint(x: 1, y: 0.5) : UnitPoint(x: 0.5, y: 0.5))
            ctx.draw(t, at: CGPoint(x: point.x, y: point.y + h / 2), anchor: anchor)
            return
        }
        t = t.font(font)
        ctx.draw(t, at: point, anchor: align == .leading ? .leading : (align == .trailing ? .trailing : .center))
    }
}

// MARK: - 界面

struct JianpuView: View {
    var onClose: () -> Void

    @State private var score: JianpuScore?
    @State private var fileName = ""
    @State private var message = "选一份 Dorico 导出的 MusicXML，就出简谱。"
    @State private var perLine = 3
    @State private var errorText = ""
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.stroke)
            if let score {
                ScrollView {
                    VStack(spacing: 18) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                            JianpuPageView(score: score, page: page, pageIndex: idx,
                                           pageCount: pages.count, perLine: perLine)
                                .frame(width: 595, height: 842)
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                                .scaleEffect(previewScale)
                                .frame(width: 595 * previewScale, height: 842 * previewScale)
                        }
                    }
                    .padding(24)
                }
                .background(Palette.windowBG)
            } else {
                emptyState
            }
            Divider().overlay(Palette.stroke)
            footer
        }
    }

    private var previewScale: CGFloat { 0.78 }

    private var pages: [JianpuPage] {
        guard let score else { return [] }
        return JianpuLayout.paginate(score, perLine: perLine)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("返回")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)

            Text("MusicXML → 简谱")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Spacer()

            if !fileName.isEmpty {
                Text(fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Picker("", selection: $perLine) {
                Text("每行 2 小节").tag(2)
                Text("每行 3 小节").tag(3)
                Text("每行 4 小节").tag(4)
            }
            .labelsHidden()
            .frame(width: 130)

            Button("选择 MusicXML…") { chooseFile() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34))
                .foregroundStyle(Palette.textSecondary)
            Text("这里只做一件事：把 MusicXML 变成简谱。")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
            Text("在 Dorico 里「文件 → 导出 → MusicXML」，再选进来。\n跟右边那台生成模型没有任何关系，不费显卡。")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textSecondary)
            Button("选择 MusicXML…") { chooseFile() }
                .buttonStyle(.borderedProminent)
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBG)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer()
            if score != nil {
                Button {
                    exportPDF()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.doc")
                        Text(exporting ? "正在导出…" : "导出 PDF…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(exporting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.sidebar)
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if let f = env["CS_JIANPU_FILE"], !f.isEmpty {
                load(url: URL(fileURLWithPath: f))
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.xml, UTType(filenameExtension: "musicxml") ?? .xml,
                                     UTType(filenameExtension: "mxl") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 Dorico 导出的 MusicXML"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    private func load(url: URL) {
        errorText = ""
        message = "正在读…"
        do {
            let s = try JianpuXMLParser.parse(url: url)
            guard !s.measures.isEmpty else {
                throw NSError(domain: "Jianpu", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "这份谱子里没有小节。"])
            }
            score = s
            fileName = url.lastPathComponent
            message = "读到了 \(s.measures.count) 小节，\(pages.count) 页。"
            let env = ProcessInfo.processInfo.environment
            if let p = env["CS_JIANPU_PDF"], !p.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    exportPDF()
                }
            }
        } catch {
            score = nil
            errorText = error.localizedDescription
            message = "没读成。"
        }
    }

    @MainActor
    private func exportPDF() {
        guard let score else { return }
        let env = ProcessInfo.processInfo.environment
        var target: URL?
        if let p = env["CS_JIANPU_PDF"], !p.isEmpty {
            target = URL(fileURLWithPath: p)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            let base = fileName.isEmpty ? "简谱" : (fileName as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "-简谱.pdf"
            if panel.runModal() == .OK { target = panel.url }
        }
        guard let url = target else { return }
        writePDF(score: score, to: url)
        if env["CS_JIANPU_PDF"] == nil {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private func writePDF(score: JianpuScore, to url: URL) {
        exporting = true
        defer { exporting = false }

        let pages = JianpuLayout.paginate(score, perLine: perLine)
        var mediaBox = CGRect(x: 0, y: 0, width: JianpuLayout.pageW, height: JianpuLayout.pageH)
        guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            errorText = "PDF 文件建不出来。"
            return
        }
        for (idx, page) in pages.enumerated() {
            pdf.beginPDFPage(nil)
            let view = JianpuPageView(score: score, page: page, pageIndex: idx,
                                      pageCount: pages.count, perLine: perLine)
                .frame(width: JianpuLayout.pageW, height: JianpuLayout.pageH)
            let renderer = ImageRenderer(content: view)
            renderer.render { _, draw in
                draw(pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        message = "PDF 存好了：\(url.lastPathComponent)"
    }
}
