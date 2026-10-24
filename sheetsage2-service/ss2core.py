#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SheetSage2 x YuE2 integration -- deterministic score semantics core.

Copyright (c) 2026 Jie Da / Inspiration-Assistant
SheetSage2 x YuE2 Integration - local, non-commercial research use only.
Weights: SheetSage2 / YuE2 / MERT-v2 (CC BY-NC 4.0, m-a-p). No cloud upload.

DESIGN CONTRACT (Flow-B is the highest-priority flow):

* This module *reads* symbols that a human wrote on the score surface.
  It never invents a chord, never corrects chord quality, never runs
  harmonic analysis.
* Chords are returned as ``verbatim`` display symbols rebuilt only from
  MusicXML <harmony> primitives (root / alter / kind / bass / degrees).
  Rebuilding a symbol is format conversion, not inference.
* Rest bars are recorded, never "fixed" by injecting hidden long notes.
* The structured condition JSON is a separate channel.  It is never
  embedded into ABC comments as a semantic carrier, because YuE2's plan
  phase does not parse comments.

The module is standard-library only so the port-8001 service can run in a
small Python 3.11 environment with no ML dependency (lazy-load rule).
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field, asdict
from typing import Dict, Iterable, List, Optional, Tuple

SERVICE_VERSION = "0.1.0"
BAR_GUARD_LIMIT = 250
COPYRIGHT_LINE = (
    "Copyright (c) 2026 Jie Da / Inspiration-Assistant. "
    "SheetSage2 x YuE2 Integration - local, non-commercial research use only. "
    "Weights: SheetSage2 / YuE2 / MERT-v2 (CC BY-NC 4.0, m-a-p). No cloud upload."
)


# --------------------------------------------------------------------------
# copyright headers for every artefact we emit
# --------------------------------------------------------------------------

def copyright_header(fmt: str) -> str:
    """Return the mandatory header for an output format.

    abc  -> '%' comment lines (ABC comments are %)
    json -> a "_copyright" field (JSON has no comments; see stamp_json)
    xml  -> an XML comment
    text -> '#' lines
    """
    fmt = (fmt or "text").lower()
    if fmt == "abc":
        return "% " + COPYRIGHT_LINE + "\n"
    if fmt == "xml":
        return "<!-- " + COPYRIGHT_LINE.replace("--", "- -") + " -->\n"
    if fmt == "json":
        return COPYRIGHT_LINE
    return "# " + COPYRIGHT_LINE + "\n"


def stamp_json(payload: dict) -> dict:
    """Attach the copyright field to any JSON object, preserving insertion order."""
    out = {"_copyright": COPYRIGHT_LINE}
    out.update(payload)
    return out


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _text(node) -> str:
    return (node.text or "").strip() if node is not None else ""


def _int(node, default: int = 0) -> int:
    try:
        return int(_text(node))
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------------
# MusicXML -> score document
# --------------------------------------------------------------------------

_KIND_SUFFIX = {
    "major": "",
    "minor": "m",
    "dominant": "7",
    "diminished": "dim",
    "augmented": "aug",
    "major-seventh": "maj7",
    "minor-seventh": "m7",
    "dominant-seventh": "7",
    "diminished-seventh": "dim7",
    "half-diminished": "m7b5",
    "major-sixth": "6",
    "minor-sixth": "m6",
    "major-ninth": "maj9",
    "dominant-ninth": "9",
    "minor-ninth": "m9",
    "major-11th": "maj11",
    "dominant-11th": "11",
    "minor-11th": "m11",
    "major-13th": "maj13",
    "dominant-13th": "13",
    "minor-13th": "m13",
    "suspended-second": "sus2",
    "suspended-fourth": "sus4",
    "power": "5",
    "none": "",
}

_SECTION_PATTERNS = [
    ("PreChorus", r"\bpre[\s-]?chorus\b|预副歌|导歌"),
    ("Chorus", r"\bchorus\b|\brefrain\b|副歌|合唱"),
    ("Interlude", r"\binterlude\b|间奏|过门"),
    ("Bridge", r"\bbridge\b|桥段|桥部"),
    ("Verse", r"\bverse\b|主歌"),
    ("Intro", r"\bintro\b|前奏"),
    ("Outro", r"\boutro\b|\bcoda\b|尾奏|尾声"),
    ("Solo", r"\bsolo\b|独奏"),
]


def _section_from_text(text: str) -> Optional[str]:
    """Map a human-written section word to a canonical label.

    Only keyword hits are mapped.  A bare rehearsal mark like "A" or "3"
    is *not* guessed into Verse/Chorus -- it stays as a named section.
    """
    if not text:
        return None
    low = text.strip().lower()
    for label, pattern in _SECTION_PATTERNS:
        if re.search(pattern, low):
            return label
    return None


def _alter_suffix(alter: int) -> str:
    if alter == 0:
        return ""
    if alter > 0:
        return "#" * alter
    return "b" * (-alter)


def _step_symbol(step: str, alter: int) -> str:
    return (step or "C") + _alter_suffix(alter)


def _harmony_symbol(harmony) -> Tuple[str, Dict[str, object]]:
    """Rebuild a display symbol from <harmony> primitives (no inference)."""
    root = harmony.find("root")
    root_step = _text(root.find("root-step")) if root is not None else ""
    root_alter = _int(root.find("root-alter")) if root is not None else 0
    kind_node = harmony.find("kind")
    kind = (kind_node.get("text") or _text(kind_node) or "major").strip() if kind_node is not None else "major"
    kind_key = (kind_node.text or "").strip() if kind_node is not None else "major"
    kind_text_attr = kind_node.get("text") if kind_node is not None else None

    # A "text" attribute (if a human typed a label) wins as the literal surface.
    if kind_text_attr:
        suffix = kind_text_attr
    else:
        suffix = _KIND_SUFFIX.get(kind_key, kind_key)

    symbol = _step_symbol(root_step, root_alter) + suffix

    bass_node = harmony.find("bass")
    bass = None
    if bass_node is not None:
        bass_step = _text(bass_node.find("bass-step"))
        bass_alter = _int(bass_node.find("bass-alter"))
        if bass_step:
            bass = _step_symbol(bass_step, bass_alter)
            symbol += "/" + bass

    # Degrees: add / alter / remove, appended verbatim in source order.
    for degree in harmony.findall("degree"):
        value = _text(degree.find("degree-value"))
        dtype = _text(degree.find("degree-type")) or "add"
        dalter = _int(degree.find("degree-alter"))
        if not value:
            continue
        if dtype == "add":
            symbol += "add" + value
        elif dtype == "alter":
            symbol += _alter_suffix(dalter) + value
        elif dtype == "remove":
            symbol += "no" + value

    meta = {
        "root": _step_symbol(root_step, root_alter),
        "root_step": root_step,
        "root_alter": root_alter,
        "kind": kind_key,
        "kind_suffix": suffix,
        "bass": bass,
        "symbol": symbol,
        "verbatim": symbol,
        "source": "human",
    }
    return symbol, meta


@dataclass
class ChordEvent:
    offset: float          # in quarters from the bar start
    symbol: str
    root: str
    kind: str
    bass: Optional[str]
    verbatim: str
    position: int          # ordering within the bar

    def to_dict(self) -> dict:
        return {
            "offset": round(self.offset, 6),
            "symbol": self.symbol,
            "root": self.root,
            "kind": self.kind,
            "bass": self.bass,
            "verbatim": self.verbatim,
            "source": "human",
            "position": self.position,
        }


@dataclass
class Bar:
    index: int
    measure_number: str
    start_quarters: float
    length_quarters: float
    chords: List[ChordEvent] = field(default_factory=list)
    vocal_notes: int = 0
    vocal_rest: bool = True
    other_active: bool = False
    rest_type: str = "unknown"
    lyrics: str = ""
    section: Optional[str] = None
    notes_injected: int = 0   # must always stay 0 (Flow-B guard)

    def to_dict(self) -> dict:
        return {
            "index": self.index,
            "measure_number": self.measure_number,
            "start_quarters": round(self.start_quarters, 6),
            "length_quarters": round(self.length_quarters, 6),
            "chords": [c.to_dict() for c in self.chords],
            "vocal": {
                "notes": self.vocal_notes,
                "rest": self.vocal_rest,
                "rest_type": self.rest_type,
                "lyrics": self.lyrics,
            },
            "other_parts_active": self.other_active,
            "section": self.section,
            "notes_injected": self.notes_injected,
        }


@dataclass
class Section:
    label: str
    raw_label: str
    start_bar: int
    end_bar: int

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class ScoreDoc:
    source_kind: str
    title: str
    composer: str
    parts: Dict[str, List[Bar]]
    sections: List[Section]
    diagnostics: List[dict]
    source_sha256: str
    bar_count: int
    vocal_part: Optional[str]
    timing: Dict[str, object]

    def to_condition_json(self) -> dict:
        vocal_bars = self.parts.get(self.vocal_part) or (list(self.parts.values())[0] if self.parts else [])
        rest_types = {}
        for bar in vocal_bars:
            rest_types[bar.rest_type] = rest_types.get(bar.rest_type, 0) + 1
        chord_total = sum(len(b.chords) for b in vocal_bars)
        return stamp_json({
            "version": "1.0",
            "source": {
                "kind": self.source_kind,
                "title": self.title,
                "composer": self.composer,
                "sha256": self.source_sha256,
            },
            "channel": "structured_condition_json",
            "note": (
                "Chords are human-authored surface symbols, read verbatim. "
                "No harmonic analysis and no AI chord inference was performed. "
                "This JSON is a separate condition channel for the UI/YuE2 plan "
                "stage; it is never embedded into ABC comments."
            ),
            "vocal_part": self.vocal_part,
            "bar_count": self.bar_count,
            "bars": [b.to_dict() for b in vocal_bars],
            "all_parts": {pid: [b.to_dict() for b in bars] for pid, bars in self.parts.items()},
            "sections": [s.to_dict() for s in self.sections],
            "summary": {
                "chord_events": chord_total,
                "rest_types": rest_types,
                "interlude_bars": [
                    b.index for b in vocal_bars
                    if b.section == "Interlude"
                ],
            },
            "timing": self.timing,
            "diagnostics": self.diagnostics,
            "guards": {
                "bar_limit": BAR_GUARD_LIMIT,
                "bar_count": self.bar_count,
                "within_limit": self.bar_count <= BAR_GUARD_LIMIT,
                "notes_injected": 0,
            },
        })


def _pick_vocal_part(parts: Dict[str, List[Bar]], part_names: Dict[str, str],
                     requested: Optional[str]) -> Optional[str]:
    if requested:
        if requested in parts:
            return requested
        for pid, name in part_names.items():
            if requested.lower() in name.lower():
                return pid
        return None
    for pid, name in part_names.items():
        low = name.lower()
        if any(k in low for k in ("vocal", "voice", "melody", "唱", "人声", "旋律", "lead")):
            return pid
    return next(iter(parts), None)


def parse_musicxml(data: bytes, source_sha256: str = "",
                   vocal_part: Optional[str] = None) -> ScoreDoc:
    """Parse a MusicXML partwise document into a deterministic score document."""
    root = ET.fromstring(data)
    diagnostics: List[dict] = []

    if root.tag not in ("score-partwise", "score-timewise"):
        raise ValueError("not a MusicXML score (root=%s)" % root.tag)
    if root.tag == "score-timewise":
        raise ValueError("score-timewise is not supported; export partwise MusicXML")

    title = _text(root.find("./work/work-title")) or _text(root.find("./movement-title")) or "Untitled"
    composer = ""
    for creator in root.findall("./identification/creator"):
        if creator.get("type") == "composer":
            composer = _text(creator)
            break

    part_names: Dict[str, str] = {}
    for score_part in root.findall("./part-list/score-part"):
        pid = score_part.get("id") or ""
        part_names[pid] = _text(score_part.find("part-name")) or pid

    parts: Dict[str, List[Bar]] = {}
    timing: Dict[str, object] = {}
    section_marks: List[Tuple[int, str, str]] = []   # (bar index 1-based, raw text, label)

    for part in root.findall("part"):
        pid = part.get("id") or "P1"
        bars: List[Bar] = []
        divisions = 1
        beats, beat_type = 4, 4
        bar_index = 0
        start_quarters = 0.0
        pending_sections: List[str] = []

        for measure in part.findall("measure"):
            bar_index += 1
            measure_number = measure.get("number") or str(bar_index)

            # attributes may appear mid-measure; apply for this bar
            attrs = measure.find("attributes")
            if attrs is not None:
                div_node = attrs.find("divisions")
                if div_node is not None:
                    divisions = max(1, _int(div_node, divisions))
                time_node = attrs.find("time")
                if time_node is not None:
                    beats = _int(time_node.find("beats"), beats)
                    beat_type = _int(time_node.find("beat-type"), beat_type)

            length_quarters = beats * (4.0 / beat_type)
            bar = Bar(index=bar_index, measure_number=measure_number,
                      start_quarters=start_quarters, length_quarters=length_quarters)

            cursor = 0          # in divisions
            chord_order = 0

            # measure-style multiple-rest 只是**排版提示**：Dorico 写「这里压成 5 小节休止」，
            # 但那 5 个 <measure> 通常**都还在文件里**（实测示例谱：46 个 measure、
            # 第 1 个声明 multiple-rest=5，后面 2-5 小节照常写出）。
            # 所以这里**绝不展开** —— 展开了就会凭空多出 4 小节，
            # 后面的休止分类和 ABC 小节会整体错位（2026-10-24 实测发现）。
            multi_rest = 0
            style = measure.find("./attributes/measure-style")
            if style is not None:
                multi_rest = _int(style.find("multiple-rest"))
                if multi_rest > 1:
                    diagnostics.append({
                        "code": "multiple_rest_layout_hint",
                        "detail": "bar %s declares a %d-bar multi-rest; the measures are "
                                  "already present, so nothing was expanded" % (measure_number, multi_rest),
                    })

            for node in list(measure):
                tag = node.tag
                if tag == "harmony":
                    offset_divisions = _int(node.find("offset"))
                    event_quarters = (cursor + offset_divisions) / float(divisions)
                    symbol, meta = _harmony_symbol(node)
                    chord_order += 1
                    bar.chords.append(ChordEvent(
                        offset=max(0.0, event_quarters),
                        symbol=symbol,
                        root=str(meta["root"]),
                        kind=str(meta["kind"]),
                        bass=meta["bass"],
                        verbatim=symbol,
                        position=chord_order,
                    ))
                elif tag == "note":
                    dur = _int(node.find("duration"))
                    is_rest = node.find("rest") is not None
                    is_chord_note = node.find("chord") is not None
                    # accumulate lyrics (any note may carry text)
                    for lyric in node.findall("lyric"):
                        txt = _text(lyric.find("text"))
                        if txt:
                            bar.lyrics = (bar.lyrics + " " + txt).strip()
                    if not is_chord_note:
                        cursor += dur
                    else:
                        # chord tones share the previous onset; no cursor advance
                        pass
                elif tag == "forward":
                    cursor += _int(node.find("duration"))
                elif tag == "backup":
                    cursor -= _int(node.find("duration"))
                elif tag == "direction":
                    for words in node.findall(".//direction-type/words"):
                        raw = _text(words)
                        label = _section_from_text(raw)
                        if label or (raw and 0 < len(raw) <= 24 and not re.search(r"[，,。；;：:]", raw)):
                            section_marks.append((bar_index, raw, label or "Section"))
                elif tag == "rehearsal":
                    raw = _text(node)
                    label = _section_from_text(raw)
                    if raw:
                        section_marks.append((bar_index, raw, label or "Section"))

            # vocal note counting was done per-part; fix for this part id
            if pid != "":
                # recount precisely: notes with <pitch>
                bar.vocal_notes = len(measure.findall(".//note[pitch]"))
                bar.vocal_rest = bar.vocal_notes == 0

            bars.append(bar)
            start_quarters += length_quarters

        parts[pid] = bars

    if not parts:
        raise ValueError("no <part> elements found")

    # align to the first/primary part's bar count; missing bars are reported
    primary = next(iter(parts.values()))
    bar_count = len(primary)
    for pid, bars in parts.items():
        if len(bars) != bar_count:
            diagnostics.append({
                "code": "part_bar_count_mismatch",
                "detail": "part %s has %d bars, primary has %d" % (pid, len(bars), bar_count),
            })

    vocal = _pick_vocal_part(parts, part_names, vocal_part)
    if vocal is None:
        vocal = next(iter(parts))

    # rest classification per bar, using the vocal part vs all other parts
    for idx in range(bar_count):
        vocal_bar = parts[vocal][idx] if idx < len(parts[vocal]) else None
        if vocal_bar is None:
            continue
        other_active = False
        for pid, bars in parts.items():
            if pid == vocal or idx >= len(bars):
                continue
            if bars[idx].vocal_notes > 0:
                other_active = True
                break
        vocal_bar.other_active = other_active
        if vocal_bar.vocal_notes > 0:
            vocal_bar.rest_type = "vocal_active"
            vocal_bar.vocal_rest = False
        else:
            vocal_bar.vocal_rest = True
            if other_active:
                vocal_bar.rest_type = "vocal_rest_instrument_continues"
            elif len(parts) == 1:
                vocal_bar.rest_type = "vocal_rest_unknown_accompaniment"
            else:
                vocal_bar.rest_type = "full_silence"

    # sections: apply to all parts, from mark bar to the bar before the next mark
    section_marks.sort(key=lambda item: item[0])
    # the same marker is usually exported on every part; keep one per bar+label
    deduped: List[Tuple[int, str, str]] = []
    for mark in section_marks:
        if deduped and deduped[-1][0] == mark[0] and deduped[-1][2] == mark[2]:
            continue
        deduped.append(mark)
    section_marks = deduped
    if section_marks:
        spans: List[Section] = []
        for pos, (start, raw, label) in enumerate(section_marks):
            end = (section_marks[pos + 1][0] - 1) if pos + 1 < len(section_marks) else bar_count
            end = max(start, min(end, bar_count))
            spans.append(Section(label=label, raw_label=raw, start_bar=start, end_bar=end))
        # merge consecutive identical Section (unlabeled) marks
        for idx, span in enumerate(spans):
            for bars in parts.values():
                for bar in bars:
                    if span.start_bar <= bar.index <= span.end_bar:
                        bar.section = span.label
        sections = spans
    else:
        sections = []
        diagnostics.append({
            "code": "no_section_markers",
            "detail": "score has no <words>/<rehearsal> markers; section stays null",
        })

    timing = {
        "beats": beats,
        "beat_type": beat_type,
        "bars": bar_count,
        "total_quarters": round(primary[-1].start_quarters + primary[-1].length_quarters, 6),
    }

    return ScoreDoc(
        source_kind="musicxml",
        title=title,
        composer=composer,
        parts=parts,
        sections=sections,
        diagnostics=diagnostics,
        source_sha256=source_sha256,
        bar_count=bar_count,
        vocal_part=vocal,
        timing=timing,
    )


# --------------------------------------------------------------------------
# ABC: structural parse, repair (format only), chord stripping
# --------------------------------------------------------------------------

_ABC_INFO = re.compile(r"^([A-Za-z]):(.*)$")
_ABC_CHORD = re.compile(r'"([^"]*)"')


@dataclass
class AbcDoc:
    info: Dict[str, List[str]]
    order: List[str]
    body_lines: List[str]
    chords: List[str]
    bar_count: int
    warnings: List[str]

    def to_text(self) -> str:
        lines = []
        seen = set()
        for field in ("X", "T", "M", "L", "Q", "K"):
            if field in self.info and field not in seen:
                lines.append("%s:%s" % (field, self.info[field][0]))
                seen.add(field)
        for field in self.order:
            if field in seen:
                continue
            for value in self.info.get(field, []):
                lines.append("%s:%s" % (field, value))
            seen.add(field)
        lines.extend(self.body_lines)
        return "\n".join(lines).rstrip() + "\n"


_VOICE_LINE = re.compile(r"^V:\s*([^\s]+)")


def _split_voices(body_lines: List[str]) -> Dict[str, List[str]]:
    voices: Dict[str, List[str]] = {}
    current = "__default__"
    for line in body_lines:
        match = _VOICE_LINE.match(line)
        if match:
            current = match.group(1)
            voices.setdefault(current, [])
            continue
        voices.setdefault(current, []).append(line)
    return voices


def _main_voice(voices: Dict[str, List[str]]) -> str:
    for name in voices:
        low = name.lower()
        if any(key in low for key in ("vocal", "voice", "melody", "lead", "唱", "人声")):
            return name
    for name, lines in voices.items():
        if any(line.strip() and not line.strip().startswith(("%", "w:")) for line in lines):
            return name
    return next(iter(voices), "__default__")


def _count_bars_in(lines: List[str]) -> int:
    total = 0
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith(("%", "w:")):
            continue
        if _ABC_INFO.match(line):
            continue
        # Z<n> is an n-bar multi-rest (SheetSage2 emits e.g. "Z4|")
        zs = re.findall(r"\bZ(\d*)", stripped)
        if zs:
            for value in zs:
                total += int(value) if value else 1
            stripped = re.sub(r"\bZ\d*\s*\|?", "", stripped)
        total += len(re.findall(r"\|+[\]|:]?", stripped))
    return total


def _count_bars(body: str) -> int:
    """Count bars in the principal (vocal/melody) voice.

    SheetSage2 transcriptions have a second "Ins" voice made of Z4/Z3 rests;
    adding those would double-count the song length.
    """
    voices = _split_voices(body.splitlines())
    return max(0, _count_bars_in(voices.get(_main_voice(voices), [])))


def parse_abc(text: str) -> AbcDoc:
    info: Dict[str, List[str]] = {}
    order: List[str] = []
    body: List[str] = []
    for line in text.splitlines():
        m = _ABC_INFO.match(line)
        if m:
            field, value = m.group(1), m.group(2)
            if field in ("w", "V"):
                # V: is a positional voice marker, not a header field
                body.append(line)
                continue
            info.setdefault(field, []).append(value)
            order.append(field)
        else:
            body.append(line)
    body_text = "\n".join(body)
    chords = _ABC_CHORD.findall("\n".join(
        l for l in body if not l.lstrip().startswith(("%", "w:", "K:"))))
    warnings: List[str] = []
    if "K" not in info:
        warnings.append("missing_k_field")
    if "M" not in info:
        warnings.append("missing_m_field")
    if "L" not in info:
        warnings.append("missing_l_field")
    return AbcDoc(info=info, order=order, body_lines=body,
                  chords=chords, bar_count=_count_bars(body_text),
                  warnings=warnings)


def repair_abc(text: str, condition: Optional[dict] = None,
               write_section_comments: bool = True) -> Tuple[str, List[dict]]:
    """Format-only repair.  Never rewrites a chord symbol.

    Returns (repaired_text, repairs).  Each repair has code/detail.
    """
    repairs: List[dict] = []
    doc = parse_abc(text)

    info = {k: list(v) for k, v in doc.info.items()}
    info.setdefault("X", ["1"])
    info.setdefault("T", [(condition or {}).get("source", {}).get("title") or "Untitled"])
    info.setdefault("M", ["4/4"])
    info.setdefault("L", ["1/8"])
    info.setdefault("Q", ["1/4=120"])
    info.setdefault("K", ["C"])

    for field, default in (("X", "1"), ("T", "Untitled"), ("M", "4/4"),
                           ("L", "1/8"), ("Q", "1/4=120"), ("K", "C")):
        if field not in doc.info:
            repairs.append({"code": "added_field", "detail": "%s:%s" % (field, default)})

    body = [line for line in doc.body_lines]
    # ensure the music does not end without a closing barline
    music_lines = [i for i, line in enumerate(body)
                   if line.strip() and not line.lstrip().startswith(("%", "w:"))
                   and not _ABC_INFO.match(line)]
    if music_lines:
        last = music_lines[-1]
        if not re.search(r"\|\s*(\]|:)?\s*$", body[last]):
            body[last] = body[last].rstrip() + " |]"
            repairs.append({"code": "closed_final_barline", "detail": "appended |]"})

    # section markers lost in conversion: re-attach as comments for the human
    # editor only.  They are NOT a semantic carrier for YuE2 (plan ignores comments).
    if write_section_comments and condition:
        sections = condition.get("sections") or []
        if sections and not any("[Section]" in line for line in body):
            header = ["%% [Section] %s (bar %d-%d)" % (s["label"], s["start_bar"], s["end_bar"])
                      for s in sections]
            # insert after the last info line
            insert_at = 0
            for i, line in enumerate(body):
                if _ABC_INFO.match(line):
                    insert_at = i + 1
            body[insert_at:insert_at] = header
            repairs.append({"code": "restored_section_markers",
                            "detail": "%d section comment(s)" % len(header)})

    repaired = AbcDoc(info=info, order=doc.order, body_lines=body,
                      chords=doc.chords, bar_count=doc.bar_count,
                      warnings=doc.warnings)
    text_out = copyright_header("abc") + repaired.to_text()
    return text_out, repairs


def strip_chords(text: str) -> Tuple[str, List[str]]:
    """Remove chord symbols for cot='melody'.  Returns (text, chords_in_order).

    Lyrics lines (w:) and comments (%) are left alone.  The chord list is
    returned so the caller can prove the human sequence was preserved in
    the condition channel before it is dropped from the melody channel.
    """
    chords: List[str] = []
    lines_out: List[str] = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(("%", "w:")) or _ABC_INFO.match(line):
            lines_out.append(line)
            continue
        found = _ABC_CHORD.findall(line)
        chords.extend(found)
        lines_out.append(_ABC_CHORD.sub("", line))
    return "\n".join(lines_out).rstrip() + "\n", chords


def detect_lost_markers(source_musicxml_text: str, abc_text: str) -> List[str]:
    """Compare human section words in MusicXML against the converted ABC."""
    words = []
    for m in re.finditer(r"<(?:words|rehearsal)>([^<]*)</(?:words|rehearsal)>", source_musicxml_text):
        raw = m.group(1).strip()
        if raw and _section_from_text(raw):
            words.append(raw)
    missing = []
    for raw in words:
        label = _section_from_text(raw)
        if label and label not in abc_text and raw not in abc_text:
            missing.append(raw)
    return missing


# --------------------------------------------------------------------------
# flow orchestrations (what the port-8001 service returns)
# --------------------------------------------------------------------------

def bar_guard(bar_count: int) -> None:
    if bar_count > BAR_GUARD_LIMIT:
        raise ValueError(
            "score has %d bars, above the %d-bar guard; split the score first"
            % (bar_count, BAR_GUARD_LIMIT)
        )


def analyze_flow_b(musicxml_bytes: bytes, abc_text: str,
                   vocal_part: Optional[str] = None) -> dict:
    """Flow-B: MusicXML is the primary source.  ABC is repaired, never rewritten."""
    sha = sha256_bytes(musicxml_bytes)
    doc = parse_musicxml(musicxml_bytes, source_sha256=sha, vocal_part=vocal_part)
    bar_guard(doc.bar_count)
    condition = doc.to_condition_json()

    repaired_abc, repairs = repair_abc(abc_text, condition)
    melody_abc, abc_chords = strip_chords(repaired_abc)

    # consistency audit: the human chord sequence in ABC must be a subsequence
    # of the chord sequence read from MusicXML (same order, same symbols).
    xml_chords = [c.verbatim for bar in doc.parts[doc.vocal_part] for c in bar.chords]
    abc_matches = 0
    for sym in abc_chords:
        if abc_matches < len(xml_chords) and sym == xml_chords[abc_matches]:
            abc_matches += 1
    chord_audit = {
        "xml_chords": len(xml_chords),
        "abc_chords": len(abc_chords),
        "in_order_matches": abc_matches,
        "chords_rewritten": False,
        "note": "ABC chord sequence is compared verbatim against the MusicXML source",
    }

    # compare against the *original* ABC: the repaired copy carries restored
    # section comments, which would hide the very loss we are auditing.
    lost = detect_lost_markers(
        musicxml_bytes.decode("utf-8", "replace"), abc_text)

    return stamp_json({
        "flow": "B",
        "status": "ok",
        "bar_count": doc.bar_count,
        "outputs": {
            "repaired_abc": repaired_abc,
            "melody_abc": melody_abc,
            "structured_condition_json": condition,
        },
        "diagnostics": {
            "repairs": repairs,
            "warnings": doc.diagnostics,
            "lost_section_markers": lost,
            "chord_audit": chord_audit,
            "abc_bar_count": parse_abc(repaired_abc).bar_count,
            "xml_bar_count": doc.bar_count,
        },
        "guarantees": {
            "chords_verbatim": True,
            "chords_in_melody_channel": len(abc_chords),
            "notes_injected": 0,
            "ai_chord_inference": False,
            "harmonic_analysis": False,
        },
    })


def analyze_flow_a(abc_text: str, musicxml_bytes: Optional[bytes] = None) -> dict:
    """Flow-A: AI drafted ABC.  Repair format, extract conditions from the draft."""
    if musicxml_bytes:
        doc = parse_musicxml(musicxml_bytes)
        condition = doc.to_condition_json()
        bar_guard(doc.bar_count)
    else:
        parsed = parse_abc(abc_text)
        bar_guard(parsed.bar_count)
        condition = stamp_json({
            "version": "1.0",
            "source": {"kind": "abc_draft", "title": parsed.info.get("T", ["Untitled"])[0]},
            "channel": "structured_condition_json",
            "note": "Draft ABC has no score surface; section labels come only from ABC text.",
            "bar_count": parsed.bar_count,
            "bars": [],
            "sections": [],
            "summary": {"chord_events": len(parsed.chords),
                        "rest_types": {}, "interlude_bars": []},
            "diagnostics": [{"code": "draft_abc", "detail": "no MusicXML supplied"}],
            "guards": {"bar_limit": BAR_GUARD_LIMIT, "bar_count": parsed.bar_count,
                       "within_limit": parsed.bar_count <= BAR_GUARD_LIMIT,
                       "notes_injected": 0},
        })

    repaired_abc, repairs = repair_abc(abc_text, condition)
    melody_abc, abc_chords = strip_chords(repaired_abc)
    return stamp_json({
        "flow": "A",
        "status": "ok",
        "bar_count": condition.get("bar_count", parse_abc(abc_text).bar_count),
        "outputs": {
            "repaired_abc": repaired_abc,
            "melody_abc": melody_abc,
            "structured_condition_json": condition,
        },
        "diagnostics": {"repairs": repairs, "warnings": []},
        "guarantees": {"chords_verbatim": True,
                       "chords_in_melody_channel": len(abc_chords),
                       "notes_injected": 0, "ai_chord_inference": False},
    })


def analyze_flow_c(transcribed_abc: str, source_audio_sha256: str = "") -> dict:
    """Flow-C: SheetSage2 transcription result -> repair + conditions.

    The heavy audio encoder runs in a child process (see service); this
    function only handles the already-transcribed ABC.
    """
    parsed = parse_abc(transcribed_abc)
    bar_guard(parsed.bar_count)
    condition = stamp_json({
        "version": "1.0",
        "source": {"kind": "sheetsage2_transcription", "sha256": source_audio_sha256},
        "channel": "structured_condition_json",
        "note": "Chords here are model output from audio, not human-authored. "
                "Flow-C must surface them for user edit before rendering.",
        "bar_count": parsed.bar_count,
        "bars": [],
        "sections": [],
        "summary": {"chord_events": len(parsed.chords),
                    "rest_types": {}, "interlude_bars": []},
        "diagnostics": [{"code": "audio_transcription",
                         "detail": "verify against reference before trusting chords"}],
        "guards": {"bar_limit": BAR_GUARD_LIMIT, "bar_count": parsed.bar_count,
                   "within_limit": parsed.bar_count <= BAR_GUARD_LIMIT,
                   "notes_injected": 0},
    })
    repaired_abc, repairs = repair_abc(transcribed_abc, condition)
    melody_abc, chords = strip_chords(repaired_abc)
    return stamp_json({
        "flow": "C",
        "status": "ok",
        "bar_count": parsed.bar_count,
        "outputs": {"repaired_abc": repaired_abc, "melody_abc": melody_abc,
                    "structured_condition_json": condition},
        "diagnostics": {"repairs": repairs},
        "guarantees": {"chords_verbatim": False,
                       "chords_in_melody_channel": len(chords),
                       "notes_injected": 0, "ai_chord_inference": True},
    })
