import Foundation

// MARK: - 把 ACE 里选中的轨送进 Live（2026-10-18）
//
// 反方向的那座桥：Live 分轨不要钱，所以「ACE 里唱好的 → 拿回 Live 分轨、循环」
// 是常走的路。干活的是 `scripts/ace_to_live.py`（ACE 渲染 → Live 桥摆进编曲视图），
// 这里只管起进程、把结果说成人话。
//
// 边界：只做「选中轨」范围的渲染（你在 ACE 里选哪条就送哪条），
// 不改 ACE 工程；进 Live 后落到「来自 ACE」那条轨，接在后面。

enum ACEClipTransfer {
    static func send() -> ACETransferResult {
        let script = BackendClient.locateRoot().appendingPathComponent("scripts/ace_to_live.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failure("找不到桥的脚本：scripts/ace_to_live.py")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return .failure("桥起不来：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        if proc.terminationStatus == 0 {
            let lines = text.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let tail = lines.suffix(2).joined(separator: "　")
            return ACETransferResult(ok: true, message: "已送进 Live。\(tail)")
        }

        let why = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure("没送成：" + (why.isEmpty ? "退出码 \(proc.terminationStatus)" : why))
    }
}
