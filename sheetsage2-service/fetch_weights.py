#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fetch the official SheetSage2 + MERT-v2-FullSong weights (lazy Flow-C only).

Copyright (c) 2026 Jie Da / Inspiration-Assistant
SheetSage2 x YuE2 Integration - local, non-commercial research use only.
Weights: CC BY-NC 4.0 (m-a-p). Files are written to local disk only; nothing
is uploaded anywhere.

Downloads the *pinned* revisions that mlx-Yue verifies:
  m-a-p/SheetSage2        eab522a8168e8b8b8c4856bf8609cd86198f01fe
  m-a-p/MERT-v2-FullSong  d8ba1c745e733b3908ce6ad16ebeb17ac7600a42

Usage:
  HF_ENDPOINT=https://hf-mirror.com \\
    ~/Documents/.../yue2-local/mlx-Yue/.venv/bin/python fetch_weights.py \\
    --cache-dir ~/inspiration-assistant/models/hf-cache
"""
import argparse
import json
import os
import sys
from pathlib import Path

PINS = [
    ("m-a-p/SheetSage2", "eab522a8168e8b8b8c4856bf8609cd86198f01fe"),
    ("m-a-p/MERT-v2-FullSong", "d8ba1c745e733b3908ce6ad16ebeb17ac7600a42"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", default=str(Path.home() / "inspiration-assistant/models/hf-cache"))
    parser.add_argument("--offline-check", action="store_true",
                        help="only verify that both snapshots are present")
    args = parser.parse_args()
    cache = Path(args.cache_dir).expanduser()
    cache.mkdir(parents=True, exist_ok=True)

    from huggingface_hub import snapshot_download

    report = {}
    for repo, revision in PINS:
        if args.offline_check:
            local = cache / ("models--" + repo.replace("/", "--"))
            ok = any(p.is_dir() and (p / "model.safetensors").exists()
                     for p in local.glob("snapshots/*"))
            report[repo] = {"present": ok, "revision": revision}
            continue
        print("[fetch] %s @ %s" % (repo, revision[:12]), flush=True)
        path = snapshot_download(
            repo, revision=revision, cache_dir=str(cache),
            allow_patterns=["config.json", "model.safetensors"],
            resume_download=True,
        )
        size = os.path.getsize(Path(path) / "model.safetensors")
        report[repo] = {"path": path, "revision": revision,
                        "model_safetensors_bytes": size,
                        "model_safetensors_gb": round(size / 1e9, 2)}
        print("[ok] %s -> %s (%.2f GB)" % (repo, path, size / 1e9), flush=True)

    print(json.dumps(report, indent=2), flush=True)
    if args.offline_check and not all(v["present"] for v in report.values()):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
