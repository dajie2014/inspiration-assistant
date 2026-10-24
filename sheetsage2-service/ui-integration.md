# UI 接入方案 · 灵感助手 × 8001 语义服务

> Copyright (c) 2026 Jie Da / Inspiration-Assistant
> SheetSage2 x YuE2 Integration - local, non-commercial research use only.

这一份只讲「界面怎么接」，不改代码。现有 `ContentView.swift`（2014 行）里
已经有大量可复用件，**不要重写**。

---

## 1. 现有可复用入口（先认清，别做重复的）

| 需求 | 现有东西 | 位置 |
|---|---|---|
| 上传音频 | 「选择源音频…」（`mode == .repaint`） | `ContentView.swift` 约 1596 行 |
| 导入 MusicXML | 菜单「导入谱子…」⇧⌘I，支持「只转格式 / 照它重唱」 | 菜单 + `ScoreFiles.swift` |
| 输入歌词 | 右侧歌词框 | `ContentView.swift` |
| 进度卡 + 状态 | 「现在在干什么」卡 + 进度条 | 约 1675 行 |
| 生成 | 底部蓝色大按钮，走 `BackendClient` → `yue2_adapter.sh` | `BackendClient.swift` |

**结论**：三个按钮不是从零造，是把上面三条路提到界面显眼处，各加一个入口。

---

## 2. 需要新增的最小件

### 2.1 `SheetSage2Client`（新文件，约 150 行）

```swift
struct ConditionBar: Decodable { let index: Int; let chords: [ChordEvent]; let vocal: VocalInfo; let section: String? }
struct AnalyzeResult: Decodable { let flow: String; let barCount: Int; let outputs: Outputs; let diagnostics: Diagnostics }

enum SheetSage2Client {
    static func analyze(flow: String, musicxml: Data?, abc: String?, vocalPart: String? = nil) async throws -> AnalyzeResult
    static func transcribe(audioPath: String, task: String = "melody-full") async throws -> AnalyzeResult
}
```

- 一律 `POST http://127.0.0.1:8001/...`，`Content-Type: application/json`
- **MusicXML 用 `musicxml_base64` 传**，不要传路径（launchd 读不了 `~/Documents`，会卡 177 秒）
- 超时：分析 30 秒；转谱 30 分钟
- 错误只取 `error.human`，**不要把 `status_text` 或 traceback 直接摆到状态栏**

### 2.2 三个按钮

在右侧顶部（风格提示框上方）加一条：

```
[ 上传音频 ]  [ 导入 MusicXML ]  [ 输入歌词 ]
```

- 「上传音频」→ 复用现有选文件面板 → 拷到 `~/inspiration-assistant/abc-cache/inbox/` → `/transcribe`
- 「导入 MusicXML」→ 复用「导入谱子…」→ 读 `Data` → base64 → `/analyze_score {flow:"B"}`
- 「输入歌词」→ 只聚焦歌词框（不弹窗）

### 2.3 状态栏（人话）

服务已经返回 `human_status`，但界面**不要直接显示英文**。映射：

| 内部阶段 | 界面文字 |
|---|---|
| `transcribe` 开始 | 正在识谱（音频） |
| `/analyze_score` | 正在整理乐谱 |
| 生成中 | 正在生成音频 |
| 成功 | 完成了 |
| 任何错误 | 这一步没成，可以再试一次 |

**永远不显示**：HTTP 码、JSON、Python traceback。细节写日志即可。

### 2.4 谱面面板（改速度 / 移调 / 音域）

- ABC 文本用 `TextEditor` 展示 `repaired_abc`（**必须带版权头，服务已加**）
- 速度 / 移调 / 音域三个控件写进现有的 `params.json`：
  - 速度 → 现有 `bpm` 字段（`yue2_adapter.sh` 已经会传给 `prepare_score --tempo`）
  - 移调 / 音域 → 目前 adapter **没有**这两个参数，需要新增（见 §3）
- 改动后重新调 `/analyze_score` 只做校验，不重写和弦

### 2.5 高级设置（快捷键唤出）

建议 `⌥⌘,`（不与现有冲突）。三项：

1. 和弦敏感度（0–100）：**仅 Flow-A/C 生效**；Flow-B 永远 0（不改和弦）
2. 自动补和弦：**Flow-A 默认开、Flow-B 强制关**
3. YuE2 参数：steps（8/16/32）、seed、语言

---

## 3. 生成时的双输入怎么接

现有 `yue2_adapter.sh` 已经支持 `abc_path`，并且会自己：

1. 转 MusicXML（如果是 ABC）
2. 人声升八度
3. 翻成 YuE2 原生写法
4. 剥和弦
5. **强制 `cot = melody`**

所以界面只需要把**原始 MusicXML 路径**作为 `abc_path` 传给 adapter：

```
Flow-B: abc_path = 用户导入的 .musicxml
Flow-A: abc_path = 服务返回的 melody.abc
Flow-C: abc_path = 转谱出的 score.abc
```

**不要**把 `condition.json` 塞进 `abc_path` —— adapter 不认，YuE2 也不认。

和弦的「存活证明」在界面上这样摆：生成后显示一行小字

> 手写和弦 16 个，全部原样保留（已核对）；送唱的是旋律线，和弦未参与 AI 改写。

数字来自 `/analyze_score` 的 `diagnostics.chord_audit.in_order_matches`。

---

## 4. 需要新增的 adapter 参数（移调 / 音域）

`yue2_adapter.sh` 现在没有这两个。最小改法：

- `params.json` 新增 `transpose`（半音，整数）与 `vocal_range`（如 `"C3-C5"`）
- 在 `prepare_score.py` 第 2 步（人声升八度）之后、第 3 步之前，
  对 MusicXML 做确定性移调 / 音域夹紧
- **只动音高，不动和弦**；Flow-B 下移调后要在界面上重新显示「和弦未改」的核对结果

⚠️ 这一步会改用户谱子的音高。Flow-B 的规矩是「人写的东西不许被 AI 改」，
所以移调必须是**用户显式操作**，且默认 0（不移调）。

---

## 5. 验收（照着测，不要口头通过）

| 项 | 怎么验 |
|---|---|
| Flow-B 和弦存活 | `chord_audit.in_order_matches == xml_chords`，且 `chords_rewritten == false` |
| Flow-B Interlude | `summary.interlude_bars` = 5–12，每小节 `rest_type == vocal_rest_instrument_continues` |
| 不注入隐藏音 | `guarantees.notes_injected == 0` |
| 说唱不出现 | 真出音频 → 过 ASR 看 interlude 段有没有词 |
| 状态栏 | 全程只有中文人话，无 traceback |
| 版权头 | 打开 `repaired.abc` 第一行必须是 `% Copyright ...` |
