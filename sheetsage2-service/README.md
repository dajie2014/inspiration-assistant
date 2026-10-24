# SheetSage2 × YuE2 集成 · 8001 语义服务

> Copyright (c) 2026 Jie Da / Inspiration-Assistant
> SheetSage2 x YuE2 Integration - local, non-commercial research use only.
> Weights: SheetSage2 / YuE2 / MERT-v2 (CC BY-NC 4.0, m-a-p). No cloud upload.

这是「灵感助手」（`my-songwriter`）的 SheetSage2 语义服务。常驻 `127.0.0.1:8001`，
给三条工作流提供乐谱语义。**纯本机，不出网。**

---

## 0. 先说清楚一件事：SheetSage2 真实能力与任务书假设的差异

| 任务书假设 | 事实（2026-10-24 核实） | 本服务的处理 |
|---|---|---|
| SheetSage2 读 MusicXML、修复 ABC、识别谱面和弦 | **不。** 官方 SheetSage2 是 **音频 → lead sheet**（ABC/MIDI）模型：Melody · Chords · Beats · Key · Structure。它没有 MusicXML 阅读器，也不修 ABC。 | Flow-B 的「读人类写下的和弦」由**确定性解析器**完成（`ss2core.py`），这才是真正的 verbatim；音频转谱才交给 SheetSage2。 |
| 结构化条件 JSON 作为 YuE2 plan 的「第二通道」 | **YuE2 当前接口没有这个通道。** `run_yue2.py` 只接受 `style/tags/lyrics/cot/seed/abc/cfg_scale/id`；`cot=melody` 还**拒绝任何带和弦的 ABC**。 | 条件 JSON 作为**独立事实记录 / UI 校验基准**；送进 YuE2 的是 **strip 掉和弦的 melody ABC**。和弦从物理上就不可能被 AI 改写。 |
| Flow-B 强制 `cot="melody"`，同时和弦要「贯穿流水线」 | 两者可以同时成立，但含义是：**和弦存活在 repaired ABC / condition JSON / 导出谱里，不进 YuE2 的 melody 通道。** | 已实现并可在 `chord_audit` 里逐条核对：`in_order_matches` 必须等于源和弦数。 |

> 一句话：**Flow-B 的和弦保证，靠的是「不让它进 AI」，不是「让 AI 别改它」。**

---

## 1. 架构

```
My Songwriter.app (SwiftUI)
        │  HTTP 127.0.0.1:8001
        ▼
┌──────────────────────────────────────────────┐
│ service.py  (Python 3.11, 零第三方依赖)      │
│                                              │
│  /analyze_score ──► ss2core.py               │
│     · MusicXML 解析（确定性）                │
│     · 逐小节和弦 verbatim                    │
│     · 段落 / 休止语义                        │
│     · ABC 结构校验与格式修复                  │
│     · 250 小节守卫                           │
│                                              │
│  /transcribe ────► 一次性子进程               │
│     yue2 transcribe (Python 3.12 + MLX)      │
│     SheetSage2 + MERT-v2-FullSong            │
│     跑完即退 → 内存全释放                     │
└──────────────────────────────────────────────┘
```

**为什么拆成两套 Python**：服务本身零依赖，空闲约 30 MB；Flow-C 的音频编码器
需要 MLX（只支持 3.12）。子进程模型天然满足「懒加载 + 用完卸载」，父进程永远不加载权重。

---

## 2. 三条工作流怎么走

### Flow-A（歌词 + 风格，AI 起草）
1. YuE2 出 ABC 草稿。
2. `POST /analyze_score {"flow":"A","abc_text":...}` → `repaired_abc` / `melody_abc` / `condition_json`。
3. 用户在谱面面板改。
4. 确认后送 YuE2：`cot="melody"` + `melody_abc`。

### Flow-B（导入 MusicXML，最高优先级）
1. MusicXML（Dorico/DAW 导出）→ 转 ABC（UI 层用 `xml2abc`）。
2. `POST /analyze_score {"flow":"B","musicxml_base64":...,"abc_text":...}`
   - MusicXML 是**主来源**；
   - ABC 只做**格式修复**，和弦一个都不改；
   - 返回两个独立产物：`repaired_abc`（给编辑面板）、`condition_json`（独立条件通道）。
3. 用户在谱面面板改。
4. 送 YuE2：`melody_abc` + `cot="melody"`。

### Flow-C（音频翻唱，保留）
1. `POST /transcribe {"audio_path":"~/inspiration-assistant/abc-cache/inbox/xxx.wav","task":"melody-full"}`
2. 服务 spawn 子进程；返回 `score.abc` 后再跑 Flow-C 语义层。
3. 用户改速度/移调/音域。
4. 送 YuE2：`melody_abc` + `cot="melody"`。

---

## 3. API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 状态、模型是否就绪、内存、守卫 |
| POST | `/analyze_score` | `flow`: A/B/C；输入 `musicxml_base64` 或 `musicxml_path`（必须在 `~/inspiration-assistant/` 内）+ `abc_text` |
| POST | `/transcribe` | Flow-C 音频转谱（懒加载） |
| POST | `/unload_audio` | 确认音频编码器已卸载（子进程模式恒为 unloaded） |

**路径限制**：macOS 隐私保护会拦住 launchd 后台进程读 `~/Documents`。
实测同一请求：走路径 **177 秒**，走 base64 **0.035 秒**。所以 App 应当读文件后
用 base64 上传；或者先把文件拷进 `~/inspiration-assistant/abc-cache/inbox/`。
服务对外部路径会**立即拒绝**（`path_outside_base`），不会挂住。

---

## 4. 资源实测（M1 Max 64 GB）

| 项 | 目标 | 实测 |
|---|---|---|
| 服务空闲内存 | < 1.5 GB | **约 30 MB**（`rss_peak_mb`） |
| score-only 权重 | 2.2–2.8 GB | **2.76 GB**（SheetSage2 0.23 + MERT2 2.53） |
| 250 小节守卫 | 拒绝 | 251 小节 → HTTP 413，人话提示 |
| 音频编码器常驻 | 仅 Flow-C、用完释放 | 一次性子进程；退场即释放 |

---

## 5. 部署

```bash
# 1) 独立 Python 3.11（已装）
~/inspiration-assistant/runtime/python/cpython-3.11.16-macos-aarch64-none/bin/python3.11

# 2) 权重（已下，2.76 GB）
HF_ENDPOINT=https://hf-mirror.com \
  yue2-local/mlx-Yue/.venv/bin/python fetch_weights.py \
  --cache-dir ~/inspiration-assistant/models/hf-cache

# 3) 安装 / 重载 launchd
./install.sh --python ~/inspiration-assistant/runtime/python/cpython-3.11.16-macos-aarch64-none/bin/python3.11

# 4) 自检
curl -s http://127.0.0.1:8001/health
```

`launchctl bootstrap` 在沙箱里会报 `Input/output error`；必须用完整权限运行安装脚本。
如果 `bootout` 报 `No such process`，直接 `bootstrap` 即可。

---

## 6. 测试

```bash
python3 -m unittest discover -s tests -v
```

覆盖：和弦 verbatim、Interlude 多小节休止、不注入隐藏长音、段落识别、
ABC 修复、strip-chords、250 守卫、三条 Flow 的版权头。

---

## 7. 已知边界（诚实清单）

1. **YuE2 没有和弦条件通道**。要让和弦影响渲染，只能 `cot=full`（AI 可能改和弦，
   违反 Flow-B 核心规则）或改 YuE2 代码。当前选择：**和弦不进 YuE2**。
2. **Flow-C 的 launchd 子进程仍会读 `~/Documents` 下的 `yue2-local`**
   （TCC 会拖慢）。部署到日常使用前，应把 MLX 运行时迁到
   `~/inspiration-assistant/runtime/`，或给 python 3.11 授予完全磁盘访问。
3. **段落标签是关键词映射**（主歌/副歌/间奏/桥段/Verse/Chorus/Interlude/Bridge…）。
   Dorico 里裸的 `A`/`3` 不会被猜成 Verse/Chorus，只保留原名。
4. **单声部谱**无法判断「人声休止但伴奏继续」，会标
   `vocal_rest_unknown_accompaniment`，不冒充 `full_silence`。
5. **UI 尚未改造**。服务与测试已就绪；三个按钮、状态栏人话、谱面面板、
   高级设置还需要动 SwiftUI。
