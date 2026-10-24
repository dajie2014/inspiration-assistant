import Foundation

/// 通用 MIDI 的乐器名。
///
/// 为什么需要它：音频转 MIDI 出来的文件，轨道名是**扒谱模型自己起的名**
/// （`flutes`、`acoustic guitar`、`voice`……），有时候名字和声音对不上，
/// 更多时候干脆是英文。用户要的是「拖着 MIDI 进 DAW，一眼看出哪一轨是什么」。
///
/// ⇒ 做法：**按程序号（program）查标准名**，而不是相信扒谱模型起的名。
///   程序号是硬的（它就是采样器里那个音色），名字是软的。
///
/// 中文名为主（轨道名），英文名同时写进 MIDI 的「乐器名」那一栏 ——
/// 万一哪台软件读中文乱码，英文还在。
enum GeneralMIDI {

    /// 0–127，标准 GM 音色表。下标就是 program 号。
    static let chinese: [String] = [
        "原声大钢琴", "明亮钢琴", "电钢琴", "酒吧钢琴", "电钢琴 1", "电钢琴 2", "羽管键琴", "击弦古钢琴",
        "钢片琴", "钟琴", "八音盒", "颤音琴", "马林巴", "木琴", "管钟", "扬琴",
        "拉杆风琴", "打击风琴", "摇滚风琴", "教堂风琴", "簧风琴", "手风琴", "口琴", "探戈手风琴",
        "尼龙弦吉他", "钢弦吉他", "爵士电吉他", "清音电吉他", "闷音电吉他", "过载吉他", "失真吉他", "吉他泛音",
        "原声贝斯", "指弹电贝斯", "拨片电贝斯", "无品贝斯", "击弦贝斯 1", "击弦贝斯 2", "合成贝斯 1", "合成贝斯 2",
        "小提琴", "中提琴", "大提琴", "低音提琴", "震音弦乐", "拨弦弦乐", "竖琴", "定音鼓",
        "弦乐合奏 1", "弦乐合奏 2", "合成弦乐 1", "合成弦乐 2", "人声合唱「啊」", "人声「哦」", "合成人声", "管弦乐重击",
        "小号", "长号", "大号", "弱音小号", "圆号", "铜管乐组", "合成铜管 1", "合成铜管 2",
        "高音萨克斯", "中音萨克斯", "次中音萨克斯", "上低音萨克斯", "双簧管", "英国管", "大管", "单簧管",
        "短笛", "长笛", "竖笛", "排箫", "吹瓶", "尺八", "哨笛", "陶笛",
        "方波主音", "锯齿主音", "汽笛主音", "气声主音", "洋琴主音", "人声主音", "五度主音", "贝斯主音",
        "新时代音垫", "温暖音垫", "复音音垫", "合唱音垫", "弓弦音垫", "金属音垫", "光晕音垫", "扫频音垫",
        "雨声", "音轨", "水晶", "大气", "明亮", "精灵", "回声", "科幻",
        "西塔琴", "班卓琴", "三味线", "日本筝", "卡林巴", "风笛", "民谣小提琴", "唢呐",
        "铃铛", "阿哥哥铃", "钢鼓", "木鱼", "太鼓", "旋律嗵鼓", "合成鼓", "反镲",
        "吉他品噪", "呼吸声", "海浪", "鸟鸣", "电话铃", "直升机", "掌声", "枪声"
    ]

    /// 英文名 —— 写进 MIDI 的「乐器名」栏（`FF 04`）。
    static let english: [String] = [
        "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano",
        "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
        "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion",
        "Harmonica", "Tango Accordion",
        "Acoustic Guitar (nylon)", "Acoustic Guitar (steel)", "Electric Guitar (jazz)",
        "Electric Guitar (clean)", "Electric Guitar (muted)", "Overdriven Guitar",
        "Distortion Guitar", "Guitar Harmonics",
        "Acoustic Bass", "Electric Bass (finger)", "Electric Bass (pick)", "Fretless Bass",
        "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
        "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings", "Pizzicato Strings",
        "Orchestral Harp", "Timpani",
        "String Ensemble 1", "String Ensemble 2", "SynthStrings 1", "SynthStrings 2",
        "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
        "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section",
        "SynthBrass 1", "SynthBrass 2",
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn",
        "Bassoon", "Clarinet",
        "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi",
        "Whistle", "Ocarina",
        "Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)",
        "Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)", "Lead 8 (bass + lead)",
        "Pad 1 (new age)", "Pad 2 (warm)", "Pad 3 (polysynth)", "Pad 4 (choir)",
        "Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
        "FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)",
        "FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)",
        "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bag pipe", "Fiddle", "Shanai",
        "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom",
        "Synth Drum", "Reverse Cymbal",
        "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet",
        "Telephone Ring", "Helicopter", "Applause", "Gunshot"
    ]

    static func chineseName(for program: Int) -> String {
        chinese[clamp(program)]
    }

    static func englishName(for program: Int) -> String {
        english[clamp(program)]
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 127) }
}

/// 给一份 MIDI 的每条轨道补上乐器名。
///
/// 只做一件事：**把轨道名换成按程序号查出来的标准名**，同时把原来的名字
/// （扒谱模型起的）和标准英文名写进「乐器名」栏。音符、时值、速度一个字都不动。
///
/// 为什么要有它：音频转 MIDI 的产物是"机器扒出来的草稿"，六条轨常常是
/// `flutes` / `acoustic guitar` / `electric bass` / `drums` / `voice` ——
/// 拖进 DAW 是一排英文，还得自己猜哪条是哪条。
///
/// ★★ **写进文件的永远是英文**（用户 2026-10-24 定的）。中文只给界面看：
///   · **Dorico 里出现中文很别扭** —— 他的谱子要进 Dorico 改，轨道名是中文会打断视线。
///   · **MIDI 的文本事件没有规定编码**，各家读法不一样（中文很可能变乱码），
///     英文（纯 ASCII）谁都读得对。宁可在 DAW 里手动改一次中文，也不要冒乱码的险。
///   ⇒ 所以：**文件里写 `GeneralMIDI.english`，界面显示 `GeneralMIDI.chinese`。**
enum MIDITrackNames {

    /// 一条轨的两个名字：文件里写英文，界面上说中文。
    struct Track {
        var english: String
        var chinese: String
    }

    /// 返回值是补完名之后每一条轨的名字（按轨道顺序，空轨不出现在里面）。
    /// 界面拿 `chinese` 显示「拆出 6 轨：长笛 / 钢弦吉他 / …」。
    @discardableResult
    static func annotate(_ url: URL) throws -> [Track] {
        let data = try Data(contentsOf: url)
        guard data.count > 14, data[0..<4] == Data("MThd".utf8) else {
            throw Failure.badFile("这不是一个 MIDI 文件")
        }
        let headerLength = Int(beInt(data, 4))
        guard data.count >= 8 + headerLength else { throw Failure.badFile("文件头不完整") }
        let header = data[0..<(8 + headerLength)]

        var position = 8 + headerLength
        var rebuilt = Data(header)
        var tracks: [Track] = []
        var usedEnglish: [String] = []

        while position + 8 <= data.count, data[position..<(position + 4)] == Data("MTrk".utf8) {
            let length = Int(beInt(data, position + 4))
            let start = position + 8
            guard start + length <= data.count else { throw Failure.badFile("轨道长度不对") }
            let body = data[start..<(start + length)]

            let parsed = try parse(body)
            let track = trackName(for: parsed, used: usedEnglish)
            if let track {
                usedEnglish.append(track.english)
                tracks.append(track)
            }
            let bodyOut = serialize(parsed, name: track?.english)
            rebuilt.append(contentsOf: Data("MTrk".utf8))
            rebuilt.append(contentsOf: beBytes(bodyOut.count))
            rebuilt.append(contentsOf: bodyOut)
            position = start + length
        }

        try rebuilt.write(to: url, options: .atomic)
        return tracks
    }

    enum Failure: LocalizedError {
        case badFile(String)
        var errorDescription: String? {
            switch self {
            case .badFile(let why): return "这条 MIDI 没法改名：\(why)"
            }
        }
    }

    // MARK: - 内部结构

    private enum Kind {
        case note
        case program(Int)
        case trackName(String)
        case instrumentName(String)
        case other
    }

    private struct Event {
        var delta: Int
        /// 一定是「完整的」事件字节（以 status 开头）—— 解析时把 running status 补回去了。
        var bytes: [UInt8]
        var kind: Kind
    }

    // MARK: - 读

    private static func parse(_ body: Data) throws -> [Event] {
        var events: [Event] = []
        var index = body.startIndex
        var running: UInt8?

        while index < body.endIndex {
            let (delta, next) = try readVLQ(body, index)
            index = next
            guard index < body.endIndex else { break }
            var status = body[index]

            if status < 0x80 {
                // running status：沿用上一个 status
                guard let running else { throw Failure.badFile("轨道里有一条对不上的事件") }
                status = running
            } else {
                index += 1
                if status < 0xF0 { running = status }
            }

            let start = index
            var kind: Kind = .other

            switch status {
            case 0xFF:
                guard index < body.endIndex else { throw Failure.badFile("元事件断了") }
                let type = body[index]; index += 1
                let (length, afterLength) = try readVLQ(body, index)
                index = afterLength
                guard index + length <= body.endIndex else { throw Failure.badFile("元事件长度不对") }
                let payload = body[index..<(index + length)]
                index += length
                switch type {
                case 0x03: kind = .trackName(String(decoding: payload, as: UTF8.self))
                case 0x04: kind = .instrumentName(String(decoding: payload, as: UTF8.self))
                case 0x2F: break
                default: break
                }
                events.append(Event(delta: delta,
                                    bytes: [0xFF, type] + vlqBytes(length) + Array(payload),
                                    kind: kind))
                if type == 0x2F {
                    // 轨道结束：剩下的字节（若有）不再解析
                    return events
                }
                continue
            case 0xF0, 0xF7:
                let (length, afterLength) = try readVLQ(body, index)
                index = afterLength
                guard index + length <= body.endIndex else { throw Failure.badFile("系统消息断了") }
                index += length
                events.append(Event(delta: delta,
                                    bytes: [status] + vlqBytes(length) + [UInt8](body[afterLength..<(afterLength + length)]),
                                    kind: .other))
                continue
            default:
                break
            }

            let high = status & 0xF0
            let dataCount: Int
            switch high {
            case 0xC0, 0xD0: dataCount = 1
            default:          dataCount = 2
            }
            guard index + dataCount <= body.endIndex else { throw Failure.badFile("音符事件断了") }
            let payload = [UInt8](body[index..<(index + dataCount)])
            index += dataCount
            if high == 0xC0, let program = payload.first {
                kind = .program(Int(program))
            }
            events.append(Event(delta: delta, bytes: [status] + payload, kind: kind))
            _ = start
        }
        return events
    }

    // MARK: - 写

    private static func serialize(_ events: [Event], name: String?) -> [UInt8] {
        var out: [UInt8] = []
        var wroteName = false

        func write(_ event: Event) {
            out.append(contentsOf: vlqBytes(event.delta))
            out.append(contentsOf: event.bytes)
        }

        for event in events {
            switch event.kind {
            case .trackName:
                // 换成标准名（只换第一次出现的那条）
                if !wroteName, let name {
                    out.append(contentsOf: vlqBytes(event.delta))
                    out.append(contentsOf: textEvent(0x03, name))
                    wroteName = true
                } else if name == nil {
                    write(event)
                }
            case .instrumentName:
                // 乐器名那一栏只在没有的时候补，已经有了就不动
                write(event)
            case .note, .program, .other:
                // 在第一条真正的音符/程序号之前，把名字插进去
                if !wroteName, let name, case .program = event.kind {
                    var inserted = Event(delta: 0, bytes: [], kind: .other)
                    inserted.bytes = textEvent(0x03, name)
                    write(inserted)
                    wroteName = true
                }
                write(event)
            }
        }
        if !wroteName, let name {
            // 整条轨连程序号都没有：就放在最前面（delta 0）
            var text: [UInt8] = []
            text.append(contentsOf: vlqBytes(0))
            text.append(contentsOf: textEvent(0x03, name))
            out.insert(contentsOf: text, at: 0)
        }
        return out
    }

    private static func textEvent(_ type: UInt8, _ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return [0xFF, type] + vlqBytes(bytes.count) + bytes
    }

    // MARK: - 起名

    /// 一条轨该叫什么。
    ///
    /// 顺序：鼓通道（9）→ `Drums` / 「鼓」；有程序号 → 按 GM 表查；
    /// 都没有 → 保留原英文名；还是空 → nil（这条轨不出现在清单里）。
    ///
    /// ★ 名字**按程序号查**，不信扒谱模型起的名 —— 程序号是硬的（它就是采样器里
    ///   那个音色），名字是软的（实测 MuScriptor 会把短笛写成 `flutes`）。
    private static func trackName(for events: [Event], used: [String]) -> Track? {
        var program: Int?
        var channel: Int?
        var original: String?

        for event in events {
            switch event.kind {
            case .program(let value):
                program = value
                channel = Int(event.bytes[0] & 0x0F)
            case .trackName(let value):
                if original == nil, !value.isEmpty { original = value }
            case .note:
                if channel == nil { channel = Int(event.bytes[0] & 0x0F) }
            case .instrumentName, .other:
                break
            }
        }

        var track: Track
        if channel == 9 {
            track = Track(english: "Drums", chinese: "鼓")
        } else if let program {
            track = Track(english: GeneralMIDI.englishName(for: program),
                          chinese: GeneralMIDI.chineseName(for: program))
        } else if let original {
            track = Track(english: original, chinese: original)
        } else {
            return nil
        }

        // 两条轨同名时加一个序号（DAW 里分得清）
        if used.contains(track.english) {
            var n = 2
            while used.contains("\(track.english) \(n)") { n += 1 }
            track.english = "\(track.english) \(n)"
            track.chinese = "\(track.chinese) \(n)"
        }
        return track
    }

    // MARK: - 字节小工具

    private static func beInt(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data[offset..<(offset + 4)])
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    private static func beBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(value)
        return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func vlqBytes(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var buffer: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            buffer.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return buffer
    }

    private static func readVLQ(_ data: Data, _ start: Int) throws -> (Int, Int) {
        var index = start
        var value = 0
        var count = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            value = (value << 7) | Int(byte & 0x7F)
            count += 1
            if byte & 0x80 == 0 { return (value, index) }
            if count > 4 { throw Failure.badFile("可变长数字太长") }
        }
        throw Failure.badFile("文件提前结束")
    }
}
