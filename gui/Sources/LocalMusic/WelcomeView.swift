import SwiftUI
import AppKit

// MARK: - 欢迎界面

/// 「浩瀚宇宙里悬着一支高音谱号」。
///
/// 用户 2026-10-12 的原话：「再做一个**华而不实**的欢迎界面，浩瀚宇宙中的一个
/// 高高音谱号，黑底白色的高音谱号就像我们的图标一样」——
/// 他自己就说了这是花瓶，所以这个文件的取舍很明确：**好看优先**；
/// 但有一条不让步：**不许挡路**（约两秒自动淡出，点一下、按 Esc 立刻进）。
///
/// 谱号用的是跟程序图标**同一个字形**：Apple Symbols 里的 U+1D11E
///（`icon/make_icon.py` 画图标用的也是它）—— 所以这里跟 Dock 里那个图标
/// 是同一支谱号，不是另画的。
@MainActor
final class WelcomeWindow {

    static let shared = WelcomeWindow()
    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1000, screen.width * 0.74)
        let height = min(672, screen.height * 0.76)

        let panel = WelcomePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        // 圆角是自己画的（见 `WelcomeView`），所以窗口本身要透明。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // 无标题栏也得有个名：抓图/排查时「窗口清单」里靠它认人。
        panel.title = "欢迎"
        panel.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            self?.dismiss()
        })
        panel.center()
        window = panel

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.55
            panel.animator().alphaValue = 1
        }
    }

    /// 淡出，然后收起来。窗口留着（`isReleasedWhenClosed = false`），
    /// 下次再露一下不用重建。
    func dismiss() {
        guard let panel = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

/// 无标题栏的窗口默认**不肯当 key window**，而 Esc 与点击要靠它是 key —— 放开它。
final class WelcomePanel: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - 画面

struct WelcomeView: View {

    var onDismiss: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            Starfield()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                AppBadge()

                Spacer().frame(height: 34)

                // 「非常有精神的白色字」（用户 2026-10-12 的原话）。
                // 原先写的是**细体 + 六号字距** —— 空灵是空灵，可在星空里发飘、没劲。
                // 换成半粗 + 收窄字距 + 两道白色外发光：字自己站得住，
                // 边上还有一圈光，像从星海里亮出来的一样。
                //
                // 外面再挂一层**很淡的星尘**（用户当天追加的「加上一股淡淡的粒子感」）——
                // 粒子在**文字后面**：它只往字缝与四周透光，不会糊在字面上。
                //
                // ⚠️ 必须是 `.background(...)`，**不能**用 `ZStack { 粒子; 文字 }`：
                //    `Canvas` 是**贪婪**的，放进 ZStack 会把自己撑到"能用多大就多大"，
                //    于是整个竖排布局被顶开 —— 2026-10-12 实测就撞上了：
                //    谱号被挤到贴着窗口上沿、副标题跟底部那行字叠在了一起。
                //    `.background` 的尺寸跟着宿主走，文字占多大它占多大。
                Text("灵感路由")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(2.5)
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.5), radius: 12)
                    .shadow(color: Color(red: 0.5, green: 0.66, blue: 1.0).opacity(0.42), radius: 30)
                    // 给粒子留出文字以外的空地 —— 不然它们只敢在字里面飘。
                    .padding(.horizontal, 54)
                    .padding(.vertical, 26)
                    .background(TitleParticles())

                Spacer().frame(height: 10)

                // 英文名（2026-10-27 改）：MIR = Music Inspiration Router。
                // 放在大字和中文标语之间 —— 一眼看出"这两个名字是同一个软件"。
                // 旧名 MI · Music Inspirationist 同日退役。
                HStack(spacing: 9) {
                    Text("MIR")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .stroke(.white.opacity(0.38), lineWidth: 0.8))
                    Text("Music Inspiration Router")
                        .font(.system(size: 11.5, weight: .medium))
                        .tracking(2.0)
                }
                .foregroundStyle(.white.opacity(0.58))

                Spacer().frame(height: 13)

                // 标语（用户 2026-10-12 定：「纯线下AI音乐创作」）。
                // **2026-10-16 曾改成「纯线下AI歌曲创作」**（那阵只出带唱的歌）；
                // **2026-10-18 他改回「音乐创作」** —— 现在它能出歌、也能出纯器乐，
                // 还能把音频/谱子送进 ACE 和 Live，「歌曲」已经说小了。
                Text("纯线下AI音乐创作")
                    .font(.system(size: 13))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.48))

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Text("点一下进来")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("v\(VersionHistory.currentVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.22))
                }
                .padding(.bottom, 24)
            }
            .opacity(shown ? 1 : 0)
        }
        .background(Color(red: 0.018, green: 0.018, blue: 0.042))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onExitCommand { onDismiss() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.75)) { shown = true }
            // 别赖着不走：两秒半自动淡出。
            // `CS_WELCOME_LINGER=1` 时**不自动走** —— 那是给我抓图核对用的
            //（2.6 秒来不及看清楚谱号和星星）。
            let linger = ProcessInfo.processInfo.environment["CS_WELCOME_LINGER"] == "1"
            guard !linger else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { onDismiss() }
        }
    }
}

// MARK: 图标那一支谱号

/// 跟程序图标同一个样子：黑底 + 白色高音谱号（+ 一圈慢慢呼吸的光晕）。
private struct AppBadge: View {

    private let side: CGFloat = 170
    @State private var breathing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.235, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: side * 0.235, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1))

            // ⚠️ 这个是**字体里的字形**（U+1D11E），不是画出来的图形 ——
            //    跟图标同源。
            //    字号与位移都是**抓图量出来的**（2026-10-12）：
            //    一开始 0.70 时谱号只占了方块的 49%（图标里是 64%），看着小气；
            //    Apple Symbols 的这个字形在基线之上偏高，所以还要往下挪一点才居中。
            Text("\u{1D11E}")
                .font(.custom("Apple Symbols", size: side * 0.86))
                .foregroundStyle(.white)
                .offset(y: side * 0.035)
        }
        .frame(width: side, height: side)
        .shadow(color: Color(red: 0.42, green: 0.58, blue: 1.0)
                    .opacity(breathing ? 0.55 : 0.22),
                radius: breathing ? 46 : 26)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.3).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

// MARK: 标题外面那层星尘

/// 「一股淡淡的粒子感」（用户 2026-10-12 追加的要求）。
///
/// 分寸拿捏得很小心 —— 它是**星尘**，不是礼花：
///   · 又小又淡（半径 0.5–1.6pt、亮度 0.10–0.34），数量也压着（不到六十颗）；
///   · 只做两件事：**慢慢往上飘**（飘出去从底下回来）＋ **轻轻闪**；
///   · 画在文字**后面**，所以字面永远是干净的。
/// 一句话：远看像那行字自己在发光，凑近才发现周围浮着碎星。
private struct TitleParticles: View {

    private struct Particle {
        let x: Double
        let y: Double
        let radius: Double
        let brightness: Double
        let flickerSpeed: Double
        let rise: Double
        let phase: Double
    }

    /// 确定性伪随机：同一个种子 ⇒ 每次打开的分布一样（好看的样子可复现）。
    private static func make(_ count: Int) -> [Particle] {
        var seed: UInt64 = 0xC0FFEE_1234
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x20_0000_0000_0000)
        }
        return (0..<count).map { _ in
            let closeness = next()          // 越"近"的越大越亮，也飘得越快
            return Particle(
                x: next(),
                y: next(),
                radius: 0.5 + closeness * 1.1,
                brightness: 0.10 + closeness * 0.24,
                flickerSpeed: 0.7 + next() * 2.4,
                rise: 0.012 + next() * 0.030,
                phase: next() * 6.283)
        }
    }

    private let particles = TitleParticles.make(58)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for p in particles {
                    // 往上飘，飘出顶就从底下回来（取小数部分）
                    var y = (p.y - t * p.rise).truncatingRemainder(dividingBy: 1)
                    if y < 0 { y += 1 }
                    let x = p.x + 0.022 * sin(t * 0.4 + p.phase)
                    let flicker = 0.30 + 0.70 * (0.5 + 0.5 * sin(t * p.flickerSpeed + p.phase))
                    let r = p.radius
                    let rect = CGRect(x: x * size.width - r, y: y * size.height - r,
                                      width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(.white.opacity(p.brightness * flicker)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: 星空

/// 程序化画出来的星空：四团朦胧的星云 + 二百多颗会闪的星。
///
/// 为什么不用一张图片素材：这台机器上不该为了一张背景图多带几百 KB，
/// 而且画出来的能**慢慢动**（图片是死的）。三档大小 + 三种色温，
/// 看着才不像一张网点纸。
private struct Starfield: View {

    private struct Star {
        let x: Double          // 0…1 的相对位置
        let y: Double
        let radius: Double     // pt
        let brightness: Double
        let speed: Double
        let phase: Double
        let tint: Color
    }

    /// 星点用**确定性的伪随机**生成（同一个种子 ⇒ 每次打开星空一样）。
    /// 这样好看的样子可复现，出问题也能照着抓的图对。
    private static func makeStars(_ count: Int) -> [Star] {
        var seed: UInt64 = 0x5DEECE66D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x20_0000_0000_0000)
        }
        let tints: [Color] = [
            Color(red: 1.0, green: 1.0, blue: 1.0),
            Color(red: 0.78, green: 0.86, blue: 1.0),
            Color(red: 1.0, green: 0.94, blue: 0.82),
        ]
        return (0..<count).map { _ in
            let depth = next()                       // 越"近"的星越大越亮
            return Star(
                x: next(),
                y: next(),
                radius: 0.5 + depth * 1.5,
                brightness: 0.35 + depth * 0.6,
                speed: 0.5 + next() * 1.7,
                phase: next() * 6.283,
                tint: tints[Int(next() * 3) % 3])
        }
    }

    private let stars = Starfield.makeStars(250)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawNebulae(context, size)

                for star in stars {
                    let twinkle = 0.42 + 0.58 * (0.5 + 0.5 * sin(t * star.speed + star.phase))
                    let r = star.radius * (0.85 + 0.35 * twinkle)
                    let rect = CGRect(x: star.x * size.width - r,
                                      y: star.y * size.height - r,
                                      width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(star.tint.opacity(star.brightness * twinkle)))
                }
            }
        }
    }

    /// 四团星云。颜色压得低（0.3 上下）—— 星云是背景，抢了谱号就不好看了。
    private func drawNebulae(_ context: GraphicsContext, _ size: CGSize) {
        let blobs: [(Double, Double, Double, Color)] = [
            (0.20, 0.26, 0.60, Color(red: 0.30, green: 0.17, blue: 0.62)),
            (0.84, 0.74, 0.56, Color(red: 0.09, green: 0.27, blue: 0.60)),
            (0.64, 0.14, 0.38, Color(red: 0.48, green: 0.15, blue: 0.36)),
            (0.10, 0.88, 0.44, Color(red: 0.13, green: 0.33, blue: 0.44)),
        ]
        let short = min(size.width, size.height)
        for (fx, fy, fr, color) in blobs {
            let center = CGPoint(x: fx * size.width, y: fy * size.height)
            let radius = fr * short
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.32), color.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))
        }
    }
}
