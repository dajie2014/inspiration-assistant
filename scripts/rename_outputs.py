#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给**已经生成好的**产物补一个看得懂的名字。

2026-10-11 之前，界面和脚本都不管文件名，落下来的就是上游起的 uuid
（`1d371fc1-4eb2-5a4c-4606-459e9a9102aa.wav`），在访达里认不出哪首是哪首。
**新的生成已经会自己命名了**（见 README「生成的东西叫什么名字」），
这个脚本是给**更早留下的那些**补名字 —— 一次性动作，但留着能重复跑。

它**只改名字，不动内容**；已经是人话的名字一律跳过，所以反复跑也没事。

名字从哪儿来（挨个试，第一个有结果的算）：
  1. 同一目录里 `params.json` 的 `title`
  2. 同上，`prompt` 的开头
  3. 同一目录里**已经起过名字的音频**（比如导出的 mp3）的文件名
  4. 都没有 → 跳过，并如实报告「这个名字没处可查」，不猜

命名规则本身**不在这里重写**，直接借用 `headless_generate.py` 的
`safe_file_stem` —— 规则只留一处，别再开一份。

用法：
    python3 scripts/rename_outputs.py             # 只报告要改什么（默认不改）
    python3 scripts/rename_outputs.py --apply     # 真改
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_DIR = HERE.parent
DEFAULT_OUTPUT = PROJECT_DIR / "output"

sys.path.insert(0, str(HERE))
from headless_generate import safe_file_stem          # noqa: E402  —— 命名规则只留一处

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
AUDIO_EXT = {".wav", ".mp3", ".flac", ".m4a", ".aif", ".aiff"}


def looks_like_uuid(stem: str) -> bool:
    """这名字是不是上游随手起的 uuid —— 只有这种才需要动。"""
    return bool(UUID_RE.match(stem))


def name_for(folder: Path) -> str | None:
    """这一目录里的东西该叫什么。查不到就返回 None，**不猜**。"""
    params = folder / "params.json"
    if params.exists():
        try:
            data = json.loads(params.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        raw = str(data.get("title") or "").strip() or str(data.get("prompt") or "").strip()
        if raw:
            return safe_file_stem(raw)

    # 没有参数文件（最早那几次是手工跑脚本，没留 params.json）：
    # 退一步，借用同目录里**已经起过名字的音频**（比如导出的 mp3）
    for item in sorted(folder.iterdir()):
        if item.suffix.lower() in AUDIO_EXT and not looks_like_uuid(item.stem):
            return safe_file_stem(item.stem)
    return None


def plan(folder: Path) -> tuple[list[tuple[Path, Path]], str]:
    """算出这一目录里要把哪些文件改成什么。返回 (改法, 备注)。"""
    try:
        entries = sorted(p for p in folder.iterdir() if p.is_file())
    except OSError as exc:
        return [], f"读不了：{exc}"

    wavs = [p for p in entries if p.suffix.lower() == ".wav"]
    targets = [p for p in wavs if looks_like_uuid(p.stem)]
    if not targets:
        return [], "名字已经是人话，不动"

    base = name_for(folder)
    if not base:
        return [], "**这个名字没处可查**（没有 params.json，也没有已命名的音频），跳过"

    taken = {p.name for p in entries if p not in targets}
    moves: list[tuple[Path, Path]] = []
    seq = 0
    for src in targets:
        seq += 1
        stem = base if seq == 1 else f"{base}-{seq}"
        while f"{stem}.wav" in taken:
            seq += 1
            stem = f"{base}-{seq}"
        taken.add(f"{stem}.wav")
        moves.append((src, folder / f"{stem}.wav"))
    return moves, ""


def apply_moves(moves: list[tuple[Path, Path]]) -> None:
    """改名，并把目录内 progress.json 里指向它的路径一起改掉。"""
    folder = moves[0][0].parent
    for src, dest in moves:
        src.replace(dest)

    progress = folder / "progress.json"
    if not progress.exists():
        return
    try:
        data = json.loads(progress.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    out = data.get("output")
    if not out:
        return
    old = Path(out).name
    for src, dest in moves:
        if src.name == old:
            data["output"] = str(dest)
            break
    else:
        return
    tmp = progress.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(progress)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT), help="产物根目录")
    ap.add_argument("--apply", action="store_true", help="真改（不加这个只报告）")
    args = ap.parse_args()

    root = Path(args.output).expanduser().resolve()
    if not root.is_dir():
        print(f"找不到目录：{root}", file=sys.stderr)
        return 2

    total = 0
    skipped: list[tuple[str, str]] = []

    for folder in sorted(p for p in root.iterdir() if p.is_dir()):
        moves, note = plan(folder)
        if note:
            if "没处可查" in note:
                skipped.append((folder.name, note))
            print(f"[{folder.name}] {note}")
            continue
        if not moves:
            continue
        for src, dest in moves:
            print(f"[{folder.name}] {src.name}  →  {dest.name}")
        total += len(moves)
        if args.apply:
            apply_moves(moves)

    print()
    if args.apply:
        print(f"改了 {total} 个文件。")
    else:
        print(f"有 {total} 个文件要改（**还没动** —— 加 --apply 才真改）。")

    if skipped:
        print("\n下面这些改不了，需要你告诉我叫什么（或者本来就不重要）：")
        for name, note in skipped:
            print(f"  · {name}：{note}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
