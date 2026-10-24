#!/bin/bash
# 命名规则自检 —— 界面（Swift）和脚本（Python）各有一份「把标题变成文件名」
# 的实现，两份**必须给出完全一样的结果**：同一首曲子，界面拿它命名目录、
# 脚本拿它命名 wav，一旦漂了，文件夹里就会出现两个不一样的名字。
#
# 做法：同一批用例（CASES）同时喂给两边，各自输出，再跟「期望答案」逐条比。
# 两边都对 = 规则对 **且** 两边一致。哪边漂了就报在哪。
#
# 用法：./gui/check-naming.sh          （只要 Command Line Tools，不必完整 Xcode）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 用例表：输入 <TAB> 期望 ──────────────────────────────────────────
# 第一列是喂进去的标题，第二列是两边都必须给出的答案。
# ⚠️ 用 TAB 分隔，所以第一列里的行尾空格不会被吃掉 —— 那正是要测的东西之一。
cat > "$WORK/cases.tsv" <<'CASES'
上课比天大	上课比天大
  两头有空白  	两头有空白
Cinematic trailer cue.	Cinematic trailer cue
pop/rock mix	pop_rock mix
a:b	a_b
末尾有点...	末尾有点
多   空格	多 空格
	未命名
/斜杠开头	_斜杠开头
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA	AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Contemporary chamber music for string quartet and bass clarinet	Contemporary chamber music for string
Slow-building orchestral post-minimalism extra	Slow-building orchestral post-minimalism
上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜	上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜上海之夜
CASES

# 拆成「输入」和「期望答案」两列
awk -F'\t' '{ print $1 }' "$WORK/cases.tsv" > "$WORK/in.txt"
awk -F'\t' '{ print $2 }' "$WORK/cases.tsv" > "$WORK/want.txt"

# ── 这一边：Swift（界面真正在用的那份源码） ─────────────────────────
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

// 从标准输入逐行读，逐行打印净化结果 —— 跟 Python 那边的协议一模一样。
while let line = readLine(strippingNewline: true) {
    print(FileName.safe(line))
}
SWIFT

echo "==> 编译 Swift 那半边（只用 Foundation，不碰界面）"
swiftc -module-cache-path "$WORK/modulecache" \
  "$HERE/Sources/LocalMusic/FileName.swift" "$WORK/main.swift" \
  -o "$WORK/swiftcheck" 2>&1 | grep -v '^$' || true
[ -x "$WORK/swiftcheck" ] || { echo "!! Swift 那半边没编译出来" >&2; exit 1; }

# ── 那一边：Python（脚本真正在用的那份源码） ────────────────────────
cat > "$WORK/pycheck.py" <<'PY'
import importlib.util
import sys

# 直接加载真正的脚本源码 —— 不复制一份，免得测的是复制品
spec = importlib.util.spec_from_file_location("hg", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

lines = sys.stdin.read().split("\n")
if lines and lines[-1] == "":
    lines.pop()
for line in lines:
    sys.stdout.write(mod.safe_file_stem(line) + "\n")
PY

# ── 跑，然后逐条比 ────────────────────────────────────────────────
"$WORK/swiftcheck" < "$WORK/in.txt" > "$WORK/out-swift.txt"
/usr/bin/python3 "$WORK/pycheck.py" "$ROOT/scripts/headless_generate.py" \
  < "$WORK/in.txt" > "$WORK/out-python.txt"

fail=0

check() {                                  # $1=谁 $2=它的输出
  if diff -u "$WORK/want.txt" "$2" > "$WORK/diff.txt"; then
    echo "    $1：$(wc -l < "$WORK/want.txt" | tr -d ' ') 条全对"
  else
    echo "    $1：**对不上** ——"; sed 's/^/      /' "$WORK/diff.txt"
    fail=1
  fi
}

echo "==> 逐条比对"
check "界面（Swift）" "$WORK/out-swift.txt"
check "脚本（Python）" "$WORK/out-python.txt"

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'HINT'

!! 命名规则没对上。
   两份实现分别是：
     · gui/Sources/LocalMusic/FileName.swift   （界面用）
     · scripts/headless_generate.py 的 safe_file_stem（脚本用）
   改了一边就必须改另一边，改完再跑一次本脚本。
HINT
  exit 1
fi

echo "==> 通过：两边规则一致，且与期望答案逐条相符"
