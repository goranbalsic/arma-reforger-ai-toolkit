# Workbench CLI reference

Binary: `Arma Reforger Tools\Workbench\ArmaReforgerWorkbenchSteamDiag.exe`.
Only the Diag executable ships with the Tools app; there is no non-diag
Workbench binary to fall back to.

Switches below were read out of the shipped executable's argument parser and the
pack recipe was run end to end. Values are case-insensitive on the command line;
`-wbSilent` and `-wbsilent` both work. Quote any path containing spaces.

## The one recipe that matters

Packing, validated on this machine (produces `addon.gproj`, `data.pak`,
`resourceDatabase.rdb`):

```powershell
$wb    = 'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger Tools\Workbench\ArmaReforgerWorkbenchSteamDiag.exe'
$game  = 'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger\addons'
$proj  = 'C:\path\to\project'          # folder containing addon.gproj
$out   = 'C:\path\to\build'

& $wb -wbModule=ResourceManager `
      -addonsDir $game `
      -gproj "$proj\addon.gproj" `
      -packAddon -packAddonDir $out `
      -wbSilent -noThrow
```

`scripts\pack-addon.ps1` wraps this and fails loudly when the output is missing.

### Why each part is required

- `-wbModule=ResourceManager` - the pack/publish handlers live in the Resource
  Manager module. Without it Workbench opens the default module, exits `0`, and
  produces nothing. This is the mistake that costs an hour.
- `-addonsDir <game>\addons` - resolves the base game addons
  (`data/ArmaReforger.gproj`, GUID `58D0FB3206B6F859`, and `core/core.gproj`,
  GUID `5614BBCCBB55ED1C`). Without it the log says
  `dependency '58D0FB3206B6F859' can't be added` /
  `Cannot initialize game project settings!` and nothing is built.
  Alternative: run Workbench with its working directory set to the game install,
  because the engine also resolves `./addons` relative to CWD.
- `-gproj` - the project to operate on. Also the only way to skip the launcher.
- `-packAddon` - the action. It is a bare flag, not an option with a value.
- `-packAddonDir` - output directory. Omit it and the engine reuses the last
  session's directory, or creates one next to the profile.

## Switches

### Project and module

| Switch | Meaning |
| --- | --- |
| `-gproj <path>` | Open a `.gproj` directly (skips launcher) |
| `-addonsDir <dirs>` | Extra addon search dirs, comma separated |
| `-addons <ids>` | Addon GUIDs / folder names to mount |
| `-wbModule=<name>` | Start a module: `ResourceManager`, `ScriptEditor`, `WorldEditor`, `AnimEditor`, `ParticleEditor`, `AudioEditor`, `BehaviorEditor`, `LocalizationEditor` |
| `-plugin <name> [args]` | Run a Resource Manager plugin (`ResaveTool`, `ResaveMetaTool`, `ResourceProcessorPlugin`) |
| `-run`, `-wbrun` | Switch to game mode / run after init |
| `-link <uri>` | Handle an `enfusion://` link |
| `-exitAfterInit` | Quit once initialisation finished |

Plugin example (documented by BI):

```powershell
& $wb -wbModule=ResourceManager -plugin=ResaveTool -addonPath "C:\mod" -extension ".et"
```

### Build, pack, publish

| Switch | Meaning |
| --- | --- |
| `-packAddon` | Pack the project into a distributable addon |
| `-packAddonDir <dir>` | Output directory for the pack |
| `-packAddonCacheDir <dir>` | Cache directory used while packing |
| `-publishAddon` | Publish an already packed addon (updates only) |
| `-publishAddonDir <dir>` | Pre-packed directory to publish |
| `-publishAddonVersion <v>` | Version string |
| `-publishAddonChangeNote <text>` | Inline changelog |
| `-publishAddonChangeNoteFile <path>` | Changelog from file |
| `-publishAddonPreviewImage <path>` | Preview image |
| `-publishAddonScreenshots <dir>` | Screenshot directory |
| `-publishAddonCacheDir <dir>` | Publish cache |
| `-builddata` | Rebuild platform data |
| `-loadBuiltData` | Load a previous build to validate it |
| `-loadAddons`, `-loadNavmesh` | Load addon data / navmesh |
| `-forceSaveAll`, `-noOpenLastResource` | Editor startup behaviour |

### Validation

`-validate` only reports when it is not competing with a pack/exit action
(BI ticket advice). Correct invocation:

```powershell
& $wb -wbSilent -wbModule=ScriptEditor -validate -gproj "$proj\addon.gproj" -addonsDir $game
```

### Runtime and diagnostics

| Switch | Meaning |
| --- | --- |
| `-wbSilent` | No dialogs |
| `-noThrow` | No error popups |
| `-profile <path>` | Profile directory |
| `-saveDir <path>` | Save directory |
| `-logsDir <path>`, `-keepNumOfLogs <n>` | Log location / retention |
| `-logStats [ms]` | Periodic stats |
| `-logLevel <level>`, `-logAppend`, `-logFS` | Log verbosity |
| `-scriptAuthorizeAll` | Skip script security prompts (RunCmd/FileIO) |
| `-maxFPS <n>`, `-window`, `-posX/-posY` | Window/behaviour |
| `-freezeCheck <s>`, `-freezeCheckMode <mode>`, `-minidump <mode>` | Crash/freeze handling |
| `-disableCrashReporter`, `-silentCrashReport` | Crash reporter |
| `-scrDefine <K=V>` | Extra script preprocessor define |

The NET API used by the MCP bridge runs on `127.0.0.1:5775` and is available in
a normally launched Workbench once the handler scripts are compiled into the
open project. No switch is needed for it.

## Exit codes and logs

Workbench returns `0` even when compilation or packing fails. Never trust the
exit code alone. Check, in this order:

1. the output directory contains `data.pak`, `addon.gproj`, `resourceDatabase.rdb`;
2. `data.pak` is not suspiciously small and lists the expected files
   (`python scripts/refpak.py list <pak>`);
3. the newest log has no `(E)` lines that mention script compilation:

```powershell
$log = Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforgerWorkbench\logs" -Directory |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content (Join-Path $log.FullName 'console.log') | Select-String '\(E\)|Can''t compile|error'
```

`Can't compile "Game" script module!` in the log means the pack contains stale or
missing scripts. Fix the script, then repack.

## Reached from the binary but not documented here

`-imageSetBuild`, `-imageSetTexture`, `-metaFiles`, `-filterPath`, `-filterTags`,
`-includeTypes`, `-excludeTypes`, `-resavedata`, `-clearsettings`,
`-forcesettings`, `-forceupdate`, `-preloadVehicles`, `-generateElectricity`,
`-logNavmeshGen`, `-lspPort`. They are accepted, but their exact semantics are
not verified - treat them as advanced and test one at a time.
