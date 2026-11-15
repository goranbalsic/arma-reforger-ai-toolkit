# Downloading Workshop mods without the game (dedicated-server route)

Verified on Reforger server version 1.9.0.37 (Nov 2026). The goal: get workshop
paks onto disk without the in-game downloader — useful when the in-game
download stalls at 0 MB or you want an unattended, scriptable pull.

## Why there is no direct URL

The Reforger workshop is **not mod.io** — `ArmaReforgerSteam.exe` contains zero
mod.io references. The client pulls everything from BI's own content service
(`https://cs-public.bistudio.com/`, `https://cs-inter.bistudio.com/`) as
"Fragmentizer" data: each addon is split into a manifest plus fragments,
requested with the game session's auth. Endpoint shapes found in the binary:
`assets/%s/versions/%s/download`, `manifest/`, `s2s/assets/download-list`.
Unauthenticated GETs against these hosts return 404 or hang, so a one-line
download URL is not possible.

The workshop page (`reforger.armaplatform.com/workshop/<hex-id>`) is
server-rendered Next.js; `__NEXT_DATA__` embeds `currentVersionId` (the
version's numeric id) but no download link.

## The route that works: the free dedicated server

The DS auto-downloads any workshop mods listed in its config, unattended.

1. Install (anonymous login works):
   ```
   steamcmd +force_install_dir <dir> +login anonymous +app_update 1874900 validate +quit
   ```
   (experimental branch: 1890870)

2. Write `config.json` — validated against the 1.9 schema:

   ```json
   {
     "bindAddress": "127.0.0.1",
     "bindPort": 2001,
     "publicAddress": "127.0.0.1",
     "publicPort": 2001,
     "game": {
       "name": "ModGrabber",
       "scenarioId": "{ECC61978EDCC2B5A}Missions/23_Campaign.conf",
       "maxPlayers": 1,
       "mods": [
         { "modId": "<16 hex chars from the workshop URL>", "name": "Mod name" }
       ]
     }
   }
   ```

   Schema traps (each wrong key fails the whole config, one error at a time):
   - `bindAddress`/`publicAddress` — **not** `bindIP`/`publicIP`
   - `game.maxPlayers` — **not** `playerCountLimit`
   - no top-level `battlEye` key in this build
   - the schema is embedded in `ArmaReforgerServer.exe`; the validator prints
     the offending `#/path` on failure — just iterate

3. **Run it from the server folder as the working directory** — the binary
   resolves `./addons` relative to CWD, otherwise it dies with
   `Can't find '58D0FB3206B6F859' game addon!` in a modal dialog:

   ```
   cd <server dir>
   ArmaReforgerServer.exe -config <path>\config.json -profile <path>\serverprofile
   ```

4. Watch `<serverprofile>\logs\<latest>\console.log` for:
   ```
   BACKEND : Addon Download started <modId> - <name>
   BACKEND : Download speed ... KB/s
   ```
   Paks land under `<server dir>\addons\` (fragments stage elsewhere in the
   profile until assembled). Stop the server when the log stops moving.

## Using the paks in the client

The server's `addons\<Name>_<GUID>` folders match the client layout. Copy them
into `Documents\My Games\ArmaReforger\addons\` (replacing any 0 MB stubs left
by a stuck download — a 0 MB stub folder is the classic stuck-resume state and
must be deleted before either retry path). Alternatively mount directly:
`ArmaReforgerSteam.exe -addonsDir "<dir>" -addons "<FolderName>"`.

## Batch-downloading a multi-server mod union

To grab the combined modlist of several servers at once (verified with a
6-server, 665-mod union):

1. Pull each server's reported mods from `/v2/servers/{id}` (reforgermods.net
   V2 API) and union them by mod id — servers share many mods, so the union is
   far smaller than the sum of the lists.
2. List the locally installed addons by the GUID suffix of each folder in
   `Documents\My Games\ArmaReforger\addons\*_<GUID>` and subtract.
3. Size the batch with `POST /v2/tools/storage-plan` (`mode: "add"`,
   `current` = installed ids, `desired` = union ids). It resolves exact
   Workshop bytes server-side, no API key. Cap: **500 mods across both lists
   per call** — chunk the desired list, dedupe the returned `downloads` by id,
   and sum `bytes`.
4. Write the DS `config.json` with only the *missing* mods (the installed ones
   would be duplicate downloads) and run the DS as above. The DS always pulls
   the latest published version of each mod; server-reported versions may lag.
5. When the log goes quiet, robocopy the new `serverprofile\addons\<Name>_<GUID>`
   folders straight into `Documents\My Games\ArmaReforger\addons\`.

Rate limits: 60 req/min anonymous on read endpoints; `storage-plan` is a
single POST per chunk and unaffected in practice.

## Traps learned the hard way (batch of 600+ mods)

- **Temp folders are not storage**: the whole downloader (DS profile with tens
  of GB of finished mods included) originally lived in `%TEMP%`. One temp
  cleaner run would have deleted everything. It now lives in a permanent
  folder and the Desktop shortcut points there.
- **Server state leaked between requests**: the dashboard's HTTP loop reused a
  `$msg` variable across requests, so the JSON `{"ok":true}` from a Start or
  Verify click got appended to the next `/status` response, which broke JSON
  parsing in the browser until reload. Reset per-request state inside the loop.
- **One completion rule only**: the rule (assembled files + quiet 2 min + size
  match) lives in the dashboard's `/status` completed list; `sync-addons.ps1`
  mirrors exactly that list. A separate "quiet folder" heuristic in the sync
  mirrored half-downloaded mods after a hard kill. `test-rules.ps1` asserts the
  served rule against disk live.
- **`robocopy /MIR` needs a single-writer guarantee**: two concurrent sync
  loops (check-then-start race after a dashboard restart) can delete while
  each other copies. A named mutex makes the instance check atomic.
- **Preset blocks belong inside `SCR_WorkshopAddonManagerPresetStorage`**, and
  GUIDs are quoted (`SCR_WorkshopAddonPreset "{GUID}" {`). A preset block
  appended after the storage block, or with bare-brace GUIDs, gets dropped by
  the game on its next save. `mod-manager/make-preset.ps1` inserts correctly,
  includes only locally installed mods (unresolvable entries poison the
  preset), and verifies braces + counts.
- **`Start-Process` liveness checks lie**: the DS crash on an oversized
  download-list happens ~30 s in; a 3 s check reported "started" for a DS that
  was about to die. Check after 20 s, and re-trim the config inside Start-DS
  so the trap cannot be hit by pressing the button.
- **Dependency mods are not batch progress**: the DS auto-pulls dependencies
  with no config entry. Counting their disk bytes into `doneB` pushed progress
  past 100% and made the ETA go negative. Sum only ids present in the sizes
  file; deps still show in the Completed list.
- **1 MB download-list limit**: at startup the DS requests
  `WorkshopApi/GetDownloadListS2S` for every mod in its config. Past ~600 mods
  the response body exceeds the DS's hard 1 MB cap
  (`error response body larger than: 1048576` ->
  `Failed to fetch addon details from workshop API!` ->
  `Unable to initialize the game` -> instant exit). Fix: keep only mods *not
  yet assembled* in the config — the DS skips done ones anyway, so trimming is
  lossless. Re-trim before every restart of a long batch.
- **Dependencies are auto-pulled**: the DS downloads required dependencies of
  config mods even when they are not listed. Subtracting locally-installed
  mods when building the config therefore does not fully avoid re-downloads —
  some bandwidth goes to dependency version-sync. Unavoidable.
- **Copying into the client addons folder**: `Copy-Item -Recurse -Force`
  *merges* folders — copying a new version into a folder that holds an older
  copy mixes the two. Use `robocopy src dst /MIR` per mod folder: exact
  replica, removes stale files, idempotent.
- **A folder is not "done" because the assembly files exist**: the DS writes
  `addon.gproj`, `meta`, and `resourceDatabase.rdb` *before* downloading the
  data paks. Treat a mod as complete only when the folder has stopped
  changing (e.g. untouched for 2 minutes) and its byte size matches the
  Workshop size (`/v2/mods/{id}` -> `size`, or `POST /v2/tools/storage-plan`).
- **storage-plan gets flaky under heavy use**: after many calls it starts
  returning non-exact entries. Chunk the desired list (<= 500 mods per call
  across current+desired), and re-fetch any non-exact mods individually from
  `/v2/mods/{id}` (throttle under the 60 req/min limit).
- **Sizes files are merge-only**: the DS config is trimmed to remaining mods,
  so any script that rebuilds a sizes file *from the config* and *replaces*
  the existing file destroys the full map. `get-sizes.ps1` merges; the same
  applies to any future size tool.

## Notes

- In-game download speed ≈ server download speed (same backend); the win is
  unattended completion, no UI retry loop, and no dependence on the client's
  stuck download handling.
- `documents\My Games` stub folders created by the client use the same
  `<Name>_<GUID>` naming as the server output, so the copy is a clean merge.
