# Pak format, extraction and building

## Layout (verified against Workbench `core/data.pak` and workshop mods)

```
FORM  u32be size  "PAC1"
  HEAD  u32be size  (28 bytes of index metadata, unused)
  DATA  u32be size  (all file payloads, concatenated; each payload is
                     zlib when the entry says compressed, raw otherwise)
  FILE  u32be size  (recursive entry tree)
```

FILE tree node:

```
u8   kind          0 = directory, 1 = file
u8   nameLen
     name
dir:  u32le childCount, then childCount nodes
file: u32le absoluteOffsetInPak
      u32le storedLen
      u32le fileLen
      u32le unk
      u16   unk
      u8    compressed      (0 = stored verbatim)
      u8    level
      u32le timestamp
```

Two traps:

- **`offset` is absolute in the `.pak`, not relative to the DATA payload.** A
  reader that adds the DATA start produces 8+HEAD bytes of garbage that still
  looks like text. This bug is common in third-party readers; check it before
  trusting any tool that reads `.pak` files.
- Compressed payloads start with a zlib header (`78 9C`). Read with
  `inflate`, not `inflateRaw`; fall back to raw deflate for older archives.

## `scripts/refpak.py`

Read-only and dependency free (Python 3 standard library).

```powershell
python scripts\refpak.py list     <pak>                     # path + uncompressed size
python scripts\refpak.py manifest <pak> [out.jsonl]         # every file, JSON lines
python scripts\refpak.py cat      <pak> <virtual/path>      # dump one file
python scripts\refpak.py extract  <pak> <outdir> [exts]     # write files loose
```

`extract` with an extension list writes only those resources, which is how the
index keeps 34,460 files of inventory while putting just the 21,277 text
resources on disk:

```
python scripts\refpak.py extract "<addons>\<Name>_<GUID>\data.pak" work\<Name> .c,.conf,.et,.layout,.agr,.ast,.gproj,.json,.txt,.emat,.gamemat,.layer,.ent,.st,.styles
```

There is intentionally no `pack` command: building an addon is Workbench's job
(it compiles Enforce Script and fills `resourceDatabase.rdb`). A hand-rolled
packer would produce a pak that loads and then fails at runtime.

## Vendored vs extracted

A workshop addon folder contains `data.pak`, `resourceDatabase.rdb`,
`addon.gproj`, `meta`, thumbnails. `addon.gproj` and `meta` are loose; everything
the mod actually *is* lives in `data.pak`.

Extraction therefore copies `addon.gproj` and `meta` out of the addon folder and
everything else out of the pak, which is exactly what Workbench needs to treat
the result as a project.

## "Patch without repacking" - what is real

| Claim | Reality |
| --- | --- |
| Edit a script and see it in Workbench without repacking | **True.** Workbench loads the project folder and recompiles on `wb_reload` / Reload Scripts. |
| Run the game on a loose addon folder | **True** via `-addonsDir` + `-addons` (documented mount path). The folder must contain `addon.gproj`. |
| Patch the shipped `data.pak` in place | **False.** The pak is compressed and indexed; changing a byte breaks it. Repack. |
| Decompile a pak back to the author's source tree | **False.** Extracted resources are the *build output*, not the original project, and packed data is indexed/compressed for distribution. |

So the honest workflow is: extract once  edit the extracted copy  test live 
pack when you need to distribute or upload.

## Validating a build

```powershell
# 1. three files present
Get-ChildItem $out | Select-Object Name,Length

# 2. pak parses and contains what you expect
python scripts\refpak.py list "$out\data.pak"

# 3. no compile errors in the freshest log
$log = Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforgerWorkbench\logs" -Directory |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
Select-String -Path (Join-Path $log.FullName 'console.log') -Pattern "Can't compile|COMPILE ERROR|\(E\)"
```

Workbench exits `0` regardless of success, so steps 1-3 are the real gate.

## Dependencies

An addon's `addon.gproj` lists GUIDs. Two of them are not workshop mods:

- `58D0FB3206B6F859` - Arma Reforger base game (`addons/data/ArmaReforger.gproj`)
- `5614BBCCBB55ED1C` - Enfusion core (`addons/core/core.gproj`)

Every other GUID must be mounted at build time or packing fails before it starts.
Point `-addonsDir` at the game `addons` folder and at the folder holding your
dependency projects.
