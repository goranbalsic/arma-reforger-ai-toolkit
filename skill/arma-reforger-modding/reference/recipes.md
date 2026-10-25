# Recipes

Worked workflows. Commands assume the toolkit root is `<repo>` and the skill
folder is `<skill>`. Verify paths first with `install.ps1 -Check`.

## Modernize the leftover units of a faction

Symptom: a mod already modernizes most of a faction by overriding prefabs at
their vanilla paths, but a few units look vanilla or have no gear.

Two causes worth checking before writing anything:

1. **Empty stub override** - the mod ships a file at the vanilla path containing
   only `ID "...";` and no `components`. That does not "keep vanilla"; it
   *replaces* the prefab and deletes its kit. Look for files without a
   `components` block.
2. **No override at all** - the unit file simply is not present in the mod, so
   the base-game prefab loads untouched, including its parent (which may still be
   the vanilla one).

### 1. Establish ground truth

Extract the vanilla family and the mod's version, then compare:

```powershell
python <skill>\scripts\refpak.py extract "<game>\addons\data\dataNNN.pak" context\vanilla .et,.conf
python <skill>\scripts\refpak.py extract "<addons>\<Mod_GUID>\data.pak" work\<Mod> .et,.conf
```

Classify every unit: `ok` (has components and references the modern assets),
`STUB` (no `components`), `MISSING` (absent from the mod). Also read the spawn
list, so you only fix units that can actually appear:

```powershell
python <skill>\scripts\refpak.py cat "<game>\addons\data\dataNNN.pak" /Configs/EntityCatalog/<FACTION>/Characters_EntityCatalog_<FACTION>.conf
```

The entity catalog is the authoritative list of units for the deploy menu.

### 2. Generate same-path overrides

For each broken unit, create a prefab at the **same relative path** that:

- inherits from a prefab that is **already modernized** (assert it, never assume);
- keeps the vanilla `SCR_EditableCharacterComponent` block so the deploy-menu
  name, icon and labels are preserved;
- overrides only what changes: weapon slot, rank, launcher, or nothing at all if
  inheriting the modern kit is enough.

Rules that keep it correct:

- **Match the donor's ammo.** Swapping a 9x39 rifle into a donor whose pouches
  spawn 5.45 magazines produces a soldier with unusable ammo.
- **Keep role logic.** Leaders get leader kit, machine gunners get the MG donor,
  AT gets the launcher slot, crew gets a compact weapon, unarmed gets an empty
  `WeaponTemplate`.
- **Preserve distinct variants.** A `_KLMK`/camouflage variant should not become
  an exact clone of the base unit; keep its UI and only drop overrides that point
  at obsolete gear.
- **A new item block is safer than editing an inherited one.** Adding an
  `ItemsInitConfigurationItem` with a fresh GUID targeting an existing
  `TargetStorage` path works; rewriting an inherited array can drop entries.

Validate before packing: every `{GUID}path` you emit must resolve to a path that
exists, every donor must contain modern gear, and every file must have balanced
braces. `reference/pak-and-build.md` covers the pak side.

### 3. Pack with dependencies mounted

Your override depends on the base game **and on the mod it patches**, so both
must be resolvable at build time. Do not point `-addonsDir` at the whole workshop
folder (duplicate classes); stage the few addons you need:

```powershell
cmd /c mklink /J <stage>\<AddonFolder> "<addons>\<AddonFolder>"
powershell -File <skill>\scripts\pack-addon.ps1 -Project work\<Mod> -Out build\<Mod> -ExtraAddonsDir <stage>
```

If the log says `dependency '<GUID>' can't be added`, an addon is missing from
the mount list.

### 4. Deploy last

```powershell
powershell -File <repo>\tools\deploy-mod.ps1 -Build build\<Mod> -Id <ModId> -Guid <16 hex> -Title "<Title>" -Preset "<Preset name>"
```

Same-path overrides resolve to whichever addon is mounted last, so the script
appends your entry at the **end** of the preset and refuses to run while the game
is open (the launcher would overwrite the config on exit). It backs up the config
first.

An unpublished addon is not a Workshop item, so the launcher may report it as
*cannot be downloaded* inside a preset. Two things help: `deploy-mod.ps1` writes a
`meta` file (local-addon marker), and a test build should live in its own preset
(`-Preset "AI Test" -CopyFrom "Preset 1"`) rather than in a preset you share.
For a guaranteed test path, bypass presets:

```powershell
ArmaReforgerSteam.exe -addonsDir "<addons>" -addons "<Name>_<GUID>"
```

## Patch a script in an existing mod

```powershell
python <skill>\scripts\refpak.py extract "<addons>\<Mod_GUID>\data.pak" work\<Mod> .c,.conf
```

Edit, open the project in Workbench, `wb_reload`, test, then pack. Script files
are overridden by path exactly like prefabs.

## Find which addon owns a file

```powershell
python -c "import json;m=json.load(open(r'<repo>\context\manifests.json',encoding='utf-8'));print([k for k,v in m.items() if 'SearchTerm' in ' '.join(v)])"
```

Then map the GUID back to a folder name (`<Name>_<GUID>`) or a preset entry.

## Add an existing local addon to a preset by hand

Presets are SQF-like text. Entries look like:

```
SCR_WorkshopAddonPresetAddonMeta "{META-GUID}" {
 m_sGuid "ADDON-GUID"
 m_sName "Display Name"
}
```

Notes: `m_sGuid` precedes `m_sName` in the file, the addon GUID is the suffix of
its folder name, and the order of entries plus their GUIDs decides mount order.
`deploy-mod.ps1` does this edit for you with a backup.
