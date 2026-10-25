---
name: Arma Reforger Modding
description: Build, inspect, patch and repack Arma Reforger mods and addons with AI - browse vanilla and workshop content, read or write Enforce Script, edit prefabs/configs, drive a live Workbench over its NET API, and compile a distributable .pak. Use for any Arma Reforger / Enfusion Workbench task, any addon in a local addons folder, or any launcher addon preset.
---

# Arma Reforger modding

Everything here is reversible and works against an installed game. Follow the
rules in **Ground rules** before touching a file.

## Ground rules

1. **Never edit files inside `Documents\My Games\ArmaReforger\addons`.** Those are
   Workshop downloads; the launcher overwrites them on update and a modified
   `data.pak` fails the checksum. Extract first, edit the copy.
2. **Work in `<repo>\work\`, pack to `<repo>\build\`.** Both are disposable and
   ignored by git.
3. **Verify before you claim success.** Workbench CLI exits `0` even when packing
   fails. Check that `data.pak` exists, is non-trivial in size, and lists the
   expected paths - see `reference/pak-and-build.md`.
4. **Clean the bridge out before publishing.** A live Workbench session injects
   handler scripts into the open mod; leaving them in ships debug code.
5. Prefer MCP tools over hand-rolled automation when they exist, and the shipped
   scripts over new ones.

## Where things are

`<repo>` is the toolkit root - the folder holding `README.md`, `tools\`, `work\`
and `skill\`. Paths starting `scripts/` or `reference/` are relative to this
skill's own folder.

Run `powershell -File <repo>\install.ps1 -Check` to print resolved paths.

| What | Where |
| --- | --- |
| Workbench | `<Steam>\steamapps\common\Arma Reforger Tools\Workbench\ArmaReforgerWorkbenchSteamDiag.exe` |
| Game data | `<Steam>\steamapps\common\Arma Reforger\addons\data` (base addon `58D0FB3206B6F859`) |
| Installed addons | `Documents\My Games\ArmaReforger\addons\<Name>_<GUID>` |
| Launcher presets | `Documents\My Games\ArmaReforger\profile\.save\app<id>_user<steamid>\settings\ReforgerGameSettings.conf` |
| Workbench logs | `Documents\My Games\ArmaReforgerWorkbench\logs\logs_<timestamp>\console.log` |
| Workbench profile | `Documents\My Games\ArmaReforgerWorkbench\profile` |
| Inventory | `<repo>\context\INDEX.md`, `presets.json`, `manifests.json` |
| Extracted code | `<repo>\work\<preset>\<addon folder>\` |

## Choose the surface

| Need | Surface |
| --- | --- |
| Read vanilla scripts/prefabs, search the API, look up a class | `game_read`, `game_browse`, `asset_search`, `api_search`, `component_search` (MCP) |
| Read or write files in a mod project | `project` tool, or normal file tools on the extracted copy |
| Scaffold a new mod | `mod` (create/validate/build), `script_create`, `prefab`, `layout_create`, `config_create`, `scenario_create_conflict` |
| Change a live open world (entities, layers, camera, resources) | `wb_*` tools (needs Workbench running) |
| Compile a distributable addon | `scripts/pack-addon.ps1`, or `mod build` |
| Crack open a shipped `.pak` | `scripts/refpak.py` |
| Understand a binary, a crash, or an obfuscated behaviour | a reverse-engineering MCP (e.g. REA) |

`wb_*` tools auto-launch Workbench and inject their handler scripts. Do not start
Workbench by hand first - you will get a Workbench without the bridge.

## The edit -> test -> pack loop

1. **Extract** the addon you are changing (once):
   `python scripts/refpak.py extract "<addons>\<Name>_<GUID>\data.pak" "<repo>\work\<Name>"`
   For a whole preset use
   `python <repo>\tools\build-index.py extract "My Preset"`.
2. **Edit** `.c` / `.et` / `.conf` / `.layout` in the extracted folder. Text
   resources only - models, textures and audio are not extracted by default.
3. **Open it** in Workbench: `wb_launch` with `gprojPath` =
   `...\work\<Name>\addon.gproj`. If `wb_state` reports `game`, call `wb_stop` -
   entity and layer tools only work in edit mode.
4. **Iterate without restarting**: after editing a script call `wb_reload`
   (`target: "scripts"`). Then `wb_play` / `wb_stop` to test, `wb_state` to see
   why something did not load. Compilation is async; check the log before
   concluding a fix did not work.
5. **Pack** when the behaviour is right:
   `powershell -File scripts\pack-addon.ps1 -Project <folder> -Out <repo>\build\<Name>`.
   Confirm the three output files and read `console.log` for compile errors.
6. **Clean** the bridge out of the project before publishing.

For a game-mode test outside Workbench, pass the extracted folder as a mod:
`ArmaReforgerSteam.exe -addonsDir "<parent of the addon folder>" -addons "<folder name>"`.
That is the documented mount path; if the game rejects the folder, pack it.

## Working with presets

`<repo>\context\INDEX.md` is the generated inventory,
`<repo>\context\presets.json` the machine readable one (per-mod GUID,
dependencies, scenarios), and `<repo>\context\manifests.json` every file in
every addon's pak. Regenerate with `tools\build-index.py index` after installing
or enabling mods.

- Load order is resolved by dependency GUIDs **and** by mount order, not by the
  order you think is natural. For same-path overrides the addon mounted last
  wins, so a patch must come after the mod it patches.
- To add a mod safely, check its dependencies in `presets.json` and keep them
  enabled.

## Limits you must not paper over

- Workbench is a GUI application. Its CLI covers project open, script
  compilation, packing, publishing, data builds, validation and plugins - not
  terrain sculpting, material graphs, animation or audio editors. Anything the
  MCP tools do not expose can be added as a `NetApiHandler` script compiled into
  the open mod.
- **You cannot patch a compiled `.pak` without repacking.** Editing an extracted
  copy changes what the *project* builds; the shipped `data.pak` stays untouched
  until you pack. There is no byte-patch path that keeps the pak valid.
- Packed data is compressed and indexed for distribution and cannot be restored
  into the original source tree byte-for-byte. Keep the extracted source.
- A `.c` edit only reaches the game after Workbench recompiles scripts (reload or
  pack). Enforce Script is compiled, not interpreted from disk at runtime.

## References

- `reference/workbench-cli.md` - every CLI switch, verified against the binary.
- `reference/pak-and-build.md` - pak format, extract/pack, validation.
- `reference/mcp-tools.md` - the MCP tool surface, grouped by task.
- `reference/presets.md` - preset file format, load order, dependency traps.
- `reference/recipes.md` - worked end-to-end workflows.
