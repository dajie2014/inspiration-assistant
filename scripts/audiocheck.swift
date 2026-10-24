// audiocheck.swift — 声音链路诊断小工具（命令行）
//
// 用途：试听没声音时，把"到底哪一环断了"查清楚，而不是靠猜。
// 它做三件事：
//   1. 列出所有能输出的设备，连带各自的音量、是否静音、采样率
//   2. 指出系统默认输出是谁
//   3. 可以指定一块设备播一段音频，并在播放前**读回**确认设备真的切过去了
//
// 编译（本机只装了 Command Line Tools）：
//   swiftc -module-cache-path <某可写目录> -o audiocheck audiocheck.swift
//
// 用法：
//   ./audiocheck list
//   ./audiocheck play "<设备名>" <音频文件.wav>
//   ./audiocheck play default <音频文件.wav>

import Foundation
import CoreAudio
import AVFoundation

// MARK: - CoreAudio 读属性

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func deviceIDs() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func name(of device: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
    return status == noErr ? (value as String) : "?"
}

func outputChannels(_ device: AudioDeviceID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func masterVolume(_ device: AudioDeviceID) -> Float? {
    for element in [kAudioObjectPropertyElementMain, 1] as [AudioObjectPropertyElement] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { continue }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return value
        }
    }
    return nil
}

func muteState(_ device: AudioDeviceID) -> Bool? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                          mScope: kAudioObjectPropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(device, &addr) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func defaultOutputID() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
    return device == 0 ? nil : device
}

func runningSomewhere(_ device: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return false }
    return value != 0
}

// MARK: - 命令

/// 按显示宽度补空格。Swift 的 String(format:) 不认 C 的 %s，
/// 中文/混合宽度也容易错位，所以自己排。
func pad(_ text: String, _ width: Int) -> String {
    let filled = text.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2000 ? 2 : 1) }
    return text + String(repeating: " ", count: max(1, width - filled))
}

func cmdList() {
    let def = defaultOutputID()
    print("系统默认输出：\(def.map { name(of: $0) } ?? "无")\n")
    print(pad("设备", 26) + pad("输出路", 8) + pad("音量", 8) + pad("静音", 7) + pad("采样率", 10) + "在用")
    for id in deviceIDs() {
        let channels = outputChannels(id)
        guard channels > 0 else { continue }
        let vol = masterVolume(id).map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        let mute = muteState(id).map { $0 ? "是" : "否" } ?? "—"
        let rate = nominalSampleRate(id).map { String(format: "%.0f Hz", $0) } ?? "—"
        let busy = runningSomewhere(id) ? "是" : "否"
        let mark = (id == def) ? " ★默认" : ""
        print(pad(name(of: id), 26) + pad("\(channels)", 8) + pad(vol, 8) + pad(mute, 7) + pad(rate, 10) + busy + mark)
    }
}

func findDevice(named wanted: String) -> AudioDeviceID? {
    for id in deviceIDs() where outputChannels(id) > 0 {
        if name(of: id) == wanted { return id }
    }
    return nil
}

func cmdPlay(_ deviceArg: String, _ file: String) {
    let url = URL(fileURLWithPath: file)
    guard FileManager.default.fileExists(atPath: file) else {
        print("找不到音频文件：\(file)"); exit(2)
    }

    var target: AudioDeviceID?
    if deviceArg == "default" {
        target = defaultOutputID()
    } else if let found = findDevice(named: deviceArg) {
        target = found
    } else {
        print("没找到这块设备：\(deviceArg)（先跑 list 看看确切名字）")
        exit(2)
    }

    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    engine.attach(node)

    do {
        let audioFile = try AVAudioFile(forReading: url)
        engine.connect(node, to: engine.mainMixerNode, format: audioFile.processingFormat)

        if let device = target, let unit = engine.outputNode.audioUnit {
            var value = device
            let status = AudioUnitSetProperty(unit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &value, UInt32(MemoryLayout<AudioDeviceID>.size))
            print("把输出切到「\(name(of: device))」：\(status == noErr ? "成功" : "失败（错误码 \(status)）")")

            // 读回确认 —— 这一步是关键，写了不等于生效
            var readBack = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioUnitGetProperty(unit,
                                                  kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0,
                                                  &readBack, &size)
            if readStatus == noErr {
                print("读回确认：引擎实际使用的是「\(name(of: readBack))」")
            } else {
                print("读回失败（错误码 \(readStatus)）")
            }
        } else {
            print("没有指定设备（或拿不到输出单元），将走系统默认")
        }

        try engine.start()
        print("引擎已启动：running=\(engine.isRunning)，输出格式=\(engine.outputNode.outputFormat(forBus: 0))")

        node.scheduleFile(audioFile, at: nil) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
        node.play()
        print("正在播放 \(url.lastPathComponent)（\(String(format: "%.1f", Double(audioFile.length) / audioFile.processingFormat.sampleRate)) 秒）…")
        RunLoop.main.run()
    } catch {
        print("播放失败：\(error)")
        exit(1)
    }
}

// MARK: - 入口

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法：audiocheck list | audiocheck play \"<设备名>|default\" <文件.wav>")
    exit(1)
}
switch args[1] {
case "list": cmdList()
case "play":
    guard args.count >= 4 else { print("用法：audiocheck play \"<设备名>|default\" <文件.wav>"); exit(1) }
    cmdPlay(args[2], args[3])
default:
    print("不认识的命令：\(args[1])")
    exit(1)
}
