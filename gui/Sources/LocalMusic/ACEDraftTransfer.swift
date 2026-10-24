import Foundation
import AppKit

// MARK: - 把草稿送进 ACE Studio
//
// 用户 2026-10-13 要的：「C.S. 和 ACE 的草稿传输。支持音频和 musicxml。
// ACE 认歌词和速度特别准通过 xml。」
//
// ⚠️ **这一层是薄壳**：真正干活的逻辑在 `scripts/push_to_ace.py` 里。
//
// 为什么下沉成脚本（当天晚上定的）：他接着要求在 **Composer Assistant** 里也能送
// （「CA 里也能把材料送进 ACE」）。两边各写一遍的话，今晚在这儿踩过的坑
// （返回值不可信、ACE 刚启动没就绪、伴奏被当成唱轨、相对路径按 ACE 的目录解析）
// **CA 那边要再踩一遍**，而且以后两份必然漂移。
// ⇒ 逻辑只留一份，两个程序都调它；这里只管：拼参数、读回执、写到界面上。
//
// ★ **只做两件事**（用户当场定的，别自作主张）：
//   ① **人声进唱轨**（带歌词与速度）；② **草稿的音频进音频轨**。
//   **谱子里的伴奏声部一律不送** —— 他的原话：「谱伴奏别管，我自己演奏或者写入」。
//
// 机制、坑和全部实测数据都写在那个脚本顶上的注释里，这份文件不重抄。

/// 一次「送进 ACE」的结果。`message` 是给人看的一句话（直接摆到界面上）。
struct ACETransferResult {
    var ok: Bool
    var message: String

    static func failure(_ message: String) -> ACETransferResult {
        ACETransferResult(ok: false, message: message)
    }
}

enum ACEDraftTransfer {

    /// 送过去的东西：音频 + 谱子，两样都可能没有（界面上是两个按钮，各送一样）。
    struct Payload {
        var audio: URL?
        /// **必须是 MusicXML**（`.xml` / `.musicxml`）—— ABC 是 YuE2 认的记谱文本，
        /// ACE 不认它。脚本那边也会再拦一道。
        var score: URL?
        /// 这一首的名字，用来给 ACE 里新建的轨起名。
        var title: String
    }

    /// 真正干活的那个脚本。跟 `split_score_parts.py` 同目录（它内部要用到）。
    private static var script: URL {
        BackendClient.locateRoot().appendingPathComponent("scripts/push_to_ace.py")
    }

    /// 把一首草稿送进 ACE Studio。**会阻塞**（几十秒封顶），调用方放后台线程跑。
    ///
    /// 两样都给了就**依次**送（谱子在前）—— 别并行：ACE 那边两条导入同时在跑
    /// 会互相插队，读回来的回执也对不上号。
    static func send(_ payload: Payload) -> ACETransferResult {
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failure("找不到送 ACE 的脚本（scripts/push_to_ace.py）。")
        }
        if payload.audio == nil && payload.score == nil {
            return .failure("这一首还没有音频、也没有谱子，没东西可送。")
        }

        var landed: [String] = []
        var problems: [String] = []

        if let score = payload.score {
            let one = push(what: "score", path: score, title: payload.title)
            if let note = one.note { landed.append(note) } else { problems.append(one.reason) }
        }
        if let audio = payload.audio {
            let one = push(what: "audio", path: audio, title: payload.title)
            if let note = one.note { landed.append(note) } else { problems.append(one.reason) }
        }

        guard !landed.isEmpty else {
            return .failure(problems.first ?? "ACE 那边一条都没落下来。看看 ACE Studio 是不是正卡着。")
        }
        var message = "已送进 ACE Studio：" + landed.joined(separator: "；")
        if !problems.isEmpty {
            message += "　⚠️ 没送成：" + problems.joined(separator: "；")
        }
        return ACETransferResult(ok: problems.isEmpty, message: message)
    }

    /// 跑一次脚本。成了带回执（给人看的一句），没成带原因。
    private static func push(what: String, path: URL, title: String) -> (note: String?, reason: String) {
        // ★ **用 `/usr/bin/python3` 跑它，不直接执行脚本** —— 2026-10-13 实测踩到：
        //   直接执行要靠文件的可执行位（`chmod +x`），而这个脚本是**写文件生成的**，
        //   权限是 644 ⇒ `Process` 抛「文件"push_to_ace.py"不存在」（**报的是不存在、
        //   其实是没有执行权限**，很有迷惑性）。
        //   项目里其他脚本（`attach_lyrics.py` 等）本来就是这个跑法，跟它们一致。
        let result = run("/usr/bin/python3",
                         [script.path, "--what", what, "--title", title, path.path],
                         timeout: 180)
        guard let object = jsonObject(result.text) else {
            let tail = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, tail.isEmpty ? "送 ACE 的脚本没吭声。" : String(tail.suffix(200)))
        }
        let ok = (object["ok"] as? Bool) ?? false
        let message = (object["message"] as? String) ?? "（脚本没给说明）"
        return ok ? (message, "") : (nil, message)
    }

    // MARK: - 跑脚本

    private struct ToolResult {
        var status: Int32
        var text: String
        var timedOut: Bool
    }

    /// 看门狗有没有真的开过枪。跨线程读写，所以带把锁。
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// 跑一个外部命令，收它的输出。
    ///
    /// 超时靠一个**看门狗**：到点先 `terminate`，它要是不理就 `SIGKILL`。
    /// 没有这一条的话，ACE 一卡住按钮就会永远转下去 —— 而用户不知道它在等什么。
    private static func run(_ executable: String, _ arguments: [String],
                            timeout: TimeInterval) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, text: error.localizedDescription, timedOut: false)
        }

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.raise()
            process.terminate()
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // 先读完输出再等进程走 —— 顺序反了的话，输出一多就会把进程堵死。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return ToolResult(status: process.terminationStatus,
                          text: String(data: data, encoding: .utf8) ?? "",
                          timedOut: timedOut.isRaised)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
