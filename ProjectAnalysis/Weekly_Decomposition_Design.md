# Weekly Change Decomposition — Design (recommended scope)

Attribute each week's schedule movement to the K → M → Meeting sub-states of the
weekly update cycle, while keeping the longitudinal trend at one datapoint per
week. Diagnostic layer; does not change existing trend charts.

## The decomposition (exact, no residual)

For any scalar metric *X* (project completion date; a building's turnover date):

```
net weekly move  =  X(this canonical) − X(last canonical)
   =  [ X(this K)       − X(last canonical) ]   progress   (what reality did)
    + [ X(this M)       − X(this K)         ]   reschedule (planner's choice)
    + [ X(this Meeting) − X(this M)         ]   meeting    (team decision)
    ( + [ X(post) − X(Meeting) ] when a post-meeting/buyout revision exists )
```

The contributions sum to the net with zero residual — magnitudes are rigorous.
"Which task caused it" is the descriptive top movers inside each sub-delta.
The driving path is traced at each sub-state and set-differenced (tasks entering
/ leaving the controlling path per sub-delta).

## Scope delivered by this design

- Completion-date waterfall, per week.
- Per-building turnover waterfalls, per week (buyout branch excluded, as today).
- Driving-path membership change table: K vs M vs Meeting.
- Causal narrative fed to the Stage M synthesis prompt.

## Weekly grouping rules

- Weeks run **Sunday → Saturday**, keyed by the Saturday (`week_ending`).
- Each week's sub-states are ordered by stage rank K(1) < M(2) < Meeting(3) <
  post/buyout(4); the highest present rank is the **canonical** datapoint.
- Stage is read from the filename/stem token — Harrison `"... K/M/Meeting file"`
  (the MPP-Pipeline naming fix) and New Town legacy `"M ..."/"J ..."/"- Meeting"`.
- Stage ranks are config-driven (`weekly_decomposition.stage_order`) since other
  projects use different letters.

## Integration points (grounded in current code)

1. **`weekly_decomposition.py`** (new, present): pure helpers
   `parse_stage_token`, `resolve_stage_rank`, `week_bounds_sunday_saturday`,
   `group_into_weekly_cycles` (unit-tested); plus fixed signatures
   `compute_metrics_at`, `decompose_week` (Phase 2, pending real data).
2. **`critical_path.discover_snapshots` de-dup tie-break** (`critical_path.py:282-289`):
   change same-date "keep the largest file" to "keep the **highest stage rank**
   (Meeting/post), largest file as the tie-break." This makes the longitudinal
   stages consume the correct canonical file instead of merely the biggest one —
   a correctness upgrade for New Town too (see the `164-165` comment). Mirror the
   same rule in `select_single_snapshot` (D/E/H) so all stages agree.
3. **New stage `weekly_decomposition` (runs after Stage G, before L/M):**
   consumes the **raw, un-deduped** snapshot list, groups into weekly cycles,
   calls `compute_metrics_at` per sub-state, `decompose_week` per week; writes
   `stage_c/../weekly_decomposition.parquet` + a summary json.
4. **`compute_metrics_at` reuse (no reimplementation):**
   - completion: forward_look progress-curve / project-complete milestone finish
   - per-building turnover: `forward_look.build_turnover` (buyout-excluded)
   - driving-path set: `critical_path.trace_driving_path`
5. **Stage L (`assemble_pdf.py` / `generate_charts.py`):** new "Weekly Change
   Decomposition" section — waterfall chart per headline metric for the latest
   week + a K/M/Meeting driving-path change table. Reuse the `narr()` pattern.
6. **Stage M (`run_qc.py`):** add decomposition context to
   `_load_context_for_synthesis` and new prompt keys to `SYNTHESIS_PROMPT`
   (e.g. `weekly_decomposition_note`, `part_i_weekly_bridge`). **Every new key
   must be added to the explicit narrative merge `text_keys` list** or it silently
   vanishes (known trap).

## Config additions

```jsonc
"weekly_decomposition": {
  "enabled": true,
  "week_start": "sunday",              // Sun–Sat cycle
  "stage_order": {"K":1,"M":2,"Meeting":3,"post":4},
  "headline_metrics": ["completion","building_turnover"]
}
```
Plus the lockstep mirrors (PA-Pipeline.ps1 Get-DefaultConfig, PA-Pipeline-Setup.cs
BuildConfigJson, project_config.schema_1.json).

## Phase 0 — validate before wiring the engine (needs real data)

Requires the MPP-Pipeline naming fix live + a real Harrison extraction of ≥2
weeks with K/M/Meeting present. Confirm:

1. **Data-date sharing** — K, M, Meeting of a week share one `status_date`
   (`group_into_weekly_cycles` flags `data_date_consistent`). If not, the
   progress delta mixes real-time-passing with a data-date change; surface it.
2. **Token parseability** — every extracted file classifies to a known stage.
3. **UID stability** — task UIDs are stable across the three sub-states so the
   per-metric differencing and driving-path set-diff line up (report added/removed
   UIDs rather than mismatching).

## Status

- Built + unit-tested: stage classifier, Sun–Sat bucketing, weekly-cycle grouping.
- Pending real Harrison weeks: `compute_metrics_at`, `decompose_week`, the
  discovery de-dup upgrade, the Stage L section, and the Stage M prompt keys.
