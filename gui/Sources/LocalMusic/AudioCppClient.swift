import AVFoundation
import Foundation

/// audio.cpp（Mac 预编译版）的客户端 —— 只管「找到它、跑一次、把结果拿回来」。
///
/// 背景：灵感路由（MIR）原来自带一套 SheetSage2（Python + MLX，2.6 GB 权重）。
/// 2026-10-24 那套撤了，换成 `audiocpp`：同一件事，**60 秒的歌 25 秒出结果**，
/// 读的还是一份 GGUF（2.7 GB）。MuScriptor 更轻，412 MB，5 秒出六轨 MIDI。
///
/// **不下载、不自带权重。** 程序和模型都是人自己的东西，放在人自己的盘上。
/// 这里只做三件事：去哪儿找、跑一次、找不到时说清楚缺什么。
///
/// ⚠️ 为什么是 `Process` 而不是把模型塞进 Swift：那套推理是 C++/Metal，
///    重新实现没有意义。这个文件只是一层薄壳，**失败了也不能影响原来的生成**。
enum AudioCppClient {

    // MARK: - 配置入口

    /// 用户可以在偏好设置里指一次，之后一直用它。
    /// 键名前缀跟项目别处一致（`cs.` = Composer Step）。
    static let cliDefaultsKey = "cs.audiocpp.cli"
    static let modelsDefaultsKey = "cs.audiocpp.models"

    /// 算一个谱子要多久：4 分钟的歌约 27 秒（实测）。给足十分钟，
    /// 因为首次加载要把 2.7 GB 从盘上读进来 —— 外盘冷的时候确实慢。
    private static let timeout: TimeInterval = 600

    // MARK: - 找到程序

    /// 候选位置，按「越具体越优先」排。
    ///
    /// 最后一个候选是本机工作区的默认位置 —— 它**只在开发机上生效**，
    /// 别人的机器上不存在，找不到就会一直往下走到 `/opt/homebrew/bin`。
    /// 这就是发到 GitHub 时该有的样子：默认值可以是我这台机器的，
    /// 但**别人一改就能用**（偏好设置里填路径）。
    private static var cliCandidates: [URL] {
        var list: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: cliDefaultsKey),
           !custom.isEmpty {
            list.append(URL(fileURLWithPath: custom))
        }
        if let env = ProcessInfo.processInfo.environment["CS_AUDIOCPP_CLI"], !env.isEmpty {
            list.append(URL(fileURLWithPath: env))
        }
        // 跟 app 放在一起（有人喜欢把整包装进同一个文件夹）
        if let res = Bundle.main.resourceURL {
            list.append(res.appendingPathComponent("audiocpp/audiocpp_cli"))
            list.append(res.appendingPathComponent("audiocpp_cli"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(home.appendingPathComponent("audiocpp/audiocpp_cli"))
        list.append(URL(fileURLWithPath: "/opt/homebrew/bin/audiocpp_cli"))
        list.append(URL(fileURLWithPath: "/usr/local/bin/audiocpp_cli"))
        // 放哪都行 —— 设 `CS_AUDIOCPP_DIR` 指到那个目录即可（不必写死路径）
        if let dir = ProcessInfo.processInfo.environment["CS_AUDIOCPP_DIR"], !dir.isEmpty {
            list.append(URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)
                .appendingPathComponent("audiocpp_cli"))
        }
        return list
    }

    static func locateCLI() -> URL? {
        let fm = FileManager.default
        for url in cliCandidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - 找到模型

    /// 模型目录的候选。先看用户指的那个，再看「程序边上」的几种摆法。
    private static func modelDirs(near cli: URL) -> [URL] {
        var list: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: modelsDefaultsKey),
           !custom.isEmpty {
            list.append(URL(fileURLWithPath: custom))
        }
        let dir = cli.deletingLastPathComponent()
        // audiocpp-bin/ 和 audio.cpp/ 并排（本机就是这种摆法）
        list.append(dir.deletingLastPathComponent().appendingPathComponent("audio.cpp/models"))
        list.append(dir.appendingPathComponent("models"))
        list.append(dir.deletingLastPathComponent().appendingPathComponent("models"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(home.appendingPathComponent("audiocpp/models"))
        return list
    }

    /// 在模型目录里找一个族的 `.gguf`（会往下钻一层：`models/SheetSage2/*.gguf`）。
    private static func findModel(_ family: String, near cli: URL) -> URL? {
        let fm = FileManager.default
        for base in modelDirs(near: cli) {
            let direct = base.appendingPathComponent(family)
            if let hit = firstGGUF(in: direct, fm) { return hit }
            for entry in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.lowercased().hasPrefix(family.lowercased()) {
                if let hit = firstGGUF(in: entry, fm) { return hit }
            }
        }
        return nil
    }

    private static func firstGGUF(in dir: URL, _ fm: FileManager) -> URL? {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        // 优先非分片的那一份（本机叫 `sheetsage2-orig.gguf`）
        let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
        return ggufs.first { !$0.lastPathComponent.contains("-0000") } ?? ggufs.first
    }

    // MARK: - 能不能用

    struct Status {
        var cli: URL?
        var sheetSage2: URL?
        var muscriptor: URL?

        var canTranscribeToScore: Bool { cli != nil && sheetSage2 != nil }
        var canTranscribeToMIDI: Bool { cli != nil && muscriptor != nil }

        /// 一句人话，直接摆在按钮底下。
        var human: String {
            if cli == nil {
                return "没找到 audio.cpp 的程序（audiocpp_cli）。装上之后在偏好设置里指一下路径。"
            }
            if sheetSage2 == nil && muscriptor == nil {
                return "找到程序了，但没找到 SheetSage2 或 MuScriptor 的模型文件。"
            }
            var bits: [String] = []
            if sheetSage2 != nil { bits.append("出谱") }
            if muscriptor != nil { bits.append("出 MIDI") }
            return "音频转谱已就绪（\(bits.joined(separator: " / "))）"
        }
    }

    static func status() -> Status {
        let cli = locateCLI()
        guard let cli else { return Status() }
        return Status(cli: cli,
                      sheetSage2: findModel("SheetSage2", near: cli),
                      muscriptor: findModel("MuScriptor", near: cli))
    }

    // MARK: - 干活

    enum Failure: LocalizedError {
        case notInstalled(String)
        case needsConversion(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let why):    return why
            case .needsConversion(let why): return "这段音频转不了：\(why)"
            case .failed(let why):          return "识谱没成功：\(why)"
            }
        }
    }

    /// 音频 → ABC 草谱。返回 ABC 文本。
    ///
    /// 产物先落在 `output` 给的路径上；调用方拿到文本后可以再交给
    /// 8001 服务规范化（那句「旧服务负责把草稿理干净」）。
    static func transcribeToScore(audio: URL, output: URL) async throws -> String {
        let status = status()
        guard let cli = status.cli, let model = status.sheetSage2 else {
            throw Failure.notInstalled(status.human)
        }
        let prepared = try prepareAudio(audio)
        // 只删**自己转出来的**临时文件；原文件是用户的，一个字都不能动
        defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }

        let result = try await run(cli, [
            "--task", "midi",
            "--family", "sheetsage2",
            "--model", model.path,
            "--backend", "metal",
            "--audio", prepared.url.path,
            "--text-out", output.path
        ])
        guard result.code == 0, let text = try? String(contentsOf: output, encoding: .utf8),
              !text.isEmpty else {
            throw Failure.failed("没写出谱子（退出码 \(result.code)）。\(result.tail)")
        }
        return text
    }

    /// 把听出来的原始 ABC 整理成 YuE2 认的双行谱（Vocal + Ins）。
    ///
    /// 2026-10-26 实验：旋律进 Vocal，和弦根音进 Ins。
    /// 脚本和谱面工作室共用一份：`scripts/abc_two_voices.py`。
    static func buildTwoVoices(from abc: URL, to out: URL) -> Bool {
        let script = BackendClient.locateRoot().appendingPathComponent("scripts/abc_two_voices.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, abc.path, out.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
            && FileManager.default.fileExists(atPath: out.path)
    }

    /// 音频 → MIDI（六轨：人声 / 吉他 / 贝斯 / 鼓 / 钢琴……）。
    static func transcribeToMIDI(audio: URL, output: URL) async throws {
        let status = status()
        guard let cli = status.cli, let model = status.muscriptor else {
            throw Failure.notInstalled(status.human)
        }
        let prepared = try prepareAudio(audio)
        // 同上：原文件不能删
        defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }

        let result = try await run(cli, [
            "--task", "midi",
            "--family", "muscriptor",
            "--model", model.path,
            "--backend", "metal",
            "--audio", prepared.url.path,
            "--out", output.path
        ])
        guard result.code == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.failed("没写出 MIDI（退出码 \(result.code)）。\(result.tail)")
        }
    }

    // MARK: - 音频先统一成 48k 立体声 wav

    /// 用系统自带的 AVFoundation 转，不依赖 ffmpeg。
    ///
    /// 为什么非要转：这两个模型的入口要的是 wav 数据，而用户手里可能是
    /// mp3 / m4a / flac。让 AVFoundation 读、写成 wav，比要求人先装 ffmpeg 干净。
    ///
    /// ⚠️⚠️ **返回值里的 `temporary` 一定要看**：叫它的人跑完会删掉临时文件，
    /// 而"已经是 wav"这一支**用的是原文件**。2026-10-24 就因为这个删过用户的音频 ——
    /// 清理时把源文件当临时文件删了（实测丢了两个 10-16 的实验产物）。
    /// 所以这里明确告诉调用方"这个能删、那个不能删"。
    private static func prepareAudio(_ source: URL) throws -> (url: URL, temporary: Bool) {
        // 已经是 wav 就原样用，省掉一次转码 —— **但绝不能删**
        if source.pathExtension.lowercased() == "wav" { return (source, false) }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiocpp-in-\(UUID().uuidString).wav")
        do {
            let inFile = try AVAudioFile(forReading: source)
            let format = inFile.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(inFile.length)) else {
                throw Failure.needsConversion("这份音频读不进内存")
            }
            try inFile.read(into: buffer)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let outFile = try AVAudioFile(forWriting: target, settings: settings)
            try outFile.write(from: buffer)
            return (target, true)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.needsConversion(error.localizedDescription)
        }
    }

    // MARK: - 跑一条命令

    struct RunResult {
        var code: Int32
        /// 日志最后几行。**失败时必须带上** —— 否则界面上只剩「退出码 1」，
        /// 人不知道是音频没找到、还是模型没读到（2026-10-24 真踩到过：
        /// 测试音频被删了，界面却说"没写出 MIDI"）。
        var tail: String
    }

    /// 跑一次，等它结束。输出**不往内存里收**（那几个模型会打几百 KB 的 JSON），
    /// 一律丢进临时文件 —— 收进 Pipe 又不读，进程会卡死在那儿。
    private static func run(_ cli: URL, _ args: [String]) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = cli
            process.arguments = args

            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("audiocpp-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try? FileHandle(forWritingTo: logURL)
            process.standardOutput = log ?? FileHandle.nullDevice
            process.standardError = log ?? FileHandle.nullDevice

            // 两处都可能 resume：正常结束、超时 terminate。用锁保证只 resume 一次。
            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<RunResult, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                try? log?.close()
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { proc in
                finish(.success(RunResult(code: proc.terminationStatus,
                                          tail: logTail(logURL))))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(Failure.failed("程序起不来：\(error.localizedDescription)")))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    finish(.success(RunResult(code: -1,
                                              tail: "十分钟还没跑完，已经把它停了。")))
                }
            }
        }
    }

    /// 取日志最后三行（去掉空行）。读不到就返回空串，不抛错。
    private static func logTail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " / ")
    }
}
