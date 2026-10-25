import Foundation
import AppKit

/// 「送到谱面工作室」：把当前这份谱交给本机 8808 的离线网页工作室。
///
/// 用户 2026-10-24 要的：生成好的谱子、或导入来做 cover 的 MusicXML，
/// 一键送过去 —— 在网页里点音符改，再让他重唱，看看准不准。
///
/// 工作室本体在 `default-workspace/yue2-studio`：
/// 零依赖本地服务器，只监听 127.0.0.1。没在跑就顺手拉起来。
@MainActor
final class ScoreStudioClient {
    static let shared = ScoreStudioClient()

    private let port: UInt16 = 8808

    /// 谱面工作室是**可选组件**（另一个项目的本地网页服务）。
    ///
    /// 位置不写死：`CS_STUDIO_DIR` 指到哪就用哪；否则按顺序找
    /// **工作区里的 `yue2-studio`**（现在的实际位置）→ `~/Music/yue2-studio`（旧位置）。
    ///
    /// ⚠️ 2026-10-25 踩到：以前只认 `~/Music/yue2-studio`，而项目其实在
    /// `default-workspace/yue2-studio` ⇒ 点「进入谱面工作室」时服务器起在
    /// 一个不存在的目录里，页面打不开。现在按 `server.mjs` 是否存在来认。
    private var studioDir: URL {
        let env = ProcessInfo.processInfo.environment["CS_STUDIO_DIR"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
        }
        let fm = FileManager.default
        var candidates: [URL] = []
        candidates.append(BackendClient.locateRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("yue2-studio"))
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/yue2-studio"))
        for url in candidates
        where fm.fileExists(atPath: url.appendingPathComponent("server.mjs").path) {
            return url
        }
        return candidates[0]
    }

    /// node 的位置同样可配：`CS_NODE` 优先，否则试常见的两个安装位置。
    private var nodePath: URL {
        let env = ProcessInfo.processInfo.environment["CS_NODE"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent(".dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node")
    }

    /// 自检用：把三个路径原样报出来（`CS_STUDIO_DIR_PROBE=1`）。
    /// 不打开浏览器、不碰服务 —— 只回答"我打算在哪儿起它"。
    func probePaths() -> String {
        let dir = studioDir
        return "dir=\(dir.path) node=\(nodePath.path) "
            + "server=\(dir.appendingPathComponent("server.mjs").path)"
    }

    /// 把一份 ABC 谱送过去并打开浏览器。
    /// - completion: 成功时给的是打开的那页 URL；失败给的是人话错误。
    func send(abc: String, style: String, lyrics: String, seed: Int, steps: Int,
              title: String, completion: @escaping (Result<URL, Error>) -> Void) {
        if isPortOpen() {
            post(abc: abc, style: style, lyrics: lyrics, seed: seed, steps: steps,
                 title: title, completion: completion)
        } else {
            launchServer()
            // 起服务器要一两秒；起来之后再发。起不来就报错，别假装成功。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.post(abc: abc, style: style, lyrics: lyrics, seed: seed, steps: steps,
                          title: title, completion: completion)
            }
        }
    }

    /// 只把工作室**打开**（手上没谱的时候用）。
    ///
    /// 2026-10-25 用户要的：「在有乐谱的情况下，点进入 studio 就带出那份乐谱」——
    /// 反过来，**没有谱**时也不该点不动：打开一个空页面，让他自己导入 XML。
    /// 服务器没跑就顺手拉起来；起不来如实报（别假装打开了）。
    func open(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let page = URL(string: "http://127.0.0.1:\(port)/") else {
            completion(.failure(NSError(domain: "studio", code: 0)))
            return
        }
        if isPortOpen() {
            NSWorkspace.shared.open(page)
            completion(.success(page))
            return
        }
        launchServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            if self.isPortOpen() {
                NSWorkspace.shared.open(page)
                completion(.success(page))
            } else {
                completion(.failure(NSError(
                    domain: "studio", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                                "工作室没起来（日志在 /tmp/yue2-studio.log）"])))
            }
        }
    }

    // MARK: - 私有

    private func post(abc: String, style: String, lyrics: String, seed: Int, steps: Int,
                      title: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let api = URL(string: "http://127.0.0.1:\(port)/api/load") else {
            completion(.failure(NSError(domain: "studio", code: 0)))
            return
        }
        var request = URLRequest(url: api)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "abc": abc,
            "style": style,
            "lyrics": lyrics,
            "seed": seed,
            "steps": steps,
            "title": title,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String,
                      let page = URL(string: "http://127.0.0.1:\(self.port)/?session=\(id)") else {
                    completion(.failure(NSError(domain: "studio", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "工作室没有回话"])))
                    return
                }
                NSWorkspace.shared.open(page)
                completion(.success(page))
            }
        }.resume()
    }

    private func launchServer() {
        // nohup + &：服务器要活过这次点击，不能因为 app 退出就断。
        let escapedDir = studioDir.path.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedNode = nodePath.path.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "cd \"\(escapedDir)\" && nohup \"\(escapedNode)\" server.mjs >> /tmp/yue2-studio.log 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }

    /// 用一次 TCP 连接判断 8808 是否已经在听。
    private func isPortOpen() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
