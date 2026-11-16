# Full audit + zero-bug pass - prompt

Paste into a new chat at the repo root.

---

# Mission

Full audit and bug-fix pass of `arma-reforger-ai-toolkit`, primarily `mod-manager/`.
Goal: no known defects left in the paths that run (dashboard, downloader control,
sync, presets), and a written list of anything that is a deliberate limitation.

Do not refactor for taste. Every change must trace to a concrete failure.

# Ground truth

- `mod-manager\download-web.ps1` - HTTP dashboard on :8123, drives
  `armar-server\ArmaReforgerServer.exe` as a batch downloader, writes presets.
- `mod-manager\watchdog.ps1` - restarts the downloader (exit or 5 min silence),
  skips a mod after 3 Workshop fetch errors, honours `data\paused.flag`.
- `mod-manager\sync-addons.ps1 -Loop` - mirrors finished mods to
  `Documents\My Games\ArmaReforger\addons`.
- `mod-manager\trim-config.ps1` - trims the DS config, deletes >15 min stale partials.
- `mod-manager\make-preset.ps1` - writes `m_aPresets` in ReforgerGameSettings.conf.
- State: `Documents\Default Project\batch1-*.json` via `RFMM_HOME`/`RFMM_DATA`.

# Stack (installed, on PATH)

Fast, every change:
```
powershell -File tools\audit.ps1        # PSScriptAnalyzer, ruff, gitleaks
```
Deep, before commit:
```
powershell -File tools\audit.ps1 -Deep  # + semgrep (p/ci, p/secrets, p/python) + trivy
```
MCP: `trivy` is registered globally - use
`trivy.scan_filesystem` on the repo (expect the DB download to fail on this link;
then fall back to the CLI skip and say so, do not fake a pass).

Page JS lives inside `download-web.ps1`. Verify with `node --check` on the served
HTML (`Invoke-WebRequest http://localhost:8123/`), never by eye.

Runtime, dashboard must be up:
```
mod-manager\test-rules.ps1     # completion rule vs disk, orphans, page JS
Invoke-RestMethod http://localhost:8123/status | ConvertTo-Json -Depth 4
Invoke-RestMethod "http://localhost:8123/verify?t=<tok>" -Method Post
```
`<tok>` comes from `/status` (`s.tok`). Mutating routes need it.

# Procedure

1. **Map**: list the modules, read `download-web.ps1` end to end, note every
   state file write and every process start/stop.
2. **Static**: run the stack. Fix every real finding (not style). Re-run until clean.
3. **Runtime**: dashboard up, run `test-rules.ps1`; exercise `/status`, `/verify`,
   `pause`, `start`, `clear-queue`, `queue-all`; kill the DS and confirm the
   watchdog restarts it; confirm `Downloading now` is empty when stopped.
4. **Trace the risky flows by hand**: config write ordering (DS rewrites it on
   shutdown), queue rebuild, partial-download resume, preset placement, sync
   mirroring, token checks on every mutating route, path handling from API data.
5. **Fix** the smallest way. Reproduce before, verify after, with a command.
6. **Commit** one logical change at a time and push.

# Invariants - a change that breaks any of these is a regression

1. Installed = the addon's own `meta` -> `versions[0].package.files` matches
   exactly (`Test-AddonComplete`). Never go back to folder-size tolerance.
   Some mods ship without `addon.gproj`.
2. The DS writes ~3 MB fragments into `<mod>\temp\` then consolidates: per-mod
   progress is a high-water mark, speed is a 60 s rolling average.
3. `clear-queue` stops the DS **before** writing the empty config.
4. `Start / Resume` with an empty queue resumes interrupted (partial) downloads
   and never refills from servers - that is `Queue all missing`.
5. Presets go inside `m_aPresets` only; GUIDs quoted.
6. Never name a local `$cfg`/`$Cfg` (case-insensitive shadowing).
7. The DS exits after downloading (no world while mods are missing) and can hang
   on Workshop errors: watchdog + 3-error skip, 5-minute stall threshold.
8. Every mutating route validates the per-run token.
9. Data comes from a public API: never trust names/paths; no path traversal.

# Definition of done

- `tools\audit.ps1 -Deep` clean (or each skip explained with a reason).
- `test-rules.ps1` passes with the dashboard up, 0 failures.
- Manual matrix from step 3 passes; note what you ran.
- `git status` clean, everything pushed.
- Report: what you checked, what you fixed (file:line + the failing case), what
  you deliberately did not touch, and the remaining known limits.

If you find nothing, say so plainly and show the evidence - do not invent fixes.
