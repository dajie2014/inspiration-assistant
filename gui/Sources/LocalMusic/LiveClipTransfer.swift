import Foundation

// MARK: - 把「Live 里选中的那个 clip」送进 ACE Studio（2026-10-18）
//
// 用户要的那座桥：在 Live 里选好一个 clip（音频或 MIDI），按一下按钮，
// 它就出现在 ACE 里。干活的是 `scripts/live_to_ace.py`，这里只负责起进程、
// 把结果说成人话。
//
// 两条边界（跟脚本一致，别在界面上偷偷放宽）：
//   · 只读 Live 里**选中**的那个 clip，不改 Live 的工程；
//   · 送进 ACE 后落哪条轨、用什么音色、唱什么词，都归用户在 ACE 里定。

enum LiveClipTransfer {
    static func send() -> ACETransferResult {
        let script = BackendClient.locateRoot().appendingPathComponent("scripts/live_to_ace.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failure("找不到桥的脚本：scripts/live_to_ace.py")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path]
        // stderr 并到 stdout：只读一根管子就不会死锁，而且报错本来也该给人看。
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return .failure("桥起不来：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // 读到进程退出（EOF）
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        if proc.terminationStatus == 0 {
            // 脚本最后一行是「已送进 ACE。」，前一行是 ACE 的原话 —— 两行都带上。
            let lines = text.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let tail = lines.suffix(2).joined(separator: "　")
            return ACETransferResult(ok: true, message: "已送进 ACE。\(tail)")
        }

        let why = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure("没送成：" + (why.isEmpty ? "退出码 \(proc.terminationStatus)" : why))
    }
}
