#!/bin/bash
# ==============================================================================
# export_audio.sh — 把生成出来的 wav 导出成 MP3 或 WAV
#
# 纯本地转换（ffmpeg），不联网。界面和 Composer Assistant 都调这一个脚本。
#
# 用法：
#   ./export_audio.sh --input <源.wav> --output <目标文件>
#   格式按目标文件的扩展名决定（.mp3 / .wav），也可以用 --format 强制指定。
#   MP3 默认 320 kbps（音乐用途，尽量少损失）。
#
# 退出码：0 成功 / 2 参数或文件问题 / 3 找不到 ffmpeg / 4 转换失败
# ==============================================================================
set -uo pipefail

# macOS 的 GUI 程序继承的 PATH 很干净，命令行装的 ffmpeg 通常不在里面，
# 所以这里把常见位置也找一遍。
find_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1; then command -v ffmpeg; return; fi
  for p in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
}

INPUT=""
OUTPUT=""
FORMAT=""
BITRATE="320k"

die() { echo "[export_audio] $*" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --input)   INPUT="${2:-}"; shift 2 ;;
    --output)  OUTPUT="${2:-}"; shift 2 ;;
    --format)  FORMAT="${2:-}"; shift 2 ;;
    --bitrate) BITRATE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)         die "不认识的参数：$1" ;;
  esac
done

[ -n "$INPUT" ]  || die "缺少 --input"
[ -n "$OUTPUT" ] || die "缺少 --output"
[ -f "$INPUT" ]  || die "源文件不存在：${INPUT}"

# 格式：优先 --format，其次看目标扩展名
if [ -z "$FORMAT" ]; then
  case "${OUTPUT##*.}" in
    mp3|MP3) FORMAT="mp3" ;;
    wav|WAV) FORMAT="wav" ;;
    *)       die "认不出目标格式（文件名要以 .mp3 或 .wav 结尾，或加 --format）" ;;
  esac
fi

mkdir -p "$(dirname "$OUTPUT")"
[ -f "$OUTPUT" ] && rm -f "$OUTPUT"

if [ "$FORMAT" = "wav" ]; then
  # 源本来就是 wav：直接复制，不做多余的转码（导出即原样）
  if [ "${INPUT##*.}" = "wav" ]; then
    cp "$INPUT" "$OUTPUT" || die "复制失败" 4
    echo "[export_audio] 已导出 WAV：$OUTPUT"
    exit 0
  fi
  FFMPEG="$(find_ffmpeg)"
  [ -n "$FFMPEG" ] || die "找不到 ffmpeg，无法转成 WAV" 3
  "$FFMPEG" -hide_banner -loglevel error -y -i "$INPUT" -c:a pcm_s16le "$OUTPUT" || die "转换失败" 4
  echo "[export_audio] 已导出 WAV：$OUTPUT"
  exit 0
fi

if [ "$FORMAT" = "mp3" ]; then
  FFMPEG="$(find_ffmpeg)"
  [ -n "$FFMPEG" ] || die "找不到 ffmpeg，无法导出 MP3（命令行的 ffmpeg 装在 /opt/homebrew/bin 时可以）" 3
  "$FFMPEG" -hide_banner -loglevel error -y -i "$INPUT" -c:a libmp3lame -b:a "$BITRATE" "$OUTPUT" || die "转换失败" 4
  echo "[export_audio] 已导出 MP3（${BITRATE}）：$OUTPUT"
  exit 0
fi

die "不支持的格式：${FORMAT}"
