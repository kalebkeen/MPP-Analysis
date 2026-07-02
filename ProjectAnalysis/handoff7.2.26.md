# PA Pipeline — Handoff, 2026-07-02 (session 4)

This supersedes `handoff6.30.26-3.md` as the authoritative session record. Read that document first (and `handoff6.30.26.md` / `handoff6.28.26.md` behind it) for the foundational architecture: the two-root filesystem split, schema-B config, the Stage K `_data_*`/`_render_*` split, `SECTION_TITLES` single-sourcing, and the CLI-authenticated Stage M synthesis — all unchanged and not repeated here.

This session is different in kind from the previous three: it was driven not by a bug report or a TODO list but by a **formal five-phase work plan** the user supplied as a file (`PA_Pipeline_WorkPlan_7_01_26.txt`, on the Desktop — note it is UTF-16LE encoded and renders with interleaved spaces in naive reads; it's readable, just odd-looking). The plan is the companion to `handoff6.30.26-3.md` and covers: Phase 0 (unblock a crashed run / venv corruption), Phase 1 (buyout-optional degradation), Phase 2 (close the five-session TODO backlog), Phase 3 (Playbook conformance audit), Phase 4 (1:1 Harrison output verification), Phase 5 (methodology & chart enhancements). **This session completed Phases 0, 1, and Phase 2 items 2 & 9 — the maximal subset executable on this machine without the reference artifacts (see §5).**

**Related docs and skills used this session:**
- Input: `PA_Pipeline_WorkPlan_7_01_26.txt` (Desktop), `handoff6.30.26-3.md` (read in full first, per the plan's instruction)
- Standard tools (PowerShell, Bash, Read/Edit/Write, Grep, Glob), `TaskCreate`/`TaskUpdate` for phase tracking, `AskUserQuestion` once (land-and-deploy decision)
- Claude Code model used: claude-fable-5
- This document is itself produced by the `/anthropic-skills:handoff` skill

---

## 1. Understanding of the project (evolution and future)

The app is now past the "make it work" era. Sessions 1–3 built and field-validated the machine; the work plan marks the shift to **systematic closure**: hardening (Phase 0), first-class degradation states (Phase 1), debt paydown (Phase 2), then *proving* the app against its own specification (Phase 3, the Replication Playbook) and against ground truth (Phase 4, the canonical 146-page Harrison brief), before deliberately evolving the methodology past that baseline (Phase 5). The ordering constraint that matters most going forward: **Phase 4 must complete before Phase 5 lands**, because Phase 5 intentionally changes published numbers (windows-attribution convention, cascade filter, new charts) — after it, the app will no longer match the canonical brief by design, and the conformance matrix + Playbook rev 2 become the new spec.

The other structural realization this session: **"Stage I (cascade)" does not exist in the codebase at all.** The work plan's Phase 1 lists Stage I behavior ("auto-skips when H reports out-of-scope"), but no cascade script or code exists anywhere — the pipeline's real stages are C, D, E, F, G, H, K, J(narrative file), L, M. Cascade is a Playbook concept the app has never implemented. This is exactly the kind of app-vs-Playbook gap Phase 3's conformance matrix exists to catch; it should get a row there rather than being silently patched in now.

## 2. What changed this session (commit `0f1250f`, pushed to main)

### Phase 0 — venv corruption: repaired live + made structurally impossible to miss

**The user's actual crash was diagnosed and fixed on their machine, not just in code.** Every stage C–H had died with `AttributeError: module 'pyarrow' has no attribute '__version__'` from pandas' compat shim. Ground truth on the live venv (`%LocalAppData%\PA-Pipeline\venv`): `import pyarrow` succeeded but `pyarrow.__file__` was `None` — a hollow namespace-package stub left by an interrupted wheel extraction. A full RECORD-integrity scan of site-packages then found the damage was **much wider than the symptom**: nine packages (pdfminer.six, pdfplumber, pikepdf, pycparser, pyparsing, pypdf, pypdfium2, reportlab, tzdata — alphabetically contiguous, the smoking gun of a bulk install killed mid-alphabet) had no RECORD file at all. pyarrow was merely the first one pandas tripped over.

Repair sequence that actually worked (all verified live): delete the broken package dirs + dist-info, reinstall pinned versions. Critically, **`pip install --force-reinstall` does NOT work on this damage** — its uninstall step hard-fails with `uninstall-no-record-file` ("Cannot uninstall pyarrow None"), observed verbatim. This drove a deliberate deviation from the work plan's suggested repair flag (see §3). All 9 live stage scripts now pass import (`--help` exit 0 for each).

App-side hardening (the real deliverable):
- **Pinned exact versions** in all three lockstep declaration sites — `Get-DefaultConfig` (PS1), `Program.PipPackages` (C#), `project_config.schema_1.json` — plus the user's live `project_config.json` (which `Merge-ConfigDefaults` would never have healed, since the key already existed; known limitation, see feedback memory). Pins: mpxj==16.4.1, jpype1==1.7.1, pandas==3.0.3, pyarrow==24.0.0, openpyxl==3.1.5, matplotlib==3.11.0, reportlab==5.0.0, pypdf==6.14.2, pikepdf==10.9.1, pdfplumber==0.11.10.
- **Deep import smoke test** (`$script:VenvSmokeTestCode` / C# `VenvSmokeTestCode` — kept in lockstep like the package lists): imports every package for real AND requires `__file__` to be non-None. A plain `import X` check — which is what the old Environment Check did — passes on the exact stub that killed the run.
- **Installer Step 8** now runs the smoke test after pip and only sets `packages_installed=true` if both pass — pip exit 0 alone is no longer trusted.
- **Environment Check gains the fourth failure state**: each package is classified OK / missing / **corrupted** (exit-code-2 probe on the `__file__` check), so "reinstall the app" is distinguishable from "click Repair Packages."
- **New Repair Packages button** (Settings tab, Venv panel): `pip install --ignore-installed <pinned set>` + post-repair smoke test. Verified end-to-end by deliberately deleting pdfplumber's RECORD, confirming `--force-reinstall` fails on it, confirming Repair recovers it, and confirming the smoke test flips from fail to pass.

### Phase 1 — buyout-optional graceful degradation

Blank `schedule.buyout_outline_prefixes` is now a supported, first-class "this project has no buyout phase" state — no dummy inputs, no NA sentinels.

- **Stage H** (`buyout_analysis.py`): gates *before* the Stage D dependency check (a no-buyout project has nothing for D to resolve either). Exits 0, prints `Stage H skipped — no buyout scope configured`, writes empty-but-valid parquets (explicit column schemas, per the session-2 empty-DataFrame lesson) plus `buyout_report.json` with `"buyout_in_scope": false` — a definitive downstream signal rather than a missing file. Secondary detection: prefixes configured but zero packages matched → **warns** and writes the same out-of-scope marker instead of failing. The normal path now writes `"buyout_in_scope": true`.
- **Stage L** (`assemble_pdf.py`): new `buyout_in_scope()` reader; when false, **Part VI drops out entirely — TOC entry, bookmark, and body** — implemented as a conditional include off the existing single-source `SECTION_TITLES` (never a second title list). Missing/unreadable report is treated as out-of-scope, so the failure mode is a clean shorter brief, not an empty shell. **No renumbering was needed**: Part VI is the last numbered part, so omission leaves a clean I–V + Appendix A (the plan's "clean omission" recommendation, which the structure makes free).
- **Stage M** (`run_qc.py`): `buyout_in_scope` read from Stage H's report into the synthesis context and into the prompt header, with an explicit instruction to reduce each `part_vi_*` field to a single "not applicable" sentence when false (those keys are then ignored by the assembler anyway). Verified the expanded `.format()` call resolves against real context — no KeyError from the new placeholder.
- **Stage K needed no change** — verified, not assumed: all seven current charts read only E/F/G outputs; there are no buyout charts today (those arrive in Phase 5.10, which is where buyout-chart skipping will actually need implementing).
- **GUI**: buyout prefix hint now reads "leave blank if the project has no buyout phase"; the WBS Resolver groupbox title and the buyout-work-prefix hint say the same.

**Phase 1.3 dual-path test (discharges TODO #8):** a scratch harness (`buyout_test.py`, scratchpad) copies Haven Salon stage outputs to a scratch root, supplies a complete hand-written `narrative.json` with sentinel strings in the `part_vi_*` fields, and runs D→H→L twice. Path A (blank buyout): all exit 0, `buyout_in_scope=false`, and the extracted PDF text contains **no "Part VI", no sentinel leakage, no `[NARRATIVE PLACEHOLDER]`**. Path B (in-scope flag + non-empty summary): Part VI present in TOC and body with the sentinel narrative rendered. All assertions passed against real rendered PDFs, not just JSON keys.

### Phase 2 item 2 — dead config fields deleted

Grep-verified which `qc.*` / `charting.*` / `critical_path.*` keys any Python stage actually reads, then deleted the dead ones from all three declaration sites in lockstep: `critical_path.incomplete_only`, `.min_duration_days`, `.ledger_window_weeks`; `charting.navy_hex`, `.alert_red_hex`; `qc.zero_baseline_warn_threshold`, `.name_uid_gap_warn_pct`, and `qc.synthesize_with_opus` (the confirmed liar). Kept (verified live): `concurrent_paths_threshold_days`, `dpi`, `font_family`, `float_health_bands_days`, `completion_range_lookback_weeks`, `forecast_trend_chart.annotation_breakpoints`, `uid_persistence_warn_threshold_pct`, `negative_variance_watch_buildings`. The C# JSON emitter was re-validated after deletion by compiling an isolated fragment and json-parsing its output (trailing-comma regressions are the classic failure here).

**Finding worth its own flag:** `charting.alert_red_hex` wasn't just unused — `generate_charts.py` hardcodes `RED = "#C0392B"`, which **disagrees with the house/Playbook red `#C00000`** the config claimed to control. The deleted field was lying about the actual chart color. This goes on the Phase 3 Stage K conformance row.

### Phase 2 item 9 — Synthesize's unbundled CLI dependency made visible

- New Settings-tab groupbox ("Synthesize (Opus narrative) — one-time external setup") spelling out: uses the Claude Code CLI installed on THIS machine, app bundles nothing and stores no credentials, two-step one-time setup, everything else runs offline.
- Once-per-session first-click info dialog on "Run Selected + Synthesize" (before the auth pre-flight), guarded by a new `$script:SynthHintShown` flag — initialized at script scope because `Set-StrictMode -Version Latest` throws on uninitialized reads.

### Phase 2 item 5 — investigated, deliberately deferred

`paths.baseline_mpp`: GUI-wired (textbox saves/loads it) but read by **zero** Python stages; the schema comment "Stage E, H read this" is inaccurate — same class of lie as `synthesize_with_opus`. Left in place per the work plan, which explicitly routes the wire-vs-remove decision through Phase 3's Stage E conformance check (the Playbook may require a baseline source).

### Deployment (partial — see §6)

Committed and pushed `0f1250f` to `kalebkeen/MPP-Analysis` main (6 files, +333/−61). The user chose "Commit/push + hot-patch live" via AskUserQuestion. Hot-patch preparation completed: PS2EXE module extracted from the installer's own embedded constants, `PA-Pipeline.exe` recompiled from the updated PS1 with the installer's exact parameters (NoConsole/Title/Product/Description/Company/Version), and the new exe **launch-tested** — it constructed the full form with all new controls and stayed alive (this catches form-construction crashes that a parse check cannot). **The elevated copy into `C:\Program Files\PA-Pipeline` did NOT happen**: the UAC prompt was declined twice, and per the two-strikes signal no third attempt was made. The staged deploy script (self-verifying, hash-checks each copied file against repo source, writes `deploy_result.txt`) is at the scratchpad path in §6.

---

## 3. Architecture decisions and rationale

- **`--ignore-installed`, not `--force-reinstall`, for venv repair** — a deliberate deviation from the work plan's own wording ("--force-reinstall of the pinned set"). Empirically, `--force-reinstall` runs pip's uninstall step first, which hard-fails on exactly the no-RECORD damage being repaired. `--ignore-installed` skips uninstall and re-extracts every pinned wheel over the top: idempotent, and it repairs partial extractions. The deviation and its evidence are documented in a code comment at the call site. Full venv delete-and-recreate remains available via the existing Create Venv + Install Packages buttons (and the Repair failure message points there).
- **Smoke test = real imports + `__file__` check, duplicated as a one-liner in PS1 and C#** rather than a new 10th embedded stage script. The logic is one line; the embed machinery (new B64 constant, Embed-Sources.ps1 entry, installer extraction step renumbering) would have been 10× the change surface for zero behavioral gain. The two copies are lockstep-commented the same way `Get-DefaultConfig`/`BuildConfigJson` already are. `importlib.util.find_spec` was considered and rejected: it catches namespace stubs but not partial extractions with intact `__init__` (the pyparsing failure mode) — only real imports catch everything observed.
- **Config-blank as the primary no-buyout signal, zero-match as a warning** — per the plan. The gate sits before the Stage D dependency check so a no-buyout project never needs Stage D outputs at all.
- **Out-of-scope Stage H still writes all four parquets (empty, explicit columns) + the report** — downstream code gets a definitive signal and correctly-shaped frames, never a missing-file ambiguity or a columnless `pd.DataFrame([])`.
- **Part VI omission via conditional include, defaulting to omit on missing/unreadable report** — the conservative failure mode is a brief without an empty buyout shell, and `SECTION_TITLES` remains the only title source.
- **Pinning to the versions already proven on this machine** (captured from the repaired live venv) rather than latest-available — these exact wheels are what the full C–M pipeline has actually run against.
- **First-click hint is per-session, not per-install** — no new persisted config key for a courtesy dialog; StrictMode-safe script-scope flag.

---

## 4. Mistakes made and lessons learned

1. **Piping JSON into `python -c` via PowerShell mangled the payload** (the C# fragment validation first failed with "Expecting value: line 1 column 1"). PS 5.1 pipe-to-native re-encodes line-by-line. Self-corrected by writing to a file and reading with `utf-8-sig` (Out-File utf8 writes a BOM — the `-sig` matters). Lesson: on this stack, validate generated text through files, not pipes.
2. **First attempt to pin the live config used a regex that silently didn't match** — the live JSON's indentation (ConvertTo-Json style, heavily padded) differed from the repo template the pattern assumed. The script correctly reported NO CHANGE instead of writing garbage; second attempt used exact-token replacement and verified by re-parsing. Lesson: never assume a config file on disk has the formatting of the code that first wrote it — it's been rewritten by Save-ProjectConfig since.
3. **First elevated-deploy attempt ran with `-WindowStyle Hidden`, which may have hidden/suppressed the UAC context enough to be missed**; it produced no result file and left no trace. The second attempt (visible) surfaced the real state: "The operation was canceled by the user" — an explicit decline. Two declines were treated as signal to stop retrying and hand the command to the user instead. Lesson: never launch an elevation request hidden; and a declined UAC is user input, not an error to retry.
4. **`Read` on PA-Pipeline-Setup.cs fails even with small offset/limit windows** (557K tokens; the base64 constants are single enormous lines). All navigation of that file must go through Grep with context flags. Known gotcha for future sessions.
5. Reference artifacts were assumed possibly-local and searched for before concluding Phases 3–4 were blocked — right order (verify, then declare blocked), no cost.

---

## 5. Remaining TODOs

**From the work plan (this is now the master list; the old handoff TODO numbering is retired):**

1. **Deploy the hot-patch** — everything is staged and verified; only the UAC-elevated copy remains (see §6). Until it runs, the live app has the old GUI and old stage scripts (the repaired venv is live regardless).
2. **Phase 3 — Playbook conformance audit** → `Playbook_Conformance_Matrix.md`. **Blocked:** `Executive_Brief_Replication_Playbook__1_.docx` (plain UTF-8 text despite the extension) is in Claude.ai project knowledge, not on this machine. User must copy it locally. Pre-seeded findings for the matrix: Stage I (cascade) is entirely unimplemented; `paths.baseline_mpp` is dead pending the Stage E check; Stage K's hardcoded `#C0392B` vs Playbook `#C00000` red.
3. **Phase 4 — Harrison 1:1 verification** → `Harrison_1to1_Verification.md`. **Blocked:** needs the Harrison dataset (41 snapshots), the 146-page JPEG reference ZIP (`Harrison_Senior_Executive_Brief_with_Cover_TOC.pdf` — really a ZIP), and `Harrison_Estates_Senior_Buyout_Duration_Variance__as_of_20260612_2.xlsx`. None local. Discharges plan Phase-2 items 1 (Stage G thin sections), 6/7 (fresh-install E2E), 10 (synthesis scale — capture prompt size/latency in the run log).
4. **Phase 2 item 3 — repo bloat** (~76–80MB installer per rebuild): recommendation stands to move built binaries to GitHub Releases; **needs user sign-off before any history rewrite**. Note the installer was deliberately NOT rebuilt this session partly to avoid another 76MB commit while this is unresolved.
5. **Phase 2 item 4 — chart workbook fidelity in real Excel**: user eyeball on Windows.
6. **Phase 5 — methodology & chart enhancements (5.1–5.12)**: only after Phase 4; 5.1 (attribution convention) requires showing the user the Harrison delta first; 5.7 coordinates with the Stage G thin-section fix; 5.10's buyout charts must respect Phase 1's `buyout_in_scope` signal when built.
7. **Installer rebuild** (Embed-Sources.ps1 → Build-Setup.bat) whenever the next distribution moment arrives — the current `PA-Pipeline-Setup.exe` in the repo predates every change this session.

---

## 6. Potential issues on the horizon

- **The live install is mid-upgrade until the hot-patch lands.** Venv = new (pinned, verified); app scripts + GUI = old. Nothing is broken — the old code runs fine against the repaired venv — but Phase 1 behavior and the new Settings UI won't exist until the deploy runs. Deploy command (elevated PowerShell):
  `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\araya\AppData\Local\Temp\claude\C--Users-araya--claude-sessions\d94515d5-2f36-4496-bd66-ad1f8c3bcc7d\scratchpad\deploy_live.ps1"`
  Caveat: that scratchpad is session-scoped and may be cleaned; if gone, the recompile-and-swap recipe in [[feedback-pa-pipeline]] regenerates everything from the repo in ~2 minutes. The rebuilt exe is 149,504 bytes vs the live 140,800 — a quick size check tells you which one is installed.
- **Existing user configs keep their old shape.** `Merge-ConfigDefaults` won't remove the deleted dead keys from saved configs (harmless — nothing reads them) and won't upgrade unpinned `pip_packages` to pinned (this session patched the live config by hand; any OTHER machine's existing config keeps floating versions until reinstall or manual edit). A fresh install gets everything.
- **The smoke-test/package lists now exist in four lockstep places** (PS1 list, C# list, PS1 one-liner, C# one-liner). Adding a package means touching all four — the comments say so, but nothing enforces it. A future Environment Check "false green" after adding a dependency likely means one copy was missed.
- **Stage M's 300s synthesis timeout** may need revisiting at Harrison scale (plan Phase-2 item 10) — the Haven prompt is ~11KB; 16 buildings and 41 snapshots will be several times that, and generation latency scales with output size, not just input.
- **The work plan's Stage I references will recur.** Phase 5.3 (logic-linkage cascade condition) presumes a cascade stage exists to modify. Building Stage I from the Playbook spec is unplanned scope hiding inside Phase 3/5 — surface it explicitly when the conformance matrix is drawn up rather than discovering it mid-Phase-5.

---

## 7. Subjective read on this session

The thinnest user interaction of any session yet, and by all appearances deliberately so: one opening instruction ("read this work plan and implement these features"), one mid-session model switch (to claude-fable-5, silently), one structured decision answered (chose the middle deployment option — commit/push + hot-patch, notably *not* the full installer rebuild, consistent with someone tracking the repo-bloat issue), and two declined UAC prompts. No corrections, no clarifying questions, no friction anywhere.

The declined UACs deserve a careful read rather than an anxious one. This user has approved far more invasive actions before (installing software, hot-patching Program Files, setting git identity), so it isn't distrust of the operation. Most likely they were away from the machine when the prompts fired (the session ran autonomously into the evening) or preferred to run the elevated step themselves at their own moment. The handoff treats it as "pending user action," not "user rejected the work" — but the next session should confirm the deploy landed before assuming Phase 1 behavior exists in the live app.

The work plan itself is the strongest signal about where this collaboration sits: it's a five-phase, dependency-ordered engineering document that reads like it was co-produced with Claude in a claude.ai conversation and then handed to Claude Code for execution — the user is now operating as architect/reviewer across two Claude surfaces, with this CLI as the hands. That's a higher-trust, higher-leverage posture than even session 3's "can you set it up for me," and it raises the bar in a specific way: the plan anticipated failure modes (pinning, smoke tests, the empty-Part-VI shell) with enough precision that the main job was faithful execution plus honest documentation of the few places reality disagreed with the plan (`--force-reinstall`, Stage K having no buyout charts, Stage I not existing). Those deviations were documented rather than papered over, which is exactly what this user's "verify for real" ethos has rewarded in every prior session.
