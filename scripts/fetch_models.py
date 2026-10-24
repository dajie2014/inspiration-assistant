#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 ModelScope 并行拉取 ACE-Step 1.5 权重。

为什么要自己拉：官方下载器（acestep.model_downloader）单线程，实测约 1.6 MB/s；
ModelScope 直链实测约 10 MB/s。10 GB 权重因此从「近两小时」缩到「十几分钟」。

特性：
  * 多文件并行（默认 6 路）
  * 断点续传（复用官方下载器留下的 ._____temp 半成品）
  * 下完校验字节数，尺寸不符会重试
  * 只读 ModelScope（不碰 HuggingFace，国内直连不通）

用法：
    HOME=<项目>_home python3 fetch_models.py [--dest <checkpoints 目录>] [--jobs 6]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

REPO = "ACE-Step/Ace-Step1.5"
URL_TMPL = "https://www.modelscope.cn/models/{repo}/resolve/master/{path}"
TEMP_DIRNAME = "._____temp"          # 与官方下载器共用，便于续传

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent            # my-songwriter/
DEFAULT_DEST = PROJECT_ROOT / "backend" / "ACE-Step-1.5" / "checkpoints"


def ensure_writable_home() -> None:
    """ModelScope 会往里写 ~/.modelscope，沙箱下不可写；把 HOME 指到项目内。"""
    home = Path(os.environ.get("HOME", ""))
    try:
        probe = home / ".modelscope"
        probe.mkdir(parents=True, exist_ok=True)
        return
    except OSError:
        pass
    fallback = PROJECT_ROOT / "_home"
    fallback.mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(fallback)
    os.environ.setdefault("MODELSCOPE_CACHE", str(PROJECT_ROOT / "_cache" / "modelscope"))
    print(f"[home] HOME 不可写，改用 {fallback}", flush=True)


def list_files() -> list[tuple[str, int]]:
    from modelscope.hub.api import HubApi

    api = HubApi()
    rows = []
    for f in api.get_model_files(REPO, recursive=True):
        if (f.get("Type") or f.get("type")) == "tree":
            continue
        path = f.get("Path") or f.get("path")
        size = int(f.get("Size") or f.get("size") or 0)
        if path:
            rows.append((path, size))
    return rows


def download_one(path: str, size: int, dest_root: Path, jobs_note: str = "") -> tuple[str, bool, str]:
    final = dest_root / path
    tmp = dest_root / TEMP_DIRNAME / path
    final.parent.mkdir(parents=True, exist_ok=True)
    tmp.parent.mkdir(parents=True, exist_ok=True)

    if final.exists() and size and final.stat().st_size == size:
        return path, True, "已存在"

    url = URL_TMPL.format(repo=REPO, path=urllib.parse.quote(path))
    target = tmp if tmp.exists() or True else final

    cmd = [
        "curl", "-L", "--fail", "--retry", "5", "--retry-delay", "3",
        "--connect-timeout", "20", "-C", "-", "-o", str(target), url,
    ]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as exc:
        tail = (exc.stderr or b"").decode("utf-8", "replace").strip().splitlines()[-1:]
        return path, False, f"curl 失败: {tail}"

    got = target.stat().st_size if target.exists() else 0
    if size and got != size:
        return path, False, f"大小不符 期望 {size} 实际 {got}"

    shutil.move(str(target), str(final))
    return path, True, f"{got / 1e6:.0f} MB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default=str(DEFAULT_DEST))
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()

    ensure_writable_home()
    dest_root = Path(args.dest)
    dest_root.mkdir(parents=True, exist_ok=True)

    print(f"[1/2] 列出仓库文件：{REPO}", flush=True)
    files = list_files()
    total = sum(s for _, s in files)
    print(f"      {len(files)} 个文件，合计 {total / 1e9:.2f} GB", flush=True)

    print(f"[2/2] 并行下载（{args.jobs} 路）-> {dest_root}", flush=True)
    ok = True
    done_bytes = 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = {pool.submit(download_one, p, s, dest_root): (p, s) for p, s in files}
        for fut in cf.as_completed(futs):
            path, size = futs[fut]
            p, good, note = fut.result()
            done_bytes += size
            flag = "OK  " if good else "FAIL"
            print(f"  [{flag}] {p}  {note}   (累计 {done_bytes / 1e9:.2f}/{total / 1e9:.2f} GB)", flush=True)
            ok = ok and good

    # 清理临时目录（官方下载器也会用它）
    tmp_root = dest_root / TEMP_DIRNAME
    if tmp_root.exists() and not any(tmp_root.rglob("*")):
        tmp_root.rmdir()

    print("完成" if ok else "有文件失败，可重跑本脚本（会续传）", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
