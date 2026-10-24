import Foundation

// MARK: - 把这一首送进 Ableton Live
//
// 2026-10-17 用户选的那条：「生成完自动送」。
//
// **这一层是薄壳**：真正干活的在 `scripts/push_to_live.py`（跟 `push_to_ace.py`
// 一个位置）。它负责找音频、按 `[Verse]` 段落从谱子算时间、发消息给 Live 里
// 的 `AbletonMySongwriter` 桥。这里只管：跑它、把回执翻成人话。
//
// ★ 送不送由调用方判断（先 ping 一下桥）——没连着 Live 时**静默不送**，
//   不打扰用户。

struct LiveTransferResult {
    var ok: Bool
    var message: String
}

enum LiveTransfer {

    /// 送 Live 的脚本位置。跟 `push_to_ace.py` 同目录。
    private static var script: URL {
        BackendClient.locateRoot().appendingPathComponent("scripts/push_to_live.py")
    }

    /// 把一首的产物目录送进 Live。**阻塞**（几秒），调用方放后台线程。
    static func send(folder: URL) -> LiveTransferResult {
        guard FileManager.default.fileExists(atPath: script.path) else {
            return LiveTransferResult(ok: false, message: "找不到 scripts/push_to_live.py。")
        }
        let result = run("/usr/bin/python3",
                         [script.path, folder.path, "--json"], timeout: 60)
        guard let data = result.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let tail = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return LiveTransferResult(
                ok: false,
                message: tail.isEmpty ? "送 Live 的脚本没吭声。" : String(tail.suffix(200)))
        }

        let ok = (object["ok"] as? Bool) ?? false
        guard ok else {
            return LiveTransferResult(ok: false,
                                      message: (object["error"] as? String) ?? "Live 那边没接住。")
        }
        guard let payload = object["result"] as? [String: Any] else {
            return LiveTransferResult(ok: true, message: "已送进 Live。")
        }
        let track = (payload["track"] as? String) ?? "AI 草稿"
        let isArrangement = (payload["destination"] as? String) == "arrangement"
        if let clips = payload["clips"] as? [[String: Any]] {
            if isArrangement {
                let bar = (clips.first?["bar"] as? Double).map { barText($0) } ?? "1"
                return LiveTransferResult(
                    ok: true,
                    message: "已放进编曲视图：「\(track)」轨，从第 \(bar) 小节起，共 \(clips.count) 段。")
            }
            return LiveTransferResult(ok: true,
                                      message: "「\(track)」轨上放了 \(clips.count) 段。")
        }
        let name = (payload["name"] as? String) ?? ""
        return LiveTransferResult(
            ok: true,
            message: name.isEmpty ? "「\(track)」轨上放好了。" : "「\(track)」轨上放好了《\(name)》。")
    }

    /// 小节号按人话打：整数就整数，落在半小节就留两位。
    private static func barText(_ bar: Double) -> String {
        if abs(bar - bar.rounded()) < 0.001 {
            return String(Int(bar.rounded()))
        }
        return String(format: "%.2f", bar)
    }

    // MARK: - 跑脚本

    private struct ToolResult {
        var status: Int32
        var text: String
    }

    /// 跑一次，收输出。
    ///
    /// **没有另加看门狗**：脚本自己会重试三次就放弃（约 24 秒封顶），
    /// 再叠一层只会让错误信息变成「被杀了」。
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
            return ToolResult(status: -1, text: error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus,
                          text: String(data: data, encoding: .utf8) ?? "")
    }
}
