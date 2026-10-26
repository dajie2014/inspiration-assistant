import AppKit
import SwiftUI

/// 「换嗓子」：先出一首歌，再用你录的一段话，把歌里的嗓子换掉。
///
/// 它跟「生成」是**前后两段**，不是同一条流程里的一步 —— 所以入口放在右栏那排
/// 按钮里，点开一个只有这一件事的小窗。
///
/// 后端是 `voice_convert_adapter.sh`，契约跟另两条脚本一样（params.json 进、
/// progress.json 出）。三格：拆干声 → 换嗓子 → 合回伴奏；目标录音那边还要
/// 「分离 + 截中间 20 秒」，理由写在脚本里。
@MainActor
final class VoiceSwapModel: ObservableObject {
    @Published var source: URL?
    @Published var target: URL?
    /// 这段录音**已经是干声**（用户先在 ACE 里分离、剪好）。
    /// 开着就不再做分离和截取 —— 再动一次是画蛇添足，还白跑一次 Demucs。
    @Published var targetIsClean = false
    @Published var busy = false
    @Published var percent = 0
    @Published var status = "选一首歌，再选一段录音。"
    @Published var detail = ""
    @Published var result: URL?
    @Published var failure: String?

    private let root = BackendClient.locateRoot()
    private var process: Process?
    private var pollTask: Task<Void, Never>?

    var outputRoot: URL { OutputLocation.url(projectRoot: root) }

    var canStart: Bool { !busy && source != nil && target != nil }

    // MARK: - 选材料

    func pickSource() {
        let panel = NSOpenPanel()
        panel.title = "选一首歌"
        panel.message = "要换嗓子的那首。自己生成的歌在输出文件夹里。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        failure = nil
        result = nil
        status = "选好歌了。再选一段你的录音。"
    }

    func pickTarget() {
        let panel = NSOpenPanel()
        panel.title = "选一段你的录音"
        panel.message = "说几句话或唱一句都行。10 到 30 秒最好；长了会自动截中间那段。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = url
        failure = nil
        result = nil
        status = "材料齐了，按「开始换嗓子」。"
    }

    // MARK: - 跑

    func start() {
        guard let source, let target, !busy else { return }
        let script = root.appendingPathComponent("voice_convert_adapter.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            failure = "找不到 voice_convert_adapter.sh（项目根里应该有）"
            return
        }

        busy = true
        percent = 0
        result = nil
        failure = nil
        status = "开始…"
        detail = ""

        let stamp = Self.stamp()
        let folder = outputRoot.appendingPathComponent("VC-\(stamp)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paramsURL = folder.appendingPathComponent("params.json")
        let progressURL = folder.appendingPathComponent("progress.json")

        let params: [String: Any] = [
            "source": source.path,
            "target": target.path,
            "out_dir": folder.path,
            "title": "换嗓子",
            "target_clean": targetIsClean,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: params, options: [.prettyPrinted]),
              (try? data.write(to: paramsURL)) != nil else {
            busy = false
            failure = "写不了参数文件：\(paramsURL.path)"
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "--params", paramsURL.path, "--progress", progressURL.path]
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                // 脚本自己会把 done/failed 写进 progress.json；走到这里还没收下来，
                // 就是它半路死了 —— 把退出码说出来，别让人对着空进度等。
                if self.busy && proc.terminationStatus != 0 {
                    self.busy = false
                    self.failure = "换嗓子中途停了（退出码 \(proc.terminationStatus)）。"
                        + "详细原因在 \(folder.path)/.voice-swap/log.txt"
                }
            }
        }

        do {
            try p.run()
        } catch {
            busy = false
            failure = "起不了脚本：\(error.localizedDescription)"
            return
        }
        process = p
        poll(progressURL: progressURL, folder: folder)
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        process?.terminate()
        process = nil
        busy = false
        status = "停下了。"
    }

    func openResultInFinder() {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result])
    }

    func playResult() {
        guard let result else { return }
        NSWorkspace.shared.open(result)
    }

    // MARK: - 轮询

    private func poll(progressURL: URL, folder: URL) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.busy else { return }
                guard let snap = Self.readProgress(progressURL) else { continue }
                self.percent = snap.percent
                if !snap.message.isEmpty { self.status = snap.message }
                self.detail = snap.detail ?? ""
                if snap.state == "done" {
                    self.busy = false
                    self.percent = 100
                    self.status = "做好了。"
                    self.detail = ""
                    if let out = snap.output {
                        self.result = URL(fileURLWithPath: out)
                    }
                    return
                }
                if snap.state == "failed" {
                    self.busy = false
                    self.failure = snap.message
                    return
                }
            }
        }
    }

    private nonisolated static func readProgress(_ url: URL) -> ProgressSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProgressSnapshot.self, from: data)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - 弹窗

struct VoiceSwapView: View {
    @StateObject private var model = VoiceSwapModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("换嗓子")
                .font(.system(size: 16, weight: .semibold))
            Text("先用模型出一首歌，再拿你的一段录音，把歌里的嗓子换掉。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)

            material("歌", url: model.source, hint: "要换嗓子的那首",
                     action: model.pickSource)
            material("你的录音", url: model.target, hint: "当样板用的那段声音",
                     action: model.pickTarget)

            Toggle("这段我已经剪好了（在 ACE 里分离过，不用再处理）",
                   isOn: $model.targetIsClean)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
                .padding(.leading, 74)
                .disabled(model.busy)

            if model.busy {
                ProgressView(value: Double(model.percent), total: 100)
                    .progressViewStyle(.linear)
                Text("\(model.percent)% · \(model.status)")
                    .font(.system(size: 12))
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
            } else {
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            if let failure = model.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.result != nil {
                HStack(spacing: 8) {
                    Button("听一下") { model.playResult() }
                    Button("在访达里看看") { model.openResultInFinder() }
                }
            }

            // 结果放哪，写在这儿 —— 跟「生成」一样跟随偏好设置里的「输出文件夹」。
            Text("放在：\(model.outputRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack {
                if model.busy {
                    Button("停下") { model.cancel() }
                }
                Spacer()
                Button(model.busy ? "换着…" : "开始换嗓子") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
                Button("关上") { dismiss() }
            }
        }
        .padding(18)
        .frame(width: 520, height: 400)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
    }

    private func material(_ title: String, url: URL?, hint: String,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? hint)
                    .font(.system(size: 12))
                    .foregroundStyle(url == nil ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let url {
                    Text(url.deletingLastPathComponent().path)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            Button(url == nil ? "选…" : "换…") { action() }
                .disabled(model.busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
    }
}
