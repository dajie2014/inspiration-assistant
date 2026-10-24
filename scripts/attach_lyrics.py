#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把歌词贴进 MusicXML，好让 Dorico 打开时谱面上每一句都对得上音。

**为什么需要它**：Composer Step 出的谱子里**没有词** —— YuE2 只写旋律与和弦，
词一直留在歌词框里（实测：`示例作品.abc` 的 `w:` 行 0 条、
`.xml` 的 `<lyric>` 0 处）。于是拿进 Dorico 改的时候，谱面上看不出哪句唱哪里。

**怎么贴**（规则都是拿用户那份《示例作品》量出来的）：

  · **只要 vocal 有音符，就算要唱**（2026-10-16 用户定的，原话：
    「只要在 vocal 看到音符内容，就把歌词撒下去 —— 谱子上写着音符，
    那就是要唱的，不然写它干什么」）。
    ⇒ 以前只认 `% verse` / `% chorus` 两种段名，于是 `% intro` 那种段整段拿不到词、
    谱面上全是 `*`；现在**段里只要有人声音符就算唱段**
    （`any(eaters_of(toks))`；全休止的段 toks 为空 ⇒ 照样不吃词）。
  · **段内一个字贴一个音符**；被连音线（`-`）延续的那个音符**不占新字**。
  · **字比音符多**的段 → 平均摊开，一个音符挂两个字（MusicXML 本来就允许）。
    ⚠️ 「摊」是**猜**的：谱面上没写它实际怎么唱。
  · **字比音符少** → **把词循环着用**（2026-10-16 用户原话：「词不够就循环这个妙啊」）。
    同一段旋律反复唱同一段词，本来就是流行歌的常态；
    ⚠️ 段里只剩一两个字、位置却很多时会重复很多遍 —— 那是**上游给的词与旋律长度
    不匹配**，不是这里能修的；宁可重复，也别让谱面空着一片。

**一字多音（melisma）怎么办**（2026-10-16 聊透的）：
  · **同一个音被连音线拖长**（`C4-`）⇒ 后面的音写 `_`（= 延长上一个词）✓ 已实现。
  · **不同音高的几个音唱一个字** ⇒ 谱上**画了圆滑线**才有信息；**没画就猜不出**，
    不许猜（宁可各配一个字、让覆盖率够，人接手时自己合并）。
  · 实测：**模型自己出的谱一根圆滑线都没有**（它不会写花腔）⇒ 所以现在这条路上
    不存在"该合并的地方"，不会误伤。**哪天模型会写花腔了，这里必须跟着改**。

**什么时候不动**（两条硬规矩）：
  · 源 ABC 里**本来就有 `w:` 行**（比如从 Dorico 转出来再转回去的）
    ⇒ 那份谱子自己有词，**一个字节都不碰**。
  · **用户自己导入的谱**（他写的、要照着唱的）⇒ **不许乱动**（2026-10-16 他原话：
    「我导入的谱，有可能是我自己写的直接照着唱，不要乱动就可以」）。
    ⇒ 流程上：导入的那份**只当输入读**，产物是**另存的新文件**
    （`yue2_adapter.sh` 里连转格式都先抄到运行目录再动手，就是为这个）。

用法：
    attach_lyrics.py <源.abc> <要贴的.xml> <歌词文本文件>

⚠️ 就地改那份 XML。调用方先把产物复制出来再贴，别把用户手上那份改掉。
"""
import json
import re
import sys


def parse_abc(path):
    """→ [(段落名, [音符记号...]), ...]，只收 Vocal 声部的音符。

    ★ **一个段落标记都没有时，整份谱算一段。**
      2026-10-13 实测踩到（用户报「照谱唱那一版没词」）：
      从 Dorico 的 MusicXML 转出来的 ABC（「照谱唱」那条路用的就是它）
      **一个 `%` 行都没有**。老代码要求"先见到 `%` 才开一个段"，
      于是这里返回**空表** → `build_plan` 也是空 → `write_w_lines` **一个字都没贴、
      却安静地返回成功**（退出码 0，调用方还是 `>/dev/null 2>&1 || true`，
      连个响都没有）。产物 MusicXML 里 `<lyric>` **0 处** ⇒ 送进 ACE 只能唱「啦」。
      ⇒ 兜底：没见到任何 `%` 就把收集到的人声音符当**一段**，
        歌词照"字少则后面空着、字多则摊开"铺上去（`spread` 本来就这么干）。
    """
    sections, cur_sec, cur_voice, buf = [], None, None, []
    saw_section = False
    for raw in open(path, encoding='utf-8'):
        line = raw.rstrip('\n')
        if line.startswith('%'):
            if cur_sec is not None:
                sections.append((cur_sec, buf))
            cur_sec, buf = line.strip(), []
            saw_section = True
            continue
        m = re.match(r'^V:\s*(\S+)', line)
        if m:
            cur_voice = m.group(1)
            continue
        if cur_voice != 'Vocal':
            continue
        body = re.sub(r'"[^"]*"', '', line)      # 和弦符号里也有字母，先剔掉
        for tok in re.finditer(r"[A-Ga-g][,']*\d*(?:/\d+)?-?", body):
            buf.append(tok.group(0))
    if cur_sec is not None:
        sections.append((cur_sec, buf))
    if not saw_section and buf:
        # 整份谱一个段落标记都没有 —— 全部人声音符当一段。
        # ★ 段名**故意叫 `% verse`**（不是随手起的）：`build_plan` 只把
        #   `verse` / `chorus` 这两种段名当"唱段"，起个别的名字等于还是没人唱
        #   （2026-10-13 第一次修就栽在这儿：起名 `%%all`，段数对了、却一个音都不吃字）。
        return [('% verse', buf)]
    return sections


def parse_lyrics(text):
    """→ [(标记, 字串), ...]

    ★ **整份歌词一个 `[标记]` 都没有时，当成一段。**
      2026-10-13 实测踩到（用户报「照谱唱那一版没词」，查下去发现是**普遍**的）：
      用户的歌词就是**纯文本** —— 他写词不写 `[Verse]` / `[Chorus]`。
      而老代码只认 `[` 开头的行才算一段，于是这里返回**空表**，
      `build_plan` 一个音都分不到字，`write_w_lines` **一个字都不贴、
      却安静地报成功**（退出码 0；调用方还是 `>/dev/null 2>&1 || true`）。
      产物谱子里 `<lyric>` 一个都没有 ⇒ 送进 ACE 只能唱「啦」。
      ⇒ 兜底：没见到任何 `[标记]` 就把全部歌词当一段（标记留空），
        `build_plan` 会走"铺到所有唱段上"那条路。
    """
    out, cur = [], None
    saw_mark = False
    for line in text.split('\n'):
        if line.startswith('['):
            cur = [line.strip(), '']
            out.append(cur)
            saw_mark = True
        elif line.strip() and cur is not None:
            cur[1] += line.strip()
    if not saw_mark:
        body = ''.join(l.strip() for l in text.split('\n') if l.strip())
        return [['', body]] if body else []
    return out


def spread(words, slots):
    """把一串字铺到 slots 个位置上 → [[字...], ...]，长度正好是 slots。

    字多时平均摊（一个位置挂两个字）；**字少时把词循环着用**（不再留空）。
    """
    if slots <= 0:
        return []
    n, m = len(words), slots
    if n == 0:
        return [[] for _ in range(m)]
    if n <= m:
        # ★ 2026-10-16 用户定的第二条规矩（原话：「词不够就循环这个妙啊」）。
        #   他的一贯判据：「只要在 vocal 看到音符内容，就把歌词撒下去 ——
        #   谱子上写着音符，那就是要唱的，不然写它干什么」。
        #   于是"字比音符少"时只剩一条路：**同一段词重复唱**（同一段旋律反复，
        #   本来就是流行歌的常态；YuE2 也常把主歌／副歌唱好几轮、而词只有一轮）。
        #   ⚠️ 段里只剩一两个字、位置却很多时，会把它重复很多遍 ——
        #     那是**上游给的词与旋律长度不匹配**，不是这里能修的；
        #     宁可唱重复的词，也别让谱面上空着一片。
        return [[words[i % n]] for i in range(m)]
    return [list(words[j * n // m:(j + 1) * n // m]) for j in range(m)]


def _section_kind(name):
    """`% verse` → `verse`（谱子那侧的段落名）。"""
    return name.lstrip('%').strip().lower()


def _lyric_kind(mark):
    """`[Verse]` → `verse`（歌词那侧的段落标记）。"""
    return mark.strip().strip('[]').strip().lower()


def build_plan(abc_path, lyrics):
    """→ [[这个音符要唱的字, ...], ...]，长度 = 人声音符总数。

    ★ **三种走法**（2026-10-12：前两种是老办法，第三种是补上"反复唱"的漏）：

    · **唱段数与歌词段数相等** → **一段配一段**，最准
      （实测《示例作品》：谱子 4 个唱段、歌词 4 段，六段全对上）。
    · **对不上、但段落名能配上** → **同名的段反复用同一份词**（← 2026-10-12 新增）。
      为什么：YuE2 出的歌**会把主歌／副歌反复唱好几轮**（实测《示例作品》：
      4 分钟里 `% verse` + `% chorus` 各出现四回），而词只有一轮 ——
      老办法贴完第一轮就没了，**后三轮的谱面上全是 `*`**（看着像没词）。
      现在按名字配：每个 `% verse` 都用 `[Verse]` 那段词，每个 `% chorus` 都用
      `[Chorus]`；同一名字在歌词里出现好几段时按顺序轮着用。
      ⇒ **每一轮的开头一定准**，重复段落的词也对。
    · **还是配不上** → **忽略歌词的分段，把所有字依次铺到所有唱段上**。
      为什么不是"能配几段配几段"：现场那份新谱子（`plan_only` 出的）
      **只有 1 个 `% verse` 唱段，而歌词有 `[Verse]` + `[Chorus]` 两段** ——
      按段配会**把那 12 个字整个丢掉**。**丢字比位置偏更糟**（少一整句一眼就能看出来，
      而位置偏他只是挪两下），而那段恰好有 31 个音符位置、放得下 29 个字。

    哪些音符吃字：被前一个连音（`-`）延续的那个不吃。
    """
    sections = parse_abc(abc_path)
    segs = parse_lyrics(lyrics)

    def eaters_of(toks):
        out, prev = [], False
        for t in toks:
            out.append(not prev)
            prev = t.endswith('-')
        return out

    def fill(toks, words):
        """这一段里，吃字的音符按顺序分字，不吃字的给空。"""
        eaters = eaters_of(toks)
        slots = spread(words, sum(eaters))
        out, j = [], 0
        for eats in eaters:
            if eats:
                out.append(slots[j]); j += 1
            else:
                out.append([])
        return out

    # ★ 2026-10-16 用户定的新规矩（原话）：
    #   「只要在 vocal 看到音符内容，就把歌词撒下去。」
    #   —— 以前只认 `% verse` / `% chorus` 两种段名；于是模型标的 `% intro`
    #   （引子，可它里面**有人声音符**）整段拿不到词、谱面上全是 `*`。
    #   他对这件事的定性：音频的小节偏差不重要（这是草稿本，之后拿进 ACE 精修），
    #   **但歌词落地一定要准** ⇒ 现在改成「段里只要有人声音符，就算唱段」。
    #   ⚠️ toks 里本来就不含休止符（正则只抓 A–G），所以**全休止的段
    #      `any()` 自然是 False**、照样不吃词 —— 不用担心把前奏那些空段算进来。
    singing = [i for i, (_, toks) in enumerate(sections) if any(eaters_of(toks))]

    # 一个能吃字的唱段都没有 → 全空
    if not singing or not segs:
        return [[] for name, toks in sections for _ in toks]

    plan = []
    if len(singing) == len(segs):
        # ── ① 一段配一段 ──
        si = 0
        for i, (name, toks) in enumerate(sections):
            if i in singing:
                plan.extend(fill(toks, segs[si][1]))
                si += 1
            else:
                plan.extend([[] for _ in toks])
        return plan

    # ── ② 按段落名配：同名的段都用同一份词（反复唱的歌走这条）──
    by_kind = {}
    for mark, words in segs:
        by_kind.setdefault(_lyric_kind(mark), []).append(words)

    kinds = [_section_kind(name) for i, (name, _) in enumerate(sections) if i in singing]
    if kinds and all(k in by_kind for k in kinds):
        used = {}
        for i, (name, toks) in enumerate(sections):
            if i in singing:
                k = _section_kind(name)
                picks = by_kind[k]
                n = used.get(k, 0)
                used[k] = n + 1
                plan.extend(fill(toks, picks[n % len(picks)]))
            else:
                plan.extend([[] for _ in toks])
        return plan

    # ── ③ 兜底：所有字依次铺到所有唱段上 ──
    flags = []
    for i, (name, toks) in enumerate(sections):
        for eats in eaters_of(toks):
            flags.append(eats if i in singing else False)
    allwords = ''.join(w for _, w in segs)
    slots = spread(allwords, sum(flags))
    j = 0
    for eats in flags:
        if eats:
            plan.append(slots[j]); j += 1
        else:
            plan.append([])
    return plan


def insert_into_xml(xml_path, plan):
    text = open(xml_path, encoding='utf-8').read()

    m = re.search(r'<part id="[^"]*[Vv]ocal[^"]*">.*?</part>', text, re.S)
    if not m:
        raise SystemExit('谱子里找不到人声声部（part id 里带 Vocal 的那个）')
    start, end = m.span()

    pieces, idx = [], 0
    for nm in re.finditer(r'<note\b.*?</note>', text[start:end], re.S):
        block = nm.group(0)
        if '<rest' in block or '<chord' in block:
            continue                                  # 休止与和弦附随音不占字
        words = plan[idx] if idx < len(plan) else []
        idx += 1
        if not words:
            continue
        lyric = ''.join(
            '        <lyric number="1">\n'
            '          <syllabic>single</syllabic>\n'
            f'          <text>{w}</text>\n'
            '        </lyric>\n' for w in words)
        pieces.append((nm.start() + start, nm.end() + start, lyric))

    for ns, ne, lyric in reversed(pieces):             # 倒着插，位置才不漂
        at = text.rfind('</note>', ns, ne)
        text = text[:at] + lyric + text[at:]

    open(xml_path, 'w', encoding='utf-8').write(text)
    return idx


def read_lyrics(path):
    """歌词从哪来：`params.json`（取里面的 `lyrics`）或者一个纯文本文件都行。"""
    raw = open(path, encoding='utf-8').read()
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict) and isinstance(obj.get('lyrics'), str):
            return obj['lyrics']
    except Exception:
        pass
    return raw


def write_w_lines(abc_path, lyrics):
    """**就地**往 ABC 里插 `w:` 行 —— 让这份谱子本身就带词。

    用户 2026-10-12 定的：「在 CS 出乐谱的时候让他带上歌词」。
    以前是"导出那一步才贴到 MusicXML 上"，现在改成**谱子一出就带词**：
    ABC 里插了 `w:`，后面 `abc2xml` 转出来的 MusicXML **自然带 `<lyric>`** ——
    一份源头做好，两边都有。

    **为什么在 ABC 上做**：ABC 是源头，段落（`% verse`）和连音（`-`）都在它这儿，
    对齐要的信息全有。

    ⚠️ **一个音符唱两个字**的地方（字比音符多的那段），两个字**连写、中间不加空格**
    —— ABC 的一个音节位对应一个音符，没有别的写法。

    ⚠️ **这份 ABC 之后要是被"照它唱"喂回模型，文本就和原来不一样了**
    （整段 ABC 都进编码器）。所以调用方是**在产物落盘前**改它，模型那边早跑完了；
    但用户下次拿这份谱子去重唱时，喂进去的就是带词的版本 —— 这一条**待实测**。
    """
    text = open(abc_path, encoding='utf-8').read()
    if re.search(r'^w:', text, re.M):
        print('这份谱子已经有歌词行了，不动')
        return 0

    plan = build_plan(abc_path, lyrics)
    token = re.compile(r"[A-Ga-g][,']*\d*(?:/\d+)?-?")

    out, pi, voice = [], 0, None
    for raw in text.split('\n'):
        line = raw.rstrip('\n')
        m = re.match(r'^V:\s*(\S+)', line)
        if m:
            voice = m.group(1)
            out.append(line)
            continue
        out.append(line)
        if voice != 'Vocal' or not line.strip():
            continue
        if line[0].isalpha() and line[1:2] == ':':        # 头部行（X: T: M: …）
            continue
        if line.startswith(('%', 'w:')):
            continue

        toks = token.findall(re.sub(r'"[^"]*"', '', line))   # 与 parse_abc 同一套抽法
        chunk = plan[pi:pi + len(toks)]
        pi += len(toks)

        parts, prev = [], False
        for t, w in zip(toks, chunk):
            if prev:
                parts.append('_')            # 连音延续：这个音还在唱上一个字
            elif w:
                parts.append(''.join(w))     # 一音多字就连写
            else:
                parts.append('*')            # 这个音不唱字
            prev = t.endswith('-')
        if parts:
            out.append('w: ' + ' '.join(parts))

    open(abc_path, 'w', encoding='utf-8').write('\n'.join(out))
    return sum(len(w) for w in plan)


def audit(abc_path):
    """数一份 ABC 里**人声**的歌词覆盖情况 → dict（**只读，不改文件**）。

    ★ 2026-10-16 用户要求加的一道守门。他的原话：
      「**抄的时候也是这个原则 —— vocal 声部有音符就必须有歌词**，
       有可能这条是个废话，但是**怕他抽风**」。
      ⇒ 任何"把谱子交出去"的路径（生成、抄、导出）都可以拿它自查一遍：
        凡**人声音符却空着（`*`）**，就是没达标。

    ⚠️ **计数口径：只数"有音高的音符"**（八分、十六分、附点、连音……都算），
      **休止符（ABC 里的 `z` / `x` / `Z`）一律不算** —— 而且**休止符下面本来就不该有词**。
      用户 2026-10-16 的原话：「让他数有音高的实质，也就是那些音符，比如八分音符、
      十六分音符等等；**休止符下面不应该有词**，也是废话，但是告诉他比较好。」
      ★ 实测（bossa 三版那份）：那份谱里有 **51 个休止符**，这里报的人声音符是 **231**
      —— 休止符**没被算进去** ✓。`write_w_lines` 那边同理：写 `w:` 行时只按
      有音高的音符排位置，**不会给休止符配词**。
    """
    tok = re.compile(r"[A-Ga-g][,']*\d*(?:/\d+)?-?")
    voice, notes, words, cont, stars, has_w = None, 0, 0, 0, 0, False
    vocal_ids = {}          # 声部 id → 是不是人声（见下面那段注释）
    for raw in open(abc_path, encoding='utf-8'):
        line = raw.rstrip('\n')
        m = re.match(r'^V:\s*(\S+)', line)
        if m:
            # 声部行有两种写法：
            #   · native（YuE2 自己那份）：`V: Vocal`
            #   · 通用写法（Dorico 转出来、`prepare_score` 的 foruser 版）：
            #     `V:1 treble nm="Vocal Melody" snm="Vocal"` 声明声部属性，
            #     紧接着再来一行光秃秃的 `V:1` 才是正文。
            # ★ 2026-10-20 实测踩到：只认 `Vocal` 会把这种谱报成
            #   「这份谱子没有人声音符（不算数）」，而其实 208 个词都在。
            # ⇒ 先把「id → 是不是人声」记下来，裸 `V:1` 那些行查表。
            vid = m.group(1)
            if 'vocal' in line.lower():
                vocal_ids[vid] = True
            voice = 'Vocal' if vocal_ids.get(vid) else vid
            continue
        if voice != 'Vocal':
            continue
        if line.startswith('w:'):
            has_w = True
            parts = line[2:].split()
            stars += parts.count('*')
            cont += parts.count('_')
            words += sum(1 for x in parts if x not in ('*', '_'))
            continue
        if line.startswith('%') or not line.strip():
            continue
        if line[0].isalpha() and line[1:2] == ':':
            continue
        notes += len(tok.findall(re.sub(r'"[^"]*"', '', line)))
    # ⚠️ 一行 `w:` 都没有 ⇒ 等于**整份都没词**（不这么折算的话，
    #    "没有词行"会被读成"空着 0 个"、报出假的"达标" —— 2026-10-16 实测踩到）。
    if notes and not has_w:
        stars = notes
    return dict(notes=notes, words=words, cont=cont, stars=stars, has_w=has_w)


def coverage(a):
    """覆盖率（0–100）：有音高的音符里，多少是**有词**的。"""
    if a['notes'] == 0:
        return 100
    return round((a['notes'] - a['stars']) * 100 / a['notes'])


def audit_line(a):
    """把 audit() 的结果说成**一行人话**（给日志／进度条用）。

    ★ 判据（用户 2026-10-16 想通之后定的，原话）：
      「**不需要完全正确，只要音符下面有词，人类就好动**」。
      ⇒ 所以这里**看覆盖率、不追求 100%**：
        · 100% ⇒ 全覆盖
        · ≥ 90% ⇒ 基本覆盖（差几个不影响人接手，**不报警**）
        · < 90% ⇒ 才值得看一眼
      ⚠️ 别改成"差一个音就 ⚠️" —— 那是拿成品标准卡草稿本（他明确不要那个）。
    """
    if a['notes'] == 0:
        return '这份谱子没有人声音符（不算数）'
    cover = coverage(a)
    if cover >= 100:
        tag = '全覆盖 ✓'
    elif cover >= 90:
        tag = '基本覆盖（差 %d 个音，不影响人接手）' % a['stars']
    else:
        tag = '⚠️ 覆盖偏低（差 %d 个音），值得看一眼' % a['stars']
    return ('人声音符 %d · 有词 %d · 连音延续 %d · 空着 %d · 覆盖 %d%% · %s'
            % (a['notes'], a['words'], a['cont'], a['stars'], cover, tag))


def main():
    args = sys.argv[1:]

    # ③ 只查一遍"人声有音符的地方是不是都有词"（守门用；**不改文件**）
    if args and args[0] == '--check':
        if len(args) != 2:
            raise SystemExit(__doc__)
        a = audit(args[1])
        print(audit_line(a))
        # 退出码也按同一条判据：**≥90% 就算够用**（不是"有空白就报错"）
        raise SystemExit(0 if coverage(a) >= 90 else 1)

    # ① 往 ABC 里插 `w:` 行（出谱时用）：  --abc-only <abc> <params.json 或 歌词文本> `w:` 行（出谱时用）：  --abc-only <abc> <params.json 或 歌词文本>
    if args and args[0] == '--abc-only':
        if len(args) != 3:
            raise SystemExit(__doc__)
        abc_path, lyrics_src = args[1], args[2]
        lyrics = read_lyrics(lyrics_src)
        if not lyrics.strip() or lyrics.strip() == '[Instrumental]':
            print('没有歌词可贴（空词或纯器乐）')
            return
        n = write_w_lines(abc_path, lyrics)
        if n:
            print(f'把词写进谱子了：{n} 个字')
        return

    # ② 往 MusicXML 里贴（给旧谱子兜底）： <abc> <xml> <歌词文件>
    if len(args) != 3:
        raise SystemExit(__doc__)
    abc_path, xml_path, lyrics_path = args

    if re.search(r'^w:', open(abc_path, encoding='utf-8').read(), re.M):
        print('这份谱子自己有歌词行（w:），不动')
        return

    lyrics = read_lyrics(lyrics_path)
    if not lyrics.strip() or lyrics.strip() == '[Instrumental]':
        print('没有歌词可贴（空词或纯器乐）')
        return

    plan = build_plan(abc_path, lyrics)
    n = insert_into_xml(xml_path, plan)
    print(f'贴好了：人声音符 {n} 个，歌词 {sum(len(w) for w in plan)} 个字')


if __name__ == '__main__':
    main()
