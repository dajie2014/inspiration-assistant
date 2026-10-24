#!/bin/bash
# ==============================================================================
# render_adapter.sh — 界面 / 外部程序 与 ACE-Step 后端之间唯一的桥
#
# 职责（只有这些）：
#   1. 固定绑定本机 ACE-Step 1.5（没有后端切换选项，也不会去连任何云端）
#   2. 把音频时长硬夹到 300 秒以内；另有运行时间护栏，卡死就杀
#   3. 提供精度开关（见 BF16 说明）
#   4. 用独立子进程跑推理，界面不会卡
#   5. 全程写 progress.json：{"percent": 0-100, "state": "idle|running|done|failed"}
#   6. 正常结束或被杀，都保证推理进程消失、内存还给系统
#   7. 只往本地磁盘写 wav；本脚本自身不发起任何网络请求
#
# 用法：
#   ./render_adapter.sh --params <参数.json> [--out-dir <目录>] [--progress <progress.json>]
#
# 参数 JSON（界面和 Composer Assistant 都写这个格式）：
#   {
#     "prompt": "风格描述", "lyrics": "歌词或 [Instrumental]",
#     "mode": "generate" | "repaint" | "reference",
#     "duration": 120, "bpm": 120, "keyscale": "C Major", "steps": 8, "seed": -1,
#     "thinking": false, "language": "unknown",
#     "ref_audio": "", "src_audio": "", "repaint_start": 0, "repaint_end": -1,
#     "cover_strength": 0.5
#   }
# 退出码：0 成功 / 2 参数错 / 3 模型加载失败 / 5 生成失败 / 6 超时被杀 / 7 缺环境
# ==============================================================================

set -uo pipefail

# ------------------------------ 可配置区 --------------------------------------
# 单次生成的最长音频（秒）。超过这个数的请求会被夹到 300，不会拒绝。
MAX_AUDIO_SECONDS=300

# 运行时间护栏：真正跑起来后最多等多久（秒），超了就当卡死、杀掉。
# 经验值：M1 Max 上 1 分钟音频约 40 秒，再加模型加载的 1 分钟。
WATCHDOG_BASE=600          # 固定给模型加载留的余量
WATCHDOG_FACTOR=5          # 每 1 秒音频允许的推理秒数

# 内存看门狗（2026-10-12 加）—— 跑起来之后一直盯着，越线就按停。
# 阈值按**本机实测**定的：ACE-Step 生成时进程树峰值 13.5 GB、整机可用最低
# 22.7 GB、全程一次 swap 都没动。所以这里的线都留在"真的危险"那一侧，
# 正常生成碰不到它；碰到的时候，往往已经是机器快被拖垮了。
# 每一项都能用 CS_MEM_* 环境变量临时压小 —— **自检就靠这个**：
# 把线压到 5 GB 跑一次，看它是不是真的会把生成按停、并把原因写进 progress.json。
MEM_BUDGET_GIB="${CS_MEM_BUDGET_GIB:-20}"                  # 生成进程（连子进程）占用上限
MEM_MIN_AVAILABLE_GIB="${CS_MEM_MIN_AVAILABLE_GIB:-2}"     # 整机可用内存下限 —— 比这还低就是真没内存了
MEM_MAX_SWAP_OUT_MIB="${CS_MEM_MAX_SWAP_OUT_MIB:-64}"      # 这一趟新增换出上限（换出＝系统开始拿硬盘当内存）
MEM_MAX_SWAP_GROWTH_MIB="${CS_MEM_MAX_SWAP_GROWTH_MIB:-128}"  # swap 占用量增长上限

# 精度开关（spec 要求的可配置项，但请注意它在哪条路上真生效）：
#   本机 macOS 走 MLX 后端，上游 initialize_service 不接收精度参数，
#   MLX 自己决定数值精度 —— 也就是说在这里设 BF16=1 对 MLX 路径没有作用。
#   该开关仅在 PyTorch/CUDA 路径（将来换 NVIDIA 机器）上有意义，
#   那时它会被翻译成 ACESTEP_DTYPE=float16/float32。
BF16=0

# 是否要让语言模型参与（默认关：本工具不替用户编歌词和构思）。
# 参数 JSON 里的 "thinking" 字段可单独覆盖这一次。
DEFAULT_THINKING=0
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"                       # 本脚本就在项目根
BACKEND="$PROJECT_ROOT/backend/ACE-Step-1.5"
PYTHON="$BACKEND/python_embeded/bin/python3.11"
GENERATOR="$PROJECT_ROOT/scripts/headless_generate.py"
LOGDIR="$PROJECT_ROOT/logs"

PARAMS=""
OUT_DIR="$PROJECT_ROOT/output"
PROGRESS=""

# ⚠️ 打印只取第一个参数（消息），第二个参数是退出码 —— 早先写成 `$*`，
#    于是每个报错末尾都会多挂一个数字（"…没装好？ 7"），用户看到的就是这个。
die() { printf '%s\n' "[render_adapter] $1" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --params)    PARAMS="${2:-}"; shift 2 ;;
    --out-dir)   OUT_DIR="${2:-}"; shift 2 ;;
    --progress)  PROGRESS="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *)           die "不认识的参数：$1" ;;
  esac
done

[ -n "$PARAMS" ] || die "缺少 --params <参数.json>"
[ -f "$PARAMS" ] || die "参数文件不存在：$PARAMS"
# ⚠️ 变量名后面紧贴中文时必须写 ${VAR}：macOS 自带的 bash 3.2 会把全角字符的
#    字节当成变量名的一部分，于是报 "PYTHON?: unbound variable"。
[ -x "${PYTHON}" ] || die "找不到后端 Python：${PYTHON}（后端没装好？）" 7
[ -f "${GENERATOR}" ] || die "找不到推理脚本：${GENERATOR}" 7
# ★ 2026-10-16：权重被用户按自己的要求拆掉了（他买了 ACE Studio，不需要本地这套）。
#   这里给一句**人话**提示，别让他看到"模型加载失败"那种没头没脑的报错。
if [ ! -d "${BACKEND}/checkpoints/acestep-v15-turbo" ]; then
  die "本机的 Composer Step 模型已经在 2026-10-16 拆掉了（省出 10 GB）。
想装回来：cd ${BACKEND} && HOME=${PROJECT_ROOT}/_home ./python_embeded/bin/python3.11 ${PROJECT_ROOT}/scripts/fetch_models.py --jobs 6
或者直接用 YuE2 那台（它出的是带人声的歌 + 谱子）。" 7
fi

[ -n "$PROGRESS" ] || PROGRESS="$OUT_DIR/progress.json"
mkdir -p "$OUT_DIR" "$LOGDIR" "$(dirname "$PROGRESS")"

# ---------------------- 写 progress.json（含初始状态） ------------------------
# 用 python 写，保证和推理脚本写出来的是同一种格式。
#
# `detail` 是 2026-10-13 加的第四个参数（可省）：界面上接着大字后面那行小字，
# 用来回答"还要等多久 / 为什么慢"。它**必须带引号传**，值里有空格。
# write_progress <percent> <state> <message> [<detail>]
write_progress() {
  "$PYTHON" - "$PROGRESS" "$1" "$2" "$3" "${4:-}" <<'PY'
import json, os, sys, time
path, percent, state, message, detail = sys.argv[1:6]
payload = {"percent": int(percent), "state": state, "message": message,
           "detail": detail, "updated": int(time.time())}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
os.replace(tmp, path)
PY
}

# ------------------- 夹紧时长 + 补默认值（交给 python 改 JSON） ----------------
NORMALIZED="$LOGDIR/params_normalized.json"
"$PYTHON" - "$PARAMS" "$NORMALIZED" "$MAX_AUDIO_SECONDS" "$DEFAULT_THINKING" <<'PY'
import json, sys
src, dst, cap, default_thinking = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
with open(src, encoding="utf-8") as fh:
    p = json.load(fh)
try:
    dur = float(p.get("duration") or 60)
except (TypeError, ValueError):
    dur = 60.0
clamped = max(10.0, min(float(cap), dur))
p["duration"] = clamped
p["_duration_clamped"] = bool(abs(clamped - dur) > 0.5)
if "thinking" not in p:
    p["thinking"] = bool(default_thinking)
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(p, fh, ensure_ascii=False, indent=2)
print(clamped)
PY
[ $? -eq 0 ] || die "参数文件读不了（不是合法 JSON？）：$PARAMS"
DURATION=$("$PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))['duration'])" "$NORMALIZED")
if [ -z "$DURATION" ]; then DURATION=60; fi

WATCHDOG=$(( WATCHDOG_BASE + $(printf '%.0f' "$DURATION") * WATCHDOG_FACTOR ))
LOG="$LOGDIR/render_$(date +%Y%m%d-%H%M%S).log"

# ================== 两道闸：不许并发、内存不够不硬上 ==========================
#
# 2026-10-11 出过一次事：两次生成重叠着跑，每一次要吃约 30 GB
# （进程 15 GB ＋ MLX 锁住的 GPU 内存），64 GB 的机器当场被压垮。
# 加了这两道闸之后，宁可拒绝一次，也不让机器崩。
#
# ① 同一时间只准有一个生成在跑
LOCK_FILE="$PROJECT_ROOT/_cache/render.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
if [ -f "$LOCK_FILE" ]; then
  HOLDER=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    die "已经有一个生成在跑了（进程 ${HOLDER}）。同时跑两个会把内存压垮，等它结束再来。" 8
  fi
  rm -f "$LOCK_FILE"          # 上次没留干净的死锁，清掉
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ② 系统可用内存太低就直接不干
FREE_PCT=$(memory_pressure 2>/dev/null | awk '/memory free percentage/{gsub(/%/,"",$5); print $5}')
if [ -n "${FREE_PCT:-}" ] && [ "${FREE_PCT:-100}" -lt 20 ] 2>/dev/null; then
  die "系统可用内存只剩 ${FREE_PCT}%，不够跑一次生成。先关掉一些大程序（比如 ACE Studio 里的大工程）再试。" 9
fi

write_progress 1 running "正在准备…" "先核对一下这次的设置，马上交给 AI"

# ------------------------------- 起子进程 -------------------------------------
# 打开 job control，让推理进程自成进程组，这样超时时能整组杀掉。
export ACESTEP_DTYPE="$([ "$BF16" = "1" ] && echo float16 || echo float32)"
export ACESTEP_LM_BACKEND="${ACESTEP_LM_BACKEND:-mlx}"
export PYTORCH_ENABLE_MPS_FALLBACK=1
# matplotlib 会往 ~/.matplotlib 写字体缓存；指到项目内既躲开权限问题，也快一点
export MPLCONFIGDIR="$PROJECT_ROOT/_cache/matplotlib"
mkdir -p "$MPLCONFIGDIR"
# 明确断网环境（推理只需要本机权重）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

set -m
"$PYTHON" -u "$GENERATOR" --params "$NORMALIZED" --out-dir "$OUT_DIR" --progress "$PROGRESS" \
  >"$LOG" 2>&1 &
CHILD=$!
set +m

# ---------------------- 被强退时也要收干净 --------------------------------
# 界面被强退、终端按了 Ctrl-C、系统要求退出 —— 这些情况下本脚本会收到信号。
# 不接住的话：推理进程会变孤儿继续吃内存，而 progress.json 会一直停在
# "running"，界面看起来像永远在跑（2026-10-11 实际踩到，卡在 80%）。
# 注：SIGKILL（kill -9）接不住，那种情况由界面启动时清理陈旧状态兜底。
on_interrupt() {
  echo "[render_adapter] 收到中断信号，正在收尾" >>"$LOG"
  if [ -n "${GUARD_PID:-}" ]; then kill "$GUARD_PID" 2>/dev/null; fi
  if [ -n "${CHILD:-}" ]; then
    kill -TERM -"$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    sleep 1
    kill -KILL -"$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null
  fi
  write_progress 99 failed "半路被打断了" "界面关了，或者程序被强制退出"
  exit 130
}
trap on_interrupt TERM INT HUP

# ------------------------------ 看门狗 ---------------------------------------
# 子进程万一卡住（内存爆、等锁），到点整组杀掉，并把状态落成 failed。
(
  waited=0
  while [ "$waited" -lt "$WATCHDOG" ]; do
    sleep 5
    waited=$((waited + 5))
    kill -0 "$CHILD" 2>/dev/null || exit 0
  done
  echo "[render_adapter] 超过 ${WATCHDOG}s 仍未结束，判定为卡死，杀掉进程组 $CHILD" >>"$LOG"
  kill -TERM -"$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
  sleep 3
  kill -KILL -"$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null
  write_progress 99 failed "等得太久了，已经按停" "超过 ${WATCHDOG} 秒还没跑完，怕它一直占着机器"
) &
WATCHDOG_PID=$!

# ------------------------------ 内存看门狗 -----------------------------------
# 上面那道时间护栏只管「卡死」，管不了「内存爆」；入口那道检查（②）管的是
# 「开始的时候够不够」，也管不了「跑着跑着不够了」。这道补的正是中间那段：
# 每 2 秒量一次进程树占用 / 整机可用 / swap / 内存压力，任何一条越线就把整条
# 推理进程树按停 —— **宁可这一趟白跑，也不让 64 GB 的机器被拖垮**。
# 判据与 YuE2 自带的那道刹车同一思路（`yue2-local/mlx-Yue/src/lyra/measure.py`）。
MEM_LOG="$LOGDIR/memory_$(date +%Y%m%d-%H%M%S).jsonl"
"$PYTHON" "$PROJECT_ROOT/Tools/memory_guard.py" --pid "$CHILD" \
  --budget-gib "$MEM_BUDGET_GIB" \
  --min-available-gib "$MEM_MIN_AVAILABLE_GIB" \
  --max-swap-out-mib "$MEM_MAX_SWAP_OUT_MIB" \
  --max-swap-growth-mib "$MEM_MAX_SWAP_GROWTH_MIB" \
  --log "$MEM_LOG" >>"$LOG" 2>&1 &
GUARD_PID=$!

wait "$CHILD"
STATUS=$?
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null
kill "$GUARD_PID" 2>/dev/null
wait "$GUARD_PID" 2>/dev/null

# 看门狗踩线了吗？踩了就把原因取出来 —— 界面要显示的正是这句话。
MEM_STOPPED=""
if [ -f "$MEM_LOG" ]; then
  MEM_STOPPED=$("$PYTHON" - "$MEM_LOG" <<'PYEOF'
import json, sys
why = ""
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except Exception:
        continue
    if isinstance(d, dict) and d.get("stopped"):
        why = str(d["stopped"])
print(why)
PYEOF
)
fi

# ------------------------- 收尾：状态与内存清理 -------------------------------
# 推理进程已退出，Python 侧的内存随之归还系统（这是「跑完就释放」的实现方式）。
# 这里只补最后的状态，并确保万无一失地清掉可能残留的孙进程。
pkill -TERM -P "$CHILD" 2>/dev/null

if [ -n "$MEM_STOPPED" ]; then
  # 内存看门狗按停的：把原因原样告诉人（这是他唯一需要知道的那句话），
  # 并说清这不是故障 —— 机器还在，重来一次就行。
  write_progress 99 failed "内存不够，这一趟已经按停" "${MEM_STOPPED} —— 先把大程序关掉一些再试"
elif [ "$STATUS" -eq 0 ]; then
  # 正常完成时，headless 脚本已经写过 done/100，这里只在它漏写时兜底
  CUR=$("$PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1])).get('state',''))" "$PROGRESS" 2>/dev/null || echo "")
  [ "$CUR" = "done" ] || write_progress 100 done "出好了"
elif [ "$STATUS" -eq 6 ]; then
  write_progress 99 failed "等得太久了，已经按停" "超过 ${WATCHDOG} 秒还没跑完"
else
  CUR=$("$PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1])).get('state',''))" "$PROGRESS" 2>/dev/null || echo "")
  if [ "$CUR" != "failed" ]; then
    write_progress 99 failed "这一趟没成（退出码 ${STATUS}）" "详细原因写在日志里：$LOG"
  fi
fi

echo "[render_adapter] 结束，退出码 ${STATUS}，日志：$LOG"
exit "$STATUS"
