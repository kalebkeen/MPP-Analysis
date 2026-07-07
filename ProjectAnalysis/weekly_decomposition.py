"""
Weekly change decomposition (K -> M -> Meeting bridge analysis).

WHY
---
Each weekly update cycle produces up to three schedules that differ only by the
edits layered on top of each other:

    K file       this week's % complete / actuals posted   (what reality did)
    M file       this week's reschedule on top of K         (what the planner chose)
    Meeting file adjustments agreed in the meeting on top of M  (what the team decided)

They share ONE data (status) date, so the longitudinal trend keeps exactly one
datapoint per week -- the *last* sub-state (normally the Meeting file). This
module adds a diagnostic layer underneath that datapoint: for any scalar metric
(project completion, a building's turnover), the values at the ordered sub-states
difference EXACTLY to the week's net move, with no residual:

    net (last week's canonical -> this week's canonical)
       = (this K       - last canonical)   progress contribution
       + (this M       - this K)           reschedule contribution
       + (this Meeting - this M)           meeting contribution

So the magnitudes are rigorous; "which task caused it" is the descriptive top
movers inside each sub-delta. The driving path is also traced at each sub-state
and set-differenced, which is how we see the controlling path shift between K, M
and Meeting.

SCOPE (recommended tier)
------------------------
  * completion-date waterfall (per week)
  * per-building turnover waterfalls (per week)
  * driving-path membership change table (K vs M vs Meeting)
  * causal narrative fed to Stage M synthesis

INTEGRATION
-----------
  * Stage C parquet stem == XML filename stem (extract_snapshots.py:557), so the
    folder token appended by the MPP-Pipeline naming fix is parseable here.
  * The longitudinal stages keep using critical_path.discover_snapshots; its
    same-date de-dup tie-break (critical_path.py:282-289) is upgraded to keep the
    highest stage rank (the Meeting file) instead of merely the largest file.
  * This module consumes the RAW (un-deduped) snapshot list so it can see every
    sub-state, groups it into weekly cycles, and computes the decomposition.

The pure helpers below (token parsing, week bucketing, cycle grouping) are fully
determined by the naming convention and are unit-tested. The metric/decomposition
engine is validated against real extracted weeks (see Phase 0 checklist in
Weekly_Decomposition_Design.md) before it is wired into the stage runner.
"""

from __future__ import annotations

import re
from datetime import date, timedelta

# Default stage ranking for the K -> M -> Meeting cycle. Overridable via
# config["weekly_decomposition"]["stage_order"] because other projects use
# different letters (New Town's files carry "J ..." / "M ..." / "- Meeting").
# Higher rank == later in the week; the highest-ranked present sub-state is the
# canonical datapoint for that week.
DEFAULT_STAGE_ORDER = {"K": 1, "M": 2, "Meeting": 3, "post": 4}
UNKNOWN_RANK = 0


def parse_stage_token(stem: str):
    """Classify a snapshot stem into a cycle stage label.

    Recognizes both naming conventions:
      * MPP-Pipeline naming fix (folder token appended):  "... K file",
        "... M file", "... Meeting file"
      * New Town legacy:  leading "K "/"M "/"J ", or a "- Meeting" suffix
      * post-meeting / buyout revisions:  "post" / "buyout" anywhere

    Returns a label string ("K", "M", "Meeting", "post", or a raw single letter
    like "J") or None when nothing matches. Case-insensitive.
    """
    s = stem.lower()

    # A post-meeting / buyout revision is the LATEST edit of the week, so it must
    # be detected BEFORE "meeting" (the stem usually still contains "meeting").
    if "buyout" in s or re.search(r"\bpost[\s\-_]*meeting\b", s):
        return "post"
    # Otherwise "meeting" wins over a stage letter: a "Meeting file" or
    # "- Meeting" stem is the meeting version regardless of any stray letter.
    if "meeting" in s:
        return "Meeting"

    # "<letter> file"  (Harrison folder-token form)
    m = re.search(r"\b([kmj])\s*file\b", s)
    if m:
        return m.group(1).upper()

    # leading "<letter> " or "<letter>-" (New Town prefix form)
    m = re.match(r"\s*([kmj])[\s\-_]", s)
    if m:
        return m.group(1).upper()

    return None


def resolve_stage_rank(label, stage_order=None):
    """Map a stage label to its ordering rank. Unknown/None -> UNKNOWN_RANK."""
    order = stage_order or DEFAULT_STAGE_ORDER
    if label is None:
        return UNKNOWN_RANK
    return order.get(label, UNKNOWN_RANK)


def week_bounds_sunday_saturday(d: date):
    """Return (week_start_sunday, week_end_saturday) for the week containing d.

    Weeks run Sunday -> Saturday. Python weekday(): Mon=0 .. Sun=6.
    Days since the most recent Sunday = (weekday + 1) % 7.
    """
    days_since_sunday = (d.weekday() + 1) % 7
    start = d - timedelta(days=days_since_sunday)
    end = start + timedelta(days=6)
    return start, end


def week_label(d: date):
    """Human label for the Sun-Sat week containing d, keyed by its Saturday."""
    _, end = week_bounds_sunday_saturday(d)
    return f"week ending {end.isoformat()}"


def group_into_weekly_cycles(records, stage_order=None):
    """Group snapshot records into ordered weekly cycles.

    `records`: iterable of dicts with at least:
        stem  (str)          -- parquet/file stem, carries the stage token
        date  (datetime.date)-- the snapshot's data/status date

    Returns a list (ascending by week) of dicts:
        {
          week_start, week_end, week_label,
          substates: [ {stem, date, stage, rank}, ... ]  ordered K->M->Meeting,
          canonical_stem: stem of the highest-ranked sub-state (the datapoint),
          data_date_consistent: bool  -- True if all sub-states share one date,
          stages_present: [labels...],
        }

    Ties in rank (e.g. two files that both parse as "M") fall back to date then
    stem so ordering is deterministic. Unknown-stage files sort first (rank 0).
    """
    order = stage_order or DEFAULT_STAGE_ORDER
    weeks = {}
    for r in records:
        d = r["date"]
        start, end = week_bounds_sunday_saturday(d)
        stage = parse_stage_token(r["stem"])
        rank = resolve_stage_rank(stage, order)
        weeks.setdefault(end, []).append({
            "stem": r["stem"],
            "date": d,
            "stage": stage,
            "rank": rank,
        })

    cycles = []
    for end in sorted(weeks):
        subs = sorted(weeks[end], key=lambda x: (x["rank"], x["date"], x["stem"]))
        start = end - timedelta(days=6)
        dates = {x["date"] for x in subs}
        cycles.append({
            "week_start": start,
            "week_end": end,
            "week_label": f"week ending {end.isoformat()}",
            "substates": subs,
            "canonical_stem": subs[-1]["stem"],
            "data_date_consistent": len(dates) == 1,
            "stages_present": [x["stage"] for x in subs],
        })
    return cycles


# ---------------------------------------------------------------------------
# Metric / decomposition engine  --  wired in after Phase 0 validation against
# real extracted Harrison weeks (see Weekly_Decomposition_Design.md). Signatures
# are fixed here so the stage runner and report layer can be built against them.
# ---------------------------------------------------------------------------

def compute_metrics_at(tasks_path, preds_path, cfg):
    """Compute the decomposition metric vector for ONE sub-state snapshot.

    Reuses the existing engines rather than reimplementing them:
      * project completion  -> forward_look progress-curve / milestone finish
      * per-building turnover -> forward_look.build_turnover (buyout-excluded)
      * driving-path uid set -> critical_path.trace_driving_path

    Returns {completion: Timestamp, turnover: {building: Timestamp},
             driving_path: set[uid]}.
    """
    raise NotImplementedError("Phase 2 — implement against real extracted weeks")


def decompose_week(prev_canonical_metrics, cycle_metrics):
    """Difference ordered sub-state metric vectors into per-source contributions.

    `cycle_metrics`: ordered [ (label, metrics), ... ] for this week's sub-states.
    Returns, for completion and each building turnover, the contribution of each
    sub-delta (progress/reschedule/meeting/post) plus the net, which sum exactly;
    and for the driving path, the tasks entering/leaving at each sub-delta.
    """
    raise NotImplementedError("Phase 2 — implement against real extracted weeks")
