# Presets, load order and dependencies

## Where presets live

The launcher stores every addon preset in one SQF-like file:

```
Documents\My Games\ArmaReforger\profile\.save\app<appid>_user<steamid>\settings\ReforgerGameSettings.conf
```

Structure:

```
SCR_WorkshopAddonPreset "{PRESET-GUID}" {
    m_sName "Arma Dudes Vanilla"
    m_aAddonsMeta {
        SCR_WorkshopAddonPresetAddonMeta "{META-GUID}" {
            m_sGuid "60B2AD8092C4C94A"     <- addon GUID
            m_sName "Disable GM Dynamic Simulation"
        }
```

Two rules that break naive parsers:

1. **`m_sGuid` comes before `m_sName`.** Pair them by buffering the last GUID,
   not by attaching a GUID to the previous name - that shifts every mod by one
   and still "works" because every GUID is a real addon.
2. **The GUID is the addon id, not the workshop id.** It matches the suffix of
   the installed folder: `<Name>_<GUID>`.

Installed addon layout:

```
addons\
  <Name>_<GUID>\
    addon.gproj      <- project id, GUID, title, Dependencies { "guid" ... }
    meta             <- workshop metadata (UTF-8 with BOM), versions, scenarios
    data.pak         <- the actual content
    resourceDatabase.rdb
```

## Load order

Presets list mods, but the engine resolves what depends on what from
`addon.gproj`:

```
Dependencies {
  "58D0FB3206B6F859"     <- base game, always
  "1337C0DE5DABBEEF"     <- RHS Content Pack 01
}
```

- `58D0FB3206B6F859` = Arma Reforger base (`addons\data\ArmaReforger.gproj`).
- `5614BBCCBB55ED1C` = Enfusion core (`addons\core\core.gproj`).
- Everything else must be installed *and* enabled, or the mod silently loses its
  overrides - the classic "my patch does nothing" cause.

Before disabling a mod, check whether another enabled mod depends on it:

```powershell
python -c "import json;d=json.load(open('context/presets.json',encoding='utf-8'));t='1337C0DE5DABBEEF';print([a['name'] for a in d['addons'].values() if t in a['dependencies']])"
```

## Regenerating the index

After installing, updating or enabling mods:

```powershell
python tools\build-index.py index
python tools\build-index.py extract all            # text resources for every addon
python tools\build-index.py extract "Preset 1"     # or one preset only
```

`index` rewrites `context\INDEX.md`, `context\presets.json` and
`context\manifests.json`. `extract` writes to `work\<preset>\<addon folder>`.
Both are idempotent and skip nothing silently: missing packs and uninstalled
preset entries are reported in `INDEX.md`.

## Reading `meta` safely

`meta` is UTF-8 **with BOM** and one long JSON line. Use `utf-8-sig`; plain
`utf-8` raises `Unexpected UTF-8 BOM`. It carries the workshop version, game
version compatibility, dependencies and the scenario GUIDs
(`{GUID}Missions/Name.conf`) the addon provides.

Scenario GUIDs are the practical way to pin a mission. They belong in a server
config, not on a client command line:

```json
{ "game": { "scenarioId": "{GUID}Missions/Name.conf" } }
```

Workbench ignores `-world` (it uses `-load` / the open world instead), so do not
try to launch a scenario with it.
