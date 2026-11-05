# AD_FIX

Fixes the Arma Reforger **1.9** compile crash in the Arma Dudes 1 preset.

## Cause

`RHS - Status Quo` 0.16.5237 still uses two APIs that 1.9 changed:

| RHS code | Arma Reforger 1.9 |
| --- | --- |
| `override void SetAuthor(int playerID)` | `void SetAuthor(int playerID, bool isGM = false)` |
| `return m_iWheelIndex;` in `SCR_WheelSlotInfo` | field replaced by `GetWheelIndex()` |

Both stop the whole `Game` script module compiling, so the start-up crash is:

```text
RHS_CAS_EditableEntityComponent.c(68): Overloaded function 'SetAuthor' not compatible
RHS_DestructionTireComponent.c(459): Can't find variable 'm_iWheelIndex'
Can't compile "Game" script module!
```

## What AD_FIX does

Ships patched copies of the two RHS files at the same paths:

- `SetAuthor` takes `(int playerID, bool isGM = false)` and forwards `isGM`.
- The wheel index is read through the 1.9 getter.

Nothing else is included. RHS stays enabled and provides all other content; the
project declares it, so RHS loads first and the overrides win.

The other two mods that broke on 1.9 have fixed themselves, and AD_FIX no longer
bundles their scripts:

- Creature Melee AI 1.8.18 updated `StopLoitering` for 1.9 (1.8.17 was the
  original crash).
- AD Linear COE2 1.0.26 replaced the removed `ShouldForbidRemoveByInstigator`
  hook with `HandleAccessValidation`.

## Install

Keep `RHS - Status Quo` enabled. Enable `AD_FIX` after it (the dependency in
`addon.gproj` normally enforces this). No other mod needs to change.

## Rebuild

```powershell
powershell -ExecutionPolicy Bypass -File mods\AD_FIX\make-ad-fix.ps1
```

The script extracts the two files from the installed RHS pak, applies the
replacements, packs to `arma-ai\build\ad-fix`, verifies the packed text and
installs it as `AD_FIX_ADF1000000000001`. It aborts if either file no longer
matches - which means RHS has been updated for 1.9 and AD_FIX can be removed.

## Test it

```powershell
.\tools\launch-with-preset.ps1 -Preset "ArmaDudes 1" -ExtraGuid ADF1000000000001
```

The pass condition is that `crash.log` has no `Can't compile "Game"` line.
