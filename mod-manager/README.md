# Arma Reforger Mod Manager

A standalone local program that downloads **every mod of the servers you pick**
at the latest Workshop version, installs them into the game, and can build a
launcher preset per server.

Runs on Windows PowerShell 5.1 (built into Windows). No dependencies, no
account, no publishing.

## What it does

- **Batch downloader**: the Arma Reforger *dedicated server* binary is used as a
  downloader (it fetches the exact current Workshop version of every mod in a
  config). The dashboard drives it, trims the queue and restarts it if it dies.
- **Live server browser**: search servers by name, expand one to see its full
  modlist with exact sizes and what you already have, and **Add server** to
  queue only its missing mods at the end of the running batch.
- **Per-server mod status**: ✓ installed, ⟳ downloading, • missing, plus
  **Queue first** (that server's missing mods download before the rest) and
  **Make preset**.
- **Client install**: finished mods are copied automatically into
  `Documents\My Games\ArmaReforger\addons`, which is what the game reads.
- **Verify mods**: checks every mod against its Workshop size.
- **Refresh all**: rescans the disk and re-pulls the modlist of every tracked
  server.
- **Presets**: writes a launcher preset for a server into the game's settings,
  containing the mods that are actually installed.

## Requirements

1. Windows with PowerShell 5.1.
2. **Arma Reforger** installed (the game).
3. The **Arma Reforger dedicated server** files, used only as a downloader.
   Install with [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD):
   `app_update 1874880 validate`, then put that install in `armar-server\` next
   to the scripts (the folder must contain `ArmaReforgerServer.exe`).

## First run

1. Double-click **`Start Mods Download.cmd`**. The dashboard opens at
   http://localhost:8123 and empty state files are created in `data\`.
2. In the **Server browser**, search for a server and press **Add server**.
   Its mods are queued.
3. Press **Start / Resume**. Downloads begin; finished mods appear in the game's
   addons folder automatically.
4. When everything is installed, press **Make preset** on a server to get a
   launcher preset with exactly those mods.

## Layout

| Path | What |
| --- | --- |
| `download-web.ps1` | the program (dashboard, server browser, downloader control) |
| `sync-addons.ps1` | copies finished mods into the game's addons folder |
| `watchdog.ps1` | keeps the downloader alive: restarts it when it exits, kills it after a 3 minute stall, skips a mod the Workshop keeps refusing, honours Pause |
| `make-preset.ps1` | builds a launcher preset (`-ServerId <guid>`) |
| `trim-config.ps1` | removes already-downloaded mods from the DS config (automatic on every start) |
| `add-server.ps1` | command-line variant of Add server (`-Id <guid>` or `-Search <text>`) |
| `get-sizes.ps1` | resolves exact Workshop sizes for the queued mods (merge-only) |
| `fix-sizes.ps1` | fills any size the planner could not resolve |
| `test-rules.ps1` | asserts the completion rule against disk, and checks the served page |
| `data\` | state: tracked servers, downloader config, exact sizes (created on first run) |
| `serverprofile\` | where the dedicated server writes the downloads (created at runtime) |
| `armar-server\` | the dedicated server install you provide |
| `docs\reforgermods-api-v2.md` | offline copy of the reforgermods.net API reference |

## Where things are stored

Everything is relative to this folder. Two environment variables move the big
parts (optional):

- `RFMM_HOME` — where `serverprofile\`, `armar-server\` and `steamcmd\` live
- `RFMM_DATA` — where the `data\` json files live

Leave them unset and everything stays inside this folder. That is also how you
keep two independent setups on one machine.

Set them **in the same shell that starts the dashboard**, and be aware they are
only process environment: on this machine they are not persisted anywhere, so a
dashboard started from a plain shell comes up on the empty `data\` next to the
scripts and looks like a fresh install. `test-rules.ps1` fails with an explicit
message when it is pointed at the wrong tree instead of reporting every mod as
missing.

## How "installed" is decided

A mod counts as installed when the file list in its own `meta` matches the disk
exactly: every file that `meta` names exists and has the size it records there
(the game itself reads `meta` this way). The folder must also be quiet for 2
minutes, so a download in flight is never mistaken for a finished one.

The dashboard, the queue trimming, the client copy, `add-server`, `verify`,
`make-preset` (it needs a resolvable `meta`) and `test-rules.ps1` all use this one
rule. A folder's total size is never used: it lies for small mods (a 2 MB
tolerance made a 921 KB mod "installed" at 202 KB), it lies when the Workshop size
in `data\batch1-sizes.json` goes stale after a mod update, and it hides the markers
the DS writes before the data paks. Some Workshop mods legitimately lack
`addon.gproj`; every real addon has `meta`.

## Traps the code handles (do not "simplify" them away)

- **The DS has a ~1 MB download-list limit**: with several hundred mods in the
  config it reports "started" and crashes ~30 s later. Every start therefore
  trims the config first, waits 25 s and retries once.
- **Sizes are merged, never replaced**: the config is trimmed to the remaining
  mods, so a replace would destroy the sizes of everything already downloaded.
- **Presets go inside `m_aPresets { }`** of
  `SCR_WorkshopAddonManagerPresetStorage`, GUIDs quoted. A preset written
  anywhere else in the conf is dropped by the game on the next save. Only mods
  that are installed are included: the launcher deletes entries it cannot
  resolve, which poisons the whole preset.
- **PowerShell is case-insensitive**: never name a local variable `$cfg`/`$Cfg`
  or it shadows the script's `$Cfg` path and leaks into other functions. Same for
  the automatic variables: the DS profile path is `$DsProfile`, not `$Profile`.
- **The DS rewrites the config on exit**: anything appended while it runs is
  discarded, so every handler that writes the queue stops it first.
- **`"mods": null` means an empty queue**, not one mod: `@($null).Count` is 1 in
  PowerShell, and the DS writes exactly that shape on shutdown.
- **State files are written atomically and read tolerantly**: closing the console
  window kills the process mid-write, so a save goes to `.tmp` and is swapped in,
  and an unreadable file is renamed `*.corrupt-<timestamp>` (never deleted) so one
  bad file cannot stop the dashboard from starting.
- **Mod folders can legitimately lack `addon.gproj`** (8-file dev packs); every
  real addon has `meta`, which is what decides completion.

## Tests

```powershell
powershell -File test-rules.ps1        # with the dashboard running
```

It checks the completion rule against disk, detects partial folders that are not
queued (orphans), and validates the page's JavaScript with `node --check` when
node is installed.

## API

`reforgermods.net` free tier: 60 requests/minute, no key needed.
Full reference: `docs\reforgermods-api-v2.md`.
