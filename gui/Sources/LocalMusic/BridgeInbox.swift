import AppKit
import Foundation

/// 与 Composer Assistant（CA）之间的**文件信箱** —— 现在是**两个方向都走这里**。
///
/// 收（CA 送来）：每个 tag 一个文件，送歌词不会把风格冲掉。
///   风格 → `style.json` ；歌词 → `lyrics.json`
///   `{"from":"composer-assistant","tag":"style","text":"…","at":1791810500}`
///
/// 回（本程序交给 CA 取）：`from-composer-step.json` —— 存的是**当前表单**的样子
///   `{"from":"composer-step","prompt":"…","lyrics":"…","at":…}`
///
/// **不轮询**（两个项目都守着这条）：读的时机只有三个 ——
///   ① 启动时；② 收到那个本地分布式通知时；③ 窗口被激活时。
/// 三条都读同一批文件，**按 `at` 时间戳判"这一封我读过没有"**，
/// 所以重复读不会重复填。这样即使分布式通知被系统挡掉，只要用户把窗口
/// 切到前面就能收到 —— 通道坏一半也不会静默失灵。
///
/// ★ 写回那一半（本程序 → CA）**故意不发通知**：CA 是"点一下取回"才来读，
///   它自己知道什么时候要。多发一个通知，等于多一条会静默失灵的通道。
@MainActor
enum BridgeInbox {

    static let notificationName = "com.composerstep.bridge.style"
    /// 只认 CA 送来的；自己写回的那份发给 CA，不往自己这儿填。
    static let expectedSender = "composer-assistant"
    /// 写回那份的署名 —— CA 拿它核对"这封确实是 CS 写的"。
    static let ownName = "composer-step"

    /// 信箱里能收的**两样东西**。
    enum Field: String, CaseIterable {
        case style
        case lyrics

        var fileName: String { "\(rawValue).json" }

        /// 「这封读过没有」用的两个键。
        ///
        /// ⚠️ 风格那对**沿用旧键名**（`bridge.lastStyleAt/Text`）：换个名字等于
        /// 把它当成没读过，升级后第一次开窗就会把上一封旧信又填一遍。
        var seenAtKey: String {
            self == .style ? "bridge.lastStyleAt" : "bridge.lastLyricsAt"
        }
        var seenTextKey: String {
            self == .style ? "bridge.lastStyleText" : "bridge.lastLyricsText"
        }
    }

    /// `nonisolated`：只是算一个路径，不碰 UI、不碰 `UserDefaults` ——
    /// 写回那一半（防抖任务里）不必为了拿个路径先跳回主线程。
    nonisolated static var folder: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Composer Bridge", isDirectory: true)
    }

    nonisolated static func file(_ field: Field) -> URL {
        folder.appendingPathComponent(field.fileName)
    }

    /// 写回给 CA 的那一份。
    nonisolated static var writeBackFile: URL { folder.appendingPathComponent("from-composer-step.json") }

    struct Delivery: Codable {
        var from: String?
        var tag: String?
        var text: String?
        var at: Double?
    }

    /// 写回的信：**风格与歌词装在同一封里** —— 它们本来就是同一张表单的两栏，
    /// 分成两个文件会出现"取回时拿到半新半旧"的组合。
    struct Snapshot: Codable {
        var from: String
        var prompt: String
        var lyrics: String
        var at: Double
    }

    /// 读某一栏；有**新的**就返回那段文本，否则 `nil`。
    ///
    /// 为什么不能只看时刻（2026-10-12 真踩到）：光比"时间戳更大"太脆 ——
    /// 谁手工往信箱里塞过一封带**未来**时间戳的，后面的真信就**全被当成旧的丢掉**，
    /// 而且是**静默**的：对面程序被叫到前面了、框里却一个字没有，看起来像"按钮坏了"。
    /// 现在两条判据取**或**：时刻更大、**或者**内容跟上次不一样 —— 都算新的一封。
    static func takeNew(_ field: Field) -> String? {
        guard let data = try? Data(contentsOf: file(field)),
              let delivery = try? JSONDecoder().decode(Delivery.self, from: data),
              delivery.from == expectedSender,
              delivery.tag == nil || delivery.tag == field.rawValue,
              let text = delivery.text
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let at = delivery.at ?? 0
        let seenAt = UserDefaults.standard.double(forKey: field.seenAtKey)
        let seenText = UserDefaults.standard.string(forKey: field.seenTextKey)
        guard at > seenAt || trimmed != seenText else { return nil }
        UserDefaults.standard.set(at, forKey: field.seenAtKey)
        UserDefaults.standard.set(trimmed, forKey: field.seenTextKey)
        return trimmed
    }

    // MARK: - 谱面工作室的「重新唱一遍」

    /// 谱面工作室送来的重唱请求（2026-10-25）。
    ///
    /// 用户原话：「修改完乐谱之后，重新唱一遍。就自动触发一轮新的生成，
    /// 在主程序当中写一个 script。」
    /// 送的是**改完的整份 ABC**（不是路径 —— 工作室那边随时可能换文件），
    /// 外加当时那套词 / 风格 / 种子 / 步数。
    struct Regenerate: Codable {
        var from: String?
        var abc: String?
        var style: String?
        var lyrics: String?
        var seed: Int?
        var steps: Int?
        var title: String?
        var at: Double?
    }

    nonisolated static var regenerateFile: URL {
        folder.appendingPathComponent("regenerate.json")
    }

    /// 有没有**新的**重唱请求；有就取走。
    ///
    /// ⚠️ 判重只看时刻、不看内容：同一份谱用户可能故意再唱一遍（不满意上一版），
    /// 所以他再点一次就该再跑一次。重复读同一个文件不会重复开跑。
    static func takeRegenerate() -> Regenerate? {
        guard let data = try? Data(contentsOf: regenerateFile),
              let request = try? JSONDecoder().decode(Regenerate.self, from: data),
              request.from == "yue2-studio",
              let abc = request.abc,
              !abc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let at = request.at ?? 0
        let seenAt = UserDefaults.standard.double(forKey: "bridge.lastRegenerateAt")
        guard at > seenAt else { return nil }
        UserDefaults.standard.set(at, forKey: "bridge.lastRegenerateAt")
        return request
    }

    /// 把**当前表单**写回信箱，等 CA 来取。
    ///
    /// `nonisolated`：它只落一个文件、不碰 UI，也不读 `UserDefaults` ——
    /// 调用方（防抖任务）不必为了写一行字先跳回主线程。
    nonisolated static func writeBack(prompt: String, lyrics: String) {
        let snapshot = Snapshot(from: ownName, prompt: prompt, lyrics: lyrics,
                                at: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: writeBackFile, options: .atomic)
        } catch {
            // ★ 写不出来**不能沉默**：对面那边只会显示"还没收到"，
            //   谁也看不出到底是谁的问题（这一行专供 `CS_BRIDGE_PROBE` 自检看）。
            NSLog("[ComposerBridge] 写回信箱失败：\(error)")
        }
    }
}
