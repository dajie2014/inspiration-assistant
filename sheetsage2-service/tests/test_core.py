#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for the deterministic SheetSage2 x YuE2 score semantics layer.

Copyright (c) 2026 Jie Da / Inspiration-Assistant
SheetSage2 x YuE2 Integration - local, non-commercial research use only.

Run:  python3 -m unittest discover -s tests -v
"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "fixtures"))

import ss2core as C
import gen_fixture


SAMPLE_ABC = """X:1
T:Interlude test
M:4/4
L:1/8
Q:1/4=120
K:C
"C"C2 D2 E2 F2 | "G/B"G4 z4 | "Am"A2 B2 c2 B2 | "F"F4 z4 |
"C"C2 D2 E2 F2 | "Dm"D4 z4 | "Em"E4 z4 | "F"F4 z4 |
"G"G4 z4 | "Am"A4 z4 | "Dm"D4 z4 | "G"G4 z4 |
"F"F2 G2 A2 B2 | "G"c2 B2 A2 G2 | "C"c4 z4 | "C"C4 z4 |]
"""


class MusicXMLFlowBTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.xml_bytes = gen_fixture.build().encode("utf-8")
        cls.condition = C.parse_musicxml(cls.xml_bytes).to_condition_json()
        cls.bars = cls.condition["bars"]

    def test_bar_count(self):
        self.assertEqual(self.condition["bar_count"], 16)
        self.assertEqual(len(self.bars), 16)
        self.assertTrue(self.condition["guards"]["within_limit"])

    def test_multiple_rest_is_not_expanded_twice(self):
        """Dorico 的 <multiple-rest> 只是排版提示，后面的小节都写出来了。

        2026-10-24 用真实示例谱踩到：第 1 小节写 multiple-rest=5，
        而 measure 2-5 确实在文件里。展开会让 46 小节变成 50 小节。
        """
        measures = []
        for n in range(1, 6):
            attrs = ('<attributes><divisions>4</divisions>'
                     '<time><beats>4</beats><beat-type>4</beat-type></time>'
                     + ('<measure-style><multiple-rest>5</multiple-rest></measure-style>'
                        if n == 1 else '')
                     + '</attributes>')
            measures.append('<measure number="%d">%s<forward><duration>16</duration></forward></measure>'
                            % (n, attrs))
        xml = ('<score-partwise><part-list><score-part id="P1"><part-name>Lead</part-name>'
               '</score-part></part-list><part id="P1">' + "".join(measures) + '</part></score-partwise>')
        doc = C.parse_musicxml(xml.encode())
        self.assertEqual(doc.bar_count, 5)
        self.assertTrue(any(d["code"] == "multiple_rest_layout_hint" for d in doc.diagnostics))
        self.assertEqual(sum(b.notes_injected for b in doc.parts[doc.vocal_part]), 0)

    def test_human_chords_are_verbatim(self):
        expect = ["C", "G/B", "Am", "F", "C", "Dm", "Em", "F",
                  "G", "Am", "Dm", "G", "F", "G", "C", "C"]
        got = [bar["chords"][0]["verbatim"] for bar in self.bars]
        self.assertEqual(got, expect)

    def test_interlude_bars_are_vocal_rest_with_instrument(self):
        interlude = [b for b in self.bars if b["section"] == "Interlude"]
        self.assertEqual([b["index"] for b in interlude], list(range(5, 13)))
        for bar in interlude:
            self.assertTrue(bar["vocal"]["rest"])
            self.assertEqual(bar["vocal"]["rest_type"], "vocal_rest_instrument_continues")
            # the human chord is present in the interlude
            self.assertEqual(len(bar["chords"]), 1)

    def test_no_hidden_notes_injected(self):
        for bar in self.bars:
            self.assertEqual(bar["notes_injected"], 0)
        self.assertEqual(self.condition["guards"]["notes_injected"], 0)
        # the vocal bar 5 carries a measure rest, not a long pitch
        self.assertEqual(self.bars[4]["vocal"]["notes"], 0)

    def test_sections(self):
        labels = [(s["label"], s["start_bar"], s["end_bar"]) for s in self.condition["sections"]]
        self.assertEqual(labels, [("Verse", 1, 4), ("Interlude", 5, 12), ("Chorus", 13, 16)])
        self.assertEqual(self.condition["summary"]["interlude_bars"], list(range(5, 13)))

    def test_flow_b_audit_melody_has_no_chords(self):
        result = C.analyze_flow_b(self.xml_bytes, SAMPLE_ABC)
        self.assertEqual(result["flow"], "B")
        self.assertIn('"C"', result["outputs"]["repaired_abc"])
        self.assertNotIn('"C"', result["outputs"]["melody_abc"])
        self.assertNotIn('"', result["outputs"]["melody_abc"])
        audit = result["diagnostics"]["chord_audit"]
        self.assertFalse(audit["chords_rewritten"])
        self.assertEqual(audit["xml_chords"], 16)
        self.assertEqual(audit["abc_chords"], 16)
        self.assertEqual(result["guarantees"]["notes_injected"], 0)
        self.assertFalse(result["guarantees"]["ai_chord_inference"])
        self.assertTrue(result["outputs"]["repaired_abc"].startswith("% Copyright"))


class MusicXMLRealSampleTests(unittest.TestCase):
    def test_mini_sample(self):
        path = Path("/Users/jieda/Documents/deepseek-harness/default-workspace/tmp/musicxml-test/mini.xml")
        if not path.exists():
            self.skipTest("mini.xml not on this machine")
        doc = C.parse_musicxml(path.read_bytes())
        self.assertEqual(doc.bar_count, 4)
        chords = [b.chords[0].verbatim for b in doc.parts[doc.vocal_part] if b.chords]
        self.assertEqual(chords, ["C", "G", "Am", "F"])

    def test_dorico_export_with_words(self):
        path = Path("/Users/jieda/Documents/deepseek-harness/default-workspace/tmp/musicxml-test/lead.xml")
        if not path.exists():
            self.skipTest("lead.xml not on this machine")
        doc = C.parse_musicxml(path.read_bytes())
        self.assertGreater(doc.bar_count, 100)
        self.assertTrue(any(b.chords for b in doc.parts[doc.vocal_part]))


class ABCRepairTests(unittest.TestCase):
    def test_header_repair(self):
        text = "K:C\nC D E F"          # no closing barline at all
        repaired, repairs = C.repair_abc(text)
        self.assertTrue(repaired.startswith("% Copyright"))
        for field in ("X:", "T:", "M:", "L:", "Q:", "K:"):
            self.assertIn(field, repaired)
        codes = {r["code"] for r in repairs}
        self.assertIn("added_field", codes)
        self.assertIn("closed_final_barline", codes)
        # a bare '|' ending is already legal: do not add a second barline
        legal, _ = C.repair_abc("K:C\nC D E F |")
        self.assertNotIn("|]", legal)

    def test_strip_chords_preserves_lyrics(self):
        text = 'X:1\nT:x\nK:C\n"C"C2 D2 |\nw: 一 二 |'
        melody, chords = C.strip_chords(text)
        self.assertEqual(chords, ["C"])
        self.assertNotIn('"C"', melody)
        self.assertIn("w: 一 二", melody)

    def test_voice_aware_bar_count(self):
        text = ("X:1\nM:4/4\nL:1/8\nK:C\n"
                "V: Vocal\nC4 D4 E4 F4 | G4 A4 B4 c4 |\n"
                "V: Ins\nZ4|\nZ2|")
        self.assertEqual(C.parse_abc(text).bar_count, 2)

    def test_multi_rest_counted_in_vocal(self):
        text = "X:1\nM:4/4\nL:1/8\nK:C\nV: Vocal\nC4 | Z4 | D4 |"
        self.assertEqual(C.parse_abc(text).bar_count, 6)

    def test_lost_section_marker_detected(self):
        lost = C.detect_lost_markers(
            "<words>Interlude</words>" * 1, "X:1\nK:C\nC4 |]")
        self.assertEqual(lost, ["Interlude"])

    def test_bar_guard(self):
        many = "X:1\nK:C\n" + "".join("C4 |" for _ in range(251))
        with self.assertRaises(ValueError):
            C.analyze_flow_a(many)

    def test_flow_a_has_copyright_and_no_chords_in_melody(self):
        result = C.analyze_flow_a(SAMPLE_ABC)
        self.assertEqual(result["flow"], "A")
        self.assertEqual(result["_copyright"], C.COPYRIGHT_LINE)
        self.assertNotIn('"', result["outputs"]["melody_abc"])
        self.assertIn('"', result["outputs"]["repaired_abc"])

    def test_flow_c_marks_model_chords(self):
        result = C.analyze_flow_c(SAMPLE_ABC, source_audio_sha256="abc123")
        self.assertEqual(result["flow"], "C")
        self.assertTrue(result["guarantees"]["ai_chord_inference"])
        self.assertEqual(result["outputs"]["structured_condition_json"]["source"]["kind"],
                         "sheetsage2_transcription")


if __name__ == "__main__":
    unittest.main(verbosity=2)
