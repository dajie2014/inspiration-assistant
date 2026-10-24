#!/usr/bin/env python3
"""内存看门狗 —— 盯着一条进程树，越线就把它按下去。

为什么要有它
------------
ACE-Step 生成时实测：进程峰值 14.84 GB，整机空闲内存一度掉到 0，
MLX 还会把统一内存锁住（wired 涨到 17 GB，那部分不可回收）。
**那时候如果还有别的东西要内存，系统就会开始拿硬盘当内存用** ——
而 Mac 一旦开始 swap，整机会卡到你以为死机了。这就是「跑大模型把电脑跑崩」
的典型路径。

ACE-Step 那条路原先只有一道**时间**护栏（超时才杀），**没有内存的**。
这道补上，做法照 YuE2 的：它自带一个 16 GiB 预算 + 实时采样，
见 `yue2-local/mlx-Yue/src/lyra/measure.py` 的 `_check_sample`。

判据（四条，与 YuE2 同一套思路；阈值按本机实测定）
--------------------------------------------------
  1. 进程树占用 > `--budget-gib`
  2. 系统内存压力等级 != 1（macOS 自己的判断，1 = 正常）
  3. 系统可用内存 < `--min-available-gib`
  4. 新增 swap 换出 > `--max-swap-out-mib`，或 swap 用量增长 > `--max-swap-growth-mib`

**任何一条踩到，立刻杀掉整条进程树**，并留下一行说清是哪条踩的。
宁可这一趟白跑，也不把机器拖下去 —— 这是这个脚本存在的全部理由。

用法
----
    memory_guard.py --pid <pid>                # 盯着这条进程树，越线就杀
    memory_guard.py --pid <pid> --observe      # 只看不杀（量基线用）
    memory_guard.py --pid <pid> --log a.jsonl  # 顺便把采样明细写下来

退出码：0 = 被盯的进程自己结束了（正常）；3 = 越线，已按下
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time

try:
    import psutil
except ImportError:                                   # pragma: no cover
    sys.stderr.write("[memory_guard] 需要 psutil（ACE-Step 的内嵌 Python 自带）\n")
    raise SystemExit(7)

GIB = 1024 ** 3
MIB = 1024 ** 2
SYSCTL = "/usr/sbin/sysctl"

# ★ 2026-10-16 按**两条完整实测曲线**重新校准过，别删这段：
#
#   | 那一趟（都是带唱的） | 进程树峰值 | 可用最低 | swap 涨了 | 压力到过 |
#   |---|---|---|---|---|
#   | 30 秒              | 11.8 GB | 16.7 GB | 0      | 1 |
#   | 60 秒              | 11.3 GB |  9.9 GB | 1.0 GB | 2 |
#   | 180 秒             |  8.6 GB |  3.5 GB | 7.9 GB | 4（危急） |
#
#   ⇒ 原来的判据（"压力 != 1 就杀 / swap 涨 128 MB 就杀"）**对 60 秒那一趟太紧**：
#     它被杀时进程树已经降到 0.9 GB（解码刚结束）、整机还剩 9.9 GB 可用 —— 那叫
#     "就差一口气"，不叫危险。而 180 秒那一趟才是真危险（可用 3.5 GB）。
#   ⇒ 现在拿**可用内存还剩多少**当总闸：还剩得多就让它跑，真少了（低于下面这个数）
#     才让"压力 / swap"那两条生效。进程树超预算、可用低于 min-available 两条不变。
TIGHT_AVAILABLE_GIB = float(os.environ.get("CS_MEM_TIGHT_GIB", "6"))


def _tight(sample):
    """整机可用内存是不是已经低到"该认真看 pressure/swap 了"。"""
    return sample["system_available_bytes"] < TIGHT_AVAILABLE_GIB * GIB


def process_tree(pid):
    """这条进程树上的所有进程（含根自己）。查不到的跳过 ——
    进程随时可能退出，拿不到不是错误。"""
    try:
        root = psutil.Process(pid)
    except psutil.Error:
        return []
    procs = [root]
    try:
        procs.extend(root.children(recursive=True))
    except psutil.Error:
        pass
    return procs


def tree_rss(pid):
    """进程树占的内存（RSS 求和）。返回 (字节, 进程数)。"""
    total = 0
    count = 0
    for p in process_tree(pid):
        try:
            total += p.memory_info().rss
            count += 1
        except psutil.Error:
            continue
    return total, count


def pressure_level():
    """macOS 自己的内存压力等级：1 正常 / 2 警告 / 4 危急。
    拿不到就返回 None —— **不拿它当"正常"**，免得量不到时误判成安全。"""
    try:
        out = subprocess.run([SYSCTL, "-n", "kern.memorystatus_vm_pressure_level"],
                             capture_output=True, text=True, timeout=5)
        return int(out.stdout.strip())
    except Exception:
        return None


def take_sample(pid, baseline):
    rss, count = tree_rss(pid)
    vm = psutil.virtual_memory()
    sw = psutil.swap_memory()
    return {
        "t": round(time.time() - baseline["t0"], 1),
        "tree_rss_bytes": rss,
        "tree_processes": count,
        "system_available_bytes": vm.available,
        "system_total_bytes": vm.total,
        # 已换出的累计量：**增量**才是危险信号（累计值开机以来一直在涨）
        "swap_out_delta_bytes": sw.sout - baseline["sout"],
        "swap_used_bytes": sw.used,
        "swap_used_delta_bytes": sw.used - baseline["swap_used"],
        "pressure_level": pressure_level(),
    }


def breach(sample, args):
    """返回 None（没越线）或一句人话（越线了，说清是哪条）。"""
    if sample["tree_rss_bytes"] > args.budget_gib * GIB:
        return (f"生成进程占到了 {sample['tree_rss_bytes'] / GIB:.1f} GB，"
                f"超过给它划的 {args.budget_gib:.0f} GB")
    if sample["system_available_bytes"] < args.min_available_gib * GIB:
        return (f"整机只剩 {sample['system_available_bytes'] / GIB:.1f} GB 可用内存，"
                f"低于 {args.min_available_gib:.0f} GB 这条线")
    # ── 下面三条只在"可用内存已经低到该认真看"的时候才算数（见文件顶部的表）──
    #    还剩得多就让它跑完：实测 60 秒那趟被杀时，进程树已降到 0.9 GB（解码刚结束）、
    #    整机还有 9.9 GB 可用 —— 那是"就差一口气"，不是危险。
    if _tight(sample):
        if sample["pressure_level"] is not None and sample["pressure_level"] != 1:
            return (f"整机只剩 {sample['system_available_bytes'] / GIB:.1f} GB 可用，"
                    f"内存压力已经不是正常（等级 {sample['pressure_level']}）")
        if sample["swap_out_delta_bytes"] > args.max_swap_out_mib * MIB:
            return (f"这一趟已经往硬盘上换了 "
                    f"{sample['swap_out_delta_bytes'] / MIB:.0f} MB，超过 {args.max_swap_out_mib} MB")
        if sample["swap_used_delta_bytes"] > args.max_swap_growth_mib * MIB:
            return (f"占用的交换空间涨了 {sample['swap_used_delta_bytes'] / MIB:.0f} MB，"
                    f"超过 {args.max_swap_growth_mib} MB")
    return None


def kill_tree(pid):
    """先礼后兵：对这条树上的每一个进程 TERM，等一会儿还活着的 KILL。

    ⚠️ **不要用 os.killpg 杀整组** —— 2026-10-12 自检时实测踩到：被盯的进程
    如果**不是**进程组组长（自检时我拿一个临时脚本喂它），killpg 会把**整组**
    都带走，连调用方的 shell 一起杀。逐个杀自己这棵树，才是它该干的事。
    """
    procs = process_tree(pid)
    for p in reversed(procs):            # 先叶子后根，免得根一死就找不到孩子
        try:
            p.terminate()
        except psutil.Error:
            pass
    time.sleep(3)
    for p in reversed(procs):
        try:
            if p.is_running():
                p.kill()
        except psutil.Error:
            pass


def main():
    ap = argparse.ArgumentParser(description="内存看门狗（越线就按停）")
    ap.add_argument("--pid", type=int, required=True, help="要盯的进程（连它的子进程一起算）")
    ap.add_argument("--budget-gib", type=float, default=20.0, help="进程树占用上限（GB）")
    ap.add_argument("--min-available-gib", type=float, default=2.0, help="整机可用内存下限（GB）")
    ap.add_argument("--max-swap-out-mib", type=float, default=64.0, help="新增换出上限（MB）")
    ap.add_argument("--max-swap-growth-mib", type=float, default=128.0, help="swap 用量增长上限（MB）")
    ap.add_argument("--interval", type=float, default=2.0, help="采样间隔（秒）")
    ap.add_argument("--observe", action="store_true", help="只看不杀（量基线时用）")
    ap.add_argument("--log", default="", help="采样明细写到这里（JSONL）")
    args = ap.parse_args()

    sw0 = psutil.swap_memory()
    baseline = {"t0": time.time(), "sout": sw0.sout, "swap_used": sw0.used}
    logf = open(args.log, "a", buffering=1) if args.log else None

    try:
        while True:
            if not psutil.pid_exists(args.pid):
                return 0
            try:
                s = take_sample(args.pid, baseline)
            except Exception:
                time.sleep(args.interval)
                continue
            if logf:
                logf.write(json.dumps(s) + "\n")
            if not args.observe:
                why = breach(s, args)
                if why:
                    sys.stderr.write(f"[memory_guard] 踩线：{why} —— 停掉这一趟\n")
                    if logf:
                        logf.write(json.dumps({"stopped": why}) + "\n")
                    kill_tree(args.pid)
                    return 3
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        if logf:
            logf.close()


if __name__ == "__main__":
    raise SystemExit(main())
