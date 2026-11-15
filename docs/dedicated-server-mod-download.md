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

## Notes

- In-game download speed ≈ server download speed (same backend); the win is
  unattended completion, no UI retry loop, and no dependence on the client's
  stuck download handling.
- `documents\My Games` stub folders created by the client use the same
  `<Name>_<GUID>` naming as the server output, so the copy is a clean merge.
