"""
Stage M — Quality Control and Executive Review Prep
====================================================
Two-part stage:

Part 1 — Mechanical QC (always runs)
  1. UID persistence — task survival rate across all snapshots
  2. Rename detection — tasks whose name changed mid-project (by UID)
  3. Name-vs-UID cross-check — name-based bucket totals vs per-UID roll-up (target: within ~1%)
  4. Negative-variance buildings — buckets tracking shorter than baseline
  5. Zero-baseline lines — tasks with no saved baseline span (show n/a for %)

Outputs: stage_m/qc_report.json
         stage_m/uid_renames.parquet
         stage_m/bucket_crosscheck.parquet

Part 2 — Opus synthesis (runs when --synthesize flag is set)
  Calls claude-opus-4-8 via the Anthropic API with the QC findings + stage
  outputs, and generates:
    - questions_for_next_review   (4-6 project-specific items)
    - watch_list                  (resources/scopes most likely to drive future slip)
    - data_quality_notes          (for Part V of the brief)
    - scope_gaps                  (what's out of scope and what would close the gap)

Synthesis output is written to:
  stage_m/synthesis.json
  stage_j/narrative.json  (merged under synthesis keys; creates the file if
                            it doesn't exist, updates without overwriting
                            existing keys if it does)

Usage:
  python run_qc.py [--config project_config.json]
  python run_qc.py --config project_config.json --synthesize
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd
import numpy as np


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_config(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


def parse_segments(outline_number) -> list[str]:
    """Split an MS Project outline number ('1.1.2.3') into segments."""
    if outline_number is None:
        return []
    s = str(outline_number).strip()
    if s == "" or s.lower() == "none" or s.lower() == "nan":
        return []
    return s.split(".")


def is_buyout_outline(outline_number, buyout_prefixes) -> bool:
    """True if outline_number equals, or is a descendant of, ANY prefix in
    buyout_prefixes. Segment-aware (so outline '1.23' never wrongly matches
    prefix '1.2' the way a naive string .startswith() would) and supports
    multiple disjoint buyout branches, since buyout packages are often
    added to the schedule after construction work already exists, so they
    don't all sit under one contiguous UID range or even one outline branch."""
    segs = parse_segments(outline_number)
    if not segs:
        return False
    for prefix in buyout_prefixes:
        pseg = parse_segments(prefix)
        if pseg and segs[:len(pseg)] == pseg:
            return True
    return False


def _parquet(path):
    return pd.read_parquet(path) if Path(path).exists() else pd.DataFrame()


def _pct(n, d):
    return round(n / d * 100, 2) if d else None


# ---------------------------------------------------------------------------
# Check 1 — UID persistence across all snapshots
# ---------------------------------------------------------------------------

def check_uid_persistence(output_root, cfg):
    """
    Recompute UID persistence directly from Stage C parquets.
    Returns a dict with the full breakdown.
    Reads the extraction_report.json shortcut first — falls back to
    scanning all parquets if not present.
    """
    # Fast path: Stage C already computed this
    report_path = output_root / "stage_c" / "extraction_report.json"
    if report_path.exists():
        rpt = json.loads(report_path.read_text())
        uid_stats = rpt.get("uid_persistence", {})
        if uid_stats.get("uid_persistence_pct") is not None:
            threshold = cfg.get("qc", {}).get("uid_persistence_warn_threshold_pct", 1.0)
            pct = uid_stats["uid_persistence_pct"]
            result = {
                "source": "extraction_report.json",
                "baseline_uid_count":   uid_stats.get("baseline_uid_count"),
                "persistent_uid_count": uid_stats.get("persistent_uid_count"),
                "uid_persistence_pct":  pct,
                "rename_count":         uid_stats.get("rename_count"),
                "warn": pct < (100.0 - threshold),
                "harrison_reference":   99.8,
            }
            return result

    # Slow path: scan all snapshot parquets
    snap_dir = output_root / "stage_c" / "snapshots"
    parquets = sorted(snap_dir.glob("*.parquet")) if snap_dir.exists() else []
    if not parquets:
        return {"error": "No Stage C snapshots found.", "uid_persistence_pct": None}

    frames = []
    for p in parquets:
        df = pd.read_parquet(p, columns=["uid", "name"])
        df["snapshot"] = p.stem
        frames.append(df)
    combined = pd.concat(frames, ignore_index=True)
    first_uids = set(combined[combined["snapshot"] == frames[0]["snapshot"].iloc[0]]["uid"])
    uid_counts = combined.groupby("uid")["snapshot"].nunique()
    n_snaps = combined["snapshot"].nunique()
    persistent = uid_counts[uid_counts == n_snaps].index
    pct = _pct(len(persistent), len(first_uids))
    threshold = cfg.get("qc", {}).get("uid_persistence_warn_threshold_pct", 1.0)

    return {
        "source": "scanned",
        "snapshots_scanned": n_snaps,
        "baseline_uid_count": len(first_uids),
        "persistent_uid_count": len(persistent),
        "uid_persistence_pct": pct,
        "warn": pct is not None and pct < (100.0 - threshold),
        "harrison_reference": 99.8,
    }


# ---------------------------------------------------------------------------
# Check 2 — Rename detection
# ---------------------------------------------------------------------------

def check_renames(output_root):
    """
    Find UIDs whose task name changed across snapshots.
    Returns a summary dict and a DataFrame of renamed UIDs.
    Harrison reference: 86 of 1,798 tasks were renamed.
    """
    snap_dir = output_root / "stage_c" / "snapshots"
    parquets = sorted(snap_dir.glob("*.parquet")) if snap_dir.exists() else []
    if not parquets:
        return {"error": "No Stage C snapshots found."}, pd.DataFrame()

    frames = []
    for p in parquets:
        df = pd.read_parquet(p, columns=["uid", "name"])
        df["snapshot"] = p.stem
        frames.append(df)
    combined = pd.concat(frames, ignore_index=True)

    uid_name_counts = combined.groupby("uid")["name"].nunique()
    renamed_uids = uid_name_counts[uid_name_counts > 1].index

    # For renamed UIDs, get first name, last name, and count of distinct names
    rename_rows = []
    for uid in renamed_uids:
        history = combined[combined["uid"] == uid].sort_values("snapshot")
        names = list(history["name"].unique())
        rename_rows.append({
            "uid":          int(uid),
            "first_name":   history.iloc[0]["name"],
            "last_name":    history.iloc[-1]["name"],
            "distinct_names": len(names),
            "first_snapshot": history.iloc[0]["snapshot"],
            "last_snapshot":  history.iloc[-1]["snapshot"],
        })
    renames_df = pd.DataFrame(rename_rows)

    total_uids = combined["uid"].nunique()
    result = {
        "total_unique_uids":   total_uids,
        "renamed_uid_count":   len(renamed_uids),
        "rename_rate_pct":     _pct(len(renamed_uids), total_uids),
        "harrison_reference":  "86 of 1,798",
        "note": ("Renamed tasks are followed through the rename by UID — "
                 "a name-based method would lose continuity on these."),
    }
    return result, renames_df


# ---------------------------------------------------------------------------
# Check 3 — Name-based vs UID-based bucket cross-check
# ---------------------------------------------------------------------------

def check_bucket_crosscheck(output_root, cfg):
    """
    Compare the Stage E name-based bucket net_variance against a UID-based
    recomputation from the latest Stage C snapshot.

    Name-based roll-up (Stage E): groups tasks by name within bucket,
    computes span between earliest/latest dates.

    UID-based roll-up: uses the raw duration fields per UID, climbs parent
    UIDs to resolve the bucket, sums absolute variances directly.

    If totals are within ~1% the approach is consistent.  A larger gap signals
    either rename-driven double-counting or UID tree inconsistencies.
    """
    # Stage E name-based totals
    e_bucket = _parquet(output_root / "stage_e" / "bucket_summary.parquet")
    if e_bucket.empty:
        return {"error": "Stage E bucket_summary not found. Run Stage E first."}

    # Latest Stage C snapshot
    snap_dir = output_root / "stage_c" / "snapshots"
    parquets = sorted(snap_dir.glob("*.parquet")) if snap_dir.exists() else []
    if not parquets:
        return {"error": "No Stage C snapshots found."}

    latest = pd.read_parquet(parquets[-1])
    buyout_prefixes = cfg["schedule"]["buyout_outline_prefixes"]
    buckets_cfg = cfg["construction_variance"]["buckets"]
    bucket_lookup = {b.strip().lower(): b for b in buckets_cfg}

    # Build parent map and name map
    parent_map, name_map = {}, {}
    for row in latest.itertuples(index=False):
        uid = int(row.uid)
        name_map[uid] = str(row.name) if pd.notna(row.name) else ""
        p = getattr(row, "parent_uid", None)
        parent_map[uid] = int(p) if pd.notna(p) else None

    def resolve_bucket(leaf_uid):
        cur, seen = leaf_uid, set()
        while cur is not None and cur not in seen:
            seen.add(cur)
            if name_map.get(cur, "").strip().lower() in bucket_lookup:
                return bucket_lookup[name_map[cur].strip().lower()]
            cur = parent_map.get(cur)
        return None

    # Leaf-level UID variance
    is_construction_mask = ~latest["outline_number"].apply(
        lambda s: is_buyout_outline(s, buyout_prefixes))
    leaves = latest[is_construction_mask & (latest["is_summary"] == False)].copy()
    leaves["dur_var"] = (
        leaves["duration"].fillna(0) - leaves["baseline_duration"].fillna(0))
    leaves["bucket"] = [resolve_bucket(int(u)) for u in leaves["uid"]]
    leaves = leaves[leaves["bucket"].notna()]

    uid_bucket_net = (leaves.groupby("bucket")["dur_var"].sum().reset_index()
                      .rename(columns={"dur_var": "uid_net_variance"}))

    # Merge with name-based
    e_clean = e_bucket[e_bucket["bucket"] != "TOTAL — Buyout"].copy() \
        if "TOTAL — Buyout" in e_bucket["bucket"].values else e_bucket.copy()
    merged = pd.merge(
        e_clean[["bucket", "net_variance"]],
        uid_bucket_net,
        on="bucket", how="outer"
    ).fillna(0)
    merged["diff"] = merged["net_variance"] - merged["uid_net_variance"]
    merged["diff_pct"] = merged.apply(
        lambda r: round(float(abs(r["diff"]) / abs(r["net_variance"]) * 100), 2)
        if r["net_variance"] != 0 else None, axis=1)

    max_diff_pct = float(merged["diff_pct"].dropna().max()) if not merged.empty else None
    within_1pct  = bool(max_diff_pct is not None and max_diff_pct <= 1.0)

    return {
        "within_1pct": within_1pct,
        "warn": not within_1pct,
        "max_bucket_diff_pct": max_diff_pct,
        "harrison_reference": "within ~1%",
        "note": ("Name-based spans (Stage E) vs per-UID duration sums. A >1% gap "
                 "warrants investigation for rename-driven double-counting."),
        "bucket_detail": merged.to_dict(orient="records"),
    }, merged


# ---------------------------------------------------------------------------
# Check 4 — Negative-variance buildings
# ---------------------------------------------------------------------------

def check_negative_variance(output_root, cfg):
    """
    Buildings (or site buckets) whose net_variance is negative — tracking
    shorter than baseline.
    Harrison reference: Buildings 5 and 8.
    """
    e_bucket = _parquet(output_root / "stage_e" / "bucket_summary.parquet")
    if e_bucket.empty:
        return {"error": "Stage E bucket_summary not found."}

    building_names = set(cfg["buildings"]["names"])
    bldg = e_bucket[e_bucket["bucket"].isin(building_names)].copy()
    negative = bldg[bldg["net_variance"] < 0].sort_values("net_variance")

    watch_positive = (cfg.get("qc", {})
                      .get("negative_variance_watch_buildings", []))

    result = {
        "negative_count": len(negative),
        "negative_buildings": list(negative["bucket"]),
        "negative_variances": {r["bucket"]: round(r["net_variance"], 1)
                               for _, r in negative.iterrows()},
        "watch_list_from_config": watch_positive,
        "harrison_reference": "Buildings 5 and 8",
        "note": ("Negative-variance buckets are tracking shorter than baseline; "
                 "shown for completeness, not a focus of the review."),
    }
    return result


# ---------------------------------------------------------------------------
# Check 5 — Zero-baseline lines
# ---------------------------------------------------------------------------

def check_zero_baseline(output_root, cfg):
    """
    Rolled-up lines with zero or null baseline span — these show n/a for %Var.
    Harrison reference: 132 of 1,756.
    """
    full = _parquet(output_root / "stage_e" / "construction_variance_full.parquet")
    if full.empty:
        return {"error": "Stage E construction_variance_full not found."}

    min_base = cfg.get("construction_variance", {}).get("baseline_span_min_days", 0.5)
    total = len(full)
    zero_base = full[full["baseline_span"].fillna(0) < min_base]
    zero_count = len(zero_base)

    result = {
        "total_rolled_up_lines":  total,
        "zero_baseline_count":    zero_count,
        "zero_baseline_rate_pct": _pct(zero_count, total),
        "min_base_threshold_wd":  min_base,
        "harrison_reference":     "132 of 1,756",
        "note": ("Zero-baseline lines have no saved Baseline duration; they show "
                 "n/a for % Variance. Confirm these before reading as overruns."),
        "examples": list(zero_base["task_name"].head(10)) if not zero_base.empty else [],
    }
    return result


# ---------------------------------------------------------------------------
# Opus synthesis
# ---------------------------------------------------------------------------

def _load_context_for_synthesis(output_root, cfg, qc_results):
    """Collect the key data points Opus needs to write the review-prep narrative."""
    project = cfg["project"]["name"]
    status  = cfg["project"].get("analysis_status_date", "")

    # Stage F: top resources by net days
    br = _parquet(output_root / "stage_f" / "by_resource_net.parquet")
    top_resources = br.head(5).to_dict(orient="records") if not br.empty else []

    # Stage E: top variance lines
    tn = _parquet(output_root / "stage_e" / "top_n_all_buckets.parquet")
    top_tasks = tn.head(6)[["bucket","task_name","abs_variance"]].to_dict(
        orient="records") if not tn.empty else []

    # Stage G: float and completion
    cr_path = output_root / "stage_g" / "completion_range.json"
    comp_range = json.loads(cr_path.read_text()) if cr_path.exists() else {}
    fwd_path   = output_root / "stage_g" / "forward_report.json"
    fwd        = json.loads(fwd_path.read_text()) if fwd_path.exists() else {}

    # Stage F: net movement
    led_path = output_root / "stage_f" / "delay_ledger_report.json"
    ledger   = json.loads(led_path.read_text()) if led_path.exists() else {}

    return {
        "project": project,
        "status_date": status,
        "top_controlling_resources": top_resources,
        "top_variance_tasks": top_tasks,
        "completion_range": comp_range,
        "float_summary": fwd.get("float_summary", {}),
        "delay_ledger_totals": ledger.get("totals", {}),
        "qc_findings": {k: {ek: ev for ek, ev in v.items()
                             if ek not in ("bucket_detail",)}
                        for k, v in qc_results.items()
                        if isinstance(v, dict) and "error" not in v},
        "negative_variance_buildings": qc_results.get(
            "negative_variance", {}).get("negative_buildings", []),
        "zero_baseline_count": qc_results.get(
            "zero_baseline", {}).get("zero_baseline_count"),
    }


SYNTHESIS_PROMPT = """You are a construction project controls analyst preparing executive review materials.

Here is the data from the schedule analytics pipeline for {project} (status {status_date}):

TOP CONTROLLING RESOURCES (net days each controlled the forecast finish):
{top_resources}

TOP VARIANCE TASKS (construction):
{top_tasks}

COMPLETION FORECAST (empirical range over last N weeks):
{comp_range}

FLOAT HEALTH:
{float_summary}

DELAY LEDGER TOTALS:
{ledger_totals}

QC FINDINGS:
{qc_findings}

NEGATIVE-VARIANCE BUILDINGS (tracking shorter than baseline): {neg_buildings}
ZERO-BASELINE LINES: {zero_baseline_count}

Based on this data, generate the following executive review prep materials.
Respond ONLY in valid JSON with this exact structure — no preamble, no markdown fences:

{{
  "questions_for_next_review": [
    "Question 1",
    "Question 2",
    "Question 3",
    "Question 4",
    "Question 5"
  ],
  "watch_list": [
    {{"scope": "...", "reason": "..."}},
    {{"scope": "...", "reason": "..."}},
    {{"scope": "...", "reason": "..."}}
  ],
  "data_quality_notes": [
    "Note 1",
    "Note 2",
    "Note 3"
  ],
  "scope_gaps": [
    {{"dimension": "...", "status": "Not in this brief", "what_is_needed": "..."}},
    {{"dimension": "...", "status": "Not in this brief", "what_is_needed": "..."}}
  ]
}}

Rules:
- questions_for_next_review: 4-6 items, each a specific, answerable question about what would change the risk picture. Grounded in the actual data above — name specific resources, tasks, buildings, or findings.
- watch_list: 3-5 items, each a resource or scope with a specific data-driven reason it carries the most leverage to protect or lose the finish.
- data_quality_notes: 3-5 items, specific factual caveats (e.g. UID persistence rate, zero-baseline count, rename count) formatted as complete sentences ready to paste into Part V of the brief.
- scope_gaps: exactly 2 items — Cost/budget (Sage 300 CRE) and Open items (ACC/Autodesk Build) — with the what_is_needed field filled in precisely.
"""


def run_synthesis(context, output_root, stage_j_dir):
    """Call claude-opus-4-8 to generate the review-prep narrative."""
    import urllib.request

    prompt = SYNTHESIS_PROMPT.format(
        project=context["project"],
        status_date=context["status_date"],
        top_resources=json.dumps(context["top_controlling_resources"], indent=2),
        top_tasks=json.dumps(context["top_variance_tasks"], indent=2),
        comp_range=json.dumps(context["completion_range"], indent=2),
        float_summary=json.dumps(context["float_summary"], indent=2),
        ledger_totals=json.dumps(context["delay_ledger_totals"], indent=2),
        qc_findings=json.dumps(context["qc_findings"], indent=2),
        neg_buildings=context["negative_variance_buildings"],
        zero_baseline_count=context["zero_baseline_count"],
    )

    payload = json.dumps({
        "model": "claude-opus-4-8",
        "max_tokens": 2000,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return None, f"API call failed: {e}"

    # Extract text content
    raw = ""
    for block in data.get("content", []):
        if block.get("type") == "text":
            raw += block["text"]

    # Parse JSON — strip fences if present
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()

    try:
        synthesis = json.loads(raw)
    except json.JSONDecodeError as e:
        return None, f"JSON parse failed: {e}\nRaw response:\n{raw[:500]}"

    # ── Write synthesis ───────────────────────────────────────────────────
    synth_path = output_root / "stage_m" / "synthesis.json"
    synth_path.write_text(json.dumps(synthesis, indent=2, ensure_ascii=False),
                          encoding="utf-8")

    # ── Merge into stage_j/narrative.json ─────────────────────────────────
    stage_j_dir.mkdir(parents=True, exist_ok=True)
    narr_path = stage_j_dir / "narrative.json"
    if narr_path.exists():
        narrative = json.loads(narr_path.read_text(encoding="utf-8"))
    else:
        narrative = {}

    # Map synthesis keys to narrative keys
    narrative["questions_for_next_review"] = synthesis.get("questions_for_next_review", [])
    narrative["watch_list"]                = synthesis.get("watch_list", [])
    narrative["data_quality_notes"]        = synthesis.get("data_quality_notes", [])
    narrative["scope_gaps"]                = synthesis.get("scope_gaps", [])

    narr_path.write_text(json.dumps(narrative, indent=2, ensure_ascii=False),
                         encoding="utf-8")

    return synthesis, None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Stage M — QC and executive review prep")
    parser.add_argument("--config", default="project_config.json")
    parser.add_argument("--synthesize", action="store_true",
                        help="Call Opus API to generate questions-for-review and watch-list")
    args = parser.parse_args()

    cfg         = load_config(args.config)
    project     = cfg["project"]["name"]
    output_root = Path(cfg["paths"]["output_root"])
    stage_dir   = output_root / "stage_m"
    stage_j_dir = output_root / "stage_j"
    stage_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  Stage M — QC and Executive Review Prep")
    print(f"  Project : {project}")
    print(f"{'='*60}\n")

    qc_results = {}

    # ── Check 1: UID persistence ──────────────────────────────────────────
    print("  [1/5] UID persistence...")
    uid = check_uid_persistence(output_root, cfg)
    qc_results["uid_persistence"] = uid
    status = f"{uid.get('uid_persistence_pct')}%"
    ref    = uid.get("harrison_reference", "99.8")
    flag   = "⚠ WARN" if uid.get("warn") else "✓"
    print(f"       {flag}  {status}  (Harrison: {ref}%)")
    if uid.get("rename_count") is not None:
        print(f"       Renames seen: {uid['rename_count']}")

    # ── Check 2: Rename detection ─────────────────────────────────────────
    print("  [2/5] Rename detection...")
    rename_result, renames_df = check_renames(output_root)
    qc_results["renames"] = rename_result
    if "error" not in rename_result:
        n = rename_result["renamed_uid_count"]
        tot = rename_result["total_unique_uids"]
        print(f"       ✓  {n} of {tot} UIDs renamed  (Harrison: 86 of 1,798)")
        if not renames_df.empty:
            renames_df.to_parquet(stage_dir / "uid_renames.parquet", index=False)
    else:
        print(f"       –  {rename_result['error']}")

    # ── Check 3: Bucket cross-check ───────────────────────────────────────
    print("  [3/5] Name-vs-UID bucket cross-check...")
    xcheck = check_bucket_crosscheck(output_root, cfg)
    if isinstance(xcheck, tuple):
        xcheck_result, xcheck_df = xcheck
        qc_results["bucket_crosscheck"] = xcheck_result
        if "error" not in xcheck_result:
            w1 = xcheck_result.get("within_1pct")
            mp = xcheck_result.get("max_bucket_diff_pct")
            flag = "✓" if w1 else "⚠ WARN"
            print(f"       {flag}  Max diff {mp}%  (target: ≤1%  Harrison: within ~1%)")
            if not xcheck_df.empty:
                xcheck_df.to_parquet(stage_dir / "bucket_crosscheck.parquet", index=False)
        else:
            print(f"       –  {xcheck_result['error']}")
    else:
        qc_results["bucket_crosscheck"] = xcheck
        print(f"       –  {xcheck.get('error','unknown error')}")

    # ── Check 4: Negative-variance buildings ──────────────────────────────
    print("  [4/5] Negative-variance buildings...")
    neg = check_negative_variance(output_root, cfg)
    qc_results["negative_variance"] = neg
    if "error" not in neg:
        n = neg["negative_count"]
        bldgs = neg["negative_buildings"]
        print(f"       {'⚠' if n else '✓'}  {n} buildings negative: {bldgs}  "
              f"(Harrison: Buildings 5 and 8)")
    else:
        print(f"       –  {neg['error']}")

    # ── Check 5: Zero-baseline lines ──────────────────────────────────────
    print("  [5/5] Zero-baseline lines...")
    zb = check_zero_baseline(output_root, cfg)
    qc_results["zero_baseline"] = zb
    if "error" not in zb:
        n   = zb["zero_baseline_count"]
        tot = zb["total_rolled_up_lines"]
        print(f"       ✓  {n} of {tot} lines have zero baseline  (Harrison: 132 of 1,756)")
        if zb["examples"]:
            print(f"       Examples: {zb['examples'][:4]}")
    else:
        print(f"       –  {zb['error']}")

    # ── Write QC report ───────────────────────────────────────────────────
    qc_report = {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "project":   project,
        "snapshot_count": cfg.get("schedule", {}).get("snapshot_count"),
        "checks":    qc_results,
        "overall_pass": all(
            not v.get("warn", False)
            for v in qc_results.values()
            if isinstance(v, dict) and "error" not in v
        ),
    }
    report_path = stage_dir / "qc_report.json"
    report_path.write_text(json.dumps(qc_report, indent=2, default=str),
                           encoding="utf-8")

    print(f"\n  QC report written to {report_path}")
    print(f"  Overall: {'PASS' if qc_report['overall_pass'] else 'WARNINGS — review above'}")

    # ── Optional: Opus synthesis ──────────────────────────────────────────
    if args.synthesize:
        print(f"\n  Running Opus synthesis (claude-opus-4-8)...")
        context = _load_context_for_synthesis(output_root, cfg, qc_results)
        synthesis, err = run_synthesis(context, output_root, stage_j_dir)
        if err:
            print(f"  ✗ Synthesis failed: {err}")
        else:
            print(f"  ✓ Synthesis complete")
            print(f"    Questions for review: {len(synthesis.get('questions_for_next_review',[]))}")
            print(f"    Watch-list items:     {len(synthesis.get('watch_list',[]))}")
            print(f"    Data-quality notes:   {len(synthesis.get('data_quality_notes',[]))}")
            print(f"    Written to:")
            print(f"      {stage_dir / 'synthesis.json'}")
            print(f"      {stage_j_dir / 'narrative.json'}")
            print()
            print("  QUESTIONS FOR NEXT REVIEW:")
            for i, q in enumerate(synthesis.get("questions_for_next_review", []), 1):
                print(f"    {i}. {q}")
            print()
            print("  WATCH LIST:")
            for item in synthesis.get("watch_list", []):
                print(f"    • {item.get('scope','')}: {item.get('reason','')}")
    else:
        print(f"\n  (Run with --synthesize to generate Opus review-prep narrative)")

    print(f"\n{'='*60}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
