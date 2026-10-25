# arma-reforger-ai-toolkit

AI tooling and instructions for Arma Reforger / Enfusion modding: read the game
and every installed addon without opening the editor, turn a shipped `.pak` back
into editable source, drive a live Workbench, and compile a distributable addon
from the command line.

Built to be used by a coding agent (it ships as an OpenCode/Claude-style skill),
but every piece works standalone from a terminal.

## What is in the box

| Piece | Purpose |
| --- | --- |
| `skill/arma-reforger-modding/` | The instructions: Workbench CLI reference, pak format, preset/load-order rules, limits |
| `skill/.../scripts/refpak.py` | Read, list, manifest, and extract `.pak` archives (Python 3, stdlib only) |
| `skill/.../scripts/pack-addon.ps1` | Pack a project through Workbench and validate the result |
| `tools/build-index.py` | Index installed addons + launcher presets into a machine-readable inventory |
| `tools/deploy-mod.ps1` | Install a packed addon and enable it at the end of a launcher preset |
| `install.ps1` | Copy the skill into an agent's skill folder, or `-Check` the toolchain |

## Requirements

- Python 3.8+ (pak tools, indexer)
- PowerShell 5.1+ (scripts)
- Arma Reforger Tools (Steam) for `pack-addon.ps1` - the Workbench binary is the
  only thing that can compile Enforce Script and produce a valid `data.pak`
- Optional: Node.js 22/24 + an MCP client if you want the live Workbench bridge
  (see `skill/.../reference/mcp-tools.md`)

## Quick start

```powershell
.\install.ps1 -Check                 # resolve Workbench/game/addons paths
.\install.ps1                        # install the skill into ~/.config/opencode/skills
```

Inventory what is installed:

```powershell
python tools\build-index.py index
python tools\build-index.py extract all          # text resources for every addon
python tools\build-index.py extract "My Preset"  # or a single launcher preset
```

Work on one addon:

```powershell
python skill\arma-reforger-modding\scripts\refpak.py list  "<addons>\<Name>_<GUID>\data.pak"
python skill\arma-reforger-modding\scripts\refpak.py extract "<addons>\<Name>_<GUID>\data.pak" work\mod .c,.conf,.et,.layout
powershell -File skill\arma-reforger-modding\scripts\pack-addon.ps1 -Project work\mod -Out build\mod
powershell -File tools\deploy-mod.ps1 -Build build\mod -Id MyMod -Guid <16 hex chars> -Title "My Mod" -Preset "My Preset"
```

## How it works

- `.pak` is a `FORM`/`PAC1` container: a compressed `DATA` chunk plus a `FILE`
  entry tree whose offsets are **absolute**. `refpak.py` implements that layout,
  including zlib vs stored entries. Extraction is what makes a Workshop addon
  editable without touching the installed copy.
- Addon overrides are path-based: an addon that ships the same relative path as
  the base game (or another addon) replaces that resource. The addon mounted last
  wins, which is why `deploy-mod.ps1` appends the preset entry at the end.
  No `.meta` files are needed for prefab overrides.
- Workbench's exit code is always `0`, even when packing fails. `pack-addon.ps1`
  gates on the three output files and the newest log instead.
- Packing requires the base game and any dependency addons to be mounted via
  `-addonsDir`. A minimal build looks like:

  ```powershell
  Workbench\ArmaReforgerWorkbenchSteamDiag.exe -wbModule=ResourceManager `
    -addonsDir "<game>\addons,<staging>" -gproj "<project>\addon.gproj" `
    -packAddon -packAddonDir "<out>" -wbSilent -noThrow
  ```

  `-wbModule=ResourceManager` is mandatory; without it Workbench starts, exits
  `0`, and builds nothing.

## Local addons vs Workshop

The launcher resolves preset entries as Workshop items. A locally built addon is
not one, so a preset can report it as *cannot be downloaded* even though the
files are present.

- `deploy-mod.ps1` writes a `meta` file next to `addon.gproj`, which is what makes
  the launcher treat the folder as a local addon. Keep it if you copy a build by
  hand.
- Even with `meta`, an unpublished addon has no Workshop identity. Keep test
  builds in their own preset instead of mixing them into a shared one.
- The reliable way to test without publishing is to skip presets entirely:

  ```powershell
  ArmaReforgerSteam.exe -addonsDir "<addons folder>" -addons "<FolderName>"
  ```

  `-addons` accepts the folder name (the `<Name>_<GUID>` directory) or the GUID.

- The game launcher **deletes preset entries it cannot resolve**, and may rewrite
  the whole settings file on exit. Do not keep an unpublished build in a preset
  you care about. `tools/launch-with-preset.ps1` takes a normal preset, appends
  extra local GUIDs, and passes the whole list on the command line instead:

  ```powershell
  .\tools\launch-with-preset.ps1 -Preset "My Preset" -ExtraGuid <local guid> -DryRun
  ```

  `-DryRun` prints the resolved list and flags any GUID with no folder on disk,
  which is what the launcher would otherwise fail on.

## Publishing

Workbench uploads through the Bohemia backend. Two facts, verified against the
shipped binary and a live attempt:

- There is no command-line login (`-wbBackendLogin` does not exist in current
  builds), so Workbench's own cached session is the only credential.
- `WorkshopApi/CreateAssetUpload` rejects a new item without a **summary**, and no
  `-publishAddon*` switch sets it. Only the publish dialog does.

So: **first publish = dialog fields, every update after = headless.**

```powershell
# once: pre-fills bundle dir + preview, opens the dialog for Title/Summary/Description
.\tools\publish-addon.ps1 -Project <dir> -PublishDir <packed> -PreviewImage <png>

# forever after: no GUI
.\tools\publish-addon.ps1 -Auto -ModId <project id> -PublishDir <packed> -Version 1.0.1 `
    -ChangeNote "fix" -ExtraAddonsDir <dependency staging dir>
```

`-ExtraAddonsDir` matters: the project's dependencies must be mounted or Workbench
refuses the project (`dependency '<GUID>' can't be added`) and never reaches the
backend.

`-Auto` classifies the outcome from the Workbench log:

| Exit | Meaning |
| --- | --- |
| 0 | no backend errors reported |
| 1 | Workshop API error |
| 2 | item does not exist yet - do the first publish in the dialog |
| 3 | account not linked |
| 4 | cached session rejected |
| 5 | backend not ready (Steam offline) |
| 6 | no publish activity / Workbench hung |

A hang is treated as failure, not success - Workbench can sit forever while the
game owns the Steam identity or while a dependency is missing.

The script never asks for, stores or transmits a password.

Workbench needs roughly 3 GB of free RAM to publish. If the machine is busy
(a game, several browsers) it dies with `Out of memory` mid-publish; the script
refuses to start below 3 GB instead.

Note on "fully headless": the binary does contain the Workshop v4 upload API with
Bearer auth, so a script could reimplement login and upload. That means handling
your account password in code and breaking whenever BI changes the API - not what
this tool does.

## Limits

- Workbench is a GUI application. Its CLI covers project open, script
  compilation, packing, publishing, data builds, validation and plugins. Terrain,
  material graph, animation and audio editors have no CLI.
- A shipped `data.pak` cannot be patched in place - you edit extracted source and
  repack. Packed data is compressed and indexed for distribution and is not the
  original project.
- Enforce Script is compiled. A `.c` edit reaches the game only after Workbench
  recompiles (reload or pack).
- This toolkit never writes to the installed addons folder except when you run
  `deploy-mod.ps1`, which copies a build in and enables it in a preset (with a
  config backup, and it refuses while the game is running).

## Provenance

Workbench switches and the pak layout were verified against the retail binaries;
they are not copied from a wiki. The `.pak` reader implements the container
directly; no game code or assets are included.

Workbench and Arma Reforger are property of Bohemia Interactive. This project is
unaffiliated tooling for mods you own or are authorised to examine.

## License

MIT - see `LICENSE`.
