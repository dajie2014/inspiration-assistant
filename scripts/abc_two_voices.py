#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 SheetSage2 判出的和弦，变成 Ins 行的贝斯骨架。

用户 2026-10-26：「重点认 base 旋律」—— 和弦的根音线就是贝斯线。
人声一个音不改，只把它前面的和弦标记摘下来、写成低音。
"""
import os
import re
import sys

ALL_DURS = [48, 32, 24, 16, 12, 8, 6, 4, 3, 2, 1]
UNIT = 16          # 每小节多少单位（由 L: 行决定）
DURS = [x for x in ALL_DURS if x <= UNIT]
PC = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
SHARP = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
FLATN = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B']
KEY_NAME = 'C'
# 调号 → 哪些字母默认降（只做降号调；升号调走 SHARP 名兜底）
KEYFLATS = {
    'C': set(), 'F': {'B'}, 'Bb': {'B', 'E'}, 'Eb': {'B', 'E', 'A'},
    'Ab': {'B', 'E', 'A', 'D'}, 'Db': {'B', 'E', 'A', 'D', 'G'},
    'Gb': {'B', 'E', 'A', 'D', 'G', 'C'},
}

def note_token(body, midi):
    octv = midi // 12 - 1
    if octv >= 4:
        return body.lower() + "'" * (octv - 4)
    return body + ',' * (4 - octv)

def chord_root(chord):
    m = re.match(r'([A-G])([#b]?)', chord)
    if not m:
        return None
    letter, acc = m.group(1), m.group(2)
    pc = (PC[letter] + (1 if acc == '#' else -1 if acc == 'b' else 0)) % 12
    # ★ 按调号拼写：降号调里 D# 写成 Eb（用户 2026-10-26 指出的）
    flats = KEYFLATS.get(KEY_NAME, set())
    name = (FLATN if flats else SHARP)[pc]
    letter2, acc2 = name[0], name[1:]
    default = 'b' if letter2 in flats else ''
    if acc2 == default:
        body = letter2
    elif acc2 == '':
        body = '=' + letter2
    elif acc2 == '#':
        body = '^' + letter2
    else:
        body = '_' + letter2
    return note_token(body, 36 + pc)     # C2 一带 —— 真实贝斯的音区（谱面会有下加线，音高对）

def parse_bar(text):
    text = re.sub(r'\[K:[^\]]*\]', '', text)   # 内联调号丢掉（和主调相同）
    out = []
    chords = []
    pos = 0
    i = 0
    n = len(text)
    def read_num(j):
        k = j
        while k < n and text[k].isdigit():
            k += 1
        return (int(text[j:k]) if k > j else None), k
    while i < n:
        c = text[i]
        if c == '"':
            j = text.find('"', i + 1)
            if j < 0:
                break
            chords.append((pos, text[i + 1:j]))
            i = j + 1
        elif c in 'zZxX':
            i += 1
            num, i = read_num(i)
            d = num if num else 1
            out.append('z%d' % (d * UNIT if c in 'ZX' else d))
            pos += d * (UNIT if c in 'ZX' else 1)
        elif c in 'ABCDEFGabcdefg':
            j = i + 1
            while j < n and text[j] in '^_=':
                j += 1
            while j < n and text[j] in ",'":
                j += 1
            num, j2 = read_num(j)
            out.append(text[i:j2])
            i = j2
            pos += (num if num else 1)
        elif c == '-':
            out.append('-')
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out), chords, pos

NOTE_RE = re.compile(r'([_^=]*)([A-Ga-g])([,\']*)(\d*)')

def lower_octave(text):
    """把人声整行降一个八度（SheetSage2 判高了一个八度）。"""
    def one(m):
        acc, letter, marks, dur = m.group(1), m.group(2), m.group(3), m.group(4)
        if letter.islower():
            if marks:
                marks = marks[1:]          # c'' -> c'
            else:
                letter = letter.upper()    # c -> C
        else:
            marks = marks + ','            # C -> C,
        return acc + letter + marks + dur
    return NOTE_RE.sub(one, text)

def split_dur(n):
    out = []
    while n > 0:
        d = max([x for x in DURS if x <= n])
        out.append(d)
        n -= d
    return out

def rests(n):
    return ''.join('z%d' % d for d in split_dur(n))

def bass_bar(chords, total=None):
    if total is None:
        total = UNIT
    if not chords:
        return rests(total)
    chords = sorted(chords)
    out = []
    pos = 0
    for k, (onset, ch) in enumerate(chords):
        # 第一个和弦之前可能还有休止 —— 补上，否则小节时值不够
        if onset > pos:
            out.append(rests(onset - pos))
            pos = onset
        end = chords[k + 1][0] if k + 1 < len(chords) else total
        left = max(1, end - onset)
        root = chord_root(ch)
        if not root:
            out.append(rests(left))
        else:
            while left > 0:
                d = max([x for x in DURS if x <= left])
                out.append(root + str(d) + ('-' if left - d > 0 else ''))
                left -= d
        pos = end
    if pos < total:
        out.append(rests(total - pos))
    return ''.join(out)

def main(src, dst):
    raw = open(src).read().splitlines()
    global UNIT, DURS
    bpm = 75
    key = 'C'
    meter = '4/4'
    lden_unit = 16
    for ln in raw:
        if ln.startswith('M:'):
            meter = ln[2:].strip() or '4/4'
        if ln.startswith('L:1/'):
            lden = int(ln.split('/')[1])
            beats = int(meter.split('/')[0]) if '/' in meter else 4
            lden_unit = lden
            UNIT = beats * max(1, lden // 4)     # 3/4 + L:1/16 → 12
            DURS = [x for x in ALL_DURS if x <= UNIT]
        if ln.startswith('Q:') and '=' in ln:
            try: bpm = int(ln.split('=')[1])
            except: pass
        if ln.startswith('K:') and key == 'C':
            key = ln[2:].strip() or 'C'
            globals()['KEY_NAME'] = key
    lines = [l for l in raw if not l.startswith('%')]
    bars = []
    mode = None
    for ln in lines:
        if ln.startswith('V: Vocal'):
            mode = 'v'; continue
        if ln.startswith('V: Ins'):
            mode = 'i'; continue
        if ln.startswith('K:') or not ln or re.match(r'^[A-Z]:', ln):
            continue
        if mode != 'v':
            continue
        ln = re.sub(r'Z(\d*)', lambda m: '|'.join(['z%d' % UNIT] * int(m.group(1) or 1)), ln)
        for seg in ln.split('|'):
            seg = seg.strip()
            if not seg:
                continue
            voice, chords, pos = parse_bar(seg)
            if os.environ.get('VOCAL_OCT', '0') == '-1':
                voice = lower_octave(voice)
            if pos < UNIT:
                voice += rests(UNIT - pos)     # 原谱这一小节短了，补休止
            elif pos > UNIT:
                print('⚠️ 小节超长:', pos, '>', UNIT, seg[:40])
            bars.append((voice, chords))
    head = ['X:1', 'T:', 'M:%s' % meter, 'L:1/%d' % lden_unit, 'Q:1/4=%d' % bpm,
            'V: Vocal clef=treble name="Vocal Melody" snm="Vocal"',
            'V: Ins clef=treble name="Ins Melody" snm="Inst."',
            'K:%s' % key]
    out = head[:]
    for voice, chords in bars:
        out.append('V: Vocal')
        out.append((voice or 'z%d' % UNIT) + '|')
        out.append('V: Ins')
        out.append(bass_bar(chords) + '|')
    open(dst, 'w').write('\n'.join(out) + '\n')
    print('写出', dst, '小节', len(bars))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
