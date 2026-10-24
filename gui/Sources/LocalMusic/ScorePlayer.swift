import AudioToolbox
import AVFoundation
import Foundation

/// 「照谱奏出来」—— 读一份 MusicXML，把上面的音**原样**放一遍。
///
/// 这和「照谱唱」是两件事，别混：
///   · **照谱唱**（YuE2）：谱子当条件，模型会自己加表现、加气口，有时还会跑调。
///     它交的是**草稿**，用来听结构、听词位。
///   · **照谱奏**（这个文件）：**一个音都不许改**。音高、时值、连音线、和弦、
///     休止、速度，全按谱面来。它只回答一个问题：**这张谱子写下来，是这样响吗？**
///
/// 为什么不用 MuseScore：那要人再装一个几百 MB 的软件、还要找它的命令行路径。
/// 这里用的是 macOS **自带**的音源（`AVAudioUnitSampler` + 系统通用 MIDI 音色），
/// 零依赖 —— 发到 GitHub 上，别人打开就能听。
///
/// 音色说明：系统自带的是通用 MIDI 音色，**不难听，但也别指望它好听**。
/// 它是让你核对谱子的，不是让你混音的。想要好音色，把同一份谱子拖进 DAW 或 ACE。
enum ScorePlayer {

    // MARK: - 谱子里要用的东西

    /// 一份「能奏出来」的谱子。只收演奏需要的那几样 —— 歌词、和弦标记不进这里。
    struct Playable {
        struct Part {
            var name: String = ""
            /// MIDI 音色号（0–127）。MusicXML 里写的是 1–128，读的时候已经减过 1。
            var program: Int = 0
        }
        struct Note {
            var part: Int
            /// 起点，单位是**四分音符**（不受拍号影响）。
            var start: Double
            var duration: Double
            var pitch: Int
            /// 力度。**100 是实测定的**：80 那版峰值只有 -20.7 dB，听着偏轻；
            /// 谱子里没有力度记号可用，所以统一给一个"正常弹"的力度。
            var velocity: Int = 100
        }
        /// 速度变化点 —— 谱子中途变速时，秒数要按段累加，不能整首都用一个速度。
        struct TempoPoint {
            var quarter: Double
            var bpm: Double
        }

        var title: String = ""
        var parts: [Part] = []
        var notes: [Note] = []
        /// 开头的速度（没有就 120）。排序后的 `tempoMap` 第一点与它一致。
        var tempo: Double = 120
        var tempoMap: [TempoPoint] = [TempoPoint(quarter: 0, bpm: 120)]
        var beatsPerBar: Double = 4
        var beatType: Double = 4

        var isEmpty: Bool { notes.isEmpty }

        /// 某个四分音符位置对应第几秒（途中变速按段累加）。
        func seconds(at quarter: Double) -> Double {
            var result = 0.0
            var prevQuarter = 0.0
            var prevBpm = tempoMap.first?.bpm ?? 120
            for point in tempoMap.dropFirst() {
                if point.quarter >= quarter { break }
                result += (point.quarter - prevQuarter) * 60 / max(prevBpm, 1)
                prevQuarter = point.quarter
                prevBpm = point.bpm
            }
            result += (quarter - prevQuarter) * 60 / max(prevBpm, 1)
            return result
        }

        var lastEnd: Double { notes.map { $0.start + $0.duration }.max() ?? 0 }

        var seconds: Double { seconds(at: lastEnd) }

        /// 一句人话，摆在按钮旁边。
        ///
        /// ★ 按项目规矩：数字要先翻译。所以这里说的是「几个音、大约多久」，
        ///   而不是「noteCount = 435」。
        var summary: String {
            guard !notes.isEmpty else { return "这份谱子里没有可奏的音。" }
            let total = Int(seconds.rounded())
            let m = total / 60
            let s = total % 60
            let length = m > 0 ? "\(m) 分 \(s) 秒" : "\(s) 秒"
            let partText = parts.count > 1 ? "\(parts.count) 个声部" : "1 个声部"
            return "\(partText) · \(notes.count) 个音 · 约 \(length) · 速度 \(Int(tempo))"
        }
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case notMusicXML(String)
        case silent
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why):  return "这份谱子打不开：\(why)"
            case .notMusicXML(let why): return "这不像一份 MusicXML：\(why)"
            case .silent:               return "这份谱子里没有能奏出来的音。"
            case .engine(let why):      return "出声这一步没成：\(why)"
            }
        }
    }

    // MARK: - 读

    static func load(_ url: URL) throws -> Playable {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.unreadable("找不到 \(url.lastPathComponent)")
        }
        guard url.pathExtension.lowercased() != "abc" else {
            throw Failure.unreadable("这一版只认 MusicXML。ABC 先转成 MusicXML 再听。")
        }
        guard let parser = XMLParser(contentsOf: url) else {
            throw Failure.unreadable("\(url.lastPathComponent) 不是文本 XML")
        }
        let reader = MusicXMLPlayReader()
        parser.delegate = reader
        guard parser.parse() else {
            throw Failure.notMusicXML(parser.parserError?.localizedDescription ?? "解析中断")
        }
        guard reader.sawScorePartwise else {
            throw Failure.notMusicXML("里面没有 <score-partwise>")
        }
        return reader.finish()
    }

    // MARK: - 出声

    /// 把谱子渲染成一个 wav 文件。
    ///
    /// 为什么用「离线渲染」而不是"边放边录"：离线渲染**比实时快得多**
    /// （几分钟的曲子十几秒出完），而且不受系统声音、耳机插拔影响。
    static func render(_ score: Playable, to url: URL) throws {
        guard !score.isEmpty else { throw Failure.silent }

        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw Failure.engine("系统不支持这个采样格式")
        }

        let engine = AVAudioEngine()
        var samplers: [AVAudioUnitSampler] = []
        let bank = systemSoundBank()

        for part in score.parts {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: format)
            // 有系统音源就明确加载一次；加载不上也没关系，sampler 自己会兜底
            if let bank {
                try? sampler.loadSoundBankInstrument(at: bank,
                                                     program: UInt8(clamping: part.program),
                                                     bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                     bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            }
            samplers.append(sampler)
        }

        let blockSize: AVAudioFrameCount = 256
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: blockSize)
        do {
            try engine.start()
        } catch {
            throw Failure.engine(error.localizedDescription)
        }
        defer { engine.stop() }

        // 音符 → 两条时间线（开、关），各自按时间排好。
        // 时间单位是**秒**，变速已经在 `seconds(at:)` 里处理过了。
        var ons: [(time: Double, part: Int, pitch: Int, velocity: Int)] = []
        var offs: [(time: Double, part: Int, pitch: Int)] = []
        for note in score.notes {
            let start = score.seconds(at: note.start)
            let end = score.seconds(at: note.start + note.duration)
            let part = min(note.part, max(samplers.count - 1, 0))
            ons.append((start, part, note.pitch, note.velocity))
            // 极短的保护：时值再小也让声音起得来（1 毫秒）
            offs.append((max(end, start + 0.001), part, note.pitch))
        }
        ons.sort { $0.time < $1.time }
        offs.sort { $0.time < $1.time }

        // 尾巴留 1.5 秒，让最后一个音的余音自然收掉
        let totalSeconds = score.seconds + 1.5
        let totalFrames = AVAudioFramePosition(totalSeconds * sampleRate)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw Failure.engine(error.localizedDescription)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: blockSize) else {
            throw Failure.engine("开不出渲染缓冲")
        }

        var onCursor = 0
        var offCursor = 0
        var frame: AVAudioFramePosition = 0

        while frame < totalFrames {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(blockSize), totalFrames - frame))
            let blockEndTime = Double(frame + AVAudioFramePosition(frames)) / sampleRate

            // 先把"该关的"关掉（同一个时间点上先关后开，避免叠成两个音）
            while offCursor < offs.count, offs[offCursor].time <= blockEndTime {
                let event = offs[offCursor]
                samplers[event.part].stopNote(UInt8(clamping: event.pitch), onChannel: 0)
                offCursor += 1
            }
            while onCursor < ons.count, ons[onCursor].time <= blockEndTime {
                let event = ons[onCursor]
                samplers[event.part].startNote(UInt8(clamping: event.pitch),
                                               withVelocity: UInt8(clamping: event.velocity),
                                               onChannel: 0)
                onCursor += 1
            }

            let status = try engine.renderOffline(frames, to: buffer)
            guard status == .success else {
                throw Failure.engine("渲染中断（\(status.rawValue)）")
            }
            try outFile.write(from: buffer)
            frame += AVAudioFramePosition(frames)
        }
    }

    /// 系统自带的通用 MIDI 音源。找不到就让 sampler 用它自己的默认。
    private static func systemSoundBank() -> URL? {
        let path = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

// MARK: - 只为了"能奏"而写的 MusicXML 读法

/// 和 `ScoreReader` 里那个**故意分开写**：
///
/// `ScoreReader` 只关心「人看得见的东西」—— 标题、速度、调号、和弦、歌词，
/// 它的注释里写得很清楚：「音高一律不要」。
/// 而这里要的正好相反：**音高、时值、连音线一个都不能少**，词和和弦反而没用。
/// 硬塞进一个类里，两边都会变糊涂。
private final class MusicXMLPlayReader: NSObject, XMLParserDelegate {

    private struct Pending {
        var part: Int
        var duration: Double = 0
        var tieStart = false
        var tieStop = false
        var isChord = false
        var isGrace = false
        var isCue = false
    }

    private var stack: [String] = []
    private var text = ""

    private(set) var sawScorePartwise = false

    // 声部
    private var partIndex = -1
    private var partNames: [String] = []
    private var partPrograms: [Int] = []
    private var inPartList = false
    private var partNameBuffer = ""
    private var pendingProgram: Int?

    // 走针（单位：四分音符）
    private var divisions = 1.0
    private var clock = 0.0
    private var lastOnset = 0.0        // 上一个音的起点，给 <chord/> 用

    // 当前音符
    private var pending: Pending?
    private var pitchStep = ""
    private var pitchAlter = 0
    private var pitchOctave = 4
    private var sawPitch = false

    // 结果
    private var notes: [ScorePlayer.Playable.Note] = []
    private var title = ""
    private var tempo = 120.0
    private var tempoMap: [ScorePlayer.Playable.TempoPoint] = []
    private var beatsPerBar = 4.0
    private var beatType = 4.0
    /// 连音线接续：`part-pitch` → 上一条还没收尾的音在 `notes` 里的位置
    private var openTies: [String: Int] = [:]

    private static let steps = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    private var parentName: String? { stack.count >= 2 ? stack[stack.count - 2] : nil }
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
        case "part-list":
            inPartList = true
        case "score-part":
            inPartList = true
            partNameBuffer = ""
            pendingProgram = nil
        case "part":
            partIndex += 1
            clock = 0
            lastOnset = 0
        case "note":
            pending = Pending(part: max(partIndex, 0))
            pitchStep = ""; pitchAlter = 0; pitchOctave = 4
            sawPitch = false
        case "chord":
            pending?.isChord = true
        case "grace":
            pending?.isGrace = true
        case "cue":
            pending?.isCue = true
        case "tie", "tied":
            let type = attrs["type"] ?? ""
            if type == "start" { pending?.tieStart = true }
            if type == "stop" { pending?.tieStop = true }
        case "sound":
            if let raw = attrs["tempo"], let value = Double(raw), value > 0 {
                tempo = value
                tempoMap.append(ScorePlayer.Playable.TempoPoint(quarter: clock, bpm: value))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    // MARK: 关标签

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = trimmed
        switch name {
        case "part-list":
            inPartList = false
        case "score-part":
            partNames.append(partNameBuffer)
            partPrograms.append(pendingProgram ?? 0)
            inPartList = false
        case "part-name", "part-name-display":
            if inPartList, partNameBuffer.isEmpty { partNameBuffer = value }
        case "midi-program":
            // MusicXML 是 1–128，MIDI 是 0–127
            if let n = Int(value) { pendingProgram = max(0, min(127, n - 1)) }
        case "divisions":
            if parentName == "attributes", let n = Double(value), n > 0 { divisions = n }
        case "beats":
            if let n = Double(value), n > 0 { beatsPerBar = n }
        case "beat-type":
            if let n = Double(value), n > 0 { beatType = n }
        case "duration":
            if let parent = parentName, let raw = Double(value) {
                switch parent {
                case "note":    pending?.duration = raw / divisions
                case "backup":  clock -= raw / divisions
                case "forward": clock += raw / divisions
                default:        break
                }
            }
        case "step":
            if parentName == "pitch" { pitchStep = value; sawPitch = true }
        case "alter":
            if parentName == "pitch", let n = Int(value) { pitchAlter = n }
        case "octave":
            if parentName == "pitch", let n = Int(value) { pitchOctave = n }
        case "work-title", "movement-title":
            if title.isEmpty { title = value }
        case "note":
            finishNote()
        default:
            break
        }
        stack.removeLast()
    }

    // MARK: 收一个音

    private func finishNote() {
        guard let note = pending else { return }
        pending = nil

        // 装饰音、提示音：谱面上是"装饰"，不该占拍 —— 直接跳过，也不推进时钟
        if note.isGrace || note.isCue { return }

        let start: Double
        if note.isChord {
            start = lastOnset
        } else {
            lastOnset = clock
            start = clock
        }

        if !note.isChord {
            clock += note.duration
        }

        guard sawPitch, let pitch = midiPitch(step: pitchStep, alter: pitchAlter, octave: pitchOctave) else {
            return   // 休止符：只走时间
        }

        let key = "\(note.part)-\(pitch)"

        // ── 连音线：把两段接成一条 ──
        //
        // 一个长音被写成两个音符（tie start / tie stop）时，第二个音**不能重新 attack**，
        // 否则听上去像在中间又弹了一下。做法：延长前一个音的时值，第二个音只走时间。
        if note.tieStop, let previous = openTies[key], previous < notes.count {
            notes[previous].duration = (start + note.duration) - notes[previous].start
            if note.tieStart {
                openTies[key] = previous      // 还要继续接下去
            } else {
                openTies.removeValue(forKey: key)
            }
            return
        }

        let index = notes.count
        notes.append(ScorePlayer.Playable.Note(part: note.part, start: start,
                                               duration: note.duration, pitch: pitch))
        if note.tieStart {
            openTies[key] = index
        }
    }

    private func midiPitch(step: String, alter: Int, octave: Int) -> Int? {
        guard let base = Self.steps[step.uppercased()] else { return nil }
        let value = (octave + 1) * 12 + base + alter
        return (0...127).contains(value) ? value : nil
    }

    // MARK: 交账

    func finish() -> ScorePlayer.Playable {
        let count = max(partIndex + 1, 1)
        var parts: [ScorePlayer.Playable.Part] = []
        for index in 0..<count {
            parts.append(ScorePlayer.Playable.Part(
                name: index < partNames.count ? partNames[index] : "",
                program: index < partPrograms.count ? partPrograms[index] : 0))
        }

        var map = tempoMap.sorted { $0.quarter < $1.quarter }
        if map.isEmpty || map[0].quarter > 0 {
            map.insert(ScorePlayer.Playable.TempoPoint(quarter: 0, bpm: tempo), at: 0)
        }

        return ScorePlayer.Playable(title: title,
                                    parts: parts,
                                    notes: notes.filter { $0.duration > 0 },
                                    tempo: map[0].bpm,
                                    tempoMap: map,
                                    beatsPerBar: beatsPerBar,
                                    beatType: beatType)
    }
}
