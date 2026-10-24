import Foundation
import AppKit
import Darwin

// MARK: - 跟 Ableton Live 的那座桥
//
// 2026-10-17 用户要的：「live 和 my songwriter 同时开着的时候自动连接。
// 在 songwriter 那一端添加一个 link live 的按钮。按下则打开 live。且连接好了。」
//
// 桥本身是 Live 那边的 `AbletonMySongwriter` 控制面脚本（见
// `ableton-mysongwriter/AbletonMySongwriter/`）。它加载后会在本机开一个 UDP 端口，
// 并把端口号写进临时目录的 `mysongwriter-live.port`。
//
// 这边只做三件事：**看 Live 开没开、ping 一下端口、没开就打开它**。
// 真正的搬运（把歌放进 clip）走 `push_to_live.py`，不在这里。

/// 跟 Live 的四种状态。界面上的按钮就照着它变。
enum LiveLinkState: Equatable {
    /// Live 没开。
    case notRunning
    /// Live 开着，但桥没加载 —— 多数是设置里没选控制面。
    case noBridge
    /// 正在等它起来 / 正在连。
    case connecting
    /// 通了。
    case connected
}

enum LiveLink {

    /// Live 的安装位置。用户装的是 Suite；换版本只改这一行。
    static let appPath = "/Applications/Ableton Live 12 Suite.app"

    /// 桥写的端口文件（跟 `AbletonMySongwriter.py` 里的 PORT_FILE 必须一致）。
    static let portFileName = "mysongwriter-live.port"
    /// 端口文件还没出现时先试这个（脚本里的默认端口）。
    static let defaultPort: UInt16 = 39032

    static func isLiveRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.ableton.live"
                || (app.localizedName ?? "").hasPrefix("Ableton Live")
        }
    }

    static func openLive() {
        let url = URL(fileURLWithPath: appPath)
        guard FileManager.default.fileExists(atPath: appPath) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// 读桥写下的端口。读不到就回默认端口。
    static func port() -> UInt16 {
        let path = NSTemporaryDirectory() + portFileName
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let value = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return defaultPort }
        return value
    }

    /// 问一句「在吗」。本机回环，正常几毫秒就回。
    static func ping(timeout: TimeInterval = 0.6) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port().bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let payload = #"{"id":1,"cmd":"ping"}"#
        let sent = payload.withCString { cString in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(fd, cString, strlen(cString), 0,
                           sockaddrPointer,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return false }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var from = sockaddr_in()
        var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &from) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &fromLength)
            }
        }
        guard received > 0 else { return false }
        let data = Data(buffer.prefix(received))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["ok"] as? Bool) == true
    }
}
