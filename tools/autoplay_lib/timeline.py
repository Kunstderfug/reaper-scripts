"""Build one global tempo grid, then place immutable recordings on it."""

import math
from bisect import bisect_right

from .evidence import duration, resolve
from .manifest import _verified_manifest, partial_reset_approved
from .tempo import Grid


def compile_manifest(manifest):
    m = manifest
    points, meters, issues = _verified_manifest(m)
    sections = m["sections"]
    plan = {
        "sections": [],
        "tempo_points": [],
        "meter_anchors": [],
        "issues": issues,
        "click_exceptions": m.get("click_exceptions", []),
    }
    if not points:
        return plan
    grid = Grid(points)

    def problem(message):
        if {"message": message} not in issues:
            issues.append({"message": message})

    if plan["click_exceptions"]:
        problem("Custom pulses require rendered click qualification before generation")
    if not sections:
        problem("No sections")
    maps = []
    for s in sections:
        a, b = s["source_start_seconds"], s["source_end_seconds"]
        scale = s["scale"]
        if not (0 <= a < b and math.isfinite(scale) and scale > 0):
            raise ValueError("Invalid source interval or scale")
        holds = []
        for hold in s.get("fermatas", []):
            t = hold["source_seconds"]
            end = hold["source_end_seconds"]
            if not a <= t < end <= b:
                raise ValueError("Fermata interval lies outside source region")
            if ("duration_seconds" in hold) == ("duration_beats" in hold):
                raise ValueError("Choose one fermata duration unit")
            if "duration_seconds" in hold:
                if hold.get("window") not in ("verified_solo", "verified_silent"):
                    problem(
                        "Time-only fermata requires a reviewed solo or silent window"
                    )
                factor = hold["duration_seconds"] / ((end - t) * scale)
            else:
                factor = hold["duration_beats"]
            meter = next(v for v in reversed(meters) if v["time"] <= t)
            if (
                abs(grid.quarter(end) - grid.quarter(t) - 4 / meter["denominator"])
                > 1e-7
            ):
                problem(f"Fermata in {s['key']} must cover one source beat")
            if not (math.isfinite(factor) and factor >= 1):
                raise ValueError("Invalid fermata")
            if not (
                hold.get("approved") is True
                and hold.get("reviewer")
                and hold.get("evidence") in m["fingerprints"]
                and hold.get("window")
                in (
                    "verified_solo",
                    "verified_silent",
                    "compatible_render",
                    "new_render",
                )
            ):
                problem(f"Unreviewed fermata in {s['key']}")
            holds.append((t, end, factor))
        mapped_points, mapped_meters, warp = section_grid(
            points, meters, grid, holds, scale, m, problem
        )
        maps.append((mapped_points, mapped_meters))
        start = warp(s["source_start_seconds"])
        end = warp(s["source_end_seconds"])
        audio = resolve(m, s["audio_path"]) if s.get("audio_path") else None
        opus = resolve(m, s["opus_path"]) if s.get("opus_path") else None
        length = (
            duration(audio) if audio and s["audio_path"] in m["fingerprints"] else 0.0
        )
        obs = s.get("sanity", {})
        authored = obs.get("defaultSectionLength") or 0.0
        end = max(end, start + length, start + authored, s.get("end_seconds", 0))
        for hold in s.get("fermatas", []):
            if warp(hold["source_seconds"]) >= start + length - 1e-9:
                continue
            if hold.get("window") in ("compatible_render", "new_render"):
                if hold.get("approved_duration_beats") != hold.get(
                    "duration_beats"
                ) or hold.get("audio_sha256") != m["fingerprints"].get(s["audio_path"]):
                    problem(
                        f"Fixed recording needs compatible approved mapping for {s['key']}"
                    )
            elif (
                warp(hold["source_seconds"])
                + (hold["source_end_seconds"] - hold["source_seconds"]) * s["scale"]
                < start + length - 1e-8
                or hold.get("window") != "verified_silent"
            ):
                problem(f"Fermata conflicts with fixed recording in {s['key']}")
        lane = 0
        handoff = s.get("handoff_seconds")
        if (
            handoff is None
            and obs.get("autoContinue")
            and obs.get("autoContinueMarker") is not None
        ):
            offset = obs["autoContinueMarker"]
            basis = s.get("decision", {}).get("handoff_basis")
            if basis == "source":
                handoff = warp(s["source_start_seconds"] + offset)
            elif basis == "render":
                handoff = warp(s["source_start_seconds"] + offset / scale)
            else:
                problem(f"Review Sanity handoff time basis for {s['key']}")
        if handoff is not None and not start <= handoff <= end:
            problem(f"Handoff outside region {s['key']}")
        plan["sections"].append(
            dict(
                s,
                start_seconds=start,
                end_seconds=end,
                handoff_seconds=handoff,
                audio_path=str(audio) if audio else None,
                opus_path=str(opus) if opus else None,
                audio_duration_seconds=length,
                lane=lane,
                expected_clicks=[],
            )
        )
    place_sections(plan, maps, m.get("partial_measure_decision", {}), m["fingerprints"])
    return plan


def section_grid(points, meters, grid, holds, scale, m, problem):
    mapped_points, mapped_meters = [], []
    cuts = sorted(set(grid.times + [v for a, b, _ in holds for v in (a, b)]))
    times, factors = [], []
    source_points = {p["time"]: p for p in points}
    for i, t in enumerate(cuts):
        active = [f for a, b, f in holds if a <= t < b]
        if len(active) > 1:
            problem(f"Conflicting tempo mappings at {t}")
        factor = scale * min(active, default=1.0)
        times.append(times[-1] + (t - cuts[i - 1]) * factors[-1] if i else 0.0)
        bpm, shape = grid.at(t)
        if i and factor != factors[-1] and grid.at(cuts[i - 1])[1] == 0:
            problem(
                f"Rate discontinuity at linear ramp endpoint {t} needs compatible mapping"
            )
        factors.append(factor)
        mapped_points.append(
            dict(
                source_points.get(t, {}), time=times[-1], bpm=bpm / factor, shape=shape
            )
        )

    def warp(t):
        i = bisect_right(cuts, t) - 1
        return times[i] + (t - cuts[i]) * factors[i]

    for i, meter in enumerate(meters):
        if i:
            prev = meters[i - 1]
            bars = (
                (grid.quarter(meter["time"]) - grid.quarter(prev["time"]))
                * prev["denominator"]
                / (4 * prev["numerator"])
            )
            if abs(bars - round(bars)) > 1e-6:
                if meter.get("tail", [])[1:2] != ["5"]:
                    problem(
                        f"Unqualified source partial-measure encoding at {meter['time']}"
                    )
                d = m.get("partial_measure_decision", {})
                if not partial_reset_approved(d, m["fingerprints"]):
                    problem(f"Partial measure at {meter['time']} needs approved reset")
        mapped_meters.append(dict(meter, time=warp(meter["time"])))
    return mapped_points, mapped_meters, warp


def place_sections(plan, maps, partial_decision, fingerprints):
    """Splice the reviewed owners' source grids onto the playback timeline."""
    sections = plan["sections"]
    if not sections:
        return
    cuts = [(0.0, 0.0, 0)]  # destination, owner's mapped source time, owner index
    lanes = [0.0, 0.0]
    prior = None

    def issue(message):
        plan["issues"].append({"message": message})

    for idx, s in enumerate(sections):
        old = s["start_seconds"]
        target = old
        bridge = None
        if prior:
            if prior["handoff_seconds"] is not None:
                target = prior["handoff_seconds"] - s.get(
                    "incoming_preparation_seconds", 0.0
                )
            elif "manual_gap_seconds" in s:
                target = prior["end_seconds"] + s["manual_gap_seconds"]
            else:
                min_gap = (
                    max(
                        0.0,
                        s["source_start_seconds"] - prior["source_end_seconds"],
                    )
                    * prior["scale"]
                )
                target, bridge = _snap_manual_target(
                    cuts,
                    maps,
                    s,
                    maps[idx],
                    prior["end_seconds"] + min_gap,
                    partial_decision,
                    fingerprints,
                )
        if (
            not math.isfinite(target)
            or target < 0
            or s.get("incoming_preparation_seconds", 0) < 0
        ):
            issue(f"Invalid preparation or placement for {s['key']}")
            return
        if prior and target <= prior["start_seconds"]:
            issue(f"Non-increasing placement for {s['key']}")
            return
        if bridge is not None:
            t_bar, i_meter, in_bpm0 = bridge
            clean_meter = {
                "time": 0.0,
                "numerator": i_meter["numerator"],
                "denominator": i_meter["denominator"],
            }
            bridge_owner = len(maps)
            maps.append(
                (
                    [{"time": 0.0, "bpm": in_bpm0, "shape": 1}],
                    [clean_meter],
                )
            )
            cuts.append((t_bar, 0.0, bridge_owner))
        shift = target - old
        s["mapped_start_seconds"] = old
        s["mapped_end_seconds"] = s["end_seconds"]
        s["start_seconds"] = target
        s["end_seconds"] += shift
        if s["handoff_seconds"] is not None:
            s["handoff_seconds"] += shift
        overlap = [
            other for other in sections[:idx] if other["end_seconds"] > target + 1e-8
        ]
        boundary = target
        if overlap:
            owner = s.get("overlap_owner")
            if owner == s["key"]:
                boundary = target + s.get("ownership_offset_seconds", 0.0)
                if (
                    not target
                    <= boundary
                    <= min(previous["end_seconds"] for previous in overlap)
                ):
                    issue(f"Grid ownership boundary outside overlap at {target}")
            elif len(overlap) == 1 and owner == prior["key"]:
                boundary = prior["end_seconds"]
            else:
                issue(f"Review grid owner for overlap at {target}")
        if boundary < cuts[-1][0]:
            issue("Grid ownership boundaries cross")
            return
        source_cut = boundary - shift
        if idx:
            cuts.append((boundary, source_cut, idx))
        free = [i for i, end in enumerate(lanes) if end <= target + 1e-9]
        if not free:
            issue(f"Both orchestra lanes occupied at {target}")
        s["lane"] = free[0] if free else 0
        lanes[s["lane"]] = target + s["audio_duration_seconds"]
        prior = s
    terminal = max(s["end_seconds"] for s in sections) + 1
    points, meters = _assemble_grid(
        cuts, maps, terminal, partial_decision, fingerprints, issue
    )
    points = _prune_redundant_points(points, meters)
    plan["tempo_points"], plan["meter_anchors"] = points, meters
    actual = Grid(points)
    for s in sections:
        s["expected_clicks"] = actual.clicks(
            s["start_seconds"], s["end_seconds"], meters
        )


def _assemble_grid(cuts, maps, terminal, partial_decision, fingerprints, issue):
    """Assemble output tempo points and meter anchors across ownership cuts.

    When terminal is None (lookahead mode for manual-gap snapping), the final
    cut runs unbounded to math.inf so all future meter changes in that map
    remain visible on the output timeline.
    """
    points, meters = [], []
    active_cut = None
    source = None
    for i, (dest, origin, owner) in enumerate(cuts):
        mapped_points, mapped_meters = maps[owner]
        source = Grid(mapped_points)
        stop = (
            cuts[i + 1][0]
            if i + 1 < len(cuts)
            else (terminal if terminal is not None else math.inf)
        )
        if stop <= dest:
            continue
        previous_meter = next(m for m in reversed(mapped_meters) if m["time"] <= origin)
        bpm, shape = source.at(origin)
        if points and points[-1]["shape"] == 0 and active_cut is not None:
            prior_origin = active_cut[1] + dest - active_cut[0]
            left_bpm = Grid(maps[active_cut[2]][0]).at(prior_origin)[0]
            t0, b0 = points[-1]["time"], points[-1]["bpm"]
            if abs(left_bpm - b0) <= 1e-7:
                # Flat segment encoded with linear shape; convert to step so it
                # never ramps into the incoming section's BPM.
                points[-1]["shape"] = 1
            elif abs(left_bpm - bpm) > 1e-7:
                span = dest - t0
                if span > 1e-12:
                    eps = min(1e-5, 0.5 * span)
                    # Area-preserving closure BPM so Grid(points).quarter(dest)
                    # equals the outgoing ramp's exact quarter count.
                    close_bpm = (span * left_bpm + eps * b0) / (span + eps)
                    points.append({"time": dest - eps, "bpm": close_bpm, "shape": 1})
                else:
                    issue(f"Incompatible linear tempo endpoints at {dest}")
        exact = next((p for p in mapped_points if p["time"] == origin), {})
        points.append(dict(exact, time=dest, bpm=bpm, shape=shape))
        if not meters:
            meters.append(dict(previous_meter, time=dest))
        else:
            prev = meters[-1]
            phase = (
                (source.quarter(origin) - source.quarter(previous_meter["time"]))
                * previous_meter["denominator"]
                / 4
            )
            outgrid = Grid(points)
            outphase = (
                (outgrid.quarter(dest) - outgrid.quarter(prev["time"]))
                * prev["denominator"]
                / 4
            )
            same = all(
                prev[k] == previous_meter[k] for k in ("numerator", "denominator")
            )
            period = previous_meter["numerator"]
            delta = (phase - outphase) / period
            if abs(phase / period - round(phase / period)) < 1e-7:
                if not same or abs(delta - round(delta)) > 1e-7:
                    meter = dict(previous_meter, time=dest)
                    bars = outphase / prev["numerator"]
                    if abs(bars - round(bars)) > 1e-7:
                        if not partial_reset_approved(partial_decision, fingerprints):
                            issue(f"Unapproved partial-measure reset at {dest}")
                        # Native fixture: PT <seconds> <bpm> 1 <packed meter> 5.
                        fields = list(
                            meter.get(
                                "tail", [str(period + 65536 * meter["denominator"])]
                            )
                        )
                        fields[1:2] = ["5"]
                        meter["tail"] = fields
                    meters.append(meter)
            elif not same or abs(delta - round(delta)) > 1e-7:
                issue(f"Unrepresentable source measure phase at {dest}")
        for collection, result in ((mapped_points, points), (mapped_meters, meters)):
            result.extend(
                dict(v, time=dest + (v["time"] - origin))
                for v in collection
                if origin < v["time"] and dest + (v["time"] - origin) < stop
            )
        active_cut = (dest, origin, owner)
    if (
        terminal is not None
        and active_cut is not None
        and points
        and points[-1]["shape"] == 0
        and points[-1]["time"] < terminal
    ):
        origin = active_cut[1] + terminal - active_cut[0]
        points.append({"time": terminal, "bpm": source.at(origin)[0], "shape": 1})
    return points, meters


def _snap_manual_target(
    cuts, maps, incoming, incoming_map, min_target, partial_decision, fingerprints
):
    """Align a manual-boundary section start to its incoming bar/beat phase.

    Uses the actual assembled output grid and meter anchors (so prior approved
    partial-measure resets and later outgoing meter changes are honoured).
    When the meter changes and the incoming section starts on a pickup
    (i_phase > 0), returns a bridge spec (t_bar, i_meter, in_bpm0) so the new
    meter begins cleanly at the preceding bar line in the silent gap.
    """
    prefix_points, prefix_meters = _assemble_grid(
        cuts, maps, None, partial_decision, fingerprints, lambda _msg: None
    )
    out_grid = Grid(prefix_points)
    i_points, i_meters = incoming_map
    i_grid = Grid(i_points)
    i_origin = incoming["start_seconds"]
    i_meter = next(m for m in reversed(i_meters) if m["time"] <= i_origin)
    i_barq = i_meter["numerator"] * 4.0 / i_meter["denominator"]
    i_phase = (i_grid.quarter(i_origin) - i_grid.quarter(i_meter["time"])) % i_barq
    if abs(i_phase) < 1e-7 or abs(i_phase - i_barq) < 1e-7:
        i_phase = 0.0
    in_bpm0 = i_grid.at(i_origin)[0]
    mi = max(
        idx for idx, m in enumerate(prefix_meters) if m["time"] <= min_target + 1e-9
    )
    for k in range(mi, len(prefix_meters)):
        m = prefix_meters[k]
        next_t = prefix_meters[k + 1]["time"] if k + 1 < len(prefix_meters) else None
        m_barq = m["numerator"] * 4.0 / m["denominator"]
        q_anchor = out_grid.quarter(m["time"])
        q_lo = out_grid.quarter(max(min_target, m["time"]))
        if (m["numerator"], m["denominator"]) == (
            i_meter["numerator"],
            i_meter["denominator"],
        ):
            bars = max(0, math.ceil((q_lo - q_anchor - i_phase) / m_barq - 1e-9))
            t_target = out_grid.seconds(q_anchor + bars * m_barq + i_phase)
            if next_t is None or t_target < next_t - 1e-9:
                return t_target, None
        else:
            bars = max(0, math.ceil((q_lo - q_anchor) / m_barq - 1e-9))
            t_bar = out_grid.seconds(q_anchor + bars * m_barq)
            if next_t is not None and t_bar >= next_t - 1e-9:
                continue
            if i_phase == 0.0:
                return t_bar, None
            t_target = t_bar + i_phase * 60.0 / in_bpm0
            return t_target, (t_bar, i_meter, in_bpm0)
    raise ValueError(f"Could not snap manual target for {incoming['key']}")


def _prune_redundant_points(points, meters):
    """Drop interior constant-BPM duplicates without meter anchors or tail flags."""
    if len(points) <= 2:
        return points
    meter_times = {m["time"] for m in meters}
    kept = [points[0]]
    for i in range(1, len(points) - 1):
        prev, cur, nxt = kept[-1], points[i], points[i + 1]
        if (
            cur["time"] not in meter_times
            and not cur.get("tail")
            and abs(cur["bpm"] - prev["bpm"]) < 1e-9
            and abs(cur["bpm"] - nxt["bpm"]) < 1e-9
        ):
            continue
        kept.append(cur)
    kept.append(points[-1])
    return kept
