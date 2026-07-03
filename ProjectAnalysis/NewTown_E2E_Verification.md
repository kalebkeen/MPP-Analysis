# New Town End-to-End Verification — 2026-07-02 (Work-Plan Phase 4, adapted)

The work plan's Phase 4 called for a 1:1 reproduction of the canonical Harrison brief from the Harrison dataset. The Harrison schedule data is not available on this machine (and the buyout-variance reference xlsx failed to download), so Phase 4 was executed in adapted form, per the user's direction: **a full C→M pipeline run on the complete New Town dataset** (98 snapshots, `C:\Users\araya\Desktop\Project XML\NewTownPipelineOutput 2026-06-29`, scratch-copied — the live folder was never touched), verified against the canonical 73-page Harrison brief PDF for **structure, styling, and method**, with numeric checks against the New Town stage outputs themselves. This simultaneously discharges the plan's Phase 2 items 8 (graceful degradation — prior session), 10 (synthesis scale), and exercises every stage on a second, structurally different project (phase-based, real buyout scope, messy real-world file naming) — which is exactly what it was designed to catch. It caught three real bugs.

## Run parameters

- Config derived from the schedule itself (Stage A-style intake): buyout under outline `1` (`Buyout Work`/`Buyout Lead Times` × `Procurement`/`Subcontracting`, prefixes 1.1/1.2, suffixes 1/2); buckets Permitting, Mobilization, Site Work, Phase 1, Phase 2; buildings analog = Phase 1/Phase 2; finish milestone `Project Complete`.
- **Baseline slots probed empirically** (MPXJ, slots 0–10): construction baseline lives in slots 0–2, buyout only in slots 3–10 (successive rebaselines). User selected **construction = 0, buyout = 3** (earliest full-coverage slot). `schedule.baseline_date` = 2025-11-23 (construction baseline finish — see semantics note in the conformance matrix).
- All 98 files are `.mpp` binaries renamed `.xml` (OLE2 signature) — the fake-.xml trap; UniversalProjectReader handled all 98, zero errors, and the Playbook validation (Duration == ActualDuration on completed leaves) reported zero discrepancies across all snapshots.

## Bugs found and fixed (the run's real yield)

1. **Stage M synthesis crashed on real buyout data** — `json.dumps` on `top_packages` hit `datetime.date` objects (Stage H package actual start/finish). Haven Salon (empty buyout) never exercised this. Fixed: `default=str` on every context dump in `run_synthesis()`.
2. **Snapshot mis-ordering from unparseable filename dates** — "M New Town 3.19..26Meeting" (double dot) and the undated "Prelim New Town-Meeting" fell back to file-mtime, which is meaningless: Stage B's COM export re-saved all 98 files on 2026-06-29, wiping LastSaved (verified via MPXJ: StatusDate unset, LastSaved = export date on every sample). Result: a Sep-2024 planning draft sorted as the *latest* snapshot and corrupted the Stage F timeline tail and workbook naming. Fixed: date-pattern separators widened to `[-._]{1,2}`; the one genuinely undated draft handled via `--manifest` (dated 2024-09-01 by content: zero progress, smallest task count, pre-9/5 prelim).
3. **Stage K had no `--manifest` support** (F and G already did) — the same mis-ordering silently fed the bucket-trajectories chart with no escape hatch, including from the GUI. Fixed: `--manifest` added to `generate_charts.py`, threaded to `discover_snapshots`.

Plus one config-semantics finding (not a code bug): `schedule.baseline_date` means baseline **completion** date; setting it to the status date made the "Behind baseline" KPI read ~1 wk instead of ~32 wks. Documented in the conformance matrix; schema/GUI hint recommended.

## Verification results

**Pipeline:** all stages C→M exit 0 on the full dataset. Stage M synthesis: 159 s wall including mechanical QC; all 23 narrative keys written, spot-checked as data-grounded (named real subs — Hackman, JK Drywall, SCI, Vision; real day counts — +104-day Landscaping package, 18-day completion range; honest buyout framing: "+206.15 days against a 12,643-day baseline span, ~1.63%, across 118 packages"). No context/output-limit pressure at this scale — no chunking needed (plan Phase 2 item 10 discharged).

**Document structure vs canonical (73-page Harrison PDF):**

| Check | Result |
|---|---|
| Section order: Dashboard, Parts I–VI, Appendix A | ✅ identical |
| Part VI present (New Town has real buyout scope) | ✅ (and the Phase 1 no-buyout path was separately verified on Haven Salon 2026-07-01) |
| TOC auto page numbers match actual section pages | ✅ |
| `[NARRATIVE PLACEHOLDER]` leakage | ✅ zero |
| Dashboard layout: 6-KPI strip, Bottom Line, Top Risks, 6-row Status by Dimension (2 fixed rows) | ✅ same structure, same fixed Cost/Open-items rows |
| Fonts | ✅ Carlito-Regular/Bold only (canonical itself mixes Carlito + Helvetica) |
| Part I trend chart styling: navy series + markers, red dashed baseline w/ dated legend, gray caption | ✅ visual match |
| Chart inventory: 2 Part I, 3 Part II, 2 Part IV | ✅ same seven |
| Deltas (already in conformance matrix) | TOC lacks METHODOLOGIES sub-block + Scope Note; Part III title lacks "(as of date)"; canonical Part I "How the Slip Unfolded" table not generated; footer numbering absolute ("Page 5 of 30") vs canonical body-relative ("Page 3 of 71"); KPI scope limitation for phase-based projects |

**Numeric spot-checks (against New Town stage outputs, since canonical numbers are project-specific):** dashboard "Behind baseline ~32 wks" = Jul 3 2026 forecast vs Nov 23 2025 baseline ✅; "90% remaining work ≤5 days float" matches forward_report float_summary ✅; controlling timeline tail (Landscape Ph2 / Hackman driving 2026-07-03) consistent across Stage F parquet, dashboard narrative, and Part II ✅; buyout totals in Part VI narrative match Stage H summary parquet ✅.

**Output artifact:** `New_Town_Executive_Brief_20260623.pdf`, 30 pages (2 front + 28 body). Not committed (generated artifact); reproducible from the run config recorded here.

## Outstanding for a true Harrison 1:1

Requires the Harrison dataset (41 snapshots), and ideally the buyout-variance xlsx, neither available locally. The headline numbers that must reproduce when that run happens: PO cycle ~10→34 working days, ~2-month late start, +2,002 working-day Buyout Work span growth, +87-calendar-day net finish movement, Site Work +385 days (14 over/+452.7, 5 under/−67.8).
