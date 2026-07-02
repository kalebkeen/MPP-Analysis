# PA Pipeline — Handoff, 2026-06-30 (session 3)

This supersedes `handoff6.30.26-2.md` as the authoritative session record. Read that document first (and `handoff6.30.26.md`, and `handoff6.28.26.md` behind it) for the foundational architecture, the two-root filesystem split, the schema-B reconciliation, the ADDENDUM feature set, and the Stage H/K empty-DataFrame + Calibri/dpi legend-corruption fixes — all of that is unchanged and not repeated here. This document covers a third, still-later session on the same calendar date: closing out four remaining TODOs from session 2's list (uninstaller elevation, JVM heap config, real Carlito font bundling, a TOC/header title-drift bug), then a much larger effort fully rebuilding the Tab 2 "Run Selected + Synthesize" feature, which turned out to be almost entirely non-functional despite looking complete in the code.

**Related docs and skills used this session:**
- Input: `handoff6.30.26-2.md`, read in full at the start of this session
- Standard Claude Code tools (Bash, PowerShell, Read/Edit/Write, Grep, Glob), `WebSearch`, `AskUserQuestion` (used five times — Carlito scope, Carlito sourcing method, synthesis scope, auth-method tradeoff, git identity), `Agent` with `claude-code-guide` (used twice, for external research on the Claude Code CLI's command surface — see Mistakes, one round of this research was wrong), `TaskCreate`/`TaskUpdate` throughout
- Claude Code version used: claude-sonnet-5
- This document is itself produced by the `/anthropic-skills:handoff` skill

---

## 1. What changed this session

### Part A — four TODOs closed in one pass (commit `d82191f`)

**Uninstaller elevation (was TODO #1).** `Uninstall.exe` — generated at install time by `WriteUninstaller()` in `PA-Pipeline-Setup.cs` — never self-elevated, unlike the main installer's own `Main()`. Run non-elevated (the normal case, since neither a desktop shortcut nor Add/Remove Programs grants elevation automatically), its `rmdir` against Program Files silently failed while the app still reported "PA Pipeline has been uninstalled." Fixed by generating the same `IsAdministrator()`+`runas` self-elevate pattern into the uninstaller's own source. Verified via a real isolated test compile (first attempt failed due to Git Bash mangling `/`-prefixed csc.exe args as POSIX paths — switched to the PowerShell tool for all C# compiles this session) confirming `WindowsIdentity`/`WindowsPrincipal`/`Win32Exception` resolve with no new assembly reference needed. Also regenerated and swapped the *actual* `Uninstall.exe` already sitting in the user's live install (not just future ones), by reproducing `WriteUninstaller()`'s exact generated C# source for this real install's paths and compiling it directly.

**JVM `-Xmx` heap config (was TODO #2).** Added `environment.jvm_max_heap` (blank = JVM default, e.g. `"2g"` otherwise) through `Get-DefaultConfig`, a new Settings-tab field (grew the Bootstrap Python groupbox, shifted the Environment Check box down to make room), `Save-ConfigFromUI`/`Refresh-SettingsFromConfig`, `BuildConfigJson` (C#, for schema parity), and `extract_snapshots.py`'s `start_jvm()`/`jpype.startJVM(*jvmargs, ...)`. Verified against the *real* bundled JVM: default heap reports 1504MB; `jvm_max_heap="256m"` makes `Runtime.getRuntime().maxMemory()` report exactly 256.0MB.

**Real Carlito font bundling (was TODO #3) — the largest sub-effort.** `CARLITO_DIR` hardcoded a Linux-only path in both `generate_charts.py` and `assemble_pdf.py`, so Carlito never rendered on Windows. Asked the user how far to take this (full bundling vs. a best-effort path fix vs. skip) — chose full bundling. Asked whether Claude should source the actual font files or the user should supply them, matching the existing Python/Java precedent where the user supplies binaries via `Embed-Sources.ps1` params — user chose "Claude fetches from the official source." Sourced real Carlito v1.104 from `github.com/googlefonts/carlito` (SIL OFL 1.1) via the GitHub REST API (never guessed a raw download URL), verified each of the 4 TTF files with `fontTools` (name table says Carlito, license string checks out) before it went anywhere near the installer. Bundled as a new PE resource (`CARLITO_FONTS_RESOURCE_NAME`), extracted to an app-owned `fonts/` folder at install time as a new "Step 6 of 12" (renumbered every subsequent installer step, 11 total → 12). Caught a real gap via a test compile before it reached production code: .NET Framework 4.x's `ZipFile.ExtractToDirectory` has no `(string,string,bool)` overwrite overload — used delete-then-2-arg-extract instead. Updated `Build-Setup.bat` and `Embed-Sources.ps1` to stage/embed the new font zip the same way Python/Java already are. Per the standing requirement in project memory, re-ran the Calibri dpi+legend corruption bisection against the *real* bundled Carlito file at dpi=150 — confirmed genuine Carlito does not reproduce that bug, verified with real chart (matplotlib) and real PDF (reportlab) renders, both visually inspected.

**TOC/header title drift (was TODO #5) — turned out to be a real bug, not a style nit.** Comparing `TOC_SECTIONS` against the actual `_part_header()` calls found 4 of 8 titles had silently drifted apart: Part I's TOC entry claimed a fabricated "Nine-Month Schedule Trend" untethered from any project's real data, and Parts II/IV/VI's TOC entries were missing parenthetical subtitles the real in-body headers carry. Fixed by introducing one `SECTION_TITLES` dict that both the TOC and every `_part_header()` call now read from, so this class of drift can't recur. Verified end-to-end: ran the real Stage L assembly against a scratch copy of the real Haven Salon dataset (never touching the user's actual files), rendered both the TOC page and the Part II body page to images, confirmed they now match exactly.

**Deployment (Part A):** re-embedded via `Embed-Sources.ps1`, rebuilt `PA-Pipeline-Setup.exe` (SHA256-verified all 3 PE resources and the 4 changed base64-embedded sources against real source files), recompiled *both* `PA-Pipeline.exe` (PS2EXE) and `Uninstall.exe` (direct csc.exe, since both needed the live install itself to change, not just future installs), hot-patched `C:\Program Files\PA-Pipeline` under one elevated pass. Discovered along the way that this machine (the user's real Windows desktop, evidently a different environment than whatever prior sessions ran in) had no git identity configured at all — asked before setting `--global` config; user chose `Kaleb Keen` / `kaleb.keen@gmail.com`. Committed as `d82191f`, pushed to `kalebkeen/MPP-Analysis` main.

### Part B — the Tab 2 Synthesize button (commits `ede15a5`, `41e3ec0`)

User's report: clicking "Run Selected + Synthesize" does nothing. Investigation found three compounding bugs:

1. `run_synthesis()`'s raw HTTP POST to `api.anthropic.com/v1/messages` had **no auth header at all** — it could never have succeeded.
2. `run_qc.py`'s `main()` returned exit 0 regardless of synthesis outcome, and Stage M's Tab 2 status is marker-file-based (`qc_report.json`, written by the always-run mechanical-QC part regardless of synthesis success) — so even fixing the exit code alone wouldn't make failure visible anywhere.
3. Even a working call only ever filled 4 of ~18 `narrative.json` keys (`questions_for_next_review`/`watch_list`/`data_quality_notes`/`scope_gaps`). The 14 body-text sections the PDF actually renders as `[NARRATIVE PLACEHOLDER]` (`bottom_line`, `executive_overview`, `part_i_intro`, etc.) were, by the original code's own design, meant for **manual** entry only via the separate "Open Narrative JSON" button — never Opus-generated.

Two scope questions were put to the user rather than assumed:

- **Fill only the 4 existing fields, or expand to all ~18?** User chose: expand to everything, matching what they'd originally described wanting.
- **Auth mechanism.** The user's own stated requirement — "prompts me to log in every click, no hardcoded account info" — turned out to be internally contradictory once researched: `claude auth login` is inherently interactive/browser-based and, once completed, *persists* a session, which is the opposite of prompting every click. This conflict was surfaced explicitly with concrete tradeoffs rather than silently resolved; user chose "log in once, silent after" over "prompt for an API key every click."

Implementation: expanded `_load_context_for_synthesis()` to pull from stage_e/f/g/**h** (buyout data was previously missing entirely); expanded `SYNTHESIS_PROMPT` to request all ~18 keys in one call with explicit anti-hallucination instructions (say plainly when a data section like buyout scope is empty, never invent findings); replaced the raw API-key call with a `subprocess` invocation of the `claude` CLI itself, prompt passed via **stdin** (not a CLI argument, to avoid Windows' ~32K command-line length limit on a payload that scales with project size); added `check_claude_auth()` (Python) / `Test-ClaudeCliAuth` (PowerShell) as pre-flight-only checks — neither ever triggers a login or stores any credential; wired a pre-flight gate into the Synthesize button (fails fast, before running other stages, if Stage M is checked and auth isn't present) plus an explicit post-run failure surface (Run Log line + end-of-run `MessageBox`), since the existing marker-file status genuinely cannot detect synthesis failure.

**The claude CLI wasn't installed on this dev machine at first.** Verified everything possible without it — a real "dry run" of context-gathering and prompt-formatting against a scratch copy of Haven Salon data (11.9KB / ~3K-token prompt, correct empty-buyout handling confirmed) and confirmed both auth-check functions fail gracefully when the CLI is genuinely absent. Committed and pushed this first cut as `ede15a5`, explicitly flagging to the user that the actual `claude -p` call itself had never been exercised end-to-end.

**User then asked Claude to install the CLI.** Important boundary stated upfront and held: Claude can install the CLI itself, but the actual OAuth login/browser-approval step is fundamentally the user's own action against their own Anthropic account — Claude does not and should not attempt that on their behalf. Installed via the official native installer (`irm https://claude.ai/install.ps1 | iex`, confirmed via agent research as the current recommended Windows method, no Node.js needed), added to User PATH.

Having the real binary let Claude resolve a genuine **conflict between two separate rounds of agent research**: one said `claude auth status`/`claude setup-token` exist with specific exit-code semantics and warned headless calls might hang; a second, later round claimed there's no separate `setup-token` command at all. Rather than trusting either, Claude checked `claude --help` against the real, just-installed binary — `auth` and `setup-token` both genuinely exist, confirming the first round.

That same real-tool testing then **caught a genuine bug already shipped in `ede15a5`**: a real unauthenticated `-p --output-format json` call returns its error (`"Not logged in · Please run /login"`) as valid JSON on **stdout** with `is_error: true` — not in stderr with an auth-related substring, which is what the shipped code was checking for. Also confirmed empirically that the call fails in well under a second rather than hanging, contradicting the first research round's specific warning. Fixed by parsing the JSON envelope first and checking `is_error` before ever looking at exit code or stderr, falling back to raw stderr only if stdout wasn't valid JSON at all. Committed and pushed as `41e3ec0` — before the user had logged in yet, so before they could have hit this themselves.

**User then completed the login** (their own browser OAuth, own Anthropic account) — confirmed authenticated as `kaleb.keen@gmail.com`, Pro plan. With a real session finally available, ran the full real end-to-end test: real Stage M synthesis against a scratch copy of Haven Salon data, using the same `PYTHONIOENCODING=utf-8`/`PYTHONUTF8=1` environment the real GUI's `Invoke-PythonStage` already sets (Claude's own first bare test invocation hit a `UnicodeEncodeError` from *not* replicating this — an already-known, already-mitigated issue from an earlier session, not a new app bug). Real result: **"Narrative sections written: 14/14."** Rendered the actual generated PDF (not just checked `narrative.json`'s keys) and visually confirmed genuine, specific, data-grounded content had replaced every placeholder — real trade names, real day counts, and an honest "no building turnover baseline-vs-forecast data was provided in this brief" note where data genuinely wasn't available, rather than a fabricated figure.

Final check this session: user asked whether GitHub was up to date — confirmed via a real `git fetch` + status check that local `main` is in exact sync with `origin/main` at `41e3ec0`, no uncommitted changes.

---

## 2. Architecture (current state)

Unchanged from `handoff6.30.26-2.md` except for the points below — the two-root split, schema-B config shape, `Merge-ConfigDefaults` missing-keys-only healing, `output_marker2`, `last_config.txt`, and the Stage K `_data_*`/`_render_*` split are all still current.

- **`environment.jvm_max_heap`** is a new schema-B config key (string, blank = JVM default). Present in `Get-DefaultConfig` (PS1) and `BuildConfigJson` (C#) for parity; consumed by `extract_snapshots.py`'s `start_jvm()` as a `-Xmx` JVM arg.
- **Carlito is now a real, bundled, third PE resource** (`PASetup.CarlitoFonts.zip`, alongside the Python installer and Java runtime), extracted to `installDir\fonts` at install time. `CARLITO_DIR` in `generate_charts.py`/`assemble_pdf.py` resolves as `Path(__file__).resolve().parent / "fonts"` — a sibling of the stage scripts, not a hardcoded system path. The installer's step count is now 12 (was 11); any future step insertion needs the same careful renumbering (both `SetStatus` string literals and the plain `// Step N -` comments — they're tracked separately and both need updating).
- **`SECTION_TITLES`** (module-level dict in `assemble_pdf.py`) is now the single source of truth for every Part's title, read by both `_part_header()` calls and `TOC_SECTIONS`. Do not reintroduce a second hardcoded copy of any title string.
- **Stage M synthesis is a completely different mechanism now.** `run_synthesis()` shells out to the `claude` CLI (`subprocess`, prompt via stdin, `--output-format json --model claude-opus-4-8`) instead of calling `api.anthropic.com` directly with a stored key. No credential of any kind lives in this codebase or in `project_config.json`. Auth is entirely delegated to whatever session the user has already established via `claude`'s own interactive login, checked (never created) by `check_claude_auth()`/`Test-ClaudeCliAuth`. **This is a new external dependency the installer does not bundle** — unlike Python/Java/Carlito, a fresh install of this app on a different machine will not have Synthesize work until that machine's own user separately installs Claude Code CLI and logs in. The app degrades to a clear error message in that case, not a crash.
- **Claude Code's `-p --output-format json` envelope**: the assistant's response text is in the `result` field; failures (including "not logged in") also land there with `is_error: true` set alongside, on stdout, regardless of exit code. Any future code touching this integration should check `is_error` first, not stderr or exit code alone.
- **`narrative.json` now has ~18 Opus-managed keys plus `status_by_dimension`** (6 rows: 4 from Opus under `status_by_dimension_core`, remapped to `[dimension, status, note]` triples, plus 2 fixed rows — Cost/budget, Open items — appended by Python code in `run_synthesis()`, never re-generated by the model). If that fixed wording ever needs to change, it lives in `run_qc.py`, not the prompt.

---

## 3. Work accomplished this session

- Fixed uninstaller elevation; regenerated and deployed the real `Uninstall.exe` for the live install.
- Added `environment.jvm_max_heap` end-to-end (schema, GUI, both config-parity sources, Python consumer); verified against the real bundled JVM.
- Sourced, verified, and fully bundled the real Carlito font (installer PE resource, extraction step, both Python consumers repointed); re-verified the Calibri dpi/legend bug does not recur with the genuine font.
- Found and fixed a real TOC/body-header title-drift bug affecting half the report's sections; verified against a real rendered PDF.
- Rebuilt Stage M's Opus synthesis from a broken, 4-field, unauthenticated stub into a working, ~18-field, CLI-authenticated feature with proper failure surfacing.
- Diagnosed a real conflict in the user's own stated requirements (login-every-click vs. real OAuth) and got an explicit resolution rather than guessing.
- Installed Claude Code CLI on the dev machine, resolved a real conflict between two rounds of agent research using the actual binary, and caught + fixed a genuine bug in already-shipped code as a direct result.
- Ran a complete, real, authenticated end-to-end test of the rebuilt Synthesize feature and visually confirmed correct output in the final rendered PDF.
- Set up git identity on this machine (previously unconfigured) with explicit user approval.
- Three commits pushed to `kalebkeen/MPP-Analysis` main: `d82191f` (four-TODO batch), `ede15a5` (Synthesize rewrite), `41e3ec0` (JSON-envelope error-detection fix).
- Updated persistent project memory throughout with every new lesson so future sessions don't re-derive them.

---

## 4. Mistakes made

1. **Shipped a real bug in `ede15a5`.** The Claude CLI error-detection logic was built from agent research (no real CLI available to test against yet) suggesting stderr-substring matching for auth failures. Once the real CLI was installed and tested, this proved wrong — the actual error surfaces via the JSON envelope's `is_error` field on stdout, not stderr. Caught and fixed same-session (`41e3ec0`), before the user had authenticated and could have hit it themselves — but it did ship once. The lesson (already in memory): code built from research about an external tool's behavior is provisional until checked against the real binary; re-verify the moment real access exists, don't just trust whichever research pass sounds more authoritative.
2. **Git Bash mangled `/`-prefixed csc.exe arguments as POSIX paths** on the first C# test-compile attempt this session. Caught immediately from the compiler's own error output; switched to the PowerShell tool for every C# compile for the rest of the session.
3. **Assumed a modern .NET API surface applied to this project's actual .NET Framework 4.x toolchain** — tried `ZipFile.ExtractToDirectory(zip, dir, true)` (the 3-arg overwrite overload), which doesn't exist there. Caught via a real isolated test compile before it ever reached the real installer source; no user-facing cost.
4. **Claude's own first bare test invocation of `run_qc.py`** (for the final real end-to-end verification) crashed with `UnicodeEncodeError` from not replicating the `PYTHONIOENCODING`/`PYTHONUTF8` environment the real GUI already sets. Not an app bug — an already-known, already-fixed issue from an earlier session that Claude's own ad hoc test simply hadn't reproduced the mitigation for. Self-corrected within the same turn once the cause was traced.
5. **Two `ScheduleWakeup` calls resurfaced as duplicate/delayed prompts arriving well after the underlying work was already complete** — once after the Carlito-related CLI research, once after the CLI-install-method research. Each time this was recognized as stale and handled with a recap rather than redone, but scheduling a wakeup with the exact verbatim task prompt means that prompt can resurface out of order relative to when the work actually finished — worth remembering for future sessions using this mechanism.
6. A minor, immediately self-corrected tool-call formatting error early on (`AskUserQuestion` params nested under a spurious wrapper key) — caught by the tool's own validation, fixed on the very next call.

---

## 5. Remaining TODOs

1. Stage G per-building section looks thin (building names likely don't match schedule summary task names)
2. Several advanced config fields (`qc.*`, `charting.*`, `critical_path.*`) not exposed in any tab. **New this session:** `qc.synthesize_with_opus` specifically confirmed dead — declared in both `Get-DefaultConfig` and `BuildConfigJson` for schema parity, never actually read by anything; the real Synthesize on/off control is just which button was clicked and whether Stage M is checked.
3. Git repo growing with large binary commits (~76-80MB installer exe per rebuild, now includes the Carlito font resource too) — GitHub actively warns on every push; Git LFS worth considering.
4. `chart_data_workbook.xlsx` visual fidelity in real Excel still not verified.
5. `paths.baseline_mpp` still dead code.
6. Real Windows end-to-end install (a genuinely fresh machine, not a hot-patch) still not tested for the bundled Python/Java/Carlito extraction together.
7. Live install has now been updated via direct elevated file-patching across sessions 2 *and* 3, not the documented installer flow. A full reinstall via the rebuilt `PA-Pipeline-Setup.exe` remains the more bulletproof reset if anything ever looks inconsistent.
8. No automated test exists for "does this stage degrade gracefully on an empty/no-match scenario."
9. **New:** Synthesize now depends on an external, unbundled tool (Claude Code CLI) with its own separate auth. This dev machine has it installed and authenticated (`kaleb.keen@gmail.com`, Pro plan) as of this session, but that's a personal credential on this one machine — a different machine or user starts from zero on this specific feature, by design (nothing to bundle, since nothing is stored).
10. **New:** the ~18-key synthesis prompt (~12KB+ for a small project, scales with project complexity) has only been tested at Haven Salon's scale. A much larger project (many buildings, huge variance tables) should be re-checked for prompt size and generation latency — the stdin-based invocation removes the Windows command-line-length risk, but very large generations haven't been stress-tested against model context/output limits.

---

## 6. Potential issues on the horizon

Structural risks from prior handoffs (recompile-and-swap needed for any future `.ps1` GUI change; the Calibri/dpi legend bug pattern resurfacing if matplotlib is used elsewhere with a new externally-loaded font) are unchanged. Two new ones:

**Synthesize's new external dependency is invisible until someone hits it.** Nothing in the installer, the Settings tab, or any user-facing documentation currently tells a new user "Synthesize needs Claude Code CLI installed and logged in separately." The in-app error messages are clear when it's missing, but a new user has no reason to know this until they click the button — worth a Settings-tab note or first-run hint if this comes up again.

**`status_by_dimension`'s split between Opus-generated and code-owned rows is a subtle pattern that's easy to break by accident.** A future edit to the synthesis prompt that renames or restructures `status_by_dimension_core` without updating the corresponding Python remapping in `run_synthesis()` would silently produce a malformed or truncated table — there's no test coverage for this shape-matching today.

---

## 7. Subjective read on this session

Consistent with both prior sessions: terse, direct, high-trust. The user drove almost entirely with short, information-dense prompts (`"lets go through 1,23,5"`, `"yes continue"`, `"that is done"`) and let Claude own scope and architecture decisions, stepping in only for the judgment calls Claude explicitly flagged — Carlito sourcing method, git identity, the login-vs-prompt-every-click conflict, each deploy/push confirmation.

One new data point worth naming: the user **proactively volunteered a hard security requirement mid-task** ("i don't want my account information hardcoded") that Claude hadn't asked about. That's a different kind of signal than the prior sessions' reactive bug reports — it reads as an engaged, security-conscious user actually tracking what's being built, not passively accepting whatever gets proposed. Claude's response (surfacing the technical contradiction in that requirement explicitly, rather than silently picking an interpretation) was accepted without pushback or any sign the user found the extra back-and-forth annoying — consistent with a user who values being asked over being guessed for.

The user's final ask this session ("can you set it up for me") extended that trust to installing new software on their own machine, again with no hesitation or request for more detail first. No frustration or impatience surfaced anywhere despite a long session with real setbacks along the way — a bug that did ship once before being self-caught, a stale git-config blocker, two confusing scheduled-wakeup echoes. The tone stayed even and businesslike throughout, and the session-closing question ("have you updated the github with the latest version?") reads as a routine, careful sanity check rather than suspicion — the same "verify for real" ethos Claude has been matching all session, coming back the other direction.

