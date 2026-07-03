# Executive Brief Replication Playbook — Revision 2 (2026-07-03)

Schedule Analytics & Executive Reporting for Multifamily Projects — end-to-end workflow from raw MPP files to final PDF brief.

**What this revision is.** Rev 1 (the original .docx, based on the Harrison Estate Senior prototype) described a manual, session-driven workflow. Since then the entire Python side has been productized into the **PA-Pipeline application** (WinForms GUI + 9 stage scripts + bundled Python/Java/Carlito, repo `kalebkeen/MPP-Analysis`), verified end-to-end on a second project (New Town, 98 snapshots), and extended with the 2026-07-01 work plan's Phase 5 methodology upgrades. Rev 2 records the workflow **as it now actually runs**, so the Playbook and the app do not silently disagree. Where rev 1 text remains accurate it is summarized, not repeated — rev 1 stays in project knowledge as the historical prototype record; `Playbook_Conformance_Matrix.md` (same repo) maps every rev 1 requirement to the implementation, row by row.

**Model selection (supersedes rev 1's per-stage model banners and Appendix 1).** Rev 1 named specific models (Opus 4.7 / Sonnet 4.6); those names date quickly. The durable guidance, in role language: use a **high-judgment model** for first-time analytical design (the WBS resolver pattern, the driving-path algorithm, the two-measurement framework, cascade thresholds) and for the narrative synthesis (executive overview, VI.1 bottom-line, caveats, decisions-requested, questions-for-next-review); use a **workhorse model** for everything mechanical once the modules exist. In the productized app this distinction survives in exactly one place: **Stage M's synthesis calls the high-judgment model via the Claude Code CLI** (see Stage M); every other stage is deterministic Python needing no model at all at run time.¹

¹ Current models as of this revision: high-judgment = Claude Opus 4.8 (`claude-opus-4-8`, what `run_qc.py` invokes); workhorse = Claude Sonnet. Update this footnote, not the body text, when models change.

---

## Stage A — Pre-flight and Project Intake

Unchanged in substance: capture the project once, before any run. Every intake field now has a `project_config.json` home (Tab 1 of the app): project name/SCI number/type/contract type; **baseline date** (`schedule.baseline_date` — the immovable baseline **completion** target, e.g. Harrison April 9, New Town 2025-11-23; it drives the "Behind baseline" KPI and the Part I chart's baseline line); status date; buildings/phases; construction bucket list; `wbs_resolver.bucket_overrides`; source paths.

**New intake step — baseline-slot selection.** Rev 1 assumed Baseline 0. Real projects rebaseline into other slots: New Town keeps construction in slots 0–2 and buyout only in slots 3–10. During intake, probe slots 0–10 on a representative snapshot (MPXJ `getBaselineStart(n)`) and set `schedule.construction_baseline_number` / `schedule.buyout_baseline_number` explicitly (New Town, user-selected: construction 0, buyout 3). Extraction bakes the chosen slots into per-section baseline columns.

**New intake check — snapshot dating.** Stage B's COM export re-saves every file, destroying LastSaved; StatusDate is typically unset. **The filename date is the only reliable snapshot-date carrier.** Confirm every snapshot filename carries a parseable date (m.d.yy etc. — the app tolerates typos like "3.19..26"); rename stragglers or supply a `--manifest` CSV (stem,date) to stages F/G/K.

## Stage B — File Preparation Pipeline (PowerShell)

Unchanged; remains the **separate MPP-Pipeline tool** (Delete-NonMPP → Sort-MPP best-per-folder, Meeting > M > K > J priority, scheduler initials project-specific → Export-MPPtoXML via MS Project COM). The boundary is deliberate: PA-Pipeline consumes Stage B's output folder. New consequence documented above: exported "XML" files are native MPP binaries (unchanged trap) **and** carry the export date, not the snapshot date, in every file-system and in-file timestamp.

## Stage C — Environment Setup and Data Extraction

Superseded mechanics: the app installer bundles Python 3.12, Temurin JRE 21, and MPXJ 16.4.1 (`org.mpxj`), creates the venv with **pinned** package versions, and verifies installs with a deep import smoke test (a hollow stub package can import successfully with `__file__ = None`; plain import checks miss it). Repair path: pip `--ignore-installed` of the pinned set (`--force-reinstall` hard-fails on no-RECORD damage).

Per-snapshot fields: rev 1's list, plus per-section baseline columns (per the configured slots), scheduled start/finish, and — new in rev 2 — **`constraint_type`, `constraint_date`, `deadline`** (feeding Stage F's constraint detection and Stage M's schedule-health panel). Validation unchanged and automated: Duration == ActualDuration on completed leaves, reported per run (New Town: zero discrepancies across 98 snapshots). Persistence: parquet, cached; the cache-staleness check keys on the newest schema columns — **every time extraction gains a column, extend `required_cols`** or existing caches serve stale data silently.

Traps carried forward verbatim: fake-.xml binaries (UniversalProjectReader handles them); never name a script `inspect.py`; MPXJ 16.x needs Java 21.

## Stage D — WBS Resolver and Grouping

Unchanged: the structural resolver (`category(leaf) = first ancestor whose parent is a Group or Phase node`, bottom-up) and the six grouping fields. Generalization since rev 1: buyout scoping is by **outline prefixes** (`schedule.buyout_outline_prefixes`, segment-aware, multiple disjoint branches supported) rather than rev 1's task-ID range — more robust when buyout scope is added to a schedule after construction exists. Harrison's 84-package / 2,151-leaf distribution remains a built-in validation reference.

## Stage E — Construction Variance Analysis (Methodology A)

Unchanged: name roll-up with Instances, span-based durations on the project calendar, abs/% variance with n/a under 0.5 wd, net bucket variance as arithmetic sum, Top-N + per-building Top-10s.

**New — the in-progress rule, stated explicitly (Methodology A):** completed lines use actuals; any line with an incomplete instance measures its span to the **current scheduled finish and is therefore a forecast**; not-yet-started work contributes no actual span. Each rolled-up line now carries a `span_basis` flag (actual / forecast / not started) in the full table and workbook.

## Stage F — Critical-Path Delay Ledger (Methodology B)

Unchanged core: backward driving-path trace (driving flag first, latest-finishing fallback), milestone fallback to latest-finishing leaf, controlling activity = earliest-finishing incomplete construction task on the path, calendar-day ledger, by-resource + waterfall aggregation, gross/recovered/net totals.

**New — constraint-terminated traces.** Where a task's dates are governed by a hard constraint (anything non-ASAP: SNET, FNET, MUST_*, ALAP) or a deadline with non-positive float, and no relationship is flagged driving, the trace now records that terminus as `constraint-controlled (<TYPE>)` instead of silently estimating through it via the latest-finishing predecessor. The count surfaces in the ledger report and Methodology B. This matters in practice: New Town's scheduler used 1,886 non-ASAP constraints and 94 of 98 traces end constraint-controlled.

**New — attribution convention, made explicit and configurable.** `critical_path.attribution_convention`: `"later"` (default — the rev 1 / canonical "windows" convention: credit each window's movement to whoever was driving when it appeared) or `"earlier"` (credit the incumbent that held the path during the window). Both conventions are computed on every run and written side-by-side to `attribution_comparison.parquet`, so the choice is reviewable, never silent. **Decision of record (2026-07-03, user-approved after reviewing the New Town delta): keep "later."** Methodology B in the brief carries a one-sentence defense of whichever convention is configured.

Limitations paragraph unchanged (contemporaneous diagnostic, not causation; concurrency not separated; forensic work needs fragnets).

## Stage G — Forward Path-to-Completion (Methodology C)

Unchanged: building turnover from summary tasks, float-health bands, completion range (8-snapshot empirical band), look-ahead.

**New sub-analyses:**
- **Per-building driving paths** — the backward trace run against each configured building's own finish (latest snapshot): controlling activity, resource, remaining-on-path count, short look-ahead. Renders as a Part IV table; this is what makes the per-building section actionable for superintendents.
- **S-curve** — planned vs actual percent complete over the snapshot series, baseline-duration-weighted, sharing one denominator (`progress_curve.parquet`, chart in Part IV).
- **Slip velocity** — trailing regression of forecast-finish movement over the completion-range window: "at the current trend, completion projects to X," framed **explicitly as an empirical trend, never a forecast** (same epistemics as the completion range). Reported in `forward_report.json`, one paragraph in Part IV, one line available to the dashboard synthesis.

## Stage H — Buyout Phase Analysis (Methodology D)

Unchanged: structural-resolver scoping, the two-measurement framework (duration variance + start-date slip — Harrison's central insight: approval throughput fine at +0.3 wd, but started 4 weeks late), the summary-span vs leaf-sum trap, three roll-up levels, Lead Time excluded from duration diagnosis but retained labeled, "Lead Time Determined" folded into Decision/setup.

Rev 2 changes:
- **Stage classification is config-driven** (`buyout_analysis.stage_classification`, priority-ordered keyword dicts) with **defaults matching Methodology D.4 verbatim** (Decision/setup, Purchase-order cycle, Subcontract execution, Submittal approval, Package close-out/milestone). Leaves matching no keyword land in an explicit **Unclassified** bucket, and Stage H reports % unclassified as a QC line — a project with different naming conventions fails loudly instead of misfiling silently (New Town under the D.4 defaults: 5.8%).
- **Top Activities roll-up** now materialized (de-dup by Section/Group/Category/Activity, instance-averaged durations, median start-slip) as parquet + workbook tab, closing rev 1's third roll-up level.
- **Buyout is optional, first-class.** Blank `schedule.buyout_outline_prefixes` = the project has no buyout phase: Stage H exits cleanly writing empty-but-valid outputs plus `buyout_report.json` with `"buyout_in_scope": false`; Part VI (TOC, bookmarks, body) and the buyout charts drop out of the brief entirely. Configured-but-zero-matches warns and degrades the same way.

## Stage I — Cascade Analysis (Optional Extension) — still unimplemented, by design

Unchanged status: optional, not in the canonical brief, not in the app. **Upgraded filter definition for whenever it is built** (work plan 5.3): a cascade requires **three** conditions — (1) upstream buyout duration overrun > 2 wd, (2) downstream construction slip > 2 wd, **and (3) an actual predecessor path from the buyout task to the construction task**, walked from the relationship network Stage C already extracts. Co-occurrence alone is correlation; the logic link is what makes it a cascade. Rev 1's reliability note stands: date-only milestone slips are unreliable (rebaselining produces false positives). Thresholds remain per-project judgment.

## Stage J — Document Architecture and Narrative

Document structure, Roman-numeral parts, VI.x numbering, and cover-last build order unchanged. Two structural changes: **Part VI is conditional** (see Stage H), and the **Page-1 dashboard gains two elements**: a "Decisions Requested / Recommended Actions" block (2–4 lines, synthesized) and — for recurring briefs only — a "What Changed Since the Last Brief" delta (enabled by `paths.prior_brief` pointing at the prior run's `narrative.json`; skipped entirely on a first brief).

**The narrative mechanism is the biggest rev 1 → rev 2 delta.** Rev 1 split fields between manual entry and ad-hoc model sessions. Now **Stage M's synthesis fills every narrative key (~20) in one CLI call** — all part intros/analyses, risks, status-by-dimension, bottom-line, executive overview, VI.x notes, decisions-requested, questions, watch-list, data-quality notes, scope gaps — grounded in the stage outputs with explicit anti-hallucination instructions (empty data sections are said to be empty, never invented). Manual override remains possible by editing `stage_j/narrative.json`. `SECTION_TITLES` in `assemble_pdf.py` is the single source of truth for every part title (TOC and body headers both read it).

## Stage K — Charting

The seven core charts unchanged (forecast trend, bucket trajectories, driving-resource scatter, waterfall, resource net bar, building lollipop, float histogram) — plus **four rev 2 additions**: S-curve (Part IV), float-erosion trend (Part IV), two-measurement scatter with quadrant annotations (Part VI), PO-cycle trend with rolling median (Part VI). All eleven follow the one-`_data_*`-function dual-output pattern (PNG + editable workbook tab). The driving-resource scatter now caps its legend at `charting.legend_max_series` (default 10), grouping minor subs into "other."

Styling unchanged: navy `#1F4E78`, muted supporting palette, Carlito. **Font path corrected from rev 1:** Carlito is bundled by the installer into the app's own `fonts/` directory and resolved relative to the stage scripts — the rev 1 Linux sandbox path (`/usr/share/fonts/.../Carlito-Bold.ttf`) is obsolete.

## Stage L — PDF Assembly, Cover, and TOC

Unchanged: reportlab body → two-pass build (measure, then real page numbers) → cover+TOC built to the measured count → pypdf merge with bookmarks/metadata. Part VI conditionally included; Part V now also renders the **schedule-health panel** (see Stage M). The surgical-patch fallback (pikepdf blank via ASCII-normalized operator matching + reportlab overlay with glyph-calibrated baselines + pypdf merge) is unchanged and remains documented here as the procedure of record.

## Stage M — Quality Control and Executive Review Prep

Mechanical QC: rev 1's five checks unchanged (UID persistence, rename detection, name-vs-UID cross-check, negative-variance buildings, zero-baseline lines) **plus two**:
- **Baseline integrity (rebaseline churn):** per UID, compare saved baseline start/finish/duration across all snapshots; report count/%/branch of UIDs whose baseline changed mid-project. Rebaselining silently invalidates Stage E variances and Stage H start-slips — this is the guard (New Town: 27% of UIDs churned; the finding reshaped how that project's numbers should be read).
- **Schedule-health panel (DCMA-style):** open ends (no pred / no succ), hard-constraint count, negative-float count, leads/lags, out-of-sequence progress, actuals beyond status date, high-duration remaining. Cheap to compute from extracted data; rendered as a small Part V table; qualifies confidence in the logic-driven analyses.

**Synthesis (approved deviation from rev 1's method):** the high-judgment model is invoked via the **Claude Code CLI** (`claude -p --output-format json`, prompt via stdin), authenticated by the machine user's own one-time `claude` login — no API key or credential is ever stored in the app or config. Failures are detected via the CLI's JSON envelope (`is_error`/`result` on stdout — not exit code, not stderr). The CLI is the one dependency the installer does not bundle; the Settings tab and a first-click hint say so. Every key the synthesis prompt requests must also appear in the narrative-merge key list in `run_qc.py` — a key missing there exists only in `synthesis.json` and never reaches the brief.

---

## Appendix — Known Traps (rev 1 set + rev 2 additions)

All rev 1 traps stand (fake-.xml, `org.mpxj`, `inspect.py`, summary-span vs leaf-sum, structural resolver, cascade date-slip unreliability, surgical-patch recipe, .NET Framework 4.x constraints). New, learned the hard way since:

1. **Interrupted venv installs leave hollow stub packages** that import successfully with `__file__ = None` — fatal to pandas at import, invisible to plain import checks, and un-fixable by `pip --force-reinstall` (its uninstall step dies on the missing RECORD). Detect with the `__file__` smoke test; repair with `--ignore-installed` of the pinned set.
2. **Stage B's COM export wipes LastSaved and mtime** on every exported file. Filename dates are the only snapshot-date carrier; ordering falls back mtime-last and mis-sorts undated files to the export date.
3. **Extraction cache staleness is schema-keyed:** adding a column to extraction without extending the cache's `required_cols` serves every existing parquet stale ("cached, skipping" × 98).
4. **`json.dumps` on stage tables needs `default=str`** — package/task tables carry `datetime.date` cells; an empty-buyout project never exercises the code path, the first real-buyout project crashes it.
5. **The narrative merge is an explicit key list** — new synthesis keys must be added there too (decisions_requested went missing on its first run).
6. **PA-Pipeline.exe is compiled from the PS1** — editing `PA-Pipeline.ps1` changes nothing in the installed app until the PS2EXE recompile-and-swap.
7. **Config defaults only heal missing keys** (`Merge-ConfigDefaults`) — changed default *values* never reach existing configs; handle with explicit live fallbacks.

## Appendix — Project-Specific vs Reusable (updated)

The rev 1 "becomes reusable after refactor" list is **done** — all eight Python modules are the app's stage scripts, configuration-driven, verified on a second project. Stays project-specific per run: the intake config (including baseline slots and — new — the buyout keyword taxonomy when naming differs from the D.4 defaults), bucket overrides, Stage B scheduler initials, the synthesized findings themselves, and cascade thresholds if Stage I is ever built.
