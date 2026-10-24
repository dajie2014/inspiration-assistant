import Foundation
import CoreAudio
import AVFoundation

/// 系统里的一个音频输出设备。
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let outputChannels: Int

    /// 虚拟声卡 / 摄像头之类，排到列表后面去，免得盖住真正的声卡。
    var isVirtual: Bool {
        let lowered = name.lowercased()
        return lowered.contains("virtual") || lowered.contains("webcam")
            || lowered.contains("oray") || lowered.contains("virtualaudio")
    }
}

/// 用 CoreAudio 直接问系统要设备清单。
/// 不用 AVFoundation 那层，是因为要拿到设备的真实 ID —— 只有拿到 ID，
/// 播放的时候才能把声音**指定**送到某一块声卡上去。
enum AudioDeviceCatalog {

    // MARK: 查询

    static func outputDevices() -> [AudioOutputDevice] {
        allDeviceIDs()
            .compactMap { id in
                let channels = outputChannelCount(id)
                guard channels > 0, let name = deviceName(id) else { return nil }
                return AudioOutputDevice(id: id, name: name, outputChannels: channels)
            }
            // 真声卡在前，虚拟设备在后；同类按名字排
            .sorted { lhs, rhs in
                if lhs.isVirtual != rhs.isVirtual { return !lhs.isVirtual }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func name(of id: AudioDeviceID) -> String? {
        deviceName(id)
    }

    /// 把界面上存下来的**设备名字**还原成当前这次开机里的设备 ID。
    ///
    /// 为什么不存 ID：CoreAudio 的设备 ID 是每次开机重新分配的，
    /// 存下来重启之后多半就指到别的设备上去了（2026-10-11 试过，确认不可靠）。
    /// 名字是稳定的 —— 拔掉或改名时找不到，就回落到跟随系统。
    static func resolve(savedName: String) -> AudioDeviceID? {
        let wanted = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return outputDevices().first { $0.name == wanted }?.id
    }

    // MARK: CoreAudio 底层

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// 数一数这台设备有几路输出。0 路 = 只有输入（比如麦克风、摄像头）。
    private static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let text = name as String
        return text.isEmpty ? nil : text
    }
}

// MARK: - 指定设备播放

/// 试听用的播放器。
///
/// 这里**没有**用 AVFoundation 那个简易播放器，因为它只会往系统默认设备送声音。
/// 换成 AVAudioEngine 之后，可以在开播前把它的输出单元指到某一块声卡上 ——
/// 也就是「试听从我的 Focusrite 出来」这件事的实现方式。
@MainActor
final class DevicePlayer: ObservableObject {

    @Published private(set) var playingURL: URL?
    /// 播完（或被打断）时通知外面，用来复位界面上的播放按钮。
    var onFinish: (() -> Void)?

    // 每次播放都新建一套引擎和节点。
    // 复用同一套的话，上一块声卡的格式/状态会留在里面 —— 实测出现过
    //「第一次没声音、第二次才正常」的情况，就是这种残留造成的。
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

    /// 返回 nil 表示开始播放；返回文字表示出了什么状况（也含"切了声卡但没切上"）。
    @discardableResult
    func play(url: URL, device: AudioDeviceID?) -> String? {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)

            var note: String?

            // ① 先把输出设备定下来 —— 必须在连线之前做，
            //    否则混音器会按"上一块设备"的格式连好，之后换设备就对不上了。
            if let target = device {
                if let unit = engine.outputNode.audioUnit {
                    var value = target
                    let status = AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &value,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    if status != noErr {
                        note = "切换声卡失败（错误码 \(status)），这次按系统默认设备播放"
                    } else {
                        // 写了不等于生效 —— 读回来确认，读到的才是真的
                        var readBack = AudioDeviceID(0)
                        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                        let readStatus = AudioUnitGetProperty(
                            unit, kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global, 0, &readBack, &size
                        )
                        if readStatus == noErr, readBack != target {
                            let wanted = AudioDeviceCatalog.name(of: target) ?? "所选设备"
                            let actual = AudioDeviceCatalog.name(of: readBack) ?? "别的设备"
                            note = "想切到「\(wanted)」，但实际用的是「\(actual)」"
                        }
                    }
                } else {
                    note = "拿不到输出单元，这次按系统默认设备播放"
                }
            }

            // ② 再连线：此时混音器会按刚定好的设备来配置
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)

            // ③ 启动
            try engine.start()
            node.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.playingURL = nil
                    self.onFinish?()
                }
            }
            node.play()

            self.engine = engine
            self.node = node
            playingURL = url
            return note
        } catch {
            return "播放失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        node?.stop()
        engine?.stop()
        engine = nil
        node = nil
        if playingURL != nil {
            playingURL = nil
            onFinish?()
        }
    }

    func isPlaying(_ url: URL) -> Bool {
        playingURL == url && (node?.isPlaying ?? false)
    }
}
