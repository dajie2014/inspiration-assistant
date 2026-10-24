#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一首草稿送进 ACE Studio —— **谱子进唱轨、音频进音频轨**。

**为什么单独成一个脚本**（2026-10-13 晚定）：
Composer Step 里那两个按钮（「谱子 → ACE」「音频 → ACE」）原来是写在 Swift 里的。
当天用户又要在 **Composer Assistant** 里也能送（「CA 里也能把材料送进 ACE」）——
两边各写一遍的话，今晚在 CS 里踩过的坑（返回值不可信、刚启动没就绪、伴奏变唱轨）
CA 那边**要再踩一遍**，而且以后两份必然漂移。
⇒ 逻辑只留这一份，两边都调它。CS 的 `ACEDraftTransfer.swift` 和 CA 的
`ACEDraftPush.swift` 都只是**薄壳**：拼参数、读结果、摆到界面上。

用法：
    push_to_ace.py --what score --title "示例作品" "<...>.xml"
    push_to_ace.py --what audio --title "示例作品" "<...>.flac"

输出（stdout，一行 JSON）：
    {"ok": true,  "message": "谱声部「Vocal Melody」→ 1 条唱轨（歌词与速度一起进去了）"}
    {"ok": false, "message": "…为什么没送成…"}

退出码：成 0 / 没成 1（**"什么都没做"也算没成** —— 见下面那条教训）。

─────────────────────────────────────────────────────────────
★ 这一整套行为都是 2026-10-13 拿真文件在 ACE 2.1.8 上量出来的，不是推的：

· `import file --path x.flac` → 一条音频轨，**秒回**（解码在后台继续）。
· `import file --path x.xml`  → 每条源轨道一个 clip。
· ⚠️ **导到默认的 MIDI 轨上，歌词会丢**：实测 238 个音符一个不少，
  但 `clip lyrics` 一个字都读不出来（它明说"只对 Sing clip 有效"）。
· ✅ **指定一条 Sing 轨当落点，歌词就在**：实测报 **30 句**，
  第一句正是谱面上的「示例歌名刚好挡住烫人的太阳」，一字不差。
  ⇒ 机制是 ACE 自己的规矩：`import file` 把**点名的那条轨**当"转换模板"。
· `--with-tempo` / `--with-time-signatures` **要显式给** —— 帮助原文写明
  "项目文件默认**不**采纳源的速度与拍号"；给了之后 `tempo get` 回 **143** ✓。

★ **送什么、不送什么**（用户当天定的两条，别自作主张）：
  ① **人声进唱轨**（带歌词与速度）；② **草稿的音频进音频轨**。
  **谱子里的伴奏声部一律不送** —— 他的原话：「谱伴奏别管，我自己演奏或者写入」。

★ **三个坑，都在这儿兜住了**：
  ① **返回值不能信**：点名 Sing 轨那一次，返回里 `clipCount: 0`、`clips: []`，
     可 `track list` 明明多了轨 ⇒ 判断落没落下一律**回读 `track list`**。
  ② **ACE 刚被拉起来那几秒导入会失败**（`TrackGraphicsScene is not available`）——
     `project info` 已经通了、画面场景还没建好 ⇒ **失败等 4 秒重试一次**。
  ③ **拆声部**（`split_score_parts.py`）：整份谱导进 Sing 轨会把**伴奏也变成唱轨**
     （ACE 只按落点类型定）。实测两条都成了 Sing、伴奏那条只能唱「啦」。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

CLI = "/Applications/ACE Studio.app/Contents/Helpers/acestudio-cli"
APP = "/Applications/ACE Studio.app"
HERE = os.path.dirname(os.path.abspath(__file__))
SPLITTER = os.path.join(HERE, "split_score_parts.py")

MUSICXML_EXTS = {".xml", ".musicxml", ".mxl"}


def run_tool(executable, arguments, timeout=90):
    """跑一个命令，收它的输出。超时就杀掉（先 TERM，再 KILL）。

    返回 (退出码, stdout 文本)。命令跑不起来时退出码给 -1。
    """
    try:
        done = subprocess.run([executable] + arguments,
                              capture_output=True, text=True, timeout=timeout)
        return done.returncode, (done.stdout or "") + (done.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, f"命令超过 {timeout} 秒还没回：{os.path.basename(executable)}"
    except OSError as error:
        return -1, str(error)


def run_cli(arguments, timeout=90):
    return run_tool(CLI, arguments, timeout=timeout)


def as_json(text):
    """CLI 的输出解成 dict；解不出来返回 None（不抛错 —— 调用方要的是"成没成"）。"""
    try:
        got = json.loads(text)
    except Exception:
        return None
    return got if isinstance(got, dict) else None


def cli_reason(text):
    """CLI 报错时把最有用的一句挑出来（它把原因写在 JSON 的 error.message 里）。"""
    got = as_json(text)
    if got and isinstance(got.get("error"), dict):
        return got["error"].get("message") or "（ACE 没给原因）"
    stripped = (text or "").strip()
    return stripped[-200:] if stripped else "（ACE 没给原因）"


def ace_is_online():
    """`project info --json` 读得通**而且**解得出工程名 ＝ 桥通着。"""
    code, text = run_cli(["project", "info", "--json"], timeout=8)
    if code != 0:
        return False
    got = as_json(text)
    return bool(got and "projectName" in got)


def ensure_online():
    """ACE 不在就把它叫起来、等它就绪。返回 None ＝ 通了，否则返回一句人话。

    为什么自己开：用户已经授权过"需要 ACE 开着时自己开下来"。
    他点「送进 ACE」的意思本来就是"我现在要用 ACE"。
    """
    if ace_is_online():
        return None
    if not os.path.isdir(APP):
        return "ACE Studio 没开着，而且这台机器上找不到它。"
    subprocess.run(["open", "-a", APP], check=False)

    # 冷启动实测几秒能连上；给足 45 秒，别再让人点第二次。
    deadline = time.time() + 45
    while time.time() < deadline:
        time.sleep(1.5)
        if ace_is_online():
            return None
    return ("ACE Studio 打开了，但一直没连上（等了 45 秒）。"
            "到 ACE 的「Connect to Agents」里确认一下外部访问是开着的。")


def track_uuids():
    """工程里现有的轨 uuid 集合 —— 用来算"这一趟新加了哪几条"。"""
    code, text = run_cli(["track", "list", "--json"], timeout=15)
    got = as_json(text)
    if code != 0 or not got:
        return set()
    return {t.get("trackUuid") for t in got.get("tracks", []) if t.get("trackUuid")}


def import_with_retry(arguments, attempts=3, pause=5):
    """导一次；没成就**等一会儿再来**，最多试 3 次。

    为什么要重试：**ACE 刚起来（或刚 `project new`）那几秒，`project info`
    已经能通了，但画面场景还没建好**，导入回 `TrackGraphicsScene is not available`。
    实测就是这么撞上的 —— 而再等几秒它自己就好了。
    不能把它当成"送不进去"报给用户：那不是他的操作有问题，是 ACE 在路上。

    ⚠️ 2026-10-13 实测：只重试一次（等 4 秒）**不够** —— `project new` 之后
    紧接着导，两次都撞上同一句。改成 3 次 × 5 秒（最多多等 10 秒）才稳。
    """
    code, text = run_cli(arguments, timeout=90)
    left = attempts - 1
    while code != 0 and left > 0:
        time.sleep(pause)
        code, text = run_cli(arguments, timeout=90)
        left -= 1
    return code, text


def shorten(title):
    """轨名里带的曲名截短 —— ACE 的轨名横着排，太长会被吃掉后半截。"""
    name = (title or "").strip() or "Composer Step 草稿"
    return name if len(name) <= 16 else name[:16] + "…"


def split_parts(score_path):
    """→ ((唱声部的路径, 声部名), 临时目录)；拆不出来返回 (None, "")。

    ⚠️ 临时目录**开在系统临时区**，不落在作品旁边 —— 落在他 `output/` 里的东西，
    他会当成自己的文件（2026-10-13 定）。
    """
    if not os.path.isfile(SPLITTER):
        return None, ""
    scratch = tempfile.mkdtemp(prefix="ace-split-")
    code, text = run_tool("/usr/bin/python3", [SPLITTER, score_path, scratch], timeout=30)
    if code != 0:
        return None, ""
    try:
        got = json.loads(text.strip().splitlines()[-1])
    except Exception:
        return None, ""
    vocal = got.get("vocal") or None
    return (vocal, got.get("vocalName") or ""), scratch


def push_score(path, title):
    """谱子 → 唱轨。返回 (ok, message, 拆出来的临时目录)。"""
    if not os.path.isfile(path):
        return False, f"找不到那一份谱子：{os.path.basename(path)}", None
    if os.path.splitext(path)[1].lower() not in MUSICXML_EXTS:
        return (False, f"ACE 只认 MusicXML 的谱子，这一份是 .{os.path.splitext(path)[1].lstrip('.')}。"
                       "先在「文件」菜单里把它转成 MusicXML。", None)

    parts, scratch = split_parts(path)
    if not parts or not parts[0]:
        return False, "没能读出那份谱子的声部，先不送了（免得把伴奏当成唱轨送进去）。", scratch
    vocal, vocal_name = parts
    stem = shorten(title)
    label = vocal_name or "唱"

    before = track_uuids()
    code, text = run_cli(["track", "create", "--type", "sing",
                          "--name", f"{stem} · {label}", "--json"], timeout=15)
    got = as_json(text)
    if code != 0 or not got or "trackIndex" not in got:
        return False, f"在 ACE 里建唱轨失败：{cli_reason(text)}", scratch
    template_index = got["trackIndex"]

    code, text = import_with_retry(["import", "file",
                                    "--path", vocal,
                                    "--track-index", str(template_index),
                                    "--with-tempo", "true",
                                    "--with-time-signatures", "true",
                                    "--json"])
    if code != 0:
        return False, f"ACE 没能读进唱的那一声部：{cli_reason(text)}", scratch

    # 回读核对（返回值里那个 clipCount 是 0，不能信）
    fresh = track_uuids() - before
    if not fresh:
        return False, "唱的那一声部导进去之后，ACE 里没多出轨道，像是没落下来。", scratch
    return True, f"唱声部「{label}」→ {len(fresh)} 条唱轨（歌词与速度一起进去了）", scratch


def push_audio(path):
    """音频 → 音频轨。送完顺手读一下 ACE 自己测的速度（clip 尾部那个 BPM）。"""
    if not os.path.isfile(path):
        return False, f"找不到那一份音频：{os.path.basename(path)}"
    code, text = import_with_retry(["import", "file", "--path", path, "--json"])
    if code != 0:
        return False, f"ACE 没能读进那份音频：{cli_reason(text)}"

    # ★ 2026-10-18 用户提醒：音频进了 ACE，**尾部会显示 BPM**（ACE 自己分析的）。
    #   对应的数据是 `clip beat-content` —— 随 clip 存进工程，读一下就有。
    #   读不到不算失败：只是少报一个数。
    note = ""
    got = as_json(text) or {}
    ti = got.get("trackIndex")
    ci = got.get("clipIndex", 0)
    # ⚠️ 实测：`import file --json` 返回的是**一个对象**（带 trackIndex，
    #   没有 clips 数组）；新导入落新轨时 clipIndex 是 0。
    if isinstance(ti, int):
        # ⚠️ 刚导进去时 `loadingState` 还是 not_loaded，节拍分析要过几秒才有。
        #   实测：导入后**立刻**读会报"还没分析"，等两秒就出来了。
        for _ in range(5):
            c2, t2 = run_cli(["clip", "beat-content",
                              "--track-index", str(ti),
                              "--clip-index", str(ci if isinstance(ci, int) else 0)],
                             timeout=30)
            match = re.search(r"([\d.]+)\s*BPM", t2 or "")
            if c2 == 0 and match:
                note = "；ACE 测出速度 %s BPM" % match.group(1)
                break
            time.sleep(2)
    return True, f"音频 {os.path.basename(path)} → 1 条音频轨{note}"


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--what", required=True, choices=["score", "audio"])
    parser.add_argument("--title", default="")
    parser.add_argument("path")
    args = parser.parse_args()

    # ★ **一律换成绝对路径**（2026-10-13 实测踩到）：ACE 的 CLI 拿到相对路径时，
    #   是按**它自己的当前目录**解析的，不是按调用方的 —— 于是回
    #   `No file at 'output/…/x.flac'`，而那个文件明明就在那儿。
    args.path = os.path.abspath(os.path.expanduser(args.path))

    if not os.path.isfile(CLI):
        print(json.dumps({"ok": False,
                          "message": "找不到 ACE Studio 的命令行工具。ACE Studio 装了吗？"},
                         ensure_ascii=False))
        return 1

    reason = ensure_online()
    if reason:
        print(json.dumps({"ok": False, "message": reason}, ensure_ascii=False))
        return 1

    scratch = None
    try:
        if args.what == "score":
            ok, message, scratch = push_score(args.path, args.title)
        else:
            ok, message = push_audio(args.path)
    finally:
        # 拆出来的那两份是临时的 —— 内容已经被 ACE 读进工程里了
        if scratch and os.path.isdir(scratch):
            shutil.rmtree(scratch, ignore_errors=True)

    print(json.dumps({"ok": ok, "message": message}, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
