import json
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from autoplay_lib import compile_manifest, prepare_manifest, write_project
from autoplay_lib.tempo import Grid


class CoreTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "src").write_text(
            "<REAPER_PROJECT\n  TEMPO 100 2 4 0\n"
            '  MARKER 1 0 "marker" 0\n  MARKER 1 0 S 9\n  MARKER 1 2.4 "" 1\n>\n'
        )
        (self.root / "template").write_text(
            "<REAPER_PROJECT\n"
            + "".join(
                f'  <TRACK {{x{i}}}\n    NAME "{name}"\n    MAINSEND 1 0\n  >\n'
                for i, name in enumerate(("", "", "CLICKS"))
            )
            + "  CUSTOM 42\n>\n"
        )
        obs = {"_key": "s", "name": "S", "defaultTempo": 100, "defaultSectionLength": 3}
        score = {
            "_id": "id",
            "_rev": "rev",
            "slug": {"current": "x"},
            "pathName": "X",
            "movements": [{"_key": "m", "index": 1, "sections": [obs]}],
        }
        (self.root / "snapshot").write_text(json.dumps(score))
        media = self.root / "AUDIO/S/X_1_S_100.wav"
        media.parent.mkdir(parents=True)
        with wave.open(str(media), "wb") as w:
            w.setparams((1, 2, 8000, 0, "NONE", ""))
            w.writeframes(bytes(8000))
        opus = self.root / "CLICKDATA/X_1_S_100.opus"
        opus.parent.mkdir()
        subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(media), "-c:a", "libopus", str(opus)],
            check=True,
        )
        self.m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        self.s = self.m["sections"][0]
        self.s.update(
            decision={
                "approved": True,
                "reviewer": "author",
                "evidence": "src",
                "source_to_render_scale": 1,
                "audio_sha256": self.m["fingerprints"][self.s["audio_path"]],
            },
        )

    def test_rebuild(self):
        h = dict(
            source_seconds=0.6,
            source_end_seconds=1.2,
            duration_beats=2,
            window="verified_solo",
            **self.s["decision"],
        )
        self.s["fermatas"] = [h]
        for value, bpm, restore in ((2, 50, 1.8), (3, 100 / 3, 2.4)):
            h["duration_beats"] = value
            plan = compile_manifest(self.m)
            self.assertFalse(plan["issues"])
            self.assertAlmostEqual(plan["tempo_points"][1]["bpm"], bpm)
            self.assertAlmostEqual(plan["tempo_points"][2]["time"], restore)
            self.assertEqual(
                plan["sections"][0]["expected_clicks"][2],
                {"time": round(1000 * restore), "beat": 1},
            )
        h["source_seconds"] = 0
        self.assertTrue(compile_manifest(self.m)["issues"])

    def test_output(self):
        plan = compile_manifest(self.m)
        s = plan["sections"][0]
        self.assertEqual((s["end_seconds"], s["audio_duration_seconds"]), (3, 0.5))
        out = self.root / "out.rpp"
        first = write_project(self.m, plan, out)
        self.assertEqual(first, write_project(self.m, plan, out))
        for field in (
            "SOFFS 0",
            "PLAYRATE 1",
            "CUSTOM 42",
            "SOURCE CLICK",
            "TIMELOCKMODE 1",
        ):
            self.assertIn(field, out.read_text())
        out.write_text("edited")
        with self.assertRaisesRegex(ValueError, "receipt"):
            write_project(self.m, plan, out)

    def test_compound_and_ramp_cut(self):
        g = Grid(
            [{"time": 0, "bpm": 60, "shape": 0}, {"time": 2, "bpm": 120, "shape": 1}]
        )
        self.assertEqual(g.at(1), (90, 0))
        self.assertEqual(g.quarter(1), 1.25)
        self.assertAlmostEqual(g.seconds(1.25), 1)
        clicks = g.clicks(1, 2.2, [{"time": 0, "numerator": 6, "denominator": 8}])
        self.assertEqual(clicks[0]["beat"], 4)
        self.assertEqual(clicks[-1], {"time": 1000, "beat": 1})

    def add_regions(self, regions, first_observation=None):
        p = self.root / "src"
        p.write_text(
            p.read_text().rsplit(">", 1)[0]
            + "".join(
                f'  MARKER {i} {a} {name} 9\n  MARKER {i} {b} "" 1\n'
                for i, (a, b, name) in enumerate(regions, 2)
            )
            + ">\n"
        )
        snap = self.root / "snapshot"
        score = json.loads(snap.read_text())
        score["movements"][0]["sections"][0].update(first_observation or {})
        for _, _, name in regions:
            score["movements"][0]["sections"].append(
                {"_key": name, "name": name, "defaultTempo": 100}
            )
        snap.write_text(json.dumps(score))
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        for s in m["sections"]:
            s.update(
                audio_path=self.s["audio_path"],
                opus_path=self.s["opus_path"],
                decision=self.s["decision"].copy(),
            )
        return m

    def test_handoff_rebuild_places_incoming(self):
        m = self.add_regions(
            [(12, 14, "B")], {"autoContinue": True, "autoContinueMarker": 2.4}
        )
        a, b = m["sections"]
        a["decision"]["handoff_basis"] = "source"
        b["overlap_owner"] = b["key"]
        h = dict(
            source_seconds=0.6,
            source_end_seconds=1.2,
            duration_beats=2,
            window="verified_solo",
            **a["decision"],
        )
        a["fermatas"] = [h]
        for factor, start in ((2, 3.0), (3, 3.6)):
            h["duration_beats"] = factor
            plan = compile_manifest(m)
            self.assertFalse(plan["issues"])
            self.assertAlmostEqual(plan["sections"][1]["start_seconds"], start)
            self.assertAlmostEqual(plan["sections"][0]["handoff_seconds"], start)
            self.assertEqual(
                plan["sections"][1]["expected_clicks"][0], {"time": 0, "beat": 1}
            )

    def test_partial_reset_and_third_lane(self):
        m = self.add_regions([(1.2, 2.4, "B"), (2.4, 3.6, "C")])
        a, b, c = m["sections"]
        a["handoff_seconds"] = 0.1
        b["handoff_seconds"] = 1.3
        b["overlap_owner"] = b["key"]
        c["overlap_owner"] = c["key"]
        issues = compile_manifest(m)["issues"]
        self.assertTrue(any("Both orchestra lanes" in i["message"] for i in issues))
        self.assertTrue(any("partial-measure reset" in i["message"] for i in issues))

    def test_incoming_owns_grid_during_outgoing_tail(self):
        src = self.root / "src"
        src.write_text(
            src.read_text().rsplit(">", 1)[0]
            + "  <TEMPOENVEX\n    PT 0 100 1\n    PT 12 200 1\n  >\n>\n"
        )
        m = self.add_regions([(12, 15, "B")])
        a, b = m["sections"]
        a["end_seconds"] = 3.6
        a["handoff_seconds"] = 1.2
        for owner, interval in (("B", 300), ("s", 600)):
            b["overlap_owner"] = owner
            plan = compile_manifest(m)
            self.assertFalse(plan["issues"])
            self.assertEqual(
                plan["sections"][1]["expected_clicks"][1]["time"], interval
            )

    def test_uniform_mapping_pickup(self):
        src = self.root / "src"
        src.write_text(
            src.read_text().replace("1 0 S 9", "1 .3 S 9").rsplit(">", 1)[0]
            + "  <TEMPOENVEX\n    PT 0 100 0\n    PT 3 200 1\n  >\n>\n"
        )
        m = self.add_regions([])
        s = m["sections"][0]
        s["scale"] = 2
        s["decision"]["source_to_render_scale"] = 2
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"])
        self.assertAlmostEqual(plan["sections"][0]["start_seconds"], 0.6)
        grid = Grid(plan["tempo_points"])
        self.assertAlmostEqual(grid.at(0.6)[0], 55)
        self.assertEqual(plan["sections"][0]["expected_clicks"][0]["beat"], 2)

    def test_time_only_hold(self):
        self.s["fermatas"] = [
            dict(
                source_seconds=0.6,
                source_end_seconds=1.2,
                duration_seconds=1.8,
                window="verified_solo",
                **self.s["decision"],
            )
        ]
        plan = compile_manifest(self.m)
        self.assertFalse(plan["issues"])
        self.assertEqual(
            plan["sections"][0]["expected_clicks"][2], {"time": 2400, "beat": 1}
        )

    def test_native_partial_fixture_encoding(self):
        from autoplay_lib.manifest import source_data

        path = self.root / "partial.rpp"
        path.write_text(
            "<REAPER_PROJECT\n  TEMPO 120 4 4\n  <TEMPOENVEX\n"
            "    PT 0 120 1 262148 1\n    PT .75 120 1 262148 5\n  >\n>\n"
        )
        points, meters, _ = source_data(path)
        clicks = Grid(points).clicks(0, 2, meters)
        self.assertEqual(
            [(c["time"], c["beat"]) for c in clicks],
            [(0, 1), (500, 2), (750, 1), (1250, 2), (1750, 3)],
        )

    def test_region_extends_to_full_decoded_media(self):
        media = self.root / self.s["audio_path"]
        with wave.open(str(media), "wb") as w:
            w.setparams((1, 2, 8000, 0, "NONE", ""))
            w.writeframes(bytes(64000))
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        s = m["sections"][0]
        s["decision"] = dict(
            self.s["decision"], audio_sha256=m["fingerprints"][s["audio_path"]]
        )
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"])
        self.assertEqual(plan["sections"][0]["end_seconds"], 4)
        out = self.root / "full.rpp"
        write_project(m, plan, out)
        self.assertIn("LENGTH 4.0", out.read_text())
        self.assertIn("SOURCE OPUS", out.read_text())

    def test_changed_observations_block_generation(self):
        self.s["sanity"]["defaultSectionLength"] = 1
        with self.assertRaisesRegex(ValueError, "snapshot"):
            compile_manifest(self.m)

    def test_configured_sanity_identity(self):
        self.m["sanity"].update(
            project_id="project", dataset="production", api_version="v1"
        )
        self.assertFalse(compile_manifest(self.m)["issues"])
        self.m["sanity"]["revision"] = "other"
        with self.assertRaisesRegex(ValueError, "snapshot"):
            compile_manifest(self.m)

    def test_unmodeled_timing_preserves_inventory_and_blocks_output(self):
        from autoplay_lib import questions
        from autoplay_lib.manifest import source_data

        src = self.root / "src"
        original = src.read_text().rsplit(">", 1)[0]
        for pt, message in (
            ("PT 1 90 0", "timestamp"),
            ('PT 2 100 1 262148 1 3 0 "" 0 169 0 ABBB', "metadata"),
            ('PT 2 100 1 0 1 1 0 "" 0 0 0 A.', "click pattern"),
            ('PT 2 100 1 262148 1 1 0 "" 0 1 0 ABBB', "encoded click"),
            ("PT 2 100 3", "shape"),
        ):
            with self.subTest(pt=pt):
                src.write_text(
                    original + f"  <TEMPOENVEX\n  PT 1 95 0\n  {pt}\n  >\n>\n"
                )
                with self.assertRaisesRegex(ValueError, message):
                    source_data(src)
                m = prepare_manifest("src", "template", "snapshot", "m", self.root)
                self.assertEqual(
                    m["sections"][0]["audio_candidates"], self.s["audio_candidates"]
                )
                self.assertEqual(
                    m["raw_source_timing"], ["TEMPO 100 2 4 0", "PT 1 95 0", pt]
                )
                self.assertEqual(m["source_tempo_points"], [])
                issue = m["source_timing_issues"][0]
                self.assertEqual(issue["raw"], pt)
                self.assertEqual(
                    src.read_text().splitlines()[issue["line"] - 1].strip(), pt
                )
                self.assertIn(issue, questions(m))
                plan = compile_manifest(m)
                self.assertIn(issue, plan["issues"])
                self.assertFalse(plan["tempo_points"])
                del m["source_timing_issues"]
                with self.assertRaisesRegex(ValueError, "timing evidence"):
                    compile_manifest(m)

    def override_fixture(self, pt="PT 1 90 1"):
        from autoplay_lib.manifest import timing_review_sha256

        src = self.root / "src"
        src.write_text(
            src.read_text().rsplit(">", 1)[0]
            + f"  <TEMPOENVEX\n    PT 1 95 0\n    {pt}\n  >\n>\n"
        )
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        m["sections"][0]["decision"] = self.s["decision"].copy()
        override = m["source_timing_override"] = {
            "points": [{"time": 0, "bpm": 120, "shape": 1}],
            "meter_anchors": [{"time": 0, "numerator": 3, "denominator": 8}],
            "approved": True,
            "reviewer": "test author",
            "evidence": "snapshot",
        }
        override["approved_sha256"] = timing_review_sha256(m)
        return m

    def load_saved(self, m):
        from autoplay_lib import load_manifest

        path = self.root / "movement.json"
        path.write_text(json.dumps(m))
        return load_manifest(path, require_approved=True)

    def test_approved_override_builds_from_saved_manifest(self):
        from autoplay_lib.manifest import source_data, timing_review_sha256

        src = self.root / "src"
        original = src.read_bytes()
        for pt in ("PT 1 90 1", 'PT 2 100 1 0 1 1 0 "" 0 0 0 A.'):
            with self.subTest(pt=pt):
                src.write_bytes(original)
                m = self.override_fixture(pt)
                source = src.read_bytes()
                override = m["source_timing_override"]
                for bpm, interval in ((120, 250), (60, 500)):
                    override["points"][0]["bpm"] = bpm
                    override["approved_sha256"] = timing_review_sha256(m)
                    plan = compile_manifest(self.load_saved(m))
                    self.assertFalse(plan["issues"])
                    self.assertEqual(
                        plan["sections"][0]["expected_clicks"][1],
                        {"time": interval, "beat": 2},
                    )
                    out = self.root / f"output-{len(pt)}-{bpm}.rpp"
                    write_project(m, plan, out)
                    points, meters, _ = source_data(out)
                    self.assertEqual(points[0]["bpm"], bpm)
                    self.assertEqual(
                        (meters[0]["numerator"], meters[0]["denominator"]), (3, 8)
                    )
                self.assertEqual(src.read_bytes(), source)
                with self.assertRaises(ValueError):
                    source_data(src)

    def test_unapproved_stale_or_invalid_override_blocks(self):
        from copy import deepcopy
        from autoplay_lib import questions
        from autoplay_lib.manifest import timing_review_sha256

        m = self.override_fixture()
        for patch, renew in [
            ({"approved": False}, False),
            ({"reviewer": " "}, False),
            ({"evidence": "missing"}, False),
            ({"approved_sha256": "0" * 64}, False),
            ({"points": [{"time": 0, "bpm": 110, "shape": 1}]}, False),
            ({"points": [{"time": 0, "bpm": 0, "shape": 1}]}, True),
            ({"points": [{"time": 0, "bpm": 90, "shape": True}]}, True),
            ({"points": m["source_timing_override"]["points"] * 2}, True),
            ({"meter_anchors": [{"time": 1, "numerator": 2, "denominator": 4}]}, True),
            ({"meter_anchors": [{"time": 0, "numerator": 2, "denominator": 3}]}, True),
            (
                {
                    "points": m["source_timing_override"]["points"]
                    + [{"time": 3, "bpm": 110, "shape": 1}]
                },
                True,
            ),
        ]:
            with self.subTest(patch=patch):
                edited = deepcopy(m)
                edited["source_timing_override"].update(patch)
                if renew:
                    edited["source_timing_override"]["approved_sha256"] = (
                        timing_review_sha256(edited)
                    )
                self.assertIn(m["source_timing_issues"][0], questions(edited))
                self.assertFalse(compile_manifest(edited)["tempo_points"])
                with self.assertRaisesRegex(ValueError, "source_timing_override"):
                    self.load_saved(edited)

    def test_override_rechecks_pinned_source_and_regions(self):
        from copy import deepcopy

        m = self.override_fixture()
        for check in (compile_manifest, self.load_saved):
            for key in ("raw_source_timing", "source_timing_issues"):
                edited = deepcopy(m)
                del edited[key]
                with self.assertRaisesRegex(ValueError, "timing evidence"):
                    check(edited)
            edited = deepcopy(m)
            edited["sections"][0]["source_end_seconds"] = 3
            with self.assertRaisesRegex(ValueError, "Region differs"):
                check(edited)
        src = self.root / "src"
        src.write_text(src.read_text().replace("PT 1 95", "PT 1 96"))
        for check in (compile_manifest, self.load_saved):
            with self.assertRaisesRegex(ValueError, "Evidence changed"):
                check(m)

    def test_version_gate(self):
        for version in (2, True, "1"):
            self.m["version"] = version
            for check in (compile_manifest, self.load_saved):
                with self.assertRaisesRegex(ValueError, "manifest version"):
                    check(self.m)

    def test_reviewed_override_partial_reset_round_trips(self):
        from autoplay_lib.manifest import source_data, timing_review_sha256

        m = self.override_fixture()
        o = m["source_timing_override"]
        o["points"].append({"time": 0.375, "bpm": 120, "shape": 1})
        anchor = dict(o["meter_anchors"][0], time=0.375)
        o["meter_anchors"].append(anchor)
        o["approved_sha256"] = timing_review_sha256(m)
        anchor["reset"] = True
        with self.assertRaisesRegex(ValueError, "reviewed grid"):
            self.load_saved(m)
        o["approved_sha256"] = timing_review_sha256(m)
        with self.assertRaisesRegex(ValueError, "approved reset"):
            self.load_saved(m)
        m["partial_measure_decision"] = dict(
            policy="reset", approved=True, reviewer="editor", evidence="snapshot"
        )
        plan = compile_manifest(self.load_saved(m))
        self.assertFalse(plan["issues"])
        out = self.root / "reset.rpp"
        write_project(m, plan, out)
        points, meters, _ = source_data(out)
        self.assertEqual(meters[1]["tail"], ["524291", "5"])
        self.assertIn({"time": 375, "beat": 1}, Grid(points).clicks(0, 1, meters))
        self.assertNotIn("tail", anchor)

    def test_mp3_source_emits_gapless_flag(self):
        from autoplay_lib.rpp import item

        base = {
            "key": "s",
            "region_name": "X_1_S_100",
            "start_seconds": 0.0,
            "end_seconds": 1.0,
            "audio_duration_seconds": 1.0,
            "audio_path": "AUDIO/S/X_1_S_100.mp3",
            "opus_path": str(self.root / self.s["opus_path"]),
        }
        mp3_lines = "\n".join(item(base, "orchestra"))
        self.assertIn("<SOURCE MP3", mp3_lines)
        self.assertIn('FILE "AUDIO/S/X_1_S_100.mp3" 1', mp3_lines)

        wav_lines = "\n".join(item(dict(base, audio_path="AUDIO/S/X_1_S_100.wav"), "orchestra"))
        self.assertIn("<SOURCE WAVE", wav_lines)
        self.assertIn('FILE "AUDIO/S/X_1_S_100.wav"\n', wav_lines)

        opus_lines = "\n".join(item(base, "opus"))
        self.assertIn("<SOURCE OPUS", opus_lines)
        self.assertNotIn('.opus" 1', opus_lines)

    def test_audit_rpp_integrity_catches_playback_bugs(self):
        from autoplay_lib.evaluate import audit_rpp_integrity

        mp3_path = self.root / "AUDIO/S/X_1_S_100.mp3"
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-v", "error", "-i",
                str(self.root / self.s["audio_path"]),
                "-c:a", "libmp3lame", "-q:a", "4", str(mp3_path),
            ],
            check=True,
        )
        (self.root / self.s["audio_path"]).unlink()
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        s = m["sections"][0]
        s["decision"] = dict(
            self.s["decision"], audio_sha256=m["fingerprints"][s["audio_path"]]
        )
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"])
        out = self.root / "mp3_check.rpp"
        write_project(m, plan, out)
        # Clean built project passes
        audit_rpp_integrity(out, plan)
        clean = out.read_text()
        # Legacy MP3 flag 0 rejected
        bad = self.root / "bad.rpp"
        bad.write_text(clean.replace('.mp3" 1', '.mp3" 0'))
        with self.assertRaisesRegex(ValueError, "gapless flag"):
            audit_rpp_integrity(bad, plan)
        # Omitted MP3 flag rejected
        bad.write_text(clean.replace('.mp3" 1', '.mp3"'))
        with self.assertRaisesRegex(ValueError, "gapless flag"):
            audit_rpp_integrity(bad, plan)
        # Stretched PLAYRATE rejected
        bad.write_text(clean.replace("PLAYRATE 1 ", "PLAYRATE 1.0141 ", 1))
        with self.assertRaisesRegex(ValueError, "Stretched media item"):
            audit_rpp_integrity(bad, plan)
        # Non-zero SOFFS rejected
        bad.write_text(clean.replace("      SOFFS 0\n", "      SOFFS 0.05\n", 1))
        with self.assertRaisesRegex(ValueError, "SOFFS"):
            audit_rpp_integrity(bad, plan)
        # Drifted orchestra POSITION rejected (mutate specifically the orchestra MP3 item)
        mp3_idx = clean.index(".mp3")
        item_start = clean.rindex("    <ITEM", 0, mp3_idx)
        pos_idx = clean.index("POSITION 0.0\n", item_start)
        bad.write_text(
            clean[:pos_idx]
            + "POSITION 0.04063\n"
            + clean[pos_idx + len("POSITION 0.0\n") :]
        )
        with self.assertRaisesRegex(ValueError, "Orchestra item position drift"):
            audit_rpp_integrity(bad, plan)
        # Missing OPUS reference item rejected
        opus_idx = clean.index("<SOURCE OPUS")
        opus_item_start = clean.rindex("    <ITEM", 0, opus_idx)
        opus_item_end = clean.index("\n    >", opus_idx) + len("\n    >")
        bad.write_text(clean[:opus_item_start] + clean[opus_item_end:])
        with self.assertRaisesRegex(ValueError, "Missing OPUS reference item"):
            audit_rpp_integrity(bad, plan)
        # Wrong project TIMELOCKMODE rejected
        bad.write_text(clean.replace("  TIMELOCKMODE 1\n", "  TIMELOCKMODE 0\n", 1))
        with self.assertRaisesRegex(ValueError, "TIMELOCKMODE 1"):
            audit_rpp_integrity(bad, plan)
        # Missing media path rejected (prevents REAPER Missing Files modal)
        bad.write_text(clean.replace("X_1_S_100.mp3", "NONEXISTENT.mp3"))
        with self.assertRaisesRegex(ValueError, "Unresolved media path"):
            audit_rpp_integrity(bad, plan)

    def test_manual_gap_snaps_to_incoming_bar_phase(self):
        # Section B starts on Beat 2 (source time 12.6s at 100 BPM in 2/4 -> phase 1 beat).
        m = self.add_regions([(12.6, 15.0, "B")])
        for sec in m["sections"]:
            sec["scale"] = 1.2
            sec["decision"]["source_to_render_scale"] = 1.2
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"], plan["issues"])
        # Section B must start on Beat 2 cleanly!
        self.assertEqual(plan["sections"][1]["expected_clicks"][0], {"time": 0, "beat": 2})

    def test_manual_gap_meter_change_on_beat_one(self):
        # Section S is 2/4 at 100 BPM; Section B switches to 3/4 at 120 BPM on Beat 1.
        snap = self.root / "snapshot"
        score = json.loads(snap.read_text())
        score["movements"][0]["sections"].append(
            {"_key": "B", "name": "B", "defaultTempo": 120}
        )
        snap.write_text(json.dumps(score))
        src = self.root / "src"
        src.write_text(
            "<REAPER_PROJECT\n  TEMPO 100 2 4 0\n"
            "  <TEMPOENVEX\n"
            "    PT 0 100 1 262146 1\n"
            "    PT 6 120 1 262147 1\n"
            "  >\n"
            '  MARKER 1 0 S 9\n  MARKER 1 2.4 "" 1\n'
            '  MARKER 2 6 B 9\n  MARKER 2 9 "" 1\n>\n'
        )
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        for sec in m["sections"]:
            sec.update(
                audio_path=self.s["audio_path"],
                opus_path=self.s["opus_path"],
                decision=self.s["decision"].copy(),
            )
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"], plan["issues"])
        self.assertEqual(
            [c["beat"] for c in plan["sections"][1]["expected_clicks"][:4]],
            [1, 2, 3, 1],
        )
        self.assertFalse(
            any(a.get("tail", [])[1:2] == ["5"] for a in plan["meter_anchors"])
        )

    def test_manual_gap_meter_change_with_pickup(self):
        # Section S is in 2/4 (100 BPM, source 6.0..8.4) and Section B (following S across
        # a manual gap) is in 3/4 (120 BPM, source 1.0..4.0 = Beat 3 pickup).
        # At min_target after S, the outgoing timeline is still 2/4 with no later 3/4,
        # so _snap_manual_target must bridge a clean 3/4 anchor at t_bar before B's Beat-3 entry.
        snap = self.root / "snapshot"
        score = json.loads(snap.read_text())
        score["movements"][0]["sections"].append(
            {"_key": "B", "name": "B", "defaultTempo": 120, "defaultSectionLength": 3}
        )
        snap.write_text(json.dumps(score))
        src = self.root / "src"
        src.write_text(
            "<REAPER_PROJECT\n  TEMPO 120 3 4 0\n"
            "  <TEMPOENVEX\n"
            "    PT 0 120 1 262147 1\n"
            "    PT 6 100 1 262146 1\n"
            "  >\n"
            '  MARKER 1 6 S 9\n  MARKER 1 8.4 "" 1\n'
            '  MARKER 2 1 B 9\n  MARKER 2 4 "" 1\n>\n'
        )
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        for sec in m["sections"]:
            sec.update(
                audio_path=self.s["audio_path"],
                opus_path=self.s["opus_path"],
                decision=self.s["decision"].copy(),
            )
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"], plan["issues"])
        # Section B starts at Beat 3 (0 ms), followed by Bar 2 Beat 1 (500 ms), Beat 2 (1000 ms), Beat 3 (1500 ms).
        self.assertEqual(
            plan["sections"][1]["expected_clicks"][:4],
            [
                {"time": 0, "beat": 3},
                {"time": 500, "beat": 1},
                {"time": 1000, "beat": 2},
                {"time": 1500, "beat": 3},
            ],
        )
        # Bridge 3/4 meter anchor must sit cleanly at t_bar (1.0 s before B's Beat-3 entry) with no reset flag.
        bridge_anchors = [
            a
            for a in plan["meter_anchors"]
            if (a["numerator"], a["denominator"]) == (3, 4)
            and a["time"] > plan["sections"][0]["start_seconds"]
        ]
        self.assertEqual(len(bridge_anchors), 1)
        self.assertAlmostEqual(
            bridge_anchors[0]["time"],
            plan["sections"][1]["start_seconds"] - 1.0,
            places=9,
        )
        self.assertFalse(
            any(a.get("tail", [])[1:2] == ["5"] for a in plan["meter_anchors"])
        )

    def test_manual_gap_snaps_after_partial_measure_reset(self):
        # Earlier approved partial reset between S and B shifts output bar lines;
        # manual gap to C must anchor to the actual output meter, not the source meter.
        snap = self.root / "snapshot"
        score = json.loads(snap.read_text())
        score["movements"][0]["sections"][0].update(
            {"autoContinue": True, "autoContinueMarker": 0.9, "defaultSectionLength": 1.2}
        )
        score["movements"][0]["sections"].extend(
            [
                {"_key": "B", "name": "B", "defaultTempo": 100, "defaultSectionLength": 1.2},
                {"_key": "C", "name": "C", "defaultTempo": 100, "defaultSectionLength": 1.2},
            ]
        )
        snap.write_text(json.dumps(score))
        src = self.root / "src"
        src.write_text(
            "<REAPER_PROJECT\n  TEMPO 100 2 4 0\n"
            '  MARKER 1 0 S 9\n  MARKER 1 1.2 "" 1\n'
            '  MARKER 2 2.4 B 9\n  MARKER 2 3.6 "" 1\n'
            '  MARKER 3 6.6 C 9\n  MARKER 3 7.8 "" 1\n>\n'
        )
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        for sec in m["sections"]:
            sec.update(
                audio_path=self.s["audio_path"],
                opus_path=self.s["opus_path"],
                decision=dict(self.s["decision"], handoff_basis="source"),
            )
        m["sections"][1]["overlap_owner"] = "B"
        m["partial_measure_decision"] = {
            "policy": "reset",
            "approved": True,
            "reviewer": "author",
            "evidence": "src",
        }
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"], plan["issues"])
        # Exactly one partial-measure reset (at B's handoff 0.9 s), none at C's manual gap.
        resets = [a for a in plan["meter_anchors"] if a.get("tail", [])[1:2] == ["5"]]
        self.assertEqual(len(resets), 1)
        self.assertAlmostEqual(resets[0]["time"], 0.9, places=9)
        # C starts at source 6.6s (Beat 2 in 2/4 at 100 BPM) -> must land on Beat 2 on output grid.
        self.assertEqual(plan["sections"][2]["expected_clicks"][0], {"time": 0, "beat": 2})

    def test_manual_gap_snaps_across_later_meter_change(self):
        # Outgoing section S starts in 2/4 (0..2.4s), then the source map changes to 3/4 at 3.6s.
        # Manual gap from S (end 3.0s) with min_gap = 0.4s -> min_target = 3.4s (just before 3.6s meter change).
        # B is in 3/4 starting on Beat 2 (source 4.2s) -> snap must cross the 3.6s meter change and land cleanly in 3/4.
        snap = self.root / "snapshot"
        score = json.loads(snap.read_text())
        score["movements"][0]["sections"].append(
            {"_key": "B", "name": "B", "defaultTempo": 100, "defaultSectionLength": 1.8}
        )
        snap.write_text(json.dumps(score))
        src = self.root / "src"
        src.write_text(
            "<REAPER_PROJECT\n  TEMPO 100 2 4 0\n"
            "  <TEMPOENVEX\n"
            "    PT 0 100 1 262146 1\n"
            "    PT 3.6 100 1 262147 1\n"
            "  >\n"
            '  MARKER 1 0 S 9\n  MARKER 1 2.4 "" 1\n'
            '  MARKER 2 4.2 B 9\n  MARKER 2 6.0 "" 1\n>\n'
        )
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        for sec in m["sections"]:
            sec.update(
                audio_path=self.s["audio_path"],
                opus_path=self.s["opus_path"],
                decision=self.s["decision"].copy(),
            )
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"], plan["issues"])
        # B enters on Beat 2 of 3/4 at 0 ms, then Beat 3 at 600 ms, Beat 1 at 1200 ms.
        self.assertEqual(
            plan["sections"][1]["expected_clicks"][:3],
            [
                {"time": 0, "beat": 2},
                {"time": 600, "beat": 3},
                {"time": 1200, "beat": 1},
            ],
        )
        self.assertFalse(
            any(a.get("tail", [])[1:2] == ["5"] for a in plan["meter_anchors"])
        )

    def test_linear_ramp_closes_cleanly_at_section_boundary(self):
        # Section S ramps linearly from 150->60 BPM over [0, 3] (slope -30 BPM/s).
        # At handoff dest=2.0s: outgoing BPM is 90 and exact quarter count is 2*(150+90)/120 = 4.0 QN (bar 3, Beat 1).
        # Section B starts at source 5.75s (quarter = 8.0 QN = bar 5, Beat 1) at 120 BPM.
        # No partial-measure approval is supplied or needed.
        src = self.root / "src"
        src.write_text(
            "<REAPER_PROJECT\n  TEMPO 150 2 4 0\n"
            "  <TEMPOENVEX\n    PT 0 150 0\n    PT 3 60 1\n    PT 5.75 120 1\n  >\n"
            '  MARKER 1 0 S 9\n  MARKER 1 2.5 "" 1\n'
            '  MARKER 2 5.75 B 9\n  MARKER 2 8.0 "" 1\n>\n'
        )
        snap = self.root / "snapshot"
        score = json.loads(snap.read_text())
        score["movements"][0]["sections"][0].update(
            {"autoContinue": True, "autoContinueMarker": 2.0}
        )
        score["movements"][0]["sections"].append(
            {"_key": "B", "name": "B", "defaultTempo": 120}
        )
        snap.write_text(json.dumps(score))
        m = prepare_manifest("src", "template", "snapshot", "m", self.root)
        for sec in m["sections"]:
            sec.update(
                audio_path=self.s["audio_path"],
                opus_path=self.s["opus_path"],
                decision=dict(self.s["decision"], handoff_basis="source"),
            )
        m["sections"][1]["overlap_owner"] = "B"
        plan = compile_manifest(m)
        self.assertFalse(plan["issues"], plan["issues"])
        # No partial-measure reset flag ("5") should be inserted.
        self.assertFalse(
            any(a.get("tail", [])[1:2] == ["5"] for a in plan["meter_anchors"])
        )
        pts = plan["tempo_points"]
        dest_idx = next(i for i, p in enumerate(pts) if abs(p["time"] - 2.0) < 1e-9)
        self.assertAlmostEqual(pts[dest_idx]["bpm"], 120.0, places=9)
        # Closure point sits at dest - 1e-5 with step shape (1) and outgoing ~90 BPM.
        close_pt = pts[dest_idx - 1]
        self.assertAlmostEqual(close_pt["time"], 2.0 - 1e-5, places=9)
        self.assertEqual(close_pt["shape"], 1)
        self.assertAlmostEqual(close_pt["bpm"], 90.0, places=3)
        # Point before closure is the linear ramp start (shape 0); no ramp leads into 120 BPM.
        self.assertEqual(pts[dest_idx - 2]["shape"], 0)
        self.assertNotEqual(pts[dest_idx - 1]["shape"], 0)
        # Integrated quarter count at dest=2.0 matches the outgoing ramp's exact 4.0 QN within 1e-9.
        self.assertAlmostEqual(Grid(pts).quarter(2.0), 4.0, places=9)
