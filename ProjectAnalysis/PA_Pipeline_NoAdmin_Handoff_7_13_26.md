# PA Pipeline — No-Admin Runtime Handoff
**Date:** 2026-07-13
**Author:** Claude (planning session with Kaleb)
**Companion docs:** `PA_Pipeline_WorkPlan_7_01_26.md`, `handoff6.28.26.md`, `PA-Pipeline.ps1`, `PA-Pipeline-Setup.cs`, `Build-Setup.bat`

---

## 0. Phase A findings (recorded 2026-07-13, implementation session — repo-side)

Machine-side checks (A.1 on the installed exe, A.3 ground truth on Kaleb's
machine) still need a Windows box and fold into Phase F. Everything checkable
from source was checked:

- **Culprit #2 (requireAdministrator manifest): NOT present in source.** The
  installer's `Invoke-ps2exe` call passes no `-requireAdmin`, and the bundled
  PS2EXE only writes a custom manifest when `-requireAdmin`/`-DPIAware`/
  `-supportOS`/`-longPaths` is set — otherwise csc's default `asInvoker`
  manifest applies. A guard comment now sits on the compile step so the
  switch never sneaks in.
- **Culprit #1 (venv in Program Files): NOT in current source.** Both
  `Get-DefaultConfig` (PA-Pipeline.ps1) and the installer's `RunInstall`/
  `BuildConfigJson` already target `%LocalAppData%\PA-Pipeline\venv`. The
  Program Files venv path in `project_config.schema_1.json` was **stale
  documentation** (now fixed). Configs written by *older installed builds*
  can still carry Program Files paths — the new startup migration (Phase C.2)
  handles those.
- **Culprit #3 (elevated installer → wrong-profile state): PRESENT — this was
  the live defect in source.** `Main()` self-elevated via `runas`, so on a
  non-admin user the whole install ran as the admin account, and the venv +
  config (resolved from the *admin's* `%LocalAppData%`) landed in the wrong
  profile. Removed end-to-end (installer + generated uninstaller) per Phase D.
- **New finding — the build-chain trap was live:** the embedded base64
  constants in `PA-Pipeline-Setup.cs` were stale relative to the repo sources
  (8 of 10 differed in real content, not just line endings — the repo's newer
  docx output, building name aliases, calendar-auto, and CrossProjectName
  sanitizer work was not embedded). Re-encoded from the live sources, and the
  re-encode is now a mandatory, fatal-on-failure step 2 of `Build-Setup.bat`
  (Phase E.2).

Implementation status: Phases B, C, D, E complete (branch
`claude/handoff-doc-changes-bg6gj1`). Phase F — fresh no-UAC install, venv
bootstrap, full Stage C–M run, analysis-invariance diff, uninstall — remains
and requires a Windows machine with a genuinely non-admin account.

---

## 1. Objective

Modify the PA Pipeline (MPP-Analysis) app so it installs and runs **without administrator rights**. Hard constraint from Kaleb: **zero changes to the analysis.** No `.py` stage script content changes of any kind. Stage C–M outputs must be byte-for-byte / content-identical before and after this work. This is packaging and filesystem plumbing only.

---

## 2. Project understanding & how we got here

The app is a WinForms GUI (`PA-Pipeline.ps1`, compiled to `PA-Pipeline.exe` via PS2EXE) driving a 9-stage Python pipeline (C, D, E, F, G, H, K, L, M) through a managed venv. The installer (`PA-Pipeline-Setup.cs`, C# 5 via `csc.exe`) self-elevates via UAC `runas` because it writes to `C:\Program Files\PA-Pipeline`.

The 6/28 handoff shows the app was **already designed to never elevate at runtime** — the two-root split:

- `$script:AppRoot` = install dir (Program Files) — read-only at runtime. Holds the exe, `Uninstall.exe`, and the 9 `.py` stage scripts.
- `$script:DataRoot` = `%LocalAppData%\PA-Pipeline` — read-write, no elevation. Holds `project_config.json` and (per design intent) the managed venv.

Kaleb reports the app currently **requires admin to run**, which means something is violating that design. Three suspected culprits, in order of probability (Phase A confirms which):

1. **Venv actually lives in Program Files.** `project_config.schema_1.json` shows `paths.venv_dir = C:\Program Files\PA-Pipeline\venv` and `python_exe` inside it, written by the installer. If real, every pip operation, matplotlib font-cache write, or venv repair hits Access Denied at normal privilege.
2. **`requireAdministrator` manifest in the exe.** PS2EXE has a `-requireAdmin` switch; if the embedded PS2EXE invocation inside the installer passes it, Windows forces UAC on every launch regardless of what the app does.
3. **Wrong-profile state from elevated install.** The installer's `runas` elevation runs as the admin account when the logged-in user is not an admin — so the venv and config the installer creates land in the **admin's** `%LocalAppData%`, not the user's. The app then only works when relaunched as that admin.

The 6/28 handoff itself flagged (its item 5) that a from-scratch design would likely not choose Program Files at all. This work executes that simplification.

---

## 3. Work accomplished this session

Planning only — no code changed yet.

- Diagnosed the three candidate root causes above from project knowledge (installer source, app source, config schema, 6/28 handoff).
- Produced the six-phase plan below, reviewed and approved by Kaleb.
- Decision made: go all the way to a **per-user install** (Phase D), not just a manifest + venv-relocation patch. Rationale in §5.

---

## 4. The plan (Phases A–F)

### Phase A — Diagnose (do first, ~30 min)
1. Binary-grep the installed `PA-Pipeline.exe` for `requireAdministrator`:
   `Select-String -Path 'C:\Program Files\PA-Pipeline\PA-Pipeline.exe' -Pattern 'requireAdministrator' -Encoding Byte` (or `findstr /m requireAdministrator`). Also check for `asInvoker` / `highestAvailable` to see what manifest, if any, is embedded.
2. Inspect the installer's embedded PS2EXE invocation (inside `PA-Pipeline-Setup.cs`, the `Invoke-PS2EXE` call built at install time) for `-requireAdmin`.
3. On Kaleb's machine, confirm ground truth: where does the venv actually exist? What does the live `project_config.json` `paths.venv_dir` / `paths.python_exe` point to? Which profile's `%LocalAppData%` holds `PA-Pipeline`?
4. Record findings at the top of this doc before proceeding — Phases B–D are all still worth doing regardless, but knowing the actual trigger validates the fix in Phase F.

### Phase B — Manifest fix
- Ensure the PS2EXE compile of `PA-Pipeline.exe` does **not** pass `-requireAdmin`; the resulting exe should carry an `asInvoker` manifest.
- Same check for `Uninstall.exe` generation in `WriteUninstaller()` — it should also be `asInvoker` once Phase D makes everything user-writable.

### Phase C — Relocate all writable state per-user
1. Change `paths.venv_dir` → `%LocalAppData%\PA-Pipeline\venv` and `paths.python_exe` accordingly, in **both** places (known sync constraint — no shared schema source of truth):
   - `Get-DefaultConfig` in `PA-Pipeline.ps1`
   - `BuildConfigJson` in `PA-Pipeline-Setup.cs`
2. Startup migration in the `.ps1`: if the loaded config's `venv_dir` points under Program Files (or the venv python is missing/unlaunchable), route the user to the existing Settings-tab venv rebuild path targeting DataRoot. Reuse the Phase-0 hardened bootstrap (pinned versions + post-install smoke test) — do not write a second bootstrap.
3. Stage-launch environment hardening in `Invoke-PythonStage` (env vars only — does not touch script content or analysis):
   - `PYTHONDONTWRITEBYTECODE=1` — stage scripts sit in read-only AppRoot; suppress `__pycache__` write attempts next to them.
   - `MPLCONFIGDIR=%LocalAppData%\PA-Pipeline\mplcache` — matplotlib font cache must never target a read-only or wrong-profile location.
4. Preserve the existing legacy-config migration pattern (copy-forward, never destructive).

### Phase D — Per-user install (approved recommendation)
1. Change the installer's default target from `C:\Program Files\PA-Pipeline` to `%LocalAppData%\Programs\PA-Pipeline` (the VS Code user-install convention).
2. **Remove the self-elevation** (`runas` relaunch in `Main()` and `IsAdministrator()` gate). The installer runs as the invoking user — which also guarantees the venv and config land in the *correct* profile, killing culprit #3 at the root.
3. Shortcut creation must target per-user locations only (user Desktop, user Start Menu) — verify `CreateShortcut` call sites.
4. Uninstall registry entry already writes to `HKCU` (confirmed in `WriteRegistry`) — no change needed.
5. This **fixes the known-broken uninstaller for free** (6/28 TODO item 2): `Uninstall.exe` runs non-elevated and its `rmdir /S /Q` previously would have failed on Program Files; under a per-user install everything it deletes is user-writable. Close that TODO as part of this work.
6. Migration note for existing machines: the old Program Files install is orphaned. One-time cleanup needs admin once (or just leave it — new install takes precedence via shortcuts/registry). Document whichever Kaleb chooses in the run notes.

### Phase E — Rebuild with the chain guard
1. **Before rebuilding:** re-encode the edited `PA-Pipeline.ps1` (and any touched `.py` — there should be none) into `PA-Pipeline-Setup.cs` base64 constants. `Build-Setup.bat` does **not** do this; skipping it ships stale code silently. This is the project's #1 known trap.
2. **Permanently close the trap:** add a scripted pre-build re-encode step to `Build-Setup.bat` (read `PA-Pipeline.ps1` + the 9 `.py` files, regenerate the base64 constants in the `.cs`, then compile). The 6/28 session did this ad hoc via unsaved PowerShell — make it a saved, runnable script this time.
3. C# 5 constraints apply (`csc.exe` v4.0.30319): no string interpolation, no modern syntax.

### Phase F — Verification on a standard (non-admin) account
All of the following on a Windows account with no admin rights:
1. Fresh install completes with **no UAC prompt**.
2. Venv bootstrap succeeds into `%LocalAppData%\PA-Pipeline\venv`; smoke test passes.
3. Full Harrison Stage C–M run completes.
4. **Analysis-invariance check:** compare outputs against the current build's outputs — parquet contents, xlsx values, PDF text/structure identical. Any delta is a defect in this work, full stop.
5. Config save from Tab 1, venv reinstall from Settings tab — both succeed without elevation.
6. Uninstall runs clean, removing both the install dir and DataRoot.

---

## 5. Architecture decisions & rationale

- **Per-user install over a Program Files patch-up (Phase D).** Fixing only the manifest and venv would leave the elevated installer, which is what mis-places per-user state under the wrong profile (culprit #3) and what keeps the uninstaller broken. Per-user install removes elevation from the entire lifecycle: install, run, uninstall. It also matches the 6/28 handoff's own forward-looking recommendation.
- **Env-var hardening instead of script edits (Phase C.3).** `PYTHONDONTWRITEBYTECODE` and `MPLCONFIGDIR` are set in the launcher environment, keeping the "no analysis change" guarantee airtight — script bytes are untouched.
- **Reuse Phase-0 bootstrap, don't fork it.** This work and Work Plan Phase 0 (venv crash fix / pinned bootstrap) touch the same code; do them in one build session, one re-encode, one recompile.
- **Sequencing vs the main work plan:** outputs are unchanged, so this has **no impact on the Phase 4 → Phase 5 gate**. It can run before, alongside, or after Phase 4 verification. Folding it into the Phase 0 session is the efficient choice.

---

## 6. Mistakes made & lessons learned (carried forward + new)

- **(Carried) Build-chain integrity:** editing the `.ps1` and rebuilding without re-encoding ships stale code with no warning. Phase E.2 makes the re-encode a permanent scripted step — do not close this handoff without it.
- **(Carried) Real-conditions testing:** nearly every past bug only surfaced under real conditions (real fonts, real JVMs, real files). The equivalent here: **Phase F must run on a genuinely non-admin account**, not an admin account with UAC prompts declined. An admin account masks exactly the failures we're fixing.
- **(New, from this diagnosis) Design intent ≠ deployed reality.** The two-root split existed on paper and in code comments, but the schema shows the venv pointed into Program Files anyway, and the elevated installer can silently populate the wrong user profile. Lesson: when a design says "X never needs admin," verify on a machine where admin isn't available.
- **(Carried) Dual-config sync:** `Get-DefaultConfig` and `BuildConfigJson` have no shared source of truth. Every path change in this work hits both. Check both, every time.

---

## 7. Remaining TODOs after this work

1. Phase A findings recorded (top of this doc).
2. Phases B–F executed and Phase F checklist fully green on a standard account.
3. Pre-build re-encode script saved into the repo and wired into `Build-Setup.bat`.
4. 6/28 TODO #2 (broken uninstaller) formally closed.
5. Decide the migration story for machines with the old Program Files install (clean up once with admin, or orphan-and-ignore).
6. Then resume the main work plan: Phase 0 remainder (if not folded in) → Phase 1 buyout-optional → Phase 2 TODOs → Phase 3 conformance matrix → Phase 4 Harrison 1:1 → Phase 5 enhancements.

---

## 8. Potential issues on the horizon

- **AppData redirection / roaming profiles:** if SCI machines use folder redirection or mandatory profiles, `%LocalAppData%` behavior can differ; venv paths with spaces or long paths (`%LocalAppData%\Programs\PA-Pipeline`) should be exercised in Phase F.
- **Group Policy:** some corporate GPOs restrict executables running from user-profile directories (AppLocker / SRP). If SCI's IT enforces this, the per-user install could be blocked in a different way than UAC — worth one question to IT before rollout, or at minimum a Phase F check on a domain machine.
- **Java discovery:** stage C needs a JVM; if Java was installed machine-wide by an admin that's fine (read-only use), but confirm the JVM registry probe works from a standard account.
- **Antivirus:** PS2EXE-compiled exes running from `%LocalAppData%` occasionally trip AV heuristics more than Program Files locations. Watch for quarantine on first standard-account run.
- **Existing configs in the wild:** any machine with a config pointing at a Program Files venv will hit the Phase C.2 migration path — make sure it degrades gracefully if the user declines the rebuild.

---

## 9. Docs & skills used / updated

- `handoff6.28.26.md` — source for two-root architecture, uninstaller TODO, build-chain trap, "no Program Files at all" recommendation.
- `PA_Pipeline_WorkPlan_7_01_26.md` — sequencing context (fold into Phase 0 session; no impact on Phase 4/5 gate).
- `project_config.schema_1.json` — evidence of venv-in-Program-Files (culprit #1).
- `PA-Pipeline.ps1`, `PA-Pipeline-Setup.cs`, `Build-Setup.bat` — the three files this work edits.
- `handoff` skill — format followed for this document.

---

## 10. Read on Kaleb's mood

Direct and decisive, consistent with baseline. Presented the diagnosis and plan, approved it in one turn with no pushback and immediately asked for the handoff — signals confidence in the plan and a desire to move to build. The one hard line drawn was "no changes to the actual analysis," stated up front and unprompted; treat the Phase F analysis-invariance check as the thing he will personally judge this work by. No frustration expressed, but the admin requirement is clearly a real friction point in daily use — deliver the fix cleanly and completely, validated before presenting.
