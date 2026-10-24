#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ACE-Step 1.5 无头推理入口（GUI / render_adapter.sh 调用）。

官方只给了交互式向导（cli.py）和一个常驻 REST 服务（api_server.py）；
本脚本是第三种用法：读一个 JSON 参数文件 → 跑一次推理 → 写 wav → 退出。
每次跑完进程就结束，模型内存随之释放（规格书 Job 2 第 6 条）。

它不含任何创作逻辑：prompt、歌词、BPM、调号全部来自调用方传进来的 JSON。
默认不加载语言模型（thinking=False），因此不会自动编造歌词或音乐构思。

用法：
    python headless_generate.py --params <params.json> --out-dir <目录> --progress <progress.json>
"""
from __future__ import annotations

import argparse
import gc
import json
import os
import sys
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_DIR = HERE.parent                       # my-songwriter（项目根）
PROJECT_ROOT = PROJECT_DIR / "backend" / "ACE-Step-1.5"

STATE_IDLE = "idle"
STATE_RUNNING = "running"
STATE_DONE = "done"
STATE_FAILED = "failed"


def atomic_write_json(path: Path, payload: dict) -> None:
    """先写临时文件再改名 —— GUI 永远读不到写了一半的 JSON。"""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


class ProgressWriter:
    """把推理管线报出来的进度落成 progress.json。

    百分比只增不减（多线程回调会乱序），并记录最近一次的文字说明。

    两个文字字段分工（2026-10-13 加 `detail`）：
      · `message` —— **现在在干什么**（界面用大字显示）
      · `detail`  —— **大概要等多久、为什么慢**（界面用小字接在后面）
    光说"正在加载"没用：等的人想知道的是"这一步要多久"，所以慢的那几步
    必须配一句人话。
    """

    def __init__(self, path: Path, total_floor: float = 3.0, total_ceil: float = 99.0):
        self.path = path
        self.floor = total_floor
        self.ceil = total_ceil
        self._percent = 0.0
        self._message = ""
        self._detail = ""
        self._state = STATE_RUNNING
        self._extra: dict = {}
        self.write()

    def write(self, **extra) -> None:
        payload = {
            "percent": int(round(self._percent)),
            "state": self._state,
            "message": self._message,
            "detail": self._detail,
            "updated": int(time.time()),
        }
        payload.update(self._extra)
        payload.update(extra)
        atomic_write_json(self.path, payload)

    def set(self, fraction: float | None = None, message: str | None = None,
            detail: str | None = None, **extra) -> None:
        if fraction is not None:
            try:
                pct = float(fraction)
            except (TypeError, ValueError):
                pct = None
            if pct is not None:
                if pct <= 1.0001:          # 管线里两种量纲都出现过：0.52 与 52
                    pct *= 100.0
                pct = max(self.floor, min(self.ceil, pct))
                self._percent = max(self._percent, pct)   # 只增不减
        if message:
            self._message = str(message)
        # detail 传 None = 沿用上一步那句（上游回调很密，不必每条都重说）；
        # 传 "" = 这句补充说明到此为止。
        if detail is not None:
            self._detail = str(detail)
        if extra:
            self._extra.update(extra)
        self.write()

    def finish(self, output: str | None = None, message: str = "出好了",
               detail: str | None = None) -> None:
        self._percent = 100.0
        self._message = message
        if detail is not None:
            self._detail = detail
        self._state = STATE_DONE
        self.write(output=output)

    def fail(self, message: str) -> None:
        self._message = message
        self._detail = ""                 # 出错时别留着上一步那句"再等等"
        self._state = STATE_FAILED
        self.write()


def stage_words(fraction: float | None) -> tuple[str, str]:
    """把上游那个百分比翻译成「一句人话 + 一句补充」。

    上游的 desc 是写给开发看的英文（`Preparing inputs...` /
    `Generating music (batch size: 1)...` / `Decoding audio...`），
    原样摆到界面上，用户只能看到一行看不懂的字 —— 那还不如不显示。
    所以这里压根不看 desc，只按它报的进度区间说话（2026-10-13）。
    """
    if fraction is None:
        return "正在生成…", ""
    try:
        f = float(fraction)
    except (TypeError, ValueError):
        return "正在生成…", ""
    if f <= 1.0001:                      # 0.52 与 52 两种量纲都出现过
        f *= 100.0
    if f < 51.5:
        return "先把手上的材料理一遍…", "马上进正题"
    if f < 80:
        return "正在一段一段地写…", "这一步最花时间，占整个流程的大头"
    if f < 98:
        return "把写好的变成声音…", "到这儿才开始有响动"
    return "快好了，正在收尾…", ""


def build_params(p: dict):
    """把 GUI 的 JSON 映射成 ACE-Step 的 GenerationParams。"""
    from acestep.inference import GenerationParams

    mode = (p.get("mode") or "generate").lower()
    ref_audio = (p.get("ref_audio") or "").strip() or None
    src_audio = (p.get("src_audio") or "").strip() or None

    task_type = "text2music"
    if mode == "repaint":
        task_type = "repaint"
    # reference 模式走 text2music + 参考音频（官方建议：丰富织体用参考音频 + Generate）

    thinking = bool(p.get("thinking", False))
    kwargs = dict(
        task_type=task_type,
        caption=(p.get("prompt") or "").strip(),
        lyrics=(p.get("lyrics") or "").strip() or "[Instrumental]",
        instrumental=not (p.get("lyrics") or "").strip(),
        bpm=int(p["bpm"]) if p.get("bpm") else None,
        keyscale=(p.get("keyscale") or "").strip(),
        timesignature=(p.get("timesignature") or "").strip(),
        vocal_language=(p.get("language") or "unknown").strip() or "unknown",
        duration=float(p.get("duration") or 60),
        inference_steps=int(p.get("steps") or 8),
        guidance_scale=float(p.get("guidance_scale") or 1.0),
        seed=int(p.get("seed", -1)),
        reference_audio=ref_audio,
        src_audio=src_audio,
        repainting_start=int(p.get("repaint_start") or 0),
        repainting_end=int(p.get("repaint_end") or -1),
        audio_cover_strength=float(p.get("cover_strength", 0.5)),
        # 不让语言模型自作主张补内容（规格书硬要求）；用户想要时可显式打开
        thinking=thinking,
        use_cot_metas=thinking,
        use_cot_caption=thinking,
        use_cot_language=thinking,
    )
    # 只保留 dataclass 认得的字段，避免上游版本差异导致 TypeError
    names = set(GenerationParams.__dataclass_fields__.keys())
    kwargs = {k: v for k, v in kwargs.items() if k in names}
    return GenerationParams(**kwargs), task_type, mode


def safe_file_stem(raw: str, max_length: int = 40) -> str:
    """把一段文字变成能当文件名用的样子。

    ⚠️ **和界面那边是一套规则**（`gui/Sources/LocalMusic/FileName.swift` 里的
    ``FileName.safe``）—— 目录名由界面起、wav 名由这里起，两边都得会这一手。
    **改一处就要改另一处**，改完跑 `gui/check-naming.sh`（它把两边焊在一起）。

    规则：斜杠 / 冒号 / 反斜杠 → 下划线；换行制表 → 空格；连续空格并成一个；
    去掉首尾空白和末尾的点；超长截断（英文尽量退到词边界）；空的叫「未命名」。
    """
    chars = []
    for ch in raw:
        if ch in "/:\\":
            chars.append("_")
        elif ch in "\n\r\t":
            chars.append(" ")
        else:
            chars.append(ch)
    text = "".join(chars)
    while "  " in text:
        text = text.replace("  ", " ")

    def trim(value: str) -> str:
        out = value.strip()
        while out.endswith("."):
            out = out[:-1].strip()
        return out

    text = trim(text)
    if len(text) > max_length:
        text = trim(truncate(text, max_length))
    return text or "未命名"


def truncate(text: str, max_length: int) -> str:
    """截到 max_length 字。

    ★ 英文长标题**别切在半截词上**：硬截会切出
    「Contemporary chamber music for string qu」这种，看着像写坏了。
    所以退到最后一个空格 —— 但**退太多就得不偿失**（至少保住一半），
    中文没有空格、退不动，那就原样截。

    ★ 反过来的一个坑（2026-10-11 自己踩的）：**正好切在词尾时不该退**。
    原先不判这一下，「Slow-building orchestral post-minimalism extra」
    会把已经完整拿到的 `post-minimalism` 又丢回去。
    """
    if len(text) <= max_length:
        return text
    if text[max_length] == " ":          # 下一个字符就是空格 = 正好切在词尾
        return text[:max_length]
    cut = text[:max_length]
    head, sep, _ = cut.rpartition(" ")
    if sep and len(head) >= max_length // 2:
        return head
    return cut


def rename_readable(wav_path: str, out_dir: Path, payload: dict) -> str:
    """把上游起的 UUID 文件名换成看得懂的名字。

    上游的 ``generate_music`` 用 uuid 给产物命名（``5c81fffe-….wav``），
    在访达里认不出是哪首 —— 2026-10-11 用户提的。

    名字优先取参数里的 ``title``（界面按「歌词首行 → 风格描述」算好写进来的），
    没有就用风格描述顶上。**绝不覆盖已有文件**：撞名就退成「名字-2」「名字-3」。
    改名失败也不算这趟白跑 —— 保留原文件名，照常写进度。
    """
    if not wav_path:
        return wav_path
    src = Path(wav_path)
    if not src.exists():
        return wav_path

    raw = str(payload.get("title") or "").strip() or str(payload.get("prompt") or "").strip()
    stem = safe_file_stem(raw)
    suffix = src.suffix or ".wav"

    dest = out_dir / f"{stem}{suffix}"
    seq = 2
    while dest.exists() and dest.resolve() != src.resolve():
        dest = out_dir / f"{stem}-{seq}{suffix}"
        seq += 1
    if dest.resolve() == src.resolve():
        return str(src)

    try:
        src.replace(dest)
    except OSError as exc:                     # noqa: BLE001
        print(f"[headless] 改名失败，保留原文件名：{exc}", flush=True)
        return str(src)
    print(f"[headless] 改名: {src.name} → {dest.name}", flush=True)
    return str(dest)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", required=True, help="JSON 参数文件")
    ap.add_argument("--out-dir", required=True, help="wav 输出目录")
    ap.add_argument("--progress", required=True, help="progress.json 路径")
    args = ap.parse_args()

    # 断网：推理只用本机权重，任何外连都是错误
    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        os.environ.pop(key, None)
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    # 各种缓存一律落到项目内：既不污染用户主目录，也避免受限环境下写不进去
    # （transformers 会往 ~/.cache/huggingface/modules 写动态模块，写不了就直接加载失败）
    for var, sub in (
        ("HF_HOME", "huggingface"),
        ("HF_MODULES_CACHE", "huggingface/modules"),
        ("MPLCONFIGDIR", "matplotlib"),
        ("TORCH_HOME", "torch"),
    ):
        target = PROJECT_DIR / "_cache" / sub
        target.mkdir(parents=True, exist_ok=True)
        os.environ.setdefault(var, str(target))

    # 先把三个路径都解析成绝对路径 —— 下面会 chdir 到后端目录，
    # 相对路径在那之后就全飘了（2026-10-11 实际踩到：wav 落进了后端目录）。
    params_path = Path(args.params).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()
    progress = ProgressWriter(Path(args.progress).expanduser().resolve())

    if not PROJECT_ROOT.exists():
        progress.fail(f"找不到后端目录：{PROJECT_ROOT}")
        return 2

    sys.path.insert(0, str(PROJECT_ROOT))
    os.chdir(PROJECT_ROOT)          # 上游按相对路径找 checkpoints/
    out_dir.mkdir(parents=True, exist_ok=True)

    dit_handler = llm_handler = None
    try:
        payload = json.loads(params_path.read_text(encoding="utf-8"))
        gen_params, task_type, mode = build_params(payload)
        progress.set(2, "正在准备…", detail="几秒钟的事")

        from acestep.handler import AceStepHandler
        from acestep.inference import GenerationConfig, generate_music

        model_name = payload.get("model") or "acestep-v15-turbo"
        progress.set(5, "正在启动作曲的 AI…",
                     detail="整个流程里最慢的一步，通常要等一两分钟")
        dit_handler = AceStepHandler()
        status, ok = dit_handler.initialize_service(
            project_root=str(PROJECT_ROOT),
            config_path=model_name,
            device="auto",
            offload_to_cpu=False,
        )
        if not ok:
            progress.fail(f"作曲的 AI 起不来：{status}")
            return 3
        progress.set(20, "AI 已经就位", detail="接着就开工")

        if gen_params.thinking:
            from acestep.llm_inference import LLMHandler

            progress.set(22, "再装一个写词用的 AI…", detail="这一步也要读一会儿")
            llm_handler = LLMHandler()
            status, ok = llm_handler.initialize(
                checkpoint_dir=str(PROJECT_ROOT / "checkpoints"),
                lm_model_path=payload.get("lm_model") or "acestep-5Hz-lm-1.7B",
                backend=os.environ.get("ACESTEP_LM_BACKEND", "mlx"),
                device="auto",
                offload_to_cpu=False,
                dtype=None,
            )
            if not ok:
                progress.fail(f"写词的那个 AI 起不来：{status}")
                return 4
            progress.set(28, "都装好了，马上开始", detail="")

        config = GenerationConfig(
            batch_size=int(payload.get("batch_size") or 1),
            audio_format="wav",
        )

        def on_progress(fraction=None, desc=None, **kwargs):
            # 上游的 desc 是英文、而且全是术语（那就是用户嫌的"看不懂"）。
            # 这里**不用它**，改成按百分比区间说的人话 —— 见 stage_words。
            message, note = stage_words(fraction)
            progress.set(fraction, message, detail=note)

        progress.set(30, "开始动笔了…", detail="按你给的风格和词来写")
        result = generate_music(
            dit_handler,
            llm_handler,
            params=gen_params,
            config=config,
            save_dir=str(out_dir),
            progress=on_progress,
        )

        if not getattr(result, "success", False):
            progress.fail(getattr(result, "status_message", None) or "这一趟没生成出来")
            return 5

        audios = getattr(result, "audios", None) or []
        wav_path = ""
        if audios:
            first = audios[0]
            wav_path = first.get("path", "") if isinstance(first, dict) else str(first)
        wav_path = rename_readable(wav_path, out_dir, payload)
        progress.finish(output=wav_path, message="出好了",
                        detail="音频就在这次新建的那个文件夹里")
        print(f"[headless] 输出: {wav_path}", flush=True)
        return 0

    except Exception as exc:                       # noqa: BLE001  — 任何异常都要落进 progress.json
        detail = f"{type(exc).__name__}: {exc}"
        progress.fail(detail)
        traceback.print_exc()
        return 1
    finally:
        # 量一下这次到底吃了多少内存 —— 时长越长这块越要紧，
        # 有个真实数字才知道能开多长，不用靠猜。（macOS 上 ru_maxrss 单位是字节）
        try:
            import resource

            peak_gb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9
            print(f"[headless] 本次峰值内存 {peak_gb:.2f} GB", flush=True)
        except Exception:                          # noqa: BLE001
            pass

        # 显式放掉模型，让内存尽快回到系统（进程随后退出，双保险）
        for attr in ("dit_handler", "llm_handler"):
            obj = locals().get(attr)
            if obj is not None:
                try:
                    del obj
                except Exception:                  # noqa: BLE001
                    pass
        gc.collect()
        try:
            import torch

            if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
                torch.mps.empty_cache()
        except Exception:                          # noqa: BLE001
            pass


if __name__ == "__main__":
    sys.exit(main())
