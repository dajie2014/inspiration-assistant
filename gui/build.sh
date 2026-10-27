#!/bin/bash
# 编译并打包「灵感路由.app」（MIR · Music Inspiration Router）
# 只依赖 Command Line Tools（无需完整 Xcode）：已有验证，37 秒完成。
set -euo pipefail

APP_NAME="灵感路由"
EXEC_NAME="LocalMusic"
# ★ 内部标识**不许动**（2026-10-27 更名时确认）：设置存在
#   ~/Library/Preferences/com.jieda.composerstep.plist，改了等于重置。
BUNDLE_ID="com.jieda.composerstep"

GUI_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$GUI_DIR/.." && pwd)"
# 先建在项目里，建成了再装到「应用程序」文件夹 —— 这样构建失败时，
# 已经装好的那一份不会被删掉。
OUT_APP="$ROOT/$APP_NAME.app"
# ★ 2026-10-18 用户要求：**只留一份，装在「应用程序」里**。
#   以前每打包一次，项目里就多一个副本，桌面上容易认错、点错。
#   现在构建成功就 ditto 过去、把项目里那份删掉。
INSTALL_APP="/Applications/$APP_NAME.app"
CACHE="$ROOT/../.swift-cache"

# ── 版本号 ──
#
# ★ **真源是项目根的 `CHANGELOG.md`** —— 取最上面那一版的号。
#   这里原先写死一个 `VERSION="0.1.0"`，那样"程序里显示的版本"和
#   "《版本历史》里写的版本"是两份东西，迟早对不上（忘了改哪头都会骗到人）。
#   现在只有一处：加一版就先在 CHANGELOG.md 顶上添一段 `## x.y.z · 日期`，
#   构建时自动读出来。
CHANGELOG="$ROOT/CHANGELOG.md"
if [ ! -f "$CHANGELOG" ]; then
  echo "!! 缺少 $(basename "$CHANGELOG") —— 版本号和《版本历史》都从它来。" >&2
  exit 1
fi
VERSION="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' "$CHANGELOG" 2>/dev/null \
  | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || true)"
if [ -z "${VERSION}" ]; then
  echo "!! 从 $(basename "$CHANGELOG") 里读不到版本号。" >&2
  echo "   最上面需要有一行形如：## 0.2.0 · 2026-10-12" >&2
  exit 1
fi
echo "==> 版本 ${VERSION}（取自 $(basename "$CHANGELOG")）"

# 新版 SwiftUI 把 @State / @AppStorage 这些都实现成了**宏**，宏实现由 SwiftUIMacros
# 插件提供；而该插件只随完整 Xcode 发布，Command Line Tools **不含**它。
# 症状：external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
#
# 对策：回退到较旧的 SDK —— 那里的 SwiftUI 仍用 property wrapper 实现，不需要插件。
# （这套办法在 composer-assistant 那边已经用了很久，是验证过的。）
if [ -z "${SDKROOT:-}" ] && [ ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ]; then
  for candidate in MacOSX15.4 MacOSX15 MacOSX14.4 MacOSX14; do
    sdk_path="/Library/Developer/CommandLineTools/SDKs/${candidate}.sdk"
    if [ -d "$sdk_path" ]; then
      export SDKROOT="$sdk_path"
      echo "==> 本机 CLT 缺 SwiftUIMacros 插件，自动回退 ${candidate} SDK"
      break
    fi
  done
  if [ -z "${SDKROOT:-}" ]; then
    echo "!! 找不到可回退的旧版 SDK。请装完整 Xcode，或手动指定：" >&2
    echo "   SDKROOT=/path/to/MacOSX*.sdk ./build.sh" >&2
    exit 1
  fi
fi

# SPM 默认把缓存写进 ~/Library/Caches，在受限环境下会失败 —— 指到工作区里。
swift build -c release \
  --package-path "$GUI_DIR" \
  --disable-sandbox \
  --cache-path "$CACHE" \
  --scratch-path "$GUI_DIR/.build"

BIN="$(swift build -c release --package-path "$GUI_DIR" --disable-sandbox \
  --cache-path "$CACHE" --scratch-path "$GUI_DIR/.build" --show-bin-path)/$EXEC_NAME"
[ -x "$BIN" ] || { echo "!! 找不到可执行文件：$BIN"; exit 1; }

rm -rf "$OUT_APP"
mkdir -p "$OUT_APP/Contents/MacOS" "$OUT_APP/Contents/Resources"
cp "$BIN" "$OUT_APP/Contents/MacOS/$EXEC_NAME"

# 程序图标（黑底白色高音谱号）。图标源文件在 ../icon/。
# 换图标：改 ../icon/make_icon.py 里的画法，重跑它生成 AppIcon.icns，再跑本脚本。
if [ -f "$ROOT/icon/AppIcon.icns" ]; then
  cp "$ROOT/icon/AppIcon.icns" "$OUT_APP/Contents/Resources/AppIcon.icns"
else
  echo "!! 缺少 $ROOT/icon/AppIcon.icns（先跑 icon/make_icon.py）" >&2
fi

# 《使用手册》：**装进 app**，「帮助 → 使用手册」那条才打得开。
#
# 手册是产物（`Tools/update_doc.sh` 生成在项目根），这里只做拷贝 ——
# 构建流程不依赖 Python 与 LibreOffice，和图标同一个道理。
#
# ⚠️ 缺了就**中止**，不学图标那样只警告：图标缺了的退路是系统默认图标
#    （难看但能用），而手册缺了的退路是「帮助菜单里点了一下没反应」——
#    那正是 2026-10-11 使用者抱怨的那条死路（系统默认的「帮助」项指向
#    一个不存在的帮助书）。宁可构建失败，也不出一个帮助菜单是假的的包。
GUIDE="$ROOT/灵感路由-使用手册.pdf"
if [ -f "$GUIDE" ]; then
  cp "$GUIDE" "$OUT_APP/Contents/Resources/"
  echo "  使用手册已装入（$(basename "$GUIDE")）"
else
  echo "!! 缺少 $(basename "$GUIDE") —— app 里「帮助 → 使用手册」会弹「没有附带」。" >&2
  echo "   先跑 Tools/update_doc.sh 生成它，再跑本脚本。" >&2
  exit 1
fi

# 《版本历史》：正文就是项目根的 CHANGELOG.md（版本号也是从它读的），
# 「帮助 → 版本历史」和「关于 My Songwriter」打开的窗口读的都是**这一份**拷贝。
# 和手册同理 —— 缺了同样中止：窗口点开是空的，跟菜单坏了没两样。
cp "$CHANGELOG" "$OUT_APP/Contents/Resources/CHANGELOG.md"
echo "  版本历史已装入（CHANGELOG.md · ${VERSION}）"

# ★ 2026-10-25：把**源码根**写进包里。
#   为什么：`BackendClient.locateRoot()` 靠"从 .app 往上找 render_adapter.sh"定位；
#   装在 /Applications 后，往上找六层也到不了项目根 ⇒ 落到 `~/Music/MySongwriter`，
#   于是**双击打开是空列表、生成也出不了歌**。用户平时从项目里启动，所以没撞上，
#   但"装好的那一份"应该自己能找到家。
#   这里写一份绝对路径，程序先读它（仍然校验 render_adapter.sh 在不在，
#   项目搬走了就自动回到原来的找法）。
printf '%s\n' "$ROOT" > "$OUT_APP/Contents/Resources/root.txt"
echo "  源码根已写入（root.txt）"

cat > "$OUT_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 本机自用，ad-hoc 签名足够（否则 Gatekeeper 会拦自己编的程序）
# ★ 2026-10-18 改名后踩到：app 名字带中文、目录里又留着 Finder 的扩展属性时，
#   codesign 会报 "resource fork, Finder information ... not allowed" 然后**跳过签名**
#   —— 于是 bundle 身份变成可执行文件名 `LocalMusic`，隐私授权又要重新问一遍。
#   所以：先清扩展属性，签名时**显式钉住 bundle id**。
xattr -cr "$OUT_APP" 2>/dev/null || true
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT_APP" >/dev/null 2>&1 || echo "  (签名跳过)"

echo "==> 装到 ${INSTALL_APP}（覆盖旧版）"
rm -rf "$INSTALL_APP"
/usr/bin/ditto "$OUT_APP" "$INSTALL_APP"
rm -rf "$OUT_APP"

echo "完成：$INSTALL_APP"
