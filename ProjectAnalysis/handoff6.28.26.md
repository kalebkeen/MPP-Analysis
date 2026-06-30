# PA Pipeline — Handoff, 2026-06-28

Written after the first end-to-end successful run against a real project (Popeyes Re-Image, Morrilton). This supersedes the original "PA Pipeline — Claude Code Handoff" doc and `project_config.schema_1.json` as the source of truth for how the app actually works — both of those describe a config shape the real Python scripts never read (see "Mistakes Made" below). Treat *this* document and the code itself as authoritative; treat the original handoff doc as historical context for intent only.

---

## 1. What this is

PA Pipeline is a Windows desktop app (PowerShell WinForms, compiled to a single `.exe` via PS2EXE) that configures, runs, and reviews a 9-stage Python analytics pipeline over construction-schedule data exported from MS Project. It's SCI's internal tool for turning weekly schedule snapshots into an executive PDF brief: forecast trend, critical-path delay attribution, buyout-package duration variance, and a forward look at remaining risk.

It is the sibling of `MPP-Pipeline.ps1` (a simpler existing tool that filters/exports `.mpp` files to XML) and was deliberately built to match its UI patterns, helper-function style, and C#-installer approach — same author intent, same conventions, so anyone who knows one tool can read the other.

**The pipeline it wraps** (`C:\ProjectAnalysis\*.py`), in run order:

| Stage | Script | Purpose |
|---|---|---|
| C | `extract_snapshots.py` | Read every MPP/XML snapshot via MPXJ (JPype/Java), write one parquet per snapshot |
| D | `resolve_wbs.py` | Resolve buyout-scope tasks into packages using WBS outline structure |
| E | `construction_variance.py` | Baseline-vs-actual duration variance for construction work, bucketed |
| F | `critical_path.py` | Week-over-week driving-path tracing → delay ledger (who/what controlled the finish) |
| G | `forward_look.py` | Building turnover, float-health bands, forward look-ahead, completion-date range |
| H | `buyout_analysis.py` | Buyout package duration variance by procurement stage |
| K | `generate_charts.py` | 7 matplotlib charts from D/E/F/G/H output |
| L | `assemble_pdf.py` | Two-pass ReportLab build → cover + TOC + body, merged with pypdf |
| M | `run_qc.py` | Data-quality checks; optional `--synthesize` calls Opus to draft narrative text |

Stage J (narrative) is not a script — it's `stage_j/narrative.json`, edited by hand or partly populated by Stage M's `--synthesize`. `assemble_pdf.py` falls back to placeholder text for any narrative key that's missing, so the pipeline runs end-to-end even with an empty `{}`.

---

## 2. Evolution and rationale

This was built in one continuous session, in response to real failures as they were hit — there was no test environment standing in for the user's actual MS Project exports, so "looks right" and "is right" diverged repeatedly. Roughly in order:

1. **Initial build.** Wrote `PA-Pipeline.ps1` (5 tabs: Project Setup, Pipeline Stages, Run Log, Outputs, Settings), `PA-Pipeline-Setup.cs` (self-elevating C# installer, csc.exe-compiled, base64-embeds the `.ps1` + all 9 `.py` scripts + the PS2EXE module), and `Build-Setup.bat`, following the original handoff doc's schema and tab spec, and `MPP-Pipeline.ps1`'s established helper/styling conventions.

2. **Launch crash: `$PSScriptRoot` empty.** PS2EXE doesn't reliably populate `$PSScriptRoot` in the compiled `.exe`. Added `Get-AppRoot` with a fallback chain (`$PSScriptRoot` → `$MyInvocation.MyCommand.Path` → `[Assembly]::GetEntryAssembly().Location` → `AppDomain.BaseDirectory` → cwd).

3. **Schema mismatch, discovered incrementally then fixed wholesale.** A question about the Status Date field's purpose led to finding the GUI saved `project.status_date` while the scripts read `project.analysis_status_date` — a silent rename mismatch. Checking the sibling `baseline_date` field next found something worse: the scripts read it from `schedule.baseline_date`, and there was no `schedule` section in the schema at all — `cfg["schedule"]` is a hard `KeyError`, not a soft miss. That second finding made it clear the mismatch wasn't a couple of typos, it was systemic: the original handoff doc's schema ("schema A") and what the actual scripts read ("schema B") were two different designs. Audited every `cfg[...]` access across all 9 scripts, confirmed the scripts were internally consistent with each other (and identical to a second copy found in an `Automation/` reference folder), and rebuilt Tab 1 and the whole config schema around schema B: `paths.output_root`/`xml_snapshots_folder` (not `output_dir`/`snapshots_dir`), `buildings.names` + `buildings.phases` (not a list of `{id,label,phase}`), new `schedule`/`wbs_resolver`/`construction_variance.buckets`/`working_calendar` sections. Validated by writing a Python script that exercises every required `cfg[...]` access from all 9 stages against the generated config — not just "does it parse," but "would any stage actually `KeyError` on this."

4. **Save Config → Access Denied, simultaneously with stages reading a stale config.** Two compounding causes: (a) the app installs to `C:\Program Files\PA-Pipeline\` (elevated installer), but the *running app* never elevates, so it could never write its own config back to its own install directory; (b) "Load Config"'s file picker defaulted to that same Program Files folder, where a config file from *before* the schema-B rewrite was still sitting as a decoy — picking it (a completely reasonable thing to do) repointed the active config path at a non-writable, wrong-shaped file for the rest of the session. Fixed by relocating all runtime-writable state (config + venv) to `%LocalAppData%\PA-Pipeline\` via `Get-DataRoot`, with a one-time migration that copies forward a config sitting next to the exe so in-progress work isn't lost, and by pointing the Load Config dialog at the new writable location instead.

5. **First full pipeline attempt: JVM mismatch, Carlito crash.** Stage C failed with `JVMNotSupportedException: JVM mismatch, python is 64 bit and JVM is 32 bit` — the machine had several Javas installed, and JPype's own auto-detection picked a 32-bit one despite working 64-bit JDKs being present. Found that `environment.java_home` already existed in the schema but had never actually been wired into `start_jvm()` — it was as dead as the status-date field had been. Wired it in, added a Java Home field to Tab 5 (there hadn't been one), and taught the Environment Check to detect bitness mismatches instead of just "is java on PATH." Stage L crashed separately with `KeyError: 'Carlito'` — the font-fallback code *printed* "falling back to Helvetica" but never actually registered anything under the Carlito name, so the first `setFont("Carlito", ...)` blew up. Fixed by aliasing Carlito → Helvetica via `pdfmetrics.Font(name, fallback_face, encoding)` so every existing call site keeps working unchanged.

6. **Buyout/construction split was UID-ordering, and that's fragile.** The pipeline classified buyout vs. construction tasks with a single UID cutoff (`uid <= N` = buyout). The user pointed out that buyout packages are often added to a schedule *after* construction work already exists, so they can get UIDs higher than construction tasks — breaking the cutoff. Replaced with WBS-outline-prefix matching (`schedule.buyout_outline_prefixes`, a *list* — supports both "one clean branch" and scattered branches) across all 5 affected scripts, with a shared `is_buyout_outline()` helper. Validated against a synthetic schedule built specifically to reproduce the reported scenario (a buyout task with a UID *higher* than every construction UID) — it classifies correctly because UID is no longer part of the check at all.

7. **Encoding and font-rendering cleanup.** Stage C crashed (after fully succeeding) on `UnicodeEncodeError` printing a `✓` — piped stdout defaults to cp1252 on Windows. Fixed by forcing `PYTHONIOENCODING=utf-8`/`PYTHONUTF8=1` on the child process. Stage K printed hundreds of `findfont: 'Liberation Sans' not found` warnings — the fallback font name didn't exist on Windows either. Fixed with a real fallback chain ending in matplotlib's bundled DejaVu Sans.

8. **First fully-clean 9-stage run** against the real "Popeyes Morrilton" project: 8 snapshots, 0 extraction errors, 99.3% UID persistence, real KPIs in the PDF.

9. **Baseline duration was zero everywhere in Stage E's output.** The user's hypothesis ("Baseline0 might be blank, Baseline1 might hold the real data") was *half* right: probing the real files via JPype directly showed construction tasks' baseline does live in Baseline1, but buyout tasks' baseline lives in Baseline0 — the opposite. A single global "baseline number" setting couldn't serve both. Also found a second, independent bug: the single-snapshot stages (D/E/H) picked the *alphabetically last* filename, which happened to be the oldest prelim schedule, not the latest progress snapshot — and that prelim file had zero construction baseline in *either* slot. Fixed with per-section baseline numbers (`schedule.buyout_baseline_number` / `construction_baseline_number`) and a choosable analysis snapshot (`schedule.analysis_snapshot`, defaulting to latest-by-parsed-date), both exposed on Tab 1. Verified directly against the real files: 69 of 79 previously-zero `baseline_span` rows became non-zero.

10. **PDF said "20 pages," had 18.** The page-count offset was added into the printed *total* but never into the per-page *number*, so footers ran 1..18 while claiming "of 20." Fixed by counting the cover+TOC's actual rendered pages and offsetting the body's footer by that count.

11. **Automatic TOC page numbers.** The TOC had been showing hardcoded numbers from an unrelated reference project. Implemented using ReportLab's `afterFlowable` doc-template hook plus zero-size `_Bookmark` flowables marking each section's start — verified by extracting the rendered PDF's actual TOC claims and confirming the real section header text is on each claimed page (8 of 8 correct).

---

## 3. Architecture (current state)

- **GUI:** `PA-Pipeline.ps1`, WinForms, 5 tabs, compiled to `PA-Pipeline.exe` via PS2EXE. `Set-StrictMode -Version Latest` throughout.
- **Two-root filesystem split**, settled on after the Access Denied bug:
  - `$script:AppRoot` = wherever the exe is running from (`C:\Program Files\PA-Pipeline\` once installed) — read-only at runtime. Holds `PA-Pipeline.exe`, `Uninstall.exe`, and the 9 `.py` stage scripts.
  - `$script:DataRoot` = `%LocalAppData%\PA-Pipeline\` — read-write at runtime, no elevation needed. Holds `project_config.json` and the managed `venv`.
- **Installer:** `PA-Pipeline-Setup.cs`, C# 5 (`csc.exe`, no SDK dependency), self-elevates via UAC (`runas` relaunch in `Main()`) because it writes to Program Files and creates the venv. Embeds the `.ps1`, all 9 `.py` scripts, and the PS2EXE module as base64 string constants — zero external file dependencies at build or install time. **Important maintenance fact:** re-running `Build-Setup.bat` alone does *not* pick up edits to the `.ps1` or any `.py` file — the base64 embedding is a separate manual step (done via ad hoc PowerShell during this session, not itself a saved/runnable script). Whoever edits the source files next needs to re-embed before rebuilding, or the installer ships stale code with no warning.
- **Config:** a single `project_config.json`, schema driven entirely by what the Python scripts actually read (not the original handoff doc — see Mistakes below). `Get-DefaultConfig` in the `.ps1` and `BuildConfigJson` in the installer must be kept in sync by hand; there's no shared schema source of truth between them.
- **Config loading is self-healing.** `Merge-ConfigDefaults` recursively backfills any missing key from defaults on load, so an older/partial config doesn't crash the app — but it only fills *missing* keys; it doesn't fix a key that exists with the wrong shape (a separate explicit migration was needed when `buyout_analysis.stage_classification` changed from a flat string list to `{stage, keywords}` dicts).
- **Stage status** (Tab 2's checklist) is determined by **output marker file existence on disk**, not a stored flag or exit code alone — deliberate, per the original spec, and it's self-healing: open the app fresh and the status board reflects on-disk reality, not memory.
- **Process streaming** (`Invoke-PythonStage`): a producer/consumer pattern. `Register-ObjectEvent` callbacks for `OutputDataReceived`/`ErrorDataReceived` only push raw lines onto a `ConcurrentQueue` — they never touch a WinForms control directly, since they fire on a background thread. The UI thread drains the queue inside a `DoEvents`-pumping loop, which is the only place that touches `rtbLog`. This avoids the classic PowerShell+WinForms cross-thread control-access crash.
- **Buyout/construction classification** is WBS-outline-prefix based (`is_buyout_outline()`, replicated/imported across 5 scripts), not UID-based — chosen because UID order isn't a reliable signal once a schedule has been edited over its life.
- **Snapshot selection** for the single-snapshot stages (D/E/H) goes through a shared `select_single_snapshot()` (in `critical_path.py`, imported by the others): explicit CLI arg → configured `schedule.analysis_snapshot` → latest by parsed filename date → alphabetically last as a final fallback.
- **PDF pagination** is measured, not assumed: cover+TOC is built once to learn its real page count, then the body is built with a footer offset by that real count; the TOC itself is built twice (once with placeholder/reference numbers just to measure, once with real auto-computed numbers from `afterFlowable` bookmarks). A `toc_overrides` key in `narrative.json` bypasses all of this for full manual control.

---

## 4. Work accomplished

- Full 5-tab GUI app + self-elevating installer + build script, matching `MPP-Pipeline.ps1` conventions.
- Entire config schema reconciled to match the real Python scripts (not the stale handoff doc), with an automated cross-check (every stage's required `cfg[...]` access exercised against the generated config) rather than just "does the JSON parse."
- Runtime-writable state relocated off Program Files; self-healing config migration; Load Config no longer points at a decoy file.
- JVM bitness wired up and exposed in the GUI; Environment Check now catches 32-bit/64-bit mismatches.
- Buyout/construction classification rebuilt around WBS outline position instead of fragile UID ordering, validated against a synthetic "late-added package" scenario.
- Per-section baseline-slot configuration (buyout vs. construction read different MS Project baseline numbers) plus a choosable analysis snapshot, both proven against the real project's data (69/79 previously-zero rows fixed).
- Unicode/console-encoding crash fixed; font-fallback chains fixed for both matplotlib (Stage K) and ReportLab (Stage L), so missing-Carlito degrades gracefully instead of crashing or spamming warnings.
- PDF page-count/footer mismatch fixed; TOC page numbers now auto-computed and verified against the actual rendered document (8/8 correct), with a manual override escape hatch preserved.
- **First clean 9-stage run against a real project**, producing a real 20-page executive brief with real KPIs.

Every fix above was validated against the venv's real interpreter/libraries and, where data-dependent, against the user's actual exported schedule files — not just syntax-checked. The GUI itself was validated via full non-interactive execution smoke tests (the whole script body runs, including startup config load, with the final `Application.Run` swapped for an exit hook) since there's no way to click through a real WinForms session headlessly.

---

## 5. Mistakes made

Worth being honest about, since the pattern is informative for whoever works on this next:

1. **Didn't cross-check the handoff doc's schema against the actual scripts before writing the first version.** The Python scripts were available in `C:\ProjectAnalysis` from the start. A single `grep` pass for `cfg[` across all 9 files at the very beginning would have caught the `output_dir`/`output_root`, missing-`schedule`-section, and `buildings` shape mismatches in one pass instead of three separate rounds of user-reported runtime failures. This was the single largest source of rework in the whole engagement.
2. **Didn't anticipate the Program-Files-write conflict at design time.** Installing to Program Files while having the *app itself* write its own config back to that same directory is a contradiction that should have been caught by thinking through "who has write access when" before building, not after the user hit Access Denied.
3. **Defaulting Load Config's file picker to the install directory was a foreseeable trap**, especially right after deciding to relocate the live config elsewhere — the install directory was guaranteed to have a stale decoy file in it for anyone who'd used an earlier build.
4. **Used `"Liberation Sans"` as a font fallback without checking it's installed on Windows.** It isn't, by default. Should have gone straight to a fallback chain.
5. **The original Carlito-fallback code in two different files (Stage K and Stage L) printed a message claiming a fallback would happen, but didn't actually make it happen.** A "we'll fall back" log line is not the same as a tested fallback path — this is exactly the kind of gap that only surfaces when the missing-font branch is actually exercised, which on Windows it always is.
6. **A PowerShell-specific `.NET` overload-resolution bug** (`Graphics.DrawString` given a `Rectangle` where PowerShell's dynamic binder guessed the wrong overload) slipped through because it's in paint/owner-draw code, which can't be exercised by a non-interactive smoke test — paint events only fire on real rendering. This is a structural blind spot in the verification approach used throughout (see below), not a one-off slip.
7. **Found the same class of bug (doc/schema says X, code reads Y) three separate times** before doing a full audit — `analysis_status_date`, then `baseline_date` (which escalated the investigation), then `java_home`. The second occurrence should have triggered a full audit immediately rather than the third.

**A note on method, not just outcomes:** nearly every bug in this project was the kind that only shows up under real conditions — real fonts installed (or not), real JVMs on the registry, real MS Project baseline conventions, real piped-vs-console stdout behavior. Static analysis and headless smoke tests catch syntax errors and logic errors; they cannot catch "this font isn't actually on this machine" or "this baseline slot is actually empty for this project." That gap was closed in this session by probing the real venv/JPype/MPXJ directly and by testing against the user's actual exported files whenever a fix touched data-shape — that needs to stay the standard for any future change here, not just code review.

---

## 6. Remaining TODOs

From the project's tracked open-items memory (`pa-pipeline-open-followups`) plus this session's findings:

1. **Tab 1's "Baseline MPP/XML" field is dead code.** `paths.baseline_mpp` is read by zero of the 9 scripts. Left in place at the user's request; decide whether to remove it or wire it to something (e.g., a baseline-vs-snapshot cross-check) before touching Tab 1 again.
2. **Uninstaller is untested and likely broken for the Program Files half.** `Uninstall.exe` runs non-elevated (same as the main app), so its `rmdir /S /Q` of the Program Files install directory will likely fail with Access Denied — only the `%LocalAppData%` cleanup is confirmed safe. Needs either a real test or self-elevation added to `WriteUninstaller()`'s generated source.
3. **No JVM heap-size configuration.** `jpype.startJVM()` runs with no `-Xmx`; fine so far, but there's no config field to raise it if a very large MPP file ever needs more heap.
4. **Carlito never actually renders** — `CARLITO_DIR` is hardcoded to a Linux path that doesn't exist on Windows, so charts/PDF always use the Helvetica/Calibri fallback. The crash this caused is fixed; the visual-fidelity gap is not. Only worth fixing if exact brand-font matching matters.
5. **Stage G's per-building section looked thin** on the real test run ("1 building, slip +233 days") — `buildings.names` on Tab 1 likely doesn't match the actual summary-task names in this project's schedule. Flagged, never investigated further.
6. **The 8-entry TOC section list (`TOC_SECTIONS` in `assemble_pdf.py`) is still a hardcoded list of titles/keys**, even though the page *numbers* are now automatic. If a section is ever added, removed, or renamed, that list needs a manual update — there's no dynamic "discover sections from the story" mechanism.
7. **`run_qc.py --synthesize` (the Opus narrative-generation path) has never been exercised** in this project. It's wired into the GUI ("Run Selected + Synthesize") but the actual API-calling code path is untested here.
8. **Several advanced config sections are never exposed in any tab** — `qc.*` (warn thresholds, watch-list buildings), `charting.*` beyond what's used, `critical_path.*` tuning, `pdf_assembly.*` beyond title/company. They carry through correctly from defaults, but tuning them today means hand-editing `project_config.json`.

---

## 7. Potential issues on the horizon

- **This is the first real project this pipeline has run against.** Every bug found this session was data- or environment-shape-specific (JVM bitness, baseline slot, font availability, UID ordering). A second or third project with different MS Project conventions, a different scheduler's habits, or a different machine's installed software should be *expected* to surface a few more rounds of this — the pattern so far has been "looks fine until tested for real," not "now it's done."
- **No automated sanity-check that a configured baseline slot actually has data.** The buyout/construction baseline-zero bug was caught by a human noticing wrong numbers and a manual JPype probe. A future project with yet another baseline arrangement (Baseline2, say) would silently produce all-zero variances again unless someone notices. Worth considering a Stage C check that warns if a configured baseline slot is mostly empty.
- **`java_home` is a static path the user enters once.** If that JDK is ever uninstalled or moved, Stage C's JVM detection falls back to JPype's own (already shown to be unreliable on this machine) auto-detection, silently reintroducing the original bitness-mismatch crash. The Environment Check tab catches this — but only if run proactively before a pipeline run, which isn't enforced.
- **The installer always runs a full `python -m venv` + pip install of ~10 packages on every install/reinstall**, even when the existing venv is already correct. Harmless but adds real wall-clock time (a minute or more, since several of those packages — pandas, matplotlib, pyarrow, mpxj, jpype1 — aren't small) to every reinstall cycle.
- **The base64-embedding step for the installer is manual and unscripted.** Nothing currently prevents `Build-Setup.bat` from happily recompiling a stale installer if someone edits a `.py` or the `.ps1` and forgets to re-embed first.
- **The outline-prefix buyout/construction split assumes a fairly clean WBS** (buyout and construction separated into one or a few top-level branches). A project where they're interleaved at every phase/building level would need a different mechanism — outline prefixes wouldn't be expressive enough.
- **PDF assembly now does up to 4 full ReportLab/pypdf builds per run** (body pass 1, cover+TOC measurement build, cover+TOC real build, body pass 2) to get page counts and TOC numbers exactly right. Currently fast (seconds), but worth knowing if report size grows substantially.

---

## 8. Where this goes next

The natural next steps, roughly in order of value:

1. **Run it against a second real project.** This is the highest-value next action — everything found so far was found this way, and a single data point can't tell you which assumptions are project-specific versus universal (the per-section baseline split, the outline-prefix scope, the building-name matching).
2. **Exercise the Stage M `--synthesize` path for real** and check the resulting `narrative.json` actually reads well in the assembled PDF.
3. **Test the uninstaller for real**, or just fix it proactively (item 2 in TODOs) since the fix is small and the current state is a known gap.
4. **Decide on the dead `baseline_mpp` field** rather than letting it linger as a question every time someone touches Tab 1.
5. Longer-term, consider whether the two-root (`AppRoot` / `DataRoot`) split is worth keeping versus simplifying to "everything lives under `%LocalAppData%`, nothing needs Program Files or elevation at all" — the current split exists mostly because the installer pattern was inherited from `MPP-Pipeline.ps1`, which never had this app's heavier runtime needs (its own managed venv). A from-scratch design today might not choose Program Files at all.
