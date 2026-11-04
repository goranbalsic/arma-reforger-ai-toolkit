# Spawn-replacement mods (fix or standalone)

How the working FIA→RHS_ION and USSR→modern mods are built, and how to make another
one. Everything here is verified in game.

## Why not prefab overrides

A mod that ships a prefab at a vanilla path does **not** reliably win: the base game
packages register last, so the vanilla resource stays mounted. The evidence is the
engine's own spawn log line - with an override-only mod it still reads

```
INFO: Editor EDIT: Player <name> spawned Character_USSR_Officer.et prefab at <...>
```

i.e. the vanilla prefab. `work/ussr-mod` (42 overrides) and Modern Russians both use
that approach; it is why "every USSR unit is modern" never actually happened in game.

## What works: substitute at spawn

Four hooks, all script-side, no resource replacement:

```c
modded class SCR_CatalogEntitySpawnerComponent            // catalog squads / AI
modded class ArmaReforgerScripted                         // SpawnEntityPrefabEx callers
modded class SCR_PlacingEditorComponentClass              // Game Master single units
```

`SCR_PlacingEditorComponentClass` needs **both** methods:

```c
override ResourceName GetPrefab(int index)        // index -> prefab, used when spawning
override int GetPrefabID(ResourceName prefab)     // prefab -> index, used when selecting
```

- Only `GetPrefab` -> the browser hands the substituted prefab back, the registry
  lookup fails and placement dies silently with
  `Cannot initiate placing of prefab "...", it's not registered in placeable entities!`
- Substituting the browser list (`GetPrefabs`) instead -> the replaced prefabs carry
  their own faction and vanish from the faction-filtered browser tab.

The full generator is `scripts/make-replacement-mod.py`; run it with a config:

```
python scripts/make-replacement-mod.py make-replacement-mod.example.json --project ../work/my-mod
```

It writes the cloned units, the cloned groups, the script and `addon.gproj`.

## The units must be cloned, and re-owned

Reference the replacement prefabs from **your** addon with **your** GUIDs (a `.meta`
sidecar per prefab). Two things go wrong if you skip this:

**Faction.** A swapped unit keeps the faction of the prefab it was copied from, so two
squads of the same side end up on different factions and fight each other. Override the
affiliation component using the **ID of the base prefab** the clone inherits from,
otherwise a second component is added instead of replacing the inherited one:

```
Character_RHS_ION_base.et    {6239642BBB275066}  RHS_ION
Character_RHS_AFRF_Base.et   {6062F6587469882D}  RHS_AFRF
Character_FIA_base.et        {555C98D1CD949F3E}  FIA
Character_USSR_Base.et       {520EC9618276DF23}  USSR
```

```c
components {
  SCR_CharacterFactionAffiliationComponent "{6062F6587469882D}" {
   "faction affiliation" "USSR"
  }
```

**Groups.** A group prefab carries its members in `m_aUnitPrefabSlots`. Clone every
group prefab too and point its slots at your units, or its members spawn unopposed by
the hooks.

## Two modes

| | standalone | fix |
|---|---|---|
| units | all cloned in your addon | only the gaps cloned here |
| other mod | not needed | required, listed in `addon.gproj` |
| `keepFrom` in the config | omitted | path to that mod's `data.pak` |
| example | `work/ussr-modern` 3.0.0 | `work/mr-fix` 1.0.2 |

`keepFrom` reads the other addon's pak and leaves every path it already replaces
untouched, so its prefabs keep loading and only the missing units are swapped. That is
what a "fix" mod should be - it also means the other mod's author keeps the credit for
everything except the gaps.

Beware: if that other mod's replacements do not apply in game (as happened with Modern
Russians - its prefabs are same-path overrides), leaving paths to it keeps them vanilla.
Check the spawn log line before believing a dependency does anything; if it does not,
ship the standalone variant and keep the dependency only for credit.

## Build, publish, verify

```
# pack (needs Workbench; closes the game first)
pack-addon.ps1 -Project .\work\my-mod -Out .\build\my-mod -ExtraAddonsDir .\build\deps

# update an existing item, headlessly
publish-addon.ps1 -Auto -ModId <projectId> -Project .\work\my-mod -PublishDir .\build\my-mod `
  -Version 1.0.1 -ChangeNote "..." -ExtraAddonsDir .\build\deps

# a NEW item still needs the Publish dialog once (the API requires `summary`)
publish-addon.ps1 -Project .\work\my-mod -PublishDir .\build\my-mod -PreviewImage .\work\my-mod\preview.png `
  -ExtraAddonsDir .\build\deps
```

`-ExtraAddonsDir` matters for that dialog: without the dependency addons mounted the
project fails to load and Workbench silently opens the default project instead.

Verification is the spawn line, not the deploy menu:

```
INFO: Editor EDIT: Player <name> spawned Character_USSRFix_MSV_OFFICER.et prefab   <- replaced
INFO: Editor EDIT: Player <name> spawned Character_USSR_Officer.et prefab         <- still vanilla
```

For groups, the same line appears per member as they are spawned.

## Traps that cost time

- **Do not fabricate** `profile\.save\...\workshop\I<GUID>.json` for an unpublished
  local mod: the game treats it as Workshop-managed, tries to verify it and reports the
  addon as corrupted.
- A bare local test addon needs only `addon.gproj` + `data.pak` + `resourceDatabase.rdb`.
- Published dependency lists come from the resources in the bundle, so a mod that only
  points at vanilla paths cannot declare a same-path-override dependency headlessly -
  use the dialog's dependency picker.
- Claimed versions cannot be reused: `workshopApi.assetVersionAlreadyExists`.
- The Workshop pages are CDN cached; verify a publish with `?cb=<random>`.
