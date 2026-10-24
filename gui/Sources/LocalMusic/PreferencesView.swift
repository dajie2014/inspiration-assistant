import SwiftUI
import AppKit

/// 偏好设置窗口（⌘, 或主界面右下角的齿轮）。
struct PreferencesView: View {

    /// 存的是**设备名字**，不是设备编号 —— 编号每次开机都会重新分配，
    /// 存编号的话重启之后就会指到别的设备上（实际踩过）。空串 = 跟随系统。
    @AppStorage("outputDeviceName") private var savedDeviceName: String = ""

    /// 生成结果放在哪。**空串 = 没挑过，用项目里的 `output/`**。
    /// 用 `@AppStorage` 而不是直接读 `OutputLocation`，是为了让这一页自己跟着刷新
    /// （挑完文件夹，下面那行路径要立刻变）。键与 `OutputLocation.defaultsKey` 是同一个。
    @AppStorage(OutputLocation.defaultsKey) private var outputFolderPath: String = ""

    @State private var devices: [AudioOutputDevice] = []
    @State private var systemDefaultName: String = "—"
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("试听从哪块声卡出声")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)

                    deviceRow(deviceName: "", name: "跟随系统（当前：\(systemDefaultName)）")

                    ForEach(devices) { device in
                        deviceRow(deviceName: device.name, name: label(for: device))
                    }

                    HStack(spacing: 10) {
                        Button("重新扫描") { refresh() }
                            .controlSize(.small)
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.top, 2)

                    Text("只影响试听。生成音乐用的是这台电脑自己的计算，跟哪块声卡无关。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }

            Rectangle().fill(Palette.stroke).frame(height: 1)

            // ── 生成结果放在哪 ──
            //
            // 由头（用户 2026-10-12）：「能不能把他所有生成的乐谱和音频放在用户指定的
            // 位置，而不是那个 output？」⇒ 挑一个文件夹就行；**没挑过还是老地方**。
            VStack(alignment: .leading, spacing: 7) {
                Text("生成结果放在哪")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)

                HStack(spacing: 8) {
                    Text(shortOutputPath)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("选择…") { chooseFolder() }
                        .controlSize(.small)
                    Button("恢复默认") { OutputLocation.setCustomPath("") }
                        .controlSize(.small)
                        .disabled(outputFolderPath.isEmpty)
                    Button("打开") { openOutputFolder() }
                        .controlSize(.small)
                }

                Text(outputFolderPath.isEmpty
                     ? "现在放在程序自己的文件夹里（默认）。挑一个之后，歌、谱子和它的参数都放进去。"
                     : "主界面左栏列的就是这个文件夹里的曲子。正在生成的那一首不受影响。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
        .onAppear { refresh() }
    }

    // MARK: 小件

    private func deviceRow(deviceName: String, name: String) -> some View {
        let selected = savedDeviceName == deviceName
        return Button {
            savedDeviceName = deviceName
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Palette.accent : Palette.textSecondary)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Palette.accent.opacity(0.16) : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Palette.accent.opacity(0.5) : Palette.stroke)
            )
        }
        .buttonStyle(.plain)
    }

    private func label(for device: AudioOutputDevice) -> String {
        "\(device.name)（\(device.outputChannels) 路输出）"
    }

    /// 项目根 —— **不再自己找一遍**，跟界面用同一个判断（原先这里是重复实现）。
    private var projectRoot: URL { BackendClient.locateRoot() }

    private var shortOutputPath: String {
        OutputLocation.displayPath(projectRoot: projectRoot)
    }

    // MARK: 动作

    private func refresh() {
        devices = AudioDeviceCatalog.outputDevices()
        if let id = AudioDeviceCatalog.defaultOutputDeviceID(),
           let match = devices.first(where: { $0.id == id }) {
            systemDefaultName = match.name
        } else {
            systemDefaultName = "未知"
        }

        // 存的设备不在了（拔了、改名了）就如实讲，并回落到跟随系统
        if !savedDeviceName.isEmpty, !devices.contains(where: { $0.name == savedDeviceName }) {
            note = "上次选的「\(savedDeviceName)」现在不在，已回落到跟随系统"
            savedDeviceName = ""
        } else {
            note = "共找到 \(devices.count) 块能出声的设备"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "挑一个文件夹，生成出来的歌、谱子和参数都放进去"
        panel.prompt = "用它"
        // 打开面板时落在现在这个位置（还没有就落在它的上一层）
        let current = OutputLocation.url(projectRoot: projectRoot)
        panel.directoryURL = FileManager.default.fileExists(atPath: current.path)
            ? current
            : current.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            OutputLocation.setCustomPath(url.path)
        }
    }

    private func openOutputFolder() {
        let dir = OutputLocation.url(projectRoot: projectRoot)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
