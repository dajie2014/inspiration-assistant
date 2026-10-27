#!/bin/bash
# ==============================================================================
# voice_convert_adapter.sh — 「换嗓子」（2026-10-25）
#
# 契约跟 render_adapter.sh / yue2_adapter.sh **一模一样**：
#   界面写 params.json → 本脚本写 progress.json → 退出码
#
# 它做三格：
#   1. 拆干声：Demucs 把歌拆成「人声」「伴奏」两条
#   2. 换嗓子：Seed-VC 用你的一段录音，把人声换成那个嗓子
#   3. 合回去：新人声 + 原伴奏
#
# 为什么必须先拆：Seed-VC 是**换嗓子**，不是"从带伴奏的混音里挑出人声"。
# 整首歌直接喂进去，鼓和贝斯会被当成人声内容一起处理 —— 2026-10-25 实测过。
#
# params.json：
#   { "source": "歌的音频（wav/mp3/flac）",
#     "target": "一段录音（几秒到 30 秒）",
#     "out_dir": "产物放哪", "title": "叫什么（可选）" }
#
# 环境变量：
#   SEEDVC_ROOT   Seed-VC 装在哪（默认外盘那个位置）
#
# 退出码：0 成功 / 2 参数错 / 3 缺环境 / 5 某一步失败
# ==============================================================================

set -uo pipefail
set +m

PARAMS=""
PROGRESS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --params)   PARAMS="${2:-}"; shift 2 ;;
    --progress) PROGRESS="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
PY=/usr/bin/python3
SEEDVC="${SEEDVC_ROOT:-/Volumes/REBIRTH/DSH-大文件/seed-vc}"
SEED_PY="$SEEDVC/.venv/bin/python"

# Seed-VC 的模型缓存放外盘 —— 内置盘只有二十几 G，AI 模型的缓存不能往那儿放。
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_HOME="${HF_HOME:-/Volumes/REBIRTH/DSH-大文件/hf-cache}"

write_progress() {
  local percent="$1" state="$2" message="$3" detail="${4:-}" output="${5:-}"
  [ -z "$PROGRESS" ] && return 0
  "$PY" - "$PROGRESS" "$percent" "$state" "$message" "$detail" "$output" <<'PYEOF'
import json, sys, time
path, percent, state, message, detail, output = sys.argv[1:7]
json.dump({
    "percent": int(percent), "state": state, "message": message,
    "detail": detail, "updated": int(time.time()),
    "output": (output or None),
}, open(path, "w"), ensure_ascii=False)
PYEOF
}

fail() {
  write_progress "${1:-0}" "failed" "$2" "${3:-}"
  echo "[voice_swap] $2" >&2
  exit "${4:-5}"
}

# ------------------------------ 读参数 ----------------------------------------

[ -n "$PARAMS" ] || fail 0 "没给参数文件" "" 2
[ -f "$PARAMS" ] || fail 0 "参数文件不存在：$PARAMS" "" 2

read_param() {
  "$PY" - "$PARAMS" "$1" <<'PYEOF'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], "") or "")
except Exception:
    print("")
PYEOF
}

SOURCE="$(read_param source)"
TARGET="$(read_param target)"
OUT_DIR="$(read_param out_dir)"
TITLE="$(read_param title)"

[ -n "$SOURCE" ] || fail 0 "没选歌" "" 2
[ -n "$TARGET" ] || fail 0 "没选目标录音" "" 2
[ -f "$SOURCE" ] || fail 0 "找不到这首歌：$SOURCE" "" 2
[ -f "$TARGET" ] || fail 0 "找不到那段录音：$TARGET" "" 2

[ -x "$SEED_PY" ] || fail 0 "声音转换引擎还没装好：$SEEDVC" \
  "装法见 seed-vc/README（第一次跑要下模型）" 3
command -v afconvert >/dev/null || fail 0 "系统缺 afconvert" "" 3

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$PROJECT_ROOT/output/VC-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR" || fail 0 "建不了输出目录：$OUT_DIR" "" 5
WORK="$OUT_DIR/.voice-swap"
mkdir -p "$WORK"

BASE="$(basename "$SOURCE")"
BASE="${BASE%.*}"
STAMP="$(date +%Y%m%d-%H%M%S)"
FINAL="$OUT_DIR/VC-${BASE}.wav"

echo "[voice_swap] 歌：$SOURCE"
echo "[voice_swap] 目标嗓子：$TARGET"

# ------------------------- 1. 统一格式 + 拆干声 --------------------------------

# ------------------------- 0. 把目标录音弄干净 --------------------------------
#
# ★ 2026-10-25 用户明确要求：「录音当中的人声和假东西分开，然后再从人声这里
#   截个几十秒」—— 手机录的会带环境声、可能带音乐，直接当样板会把那些也学进去。
#   顺序：分离人声 → 截中间 20 秒（太短学不像，太长会把杂音带进去）。
write_progress 3 "running" "整理你那段录音…" "先把人声挑出来，再截一段干净的"
# ★ `target_clean: true` = 这段**已经是干声**（用户自己先在 ACE Studio 里分离、
#   剪好再扔进来的）。2026-10-25 用户明确要走这条：「最保险的是我先把那个嗓子
#   音频放在 ACE 里面分割伴奏和人声，然后把剪出来的人声扔给灵感助手」。
#   这时候再分离一遍是画蛇添足 —— 直接原样用，也省掉一次 Demucs。
TARGET_ALREADY_CLEAN="$(read_param target_clean)"
TA_WAV="$WORK/target-in.wav"
afconvert -f WAVE -d LEI16 "$TARGET" "$TA_WAV" 2>/dev/null || cp "$TARGET" "$TA_WAV"
case "$TARGET_ALREADY_CLEAN" in
  True|true|1)
    TA_VOX="$TA_WAV"          # ★ 必须给 TA_VOX 赋值：下面统一还要过一遍截取
    echo "[voice_swap] 目标录音按「已是干声」处理，不再分离"
    ;;
  *)
    TA_VOX=""
    rm -rf "$WORK/target-stems"
    if "$SEED_PY" -m demucs --two-stems=vocals -o "$WORK/target-stems" "$TA_WAV" \
         >>"$WORK/log.txt" 2>&1; then
      [ -f "$WORK/target-stems/htdemucs/target-in/vocals.wav" ] && \
        TA_VOX="$WORK/target-stems/htdemucs/target-in/vocals.wav"
    fi
    # 分离失败就退回原文件 —— 有干净录音总比报错好
    [ -n "$TA_VOX" ] || TA_VOX="$TA_WAV"
    ;;
esac
TARGET_CLEAN="$WORK/target-clean.wav"
"$SEED_PY" - "$TA_VOX" "$TARGET_CLEAN" <<'PYEOF' >>"$WORK/log.txt" 2>&1 || \
  fail 4 "整理录音失败" "原因在 $WORK/log.txt" 5
import sys
import numpy as np
import soundfile as sf
src, dst = sys.argv[1:3]
x, sr = sf.read(src, always_2d=True)
want = int(30 * sr)
if len(x) > want:
    # ★ 挑**最响的**那 20 秒（2026-10-25 改）：原先取正中间，
    #   结果《甜蜜蜜》中间正好是间奏 —— 截出来一段没唱的当参考，
    #   人声样板里没人声，白跑一趟。响的那段一定是唱得最满的那段。
    mono = x.mean(axis=1) if x.ndim > 1 else x
    step = max(1, sr // 2)
    best_i, best_e = 0, -1.0
    for i in range(0, len(mono) - want + 1, step):
        e = float(np.mean(mono[i:i + want] ** 2))
        if e > best_e:
            best_e, best_i = e, i
    x = x[best_i:best_i + want]
sf.write(dst, x, sr)
print(f"参考音 {len(x) / sr:.1f} 秒")
PYEOF
TARGET="$TARGET_CLEAN"
echo "[voice_swap] 参考音整理完毕：$TARGET"

write_progress 8 "running" "把歌读进来…" "先统一成 44.1k 无损，再让人声和伴奏分开"
WAV="$WORK/source.wav"
afconvert -f WAVE -d LEI16 "$SOURCE" "$WAV" 2>/dev/null || {
  # flac/mp3 都能转；转不了就退回按原文件处理
  cp "$SOURCE" "$WAV" 2>/dev/null || fail 5 "读不了这个音频：$SOURCE" "" 5
}

write_progress 12 "running" "把人声和伴奏分开…" "通常二三十秒；第一次跑要下模型"
rm -rf "$WORK/stems"
"$SEED_PY" -m demucs --two-stems=vocals -o "$WORK/stems" "$WAV" \
  >>"$WORK/log.txt" 2>&1 || fail 20 "拆轨失败" "原因在 $WORK/log.txt" 5

VOCALS="$WORK/stems/htdemucs/source/vocals.wav"
INST="$WORK/stems/htdemucs/source/no_vocals.wav"
[ -f "$VOCALS" ] || fail 25 "没拆出人声" "可能是纯器乐，没有人声可分" 5
[ -f "$INST" ] || fail 25 "没拆出伴奏" "" 5

# ------------------------- 2. 换嗓子 ------------------------------------------

write_progress 35 "running" "换嗓子…" "四十几秒的歌大约一分多钟"
rm -rf "$WORK/out"
mkdir -p "$WORK/out"
# ★ **必须在 Seed-VC 自己的目录里跑**（2026-10-25 实际踩到）：
#   它把模型缓存放 `checkpoints/hf_cache`（**相对当前目录**），
#   从项目根直接调就会去 `my-songwriter/checkpoints/` 找 —— 找不到就重新下一遍，
#   表现是"卡在 35% 不动"，日志里一点线索都没有（tqdm 的下载条被缓冲吞了）。
( cd "$SEEDVC" && "$SEED_PY" inference.py \
    --source "$VOCALS" --target "$TARGET" --output "$WORK/out" \
    --diffusion-steps 30 --f0-condition True ) \
  >>"$WORK/log.txt" 2>&1 || fail 70 "换嗓子失败" "原因在 $WORK/log.txt" 5

NEW_VOX="$(ls -t "$WORK/out"/*.wav 2>/dev/null | head -1)"
[ -f "$NEW_VOX" ] || fail 75 "换嗓子没出结果" "原因在 $WORK/log.txt" 5

# ------------------------- 3. 合回伴奏 -----------------------------------------

write_progress 88 "running" "把伴奏合回去…" "几秒钟"
"$SEED_PY" - "$INST" "$NEW_VOX" "$FINAL" <<'PYEOF' >>"$WORK/log.txt" 2>&1 || fail 92 "合轨失败" "原因在 $WORK/log.txt" 5
import sys
import numpy as np
import soundfile as sf

inst_path, vox_path, out_path = sys.argv[1:4]
inst, sr_i = sf.read(inst_path, always_2d=True)
vox, sr_v = sf.read(vox_path, always_2d=True)
if sr_i != sr_v:
    raise SystemExit(f"采样率不一致：{sr_i} vs {sr_v}")
n = min(len(inst), len(vox))
inst, vox = inst[:n], vox[:n]
i_rms = float(np.sqrt(np.mean(inst**2))) or 1e-9
v_rms = float(np.sqrt(np.mean(vox**2))) or 1e-9
vox = vox * (i_rms / v_rms)
mix = inst + vox
peak = float(np.max(np.abs(mix)))
if peak > 0.98:
    mix = mix * (0.98 / peak)
sf.write(out_path, mix, sr_i)
PYEOF

write_progress 100 "done" "做好了" "$(basename "$FINAL")" "$FINAL"
echo "[voice_swap] 产物：$FINAL"
exit 0
