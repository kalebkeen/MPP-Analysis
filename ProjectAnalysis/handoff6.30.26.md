# PA Pipeline — Handoff, 2026-06-30

This supersedes `handoff6.28.26.md` as the authoritative session record. Read that document first for the foundational architecture, the schema-B reconciliation, and the backstory behind the two-root filesystem split — all of that is still current and is not repeated here. This document covers the 2026-06-30 session only: the ADDENDUM features, the bugs found during real install testing, and the Java bundling work that followed.

**Related docs and skills used this session:**
- Input: `PA_Pipeline_CodeHandoff_1.md` (the original spec + the ADDENDUM sections A–F added later — the ADDENDUM is what this session actually built)
- `handoff6.28.26.md` — still the authoritative source for the pre-session architecture and the 11 lessons from the first real-project run
- Skills invoked: `anthropic-skills:pdf`, `anthropic-skills:pdf` (for reading handoff docs), standard Claude Code tools (Bash, PowerShell, Read/Edit/Write, Grep, Glob)
- Claude Code version used: claude-sonnet-4-6

---

## 1. What changed this session

The ADDENDUM to the original handoff doc described five follow-on items that hadn't been built yet. All five are now shipped. In addition, two bugs were found during real install testing and fixed, and a Java runtime was bundled after the user reported the Environment Check's Java check failing on a clean machine.

### ADDENDUM items implemented

**B — Bundled Python 3.12.10 in the installer**
The original app required a real Python on PATH to create the venv. On a clean Windows machine, `python.exe` often resolves to the Microsoft Store alias stub (exit code 9009), silently failing venv creation. Fix: embed the official `python-3.12.10-amd64.exe` in the installer and run it silently to `<installDir>\python-runtime` with `PrependPath=0` so it stays invisible to the rest of the machine. The installer now uses that bundled interpreter for all venv creation; the Settings tab's "Bootstrap Python" field becomes an override-only affordance, no longer an auto-detected PATH lookup.

*Discovery worth noting:* The natural approach — embed the 26MB installer binary as a base64 string constant, same as the other embedded files — triggered `csc.exe` hard-failing with "No logical space left to create more user strings". That's the .NET #US metadata heap, and chunking the string into smaller pieces doesn't help since they all share the same heap. Switched to embedding via `/resource:` PE resource flag instead — verified with a round-trip SHA256 check before wiring it in. The same technique was used later for the Java runtime for the same reason.

**C — Corrected environment check (three distinct failure states, not one)**
The original "Check 1: system Python ≥ 3.9" check only regexed the version text. If the process returned the Store stub's message ("Python was not found; run without arguments to install from the Microsoft Store..."), the regex failed silently and reported "✗ System Python below 3.9" — wrong diagnosis. Replaced with: (1) path-exists check, (2) exit-code + stub-text check, (3) genuine version-parse, each with its own specific message.

**D — Config scoping on launch**
Added `last_config.txt` in DataRoot (not AppRoot — see the decoy-config lesson in handoff6.28.26.md for why AppRoot is never touched for config). On startup, if `last_config.txt` points at an existing file, load that instead of the fixed DataRoot path, so working across multiple projects over time just works. Also added a `StatusStrip` showing either the active config path or "No project loaded" when nothing is configured, and Tabs 2–4 now disable until a config is saved or loaded.

**E — Stage J "Open Narrative JSON" missing-file gap**
The button previously silently created an empty `{}` and opened it in Notepad regardless. Now it detects the missing file and shows a two-button dialog ("Create Empty Template" / "Cancel"). The template skeleton's 23 keys were pulled directly from every `narrative.get(...)` call site in `assemble_pdf.py` and every key `run_qc.py`'s `--synthesize` writes — not guessed. Also corrected the message text: the addendum said the file is "generated after Stage H," but the codebase is explicit that it comes from Stage M's `--synthesize`. Shipping accurate UI text rather than copying a documentation error.

**F — Editable chart_data_workbook.xlsx in Stage K**
Each of the 7 `chart_*` functions in `generate_charts.py` was split into a `_data_*` function returning a clean DataFrame + chart title, and a `_render_*` function doing the matplotlib PNG output. A new `write_chart_workbook()` uses those same DataFrames to build a single `stage_k/chart_data_workbook.xlsx` with one tab per chart (native openpyxl `LineChart`, `BarChart`, `ScatterChart` objects styled to the house palette). A second `output_marker2` key was added to Stage K's pipeline_state entry so the status board requires both the PNG set AND the workbook to be present before marking Stage K green.

Chart types per chart:
| Chart | Excel type |
|-------|-----------|
| Forecast Trend | LineChart (date x-axis, forecast + baseline series) |
| Variance Trajectories | LineChart (wide-pivoted, one series per bucket) |
| Driving Resource | ScatterChart (wide-pivoted, one series per resource) |
| Delay Waterfall | BarChart col, per-point red/green/gray via DataPoint.graphicalProperties |
| Resource Net Bar | BarChart bar (horizontal), same per-point coloring |
| Building Lollipop | BarChart bar, stacked floating-bar (invisible baseline + visible slip) |
| Float Histogram | BarChart col, Critical band red, others navy |

Verified end-to-end against synthetic parquet inputs using a real Python + openpyxl install: all 7 charts render, all sheets have 1 chart object and the right data row count, `openpyxl.load_workbook` round-trip succeeds.

### Bugs found during real install testing

**output_marker2 PropertyNotFoundException × 8 on startup**
Root cause: I added `output_marker2` only to Stage K's default `pipeline_state` entry, not the other 8. Under `Set-StrictMode -Version Latest`, dot-accessing a hashtable key that doesn't exist at all throws — unlike a key that exists with an empty value. Fix: added `output_marker2=''` to every stage's default shape. `Merge-ConfigDefaults` then automatically backfills it for any already-saved config file that predates this key, since the key is genuinely absent in those files (vs merely blank).

**java_home stale-value migration miss**
After bundling Java, the Environment Check reported "Java Home not set" even though a bundled runtime was now being installed. Root cause: the user's existing `project_config.json` already had `environment.java_home` saved as `""` from before Java bundling existed. `Merge-ConfigDefaults` only backfills keys that are entirely MISSING — it does not touch keys that already exist with a stale blank value. So the new non-blank default from `Get-DefaultConfig` never reached the user's config file.

Fix: added a live fallback in `Refresh-SettingsFromConfig`: if the Java Home textbox is still blank after populating from config, auto-fill it with `Join-Path $script:AppRoot 'java-runtime'` (the same formula `Get-DefaultConfig` uses). This runs at every app launch, meaning the Settings tab and Environment Check display the correct bundled path immediately. When the user runs a stage (or saves config), `Save-ConfigFromUI` writes `$tbJavaHome.Text` into `environment.java_home` and `Save-ProjectConfig` saves it to disk before the Python process reads the file — so Stage C's JVM pin heals automatically without any explicit user action.

*Pattern to remember:* Any schema change that alters the DEFAULT VALUE of an existing key (not adds a new key) requires an explicit live-fallback like this, because `Merge-ConfigDefaults` cannot patch stale-but-present values.

### Java runtime bundling

After the Environment Check correctly reported Java as missing (the real Stage C dependency), the Java runtime was bundled following the same pattern as Python:

- **Distribution:** Eclipse Temurin JRE 21 (OpenJDK build, redistribution-friendly license, unlike Oracle JRE). Windows x64 `.zip`, ~47MB.
- **Embedding:** `/resource:` PE embedding, same as Python installer, same reason (same csc.exe string-heap limit would block base64 encoding of anything this large).
- **Extraction:** `System.IO.Compression.ZipFile.ExtractToDirectory` into a temp folder, then `Directory.Move` of the single top-level folder (e.g. `jdk-21.0.11+10-jre`) to `<installDir>\java-runtime`. The folder name is discovered programmatically rather than hardcoded, so it won't go stale when Temurin releases a new version.
- **Config wiring:** `environment.java_home` (which already existed and already wired into `start_jvm()` in `extract_snapshots.py` and the Settings tab) is set to the bundled JRE path by the installer. No new config field needed — unlike `python_exe` (which already meant "the venv interpreter used for every stage run" and couldn't be reused), `java_home` had no competing meaning, so it serves as both the default and the override in a single field.
- **No PATH dependency:** The Environment Check's Java section dropped the `Get-Command java.exe` PATH fallback. JPype's own JVM auto-detection has already demonstrated it picks a 32-bit JVM over a working 64-bit one on this machine; a PATH-resolved "java" is just as unreliable. Same reasoning as the Python/Store-stub fix.

Also discovered and fixed while reasoning through Java bundling: `Save-ConfigFromUI` never persisted the Bootstrap Python textbox value back into `paths.system_python_exe`. User-typed overrides to that field only lived for the current session and silently reverted to the bundled-default path on next launch. Fixed by adding the obvious missing line alongside the existing `environment.java_home` write.

### Embed-Sources.ps1 (new file)

The installer's base64 embedding step was undocumented and unscripted — running `Build-Setup.bat` alone would happily recompile a stale installer if any `.ps1` or `.py` file had been edited without re-embedding. Added `Embed-Sources.ps1` as a permanent, runnable tool that: re-encodes `PA-Pipeline.ps1` and all 9 stage scripts into their `_B64` constants in `PA-Pipeline-Setup.cs`, and copies the bundled Python installer and Java JRE zip next to the `.cs` so `Build-Setup.bat`'s `/resource:` flags can find them. Accepts `-PythonInstallerPath` and `-JavaRuntimePath` params; omitting either leaves the existing staged file untouched.

Usage:
```
.\Embed-Sources.ps1 -PythonInstallerPath C:\...\python-3.12.10-amd64.exe -JavaRuntimePath C:\...\temurin-21-jre-windows-x64.zip
Build-Setup.bat
```

---

## 2. Architecture (current state)

All of the two-root split, schema-B config shape, process streaming, and stage-status patterns from `handoff6.28.26.md` are unchanged. Additions:

- **Installer embeds three categories of payload:** (1) PA-Pipeline.ps1 + 9 .py scripts as base64 `const string` in C# source, (2) python-3.12.10-amd64.exe as a PE resource (`/resource:` flag, not a string constant — csc.exe's #US metadata heap can't hold ~26MB of string data), (3) temurin-21-jre-windows-x64.zip as a second PE resource, same reason.
- **Installer step order (11 steps):** Prepare → Extract files → Compile .exe → Install Python runtime → Install Java runtime → Create venv → Install packages → Write config → Shortcuts → Uninstaller → Registry.
- **`Merge-ConfigDefaults` is self-healing for missing keys only.** Stale-but-present keys with wrong values need explicit per-field live-fallback logic (see Refresh-SettingsFromConfig for the two examples now in the codebase: Bootstrap Python and Java Home).
- **`output_marker2`:** Any `pipeline_state` stage entry can now carry an optional `output_marker2` key. `Get-StageStatusText` checks both markers before returning `success`, so Stage K (which requires both the PNG set AND `chart_data_workbook.xlsx`) shows green only when both are present. All stages that don't use `output_marker2` carry it as an empty string — NOT absent, because `Set-StrictMode -Version Latest` throws on dot-access of a key that doesn't exist at all.
- **`last_config.txt`** in DataRoot remembers the last opened/saved config path across launches, enabling seamless multi-project use. Never stored in AppRoot (decoy-file lesson).
- **Stage K `_data_*` / `_render_*` split:** Each chart function's data assembly now lives in a `_data_<name>()` function returning a clean DataFrame + title. The PNG (matplotlib) and the workbook (openpyxl) both call the same data function — no separate maintained copy of any chart's data logic.

---

## 3. Work accomplished this session

- ADDENDUM items B–F built, tested against real tools (real csc.exe compile, real openpyxl + pandas + pyarrow in a local Python 3.12 embeddable install for chart verification, real SHA256 round-trip checks for all embedded resources).
- Discovered and confirmed the csc.exe #US metadata heap limit empirically rather than just asserting the risk.
- Fixed two bugs found during the user's real install testing (output_marker2, java_home stale-value).
- Bundled Temurin JRE 21 following the same pattern established for Python, verifying the zip-extract-and-rename logic against the real 47MB file before integrating.
- Added `Embed-Sources.ps1` closing a long-documented gap ("the base64 embedding step is manual and unscripted").
- Verified all four config-schema diffs (`Get-DefaultConfig` PS1 vs `BuildConfigJson` C#) came out empty — same discipline established in the prior session, maintained here.
- Every commit pushed to `kalebkeen/MPP-Analysis` main; final installer is ~77MB.

---

## 4. Mistakes made

1. **Assumed `Set-StrictMode -Version Latest` would silently return `$null` for a missing hashtable key.** It throws. Adding `output_marker2` to only Stage K's default and then reading it on every stage on startup produced 8 crashes before the first tab rendered. The fix is trivial (add the key to every stage's default), but the assumption cost a real end-to-end test round-trip to discover.

2. **Assumed `Merge-ConfigDefaults` would heal the stale `java_home = ""` migration case.** It doesn't — only fills absent keys, not present-but-blank ones. Required a separate live-fallback in `Refresh-SettingsFromConfig`. The pattern for dealing with this is now documented and exemplified twice in the codebase (Bootstrap Python and Java Home), but it's easy to miss for the next schema evolution.

3. **Assumed base64-chunked string arrays would bypass the csc.exe string-literal limit.** The limit is on the total #US heap across ALL string literals in the assembly, not any individual one. Chunking generates more tokens but the same total bytes — no improvement. Discovered empirically (compile failed with a clear error message), resolved by switching to PE resource embedding.

4. **`JAVA_RUNTIME_RESOURCE_NAME` was defined on `Program` class and used unqualified inside `SetupForm.RunInstall()`.** C# caught this at compile time with CS0103 (name not found in current context). Required a `Program.` qualifier at the two call sites.

---

## 5. Remaining TODOs

*Inherited from `handoff6.28.26.md` (numbering matches that doc's section 6):*

1. **Uninstaller untested and likely broken** for the Program Files half — runs non-elevated, so `rmdir /S /Q` of an admin-owned directory will probably fail with Access Denied. Needs either a test or self-elevation added.
2. **No JVM heap-size config.** `jpype.startJVM()` runs with no `-Xmx`.
3. **Carlito never actually renders.** `CARLITO_DIR` hardcodes a Linux path. Charts and PDF always use the Helvetica/Calibri fallback.
4. **Stage G per-building section looked thin** ("1 building, slip +233 days") — `buildings.names` likely doesn't match the actual summary-task names in this project's schedule.
5. **TOC_SECTIONS in `assemble_pdf.py` is still a hardcoded list** of 8 titles. Adding, removing, or renaming a section requires a manual update there.
6. **Stage M `--synthesize` untested** against a real project. API call path not exercised.
7. **Several advanced config sections not exposed in any tab** — `qc.*`, `charting.*` beyond basics, `critical_path.*`, `pdf_assembly.*` beyond title/company. They carry through from defaults correctly but can't be tuned without hand-editing JSON.

*New from this session:*

8. **Git repo growing with large binary commits.** The installer exe is now ~77MB (it grows with every rebuild since it embeds 26MB Python + 47MB Java), and both binary payloads (python-3.12.10-amd64.exe, temurin-21-jre-windows-x64.zip) are committed directly to the repo (~75MB total). GitHub already warned about file size. Git LFS would prevent history bloat.
9. **chart_data_workbook.xlsx visual fidelity in real Excel not verified.** The openpyxl API was tested structurally (sheets exist, chart objects are present, data round-trips via `load_workbook`), but no actual Excel was opened to confirm the charts render usably. The building_lollipop stacked floating-bar chart in particular uses a non-standard technique that would benefit from visual confirmation.
10. **Real Windows end-to-end install not yet tested for the bundled runtimes.** The Python installer (MSI) returned exit code 3 in the sandbox environment (MSI service restricted), and the Java JRE zip extraction was only tested against a locally-extracted test exe (not a real elevated install into Program Files). Everything else (csc.exe compile, embedded resource SHA256 verification, Schema diff) was verified for real. The install steps themselves need a real end-to-end run on the target machine.
11. **`paths.baseline_mpp` is still dead code.** Read by zero of the 9 scripts. Either wire it to something (a baseline cross-check on Stage C?) or remove it from the UI.

---

## 6. Potential issues on the horizon

Most of the structural risks from `handoff6.28.26.md` section 7 are unchanged. Two new ones:

**The `Merge-ConfigDefaults` stale-value limitation will bite again** on the next schema evolution that changes an existing key's default value rather than adding a new one. The pattern for handling it (live fallback in `Refresh-SettingsFromConfig`) is now established and documented, but it requires intentional action — it's easy to assume Merge-ConfigDefaults will handle it.

**The installer's "don't clobber existing config" rule means new schema features don't auto-apply on reinstall.** A user who reinstalls to get the Java runtime still has their old blank `java_home` in their saved config. This session's live-fallback in `Refresh-SettingsFromConfig` handles it for java_home specifically, but any future installer-step that pre-populates a config field will face the same pattern: existing-config users won't benefit from the new default until the app is opened (where the live fallback fires) and they save config or run a stage.

---

## 7. Subjective read on this session

The session was productive and essentially friction-free. The user communicated in very short bursts ("yes that is fine," "push to git hub," copy-pasted error messages with no additional context), which in this case reflects confidence rather than impatience — they trusted Claude's judgment on every architecture decision without requiring justification, and there was no pushback or redirection on any approach taken.

The two bugs that surfaced during real testing (output_marker2, java_home) were reported matter-of-factly, diagnosed and fixed quickly, and no frustration was expressed. The user's request to bundle Java came immediately after the Environment Check failed, which suggests they're actively testing the new installer on their machine, which is exactly the right next step per the prior session's retro ("run it against a second real project" / "test the uninstaller for real").

Confidence in Claude's work: high. The user trusted Claude to: (a) deviate from the addendum's literal spec when the spec conflicted with already-fixed real bugs, (b) make architecture decisions (PE resource vs base64, single-field vs two-field for java_home) without second-guessing, and (c) write this handoff document rather than writing it themselves.

One observation worth preserving: this user writes very short messages even when the task is large. "push to git hub" means exactly that, no elaboration. Planning to match that communication register in future sessions.
