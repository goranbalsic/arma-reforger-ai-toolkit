# MCP tools

This skill assumes you have at least one MCP server that can read the game and
talk to Workbench. The tool names below are the ones exposed by a Reforger
modding MCP server (the `reforger-forge` / `enfusion-mcp` family); other servers
may name them differently, so check your own tool list before calling.

Typical pairing:

- a Reforger modding server - game data, API index, project scaffolding, live
  Workbench (around 50 tools);
- a reverse-engineering server (optional) - PE/ELF inspection, strings,
  decompile providers, managed/.NET, JS/Electron, web captures.

Tool names are prefixed by the server: `reforger_game_read`, `rea_inspect`.

## Offline - no Workbench needed

| Tool | Use it for |
| --- | --- |
| `api_search` | 8,693 Enfusion classes and methods, inherited members, inheritance tree |
| `component_search` | ScriptComponent descendants filtered by category or event handler |
| `wiki_search` / `wiki_read` | 258 pre-downloaded BI wiki guides, full text with examples |
| `wb_knowledge` | Distilled modding patterns; `query="index"` lists topics |
| `game_browse` / `game_read` | Vanilla files, loose or inside `.pak`, transparently |
| `asset_search` | Find prefabs/models/textures by name, returns paths and GUIDs |
| `game_duplicate` | Copy a vanilla prefab/config into your mod with ancestry resolved |
| `workshop_info` | Read a `.gproj`'s workshop id, dependencies, scenarios |
| `project` | browse / read / write files in the project directory |
| `mod` | create, validate, or build an addon (`action=...`) |

## Code generation (offline)

`script_create` (component, gamemode, action, entity, manager, modded, basic),
`prefab` (`action=create` / `action=inspect` full ancestry merge),
`layout_create` (hud, menu, dialog, list), `config_create` (factions, mission
headers, entity catalogs, placeables), `server_config`,
`scenario_create_conflict` (full Conflict scenario, up to 7 files),
`animation_graph`, `building_setup`.

When you generate a `.c` that overrides a parent class, pass `parentClass` so the
tool fetches the real overridable signatures from the API index instead of
guessing.

## Live - requires Workbench

All of these auto-launch Workbench through `-gproj` and inject the bridge
scripts. Never start Workbench by hand for this.

Connection and lifecycle: `wb_launch`, `wb_connect`, `wb_diagnose`, `wb_state`,
`wb_reload`, `wb_cleanup`.

Play/test: `wb_play`, `wb_stop`, `wb_save`, `wb_undo_redo`, `wb_open_resource`,
`wb_execute_action` (any menu action by path, e.g. `Tools,Reload Scripts`).

World editing: `wb_entity_create`, `wb_entity_delete`, `wb_entity_list`,
`wb_entity_inspect`, `wb_entity_modify`, `wb_entity_select`,
`wb_entity_duplicate`, `wb_component`, `wb_clipboard`, `wb_layers`,
`wb_prefabs`, `wb_projects`, `wb_resources`, `wb_terrain`.

Text and assets: `wb_script_editor` (read/write the open script file by line),
`wb_localization` (string table CRUD), `wb_validate` (material/texture
validators).

### The bridge, so you can extend it

Workbench exposes a NET API on `127.0.0.1:5775`. Each tool is an Enforce
`NetApiHandler` compiled into the open project under
`<mod>\Scripts\WorkbenchGame\EnfusionMCP\`. Pattern:

```c
class EMCP_WB_ThingRequest : JsonApiStruct { string arg; void EMCP_WB_ThingRequest() { RegV("arg"); } }
class EMCP_WB_ThingResponse : JsonApiStruct { string status; void EMCP_WB_ThingResponse() { RegV("status"); } }
class EMCP_WB_Thing : NetApiHandler { ... }
```

If a GUI function has no tool, write a handler with that shape, call it through
the client, and keep it in your mod only while developing. `wb_cleanup -modDir
<folder>` removes the folder (it takes `modDir`, not the gproj path).

### Things you only learn by running it

- `wb_launch -gprojPath <project>` can land directly in **game mode**. Entity,
  layer and prefab tools then refuse with "WorldEditorAPI not available" - call
  `wb_stop` first and confirm `wb_state` says `edit`.
- Launching with `-gproj` and CWD set to the game install is what resolves the
  base addon. If you launch Workbench yourself without that, packing fails with
  `dependency '58D0FB3206B6F859' can't be added`.
- The bridge compiles handler scripts as part of the *open project*, so a
  script-only extracted addon is enough to work; the mod does not need its
  assets present for the live tools to function.
- After `wb_reload`, script compilation is asynchronous. Do not assert a fix from
  a single call - check `wb_state` or the log for compile errors.

## `rea` - when modding has no answer

Use it when the question is about the *binary*, not the data:

- `inspect` a PE for imports/sections/strings (no provider needed);
- `decompile` / `function` with a real provider for Workbench behaviour;
- .NET/IL, Electron/JS, crash dumps, web captures.

It is slower and heavier than reading a `.c` file. Reach for it when a bug is in
the engine itself, or when you need to know which CLI switches or config keys a
binary actually honours.

## Failure modes

| Symptom | Cause / fix |
| --- | --- |
| `game_read` returns plausible but wrong text | Pak reader offset bug: FILE entry offsets are absolute, not DATA-relative. Fix the reader or use `refpak.py`, then restart the server. |
| `wb_connect` refuses | Workbench not launched with the bridge scripts, or another Workbench instance owns port 5775. `wb_diagnose`. |
| `wb_launch` hangs at "waiting for NET API" | Script compile failure in the open mod - read the fresh `console.log`. |
| `project_write` outside project | Path validation; only the configured project root is writable. |
