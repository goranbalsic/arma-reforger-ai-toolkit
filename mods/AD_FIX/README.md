# AD_FIX

Fixes the Arma Dudes 1 preset crash after the Arma Reforger **1.9** update.

## Cause

`Creature Melee AI` (`4FD4A1BD550793F4`) overrides a character controller method
whose signature changed in 1.9:

```text
Can't compile "Game" script module!
Scripts/Game/CreatureMeleeAI/Actions/CMAI_PersonThrow.c(107): Overloaded function 'StopLoitering' not compatible
```

1.9 added a second parameter:

```c
// 1.8
void StopLoitering(bool terminateFast)
// 1.9
void StopLoitering(bool terminateFast, SCR_LoiterCustomAnimData customAnimData = null)
```

The mod still declares the old one, so the whole `Game` module fails to compile
and the game crashes on startup. `CMAI_CarryPresentation.c` overrides the same
method on `SCR_CharacterCommandLoiter` and breaks the same way.

## What AD_FIX does

It is a normal addon that ships a **complete copy of Creature Melee AI's script
files** with only those two overrides updated, then forwards the new argument:

```c
override void StopLoitering(bool terminateFast, SCR_LoiterCustomAnimData customAnimData = null)
{
    ...
    super.StopLoitering(terminateFast, customAnimData);
}
```

Everything else in the mod (prefabs, assets, behaviour) still comes from the
Workshop addon, which stays enabled and becomes a declared dependency.

Why the whole script set and not just the two files: Enfusion merges every
`modded class` in a module, and a partial override from a second addon cannot
see members declared by files left in the original addon
(`Undefined function ... CMAI_RequestPersonThrow`). Shipping all 135 scripts
keeps each class chain in one addon.

## Install

1. Keep `Creature Melee AI` enabled.
2. Enable `AD_FIX` **after** it. The dependency in `addon.gproj` normally
   enforces this; a launcher preset that resolves by list order needs AD_FIX
   last.

No other mod in the 118-mod preset has a 1.9 compile error: packing AD_FIX with
the whole installed addons folder mounted compiles the full `Game` module
cleanly.

## Rebuild

After a Creature Melee AI update, re-run:

```powershell
powershell -ExecutionPolicy Bypass -File mods\AD_FIX\make-ad-fix.ps1
```

The script extracts the installed mod, applies the two replacements (and aborts
if the upstream text no longer matches), packs to
`arma-ai\build\ad-fix`, verifies the packed signature, and deploys it as
`AD_FIX_ADF1000000000001`.

## Test it

Launch the preset plus the local build without editing the preset:

```powershell
.\tools\launch-with-preset.ps1 -Preset "ArmaDudes 1" -ExtraGuid ADF1000000000001
```

The crash is a startup compile error, so the pass condition is simply that the
game reaches the menu/world and `crash.log` has no `Can't compile "Game"` line.
