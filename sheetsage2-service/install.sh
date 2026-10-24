#!/bin/bash
# Install the SheetSage2 semantic service as a macOS launchd background job.
#
# Copyright (c) 2026 Jie Da / Inspiration-Assistant
# SheetSage2 x YuE2 Integration - local, non-commercial research use only.
#
# Usage:
#   ./install.sh                 # needs an existing Python 3.11
#   ./install.sh --python /path/to/python3.11
#   ./install.sh --no-launch     # copy files only
#
# Run with full permissions: launchctl bootstrap fails under the agent sandbox
# with a bare "I/O error" (seen 2026-10-03, still true on 2026-10-24).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${SS2_BASE:-$HOME/inspiration-assistant}"
WORKSPACE="${SS2_WORKSPACE:-$HOME/Documents/deepseek-harness/default-workspace}"
YUE2_BIN="${SS2_YUE2_BIN:-$WORKSPACE/yue2-local/yue2}"
PLIST_LABEL="com.jieda.sheetsage2-service"
PLIST_SRC="$HERE/$PLIST_LABEL.plist.in"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
PYTHON=""
DO_LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --python) PYTHON="$2"; shift 2 ;;
    --no-launch) DO_LAUNCH=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PYTHON" ]; then
  for candidate in "$BASE/runtime/python/bin/python3.11" \
                   "$HOME/.local/share/uv/python"/*/bin/python3.11; do
    if [ -x "$candidate" ]; then PYTHON="$candidate"; break; fi
  done
fi
if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
  echo "No Python 3.11 found." >&2
  echo "Install one first, e.g.:" >&2
  echo "  UV_PYTHON_INSTALL_MIRROR=https://mirror.nju.edu.cn/github-release/astral-sh/python-build-standalone \\" >&2
  echo "  uv python install 3.11 --install-dir '$BASE/runtime/python'" >&2
  exit 1
fi

mkdir -p "$BASE/service" "$BASE/abc-cache" "$BASE/models/hf-cache" "$BASE/logs"
cp "$HERE/service.py" "$HERE/ss2core.py" "$BASE/service/"
chmod +x "$BASE/service/service.py"

# render the launchd plist
sed -e "s|__PYTHON__|$PYTHON|g" \
    -e "s|__BASE__|$BASE|g" \
    -e "s|__YUE2_BIN__|$YUE2_BIN|g" \
    "$PLIST_SRC" > "$PLIST_DST"

echo "installed service files -> $BASE/service"
echo "launchd plist         -> $PLIST_DST"
echo "python                -> $PYTHON"
echo "yue2 bin              -> $YUE2_BIN"

if [ "$DO_LAUNCH" -eq 1 ]; then
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
  sleep 1
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null; then
    # macOS often needs a moment after bootout before the label is reusable
    sleep 2
    if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"; then
      echo "" >&2
      echo "launchctl bootstrap failed (Input/output error)." >&2
      echo "Run: launchctl bootout gui/$(id -u)/$PLIST_LABEL ; sleep 1 ; launchctl bootstrap gui/$(id -u) $PLIST_DST" >&2
      echo "with full disk/launch permissions." >&2
      exit 1
    fi
  fi
  launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

  for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:8001/health" >/dev/null 2>&1; then
      echo ""
      curl -s "http://127.0.0.1:8001/health" | python3 -m json.tool | head -30
      exit 0
    fi
    sleep 0.25
  done
  echo "service did not answer /health within 30s; see $BASE/logs/" >&2
  exit 1
fi
