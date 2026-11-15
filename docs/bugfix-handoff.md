# Handoff prompt (bugfix session)

Paste this into a new chat at the repo root:

---

Repo: `arma-reforger-ai-toolkit`. Main thing: `mod-manager/` — a local mod
downloader for Arma Reforger. `download-web.ps1` runs an HTTP dashboard on
:8123 that drives the dedicated server (`armar-server/ArmaReforgerServer.exe`)
as a batch downloader, mirrors finished mods into
`Documents/My Games/ArmaReforger/addons`, and writes launcher presets into
`ReforgerGameSettings.conf` (`m_aPresets` only). `watchdog.ps1` restarts the
downloader when it exits or stalls. `sync-addons.ps1 -Loop` mirrors mods.
State is in `Documents/Default Project/*.json` (set by `RFMM_HOME`/`RFMM_DATA`),
never inside the repo.

Rules for this session:
- Find it, reproduce it with a real command, then smallest fix. No refactors.
- Run `powershell -File tools\audit.ps1` after changes; `-Deep` before commit.
- Run `mod-manager\test-rules.ps1` with the dashboard up (it asserts the
  completion rule against disk and node-checks the page).
- The page JS is inside `download-web.ps1`; verify with `node --check` on the
  served HTML, not by eyeballing.
- Commit + push, one logical change per commit.

Traps that must not regress (each caused a real bug):
1. Installed = the addon's own `meta` package file list matches exactly
   (`Test-AddonComplete`). Folder-size ±2 % let partial mods pass.
   Mods may legitimately ship without `addon.gproj`.
2. The DS writes fragments into `<mod>\temp\` and consolidates them, so byte
   totals dip: progress is high-water per mod and speed is a 60 s rolling avg.
3. `clear queue` must stop the DS **before** writing the empty config (the DS
   rewrites its config on shutdown).
4. `Start/Resume` with an empty queue resumes interrupted (partial) downloads.
5. Presets go inside `m_aPresets`; anything else is dropped by the game.
6. Never name a local `$cfg`/`$Cfg` (case-insensitive shadowing).
7. The DS exits after downloading (cannot start a world while mods are missing)
   and can hang on Workshop errors; the watchdog + 3-error skip handle that.

Current state: ~938/980 installed, queue ~40, downloader supervised.
Start: `mod-manager\Start Mods Download.cmd` (or the Desktop shortcut).
Docs: `mod-manager\README.md`, `docs\debugging-stack.md`.
