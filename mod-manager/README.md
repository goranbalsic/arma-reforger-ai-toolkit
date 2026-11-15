# Arma Reforger Mod Manager

Standalone local program: batch-downloads every mod of a list of Arma Reforger
servers (always latest version, exact sizes), auto-installs them into the game's
addon folder, and shows one web dashboard with a **live server browser**,
per-server modlists, per-mod status, launcher presets and progress stats.

Runs on Windows PowerShell 5.1 (built into Windows). No dependencies.

## Start

Double-click **`Start Mods Download.cmd`** (or run
`powershell -File download-web.ps1`). It serves http://localhost:8123 and opens
the browser. The dashboard window must stay open; closing it stops only the UI,
not a running download.

## What the dashboard does

- **Progress card**: bytes (exact), speed, ETA, active downloads, mods assembled.
- **Server browser**: search live servers (reforgermods.net API), expand a row
  to see its full modlist with on-disk markers and exact sizes, **Add server**
  queues its missing mods at the END of the running batch (never jumps the
  queue) and restarts the downloader.
- **Servers**: every tracked server with per-mod ✓/⟳/• status, sizes, per-server
  **Queue first** (reorders missing mods to the front, batch continues behind)
  and **Make preset** (builds an in-game launcher preset; game must be closed).
- **Verify mods**: size-checks every assembled mod against the Workshop.

"Completed" means one thing everywhere: all 3 assembly files present + folder
quiet 2 min + size matches Workshop ±2%. `sync-addons.ps1` mirrors exactly that
set into `Documents\My Games\ArmaReforger\addons` (single-instance mutex).

## Layout

| Path | What |
| --- | --- |
| `download-web.ps1` | the program (HTTP dashboard + DS control + browser) |
| `sync-addons.ps1` | mirrors completed mods to the client addon folder |
| `make-preset.ps1` | launcher preset builder (`-ServerId <guid>`) |
| `trim-config.ps1` | trims the DS config to un-downloaded mods (auto on every start) |
| `add-server.ps1` | CLI variant of Add server (`-Id <guid>` or `-Search <text>`) |
| `get-sizes.ps1` | resolve exact sizes for config mods (merge-only) |
| `fix-sizes.ps1` | fill unknown sizes via `/v2/mods/{id}` (rate-limited) |
| `test-rules.ps1` | asserts the live completion rule against disk |
| `migrate-here.ps1` | one-shot: move big data from `Documents\ArmaReforger-DL` into this folder |
| `data\*.json` | state: server list, DS config, exact size map |
| `serverprofile\` | DS download destination (created at runtime, gitignored) |
| `armar-server\` | ArmaReforgerServer.exe + its install (gitignored) |
| `docs\reforgermods-api-v2.md` | full offline copy of the public API reference |

## First run on a fresh machine

1. Put the dedicated server binary in `armar-server\` (steamcmd:
   `app_update 1874880` — the old `steamcmd\` folder from an existing
   installation works; or copy `armar-server\` from any existing setup).
2. Fill `data\batch1-servers.json` (one capture per server) or start empty.
3. Start the dashboard, use the server browser to add servers, press
   **Start / Resume**.

## Paths (portable by default, overridable)

Everything is relative to this folder. Two env vars relocate the big data:

- `RFMM_HOME` — where `serverprofile\`, `armar-server\`, `steamcmd\` live
- `RFMM_DATA` — where the `data\` json state lives

Unset = this folder. On this machine they are set by the Desktop .cmd until
`migrate-here.ps1` has moved the folders in here.

## Traps baked into the code (do not remove)

- **1 MB download-list limit**: the DS insta-crashes ~30 s after a false
  "started" when the config holds ~600+ mods. `Start-DS` therefore always runs
  `trim-config.ps1` first, waits 25 s, and retries once.
- **Merge-only sizes**: `batch1-sizes.json` holds sizes of everything already
  downloaded (the config is trimmed). Never replace it, only merge.
- **Presets go inside `SCR_WorkshopAddonManagerPresetStorage`** after
  `m_iVersion 1`, GUIDs quoted `"{...}"`. A block appended after the storage is
  dropped by the game. Only installed mods are included: the launcher deletes
  preset entries it cannot resolve, which would poison the whole preset.
- **PowerShell is case-insensitive + dynamically scoped**: never name a local
  variable `$cfg`/`$Cfg` (it shadows the `-config` path and reaches `Start-DS`).
- The DS writes `addon.gproj`/`meta`/`resourceDatabase.rdb` BEFORE the data
  paks, so "3 files present" alone is not completion (size must match).

## Environment notes

- `reforgermods.net` free API tier: 60 req/min, 5 000/day (no key). The tools
  endpoints need no key. Full reference in `docs\reforgermods-api-v2.md`.
- The dashboard binds to `localhost:8123` only, and every state-changing
  endpoint requires a per-run token (CSRF protection) that the built-in page
  carries automatically.
- Mods appear in-game only after the game restarts.
