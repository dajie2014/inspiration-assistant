#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate a Dorico-style MusicXML fixture for Flow-B interlude testing.

Copyright (c) 2026 Jie Da / Inspiration-Assistant
SheetSage2 x YuE2 Integration - local, non-commercial research use only.

16 bars, 4/4, divisions 480:
  bars 1-4   Verse      vocal sings, human chords C / G/B / Am / F
  bars 5-12  Interlude  vocal rest (measure rest), piano keeps playing,
                        human chords written on every interlude bar
  bars 13-16 Chorus     vocal sings again

The fixture deliberately has *no* hidden long notes on the vocal staff.
"""
from pathlib import Path

DIV = 480
HERE = Path(__file__).resolve().parent


def note(step, octave, dur=DIV, lyric=None, rest=False, print_object=None):
    parts = ["<note%s>" % (' print-object="no"' if print_object else "")]
    if rest:
        parts.append('<rest measure="yes"/>')
    else:
        parts.append("<pitch><step>%s</step><octave>%s</octave></pitch>" % (step, octave))
    parts.append("<duration>%d</duration>" % dur)
    parts.append("<voice>1</voice><type>quarter</type>")
    if lyric:
        parts.append("<lyric number=\"1\"><syllabic>single</syllabic><text>%s</text></lyric>" % lyric)
    parts.append("</note>")
    return "".join(parts)


def harmony(step, kind, alter=0, bass=None, bass_alter=0):
    out = ["<harmony><root><root-step>%s</root-step>" % step]
    if alter:
        out.append("<root-alter>%d</root-alter>" % alter)
    out.append("</root><kind>%s</kind>" % kind)
    if bass:
        out.append("<bass><bass-step>%s</bass-step>" % bass)
        if bass_alter:
            out.append("<bass-alter>%d</bass-alter>" % bass_alter)
        out.append("</bass>")
    out.append("</harmony>")
    return "".join(out)


def direction(text):
    return ("<direction placement=\"above\"><direction-type><words>%s</words>"
            "</direction-type></direction>" % text)


VOCAL_CHORDS = [
    (1, "C", "major", 0, None, 0), (2, "G", "major", 0, "B", 0),
    (3, "A", "minor", 0, None, 0), (4, "F", "major", 0, None, 0),
    (5, "C", "major", 0, None, 0), (6, "D", "minor", 0, None, 0),
    (7, "E", "minor", 0, None, 0), (8, "F", "major", 0, None, 0),
    (9, "G", "major", 0, None, 0), (10, "A", "minor", 0, None, 0),
    (11, "D", "minor", 0, None, 0), (12, "G", "major", 0, None, 0),
    (13, "F", "major", 0, None, 0), (14, "G", "major", 0, None, 0),
    (15, "C", "major", 0, None, 0), (16, "C", "major", 0, None, 0),
]

VOCAL_MELODY = {1: [("C", 4, "一"), ("D", 4, "二"), ("E", 4, "三"), ("F", 4, "四")],
                2: [("G", 4, "五"), ("A", 4, "六"), ("B", 4, "七"), ("C", 5, "八")],
                3: [("C", 5, None), ("B", 4, None), ("A", 4, None), ("G", 4, None)],
                4: [("F", 4, None), ("E", 4, None), ("D", 4, None), ("C", 4, None)],
                13: [("F", 4, None), ("G", 4, None), ("A", 4, None), ("B", 4, None)],
                14: [("C", 5, None), ("B", 4, None), ("A", 4, None), ("G", 4, None)],
                15: [("C", 5, None), ("G", 4, None), ("E", 4, None), ("C", 4, None)],
                16: [("C", 4, None), ("E", 4, None), ("G", 4, None), ("C", 5, None)]}


def build():
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" '
           '"http://www.musicxml.org/dtds/partwise.dtd">',
           '<score-partwise version="4.0">',
           '<work><work-title>Flow-B Interlude fixture</work-title></work>',
           '<identification><creator type="composer">Jie Da</creator>'
           '<encoding><software>Dorico 6 fixture</software></encoding></identification>',
           '<part-list>',
           '<score-part id="P1"><part-name>Vocal</part-name></score-part>',
           '<score-part id="P2"><part-name>Piano</part-name></score-part>',
           '</part-list>']

    chords = {bar: (step, kind, alter, bass, balter) for bar, step, kind, alter, bass, balter in VOCAL_CHORDS}
    labels = {1: "Verse", 5: "Interlude", 13: "Chorus"}

    for pid in ("P1", "P2"):
        out.append('<part id="%s">' % pid)
        for bar in range(1, 17):
            out.append('<measure number="%d">' % bar)
            if bar == 1:
                out.append('<attributes><divisions>%d</divisions>'
                           '<key><fifths>0</fifths><mode>major</mode></key>'
                           '<time><beats>4</beats><beat-type>4</beat-type></time>'
                           '<clef><sign>%s</sign><line>%d</line></clef></attributes>'
                           % (DIV, "G" if pid == "P1" else "F", 2 if pid == "P1" else 4))
            if bar in labels:
                out.append(direction(labels[bar]))
            step, kind, alter, bass, balter = chords[bar]
            out.append(harmony(step, kind, alter, bass, balter))

            if pid == "P1":
                melody = VOCAL_MELODY.get(bar)
                if melody:
                    for n_step, octave, lyric in melody:
                        out.append(note(n_step, octave, DIV, lyric=lyric))
                else:
                    # vocal rest: a measure rest, no hidden long note
                    out.append(note(None, None, DIV * 4, rest=True, print_object=True))
            else:
                # piano keeps the instrument going through the interlude
                for n_step, octave in (("C", 3), ("E", 3), ("G", 3), ("C", 4)):
                    out.append(note(n_step, octave, DIV))
            out.append('</measure>')
        out.append('</part>')

    out.append('</score-partwise>')
    return "\n".join(out)


if __name__ == "__main__":
    path = HERE / "dorico-interlude.musicxml"
    path.write_text(build(), encoding="utf-8")
    print(path)
