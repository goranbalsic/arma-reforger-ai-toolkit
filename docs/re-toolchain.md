# Reverse-engineering toolchain

The goal is not "install every RE repo". It is: for any question about Arma
Reforger, have one agent-facing interface (REA) plus a decompiler that actually
works on this machine.

## Installed and wired

| Tool | Version | Role | Connected |
| --- | --- | --- | --- |
| `rea-agents` (`rea`) | 6.8.0 | Single MCP surface: 229 tools, wraps providers | MCP `rea-tools` |
| Ghidra | 12.1.4 | Native decompiler, free | `GHIDRA_INSTALL_DIR` |
| Temurin JDK | 21.0.13 | Required by Ghidra 12.x | `JAVA_HOME` |
| `ida-pro-mcp` | 1.4.0 | Upstream MCP for IDA (attached profile) | `C:\Tools\ida-mcp.json` |
| Rizin | 0.9.1 | Fast disassembly; REA supports it as a provider | `rizin` on PATH |
| ImHex | 1.38.1 | Hex/pattern editor — best tool for `.pak`/`.rdb` inspection | GUI |
| x64dbg | 2026.05.27 | Windows debugger — runtime inspection of the engine | GUI |

REA env used by the MCP server (already set in `opencode.json`):

```
GHIDRA_INSTALL_DIR=C:\Tools\ghidra_12.1.4_PUBLIC
JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-21.0.13.9-hotspot
REA_ANALYSIS_PROVIDER=ghidra
REA_GHIDRA_STARTUP_TIMEOUT_MS=1800000
```

Useful single-shot CLI variant (does not need the MCP session):

```powershell
$env:GHIDRA_INSTALL_DIR='C:\Tools\ghidra_12.1.4_PUBLIC'
$env:JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.13.9-hotspot'
$env:REA_ANALYSIS_PROVIDER='ghidra'
$env:REA_GHIDRA_DISABLED_ANALYZERS='Decompiler Parameter ID'   # the slow one
rea inspect "<exe>" --provider ghidra --format json
```

## Deliberately not installed

| Tool | Why not |
| --- | --- |
| GhidraMCP | Redundant: REA already exposes Ghidra as a provider with better contracts |
| radare2 | Rizin is the maintained fork and REA supports it |
| jadx, apktool | Android only — Arma Reforger ships no APK |
| ILSpy, dnSpy | .NET only — the engine is native C++ with Enforce scripts |
| Frida | Runtime hooking of mobile/desktop apps; not needed for data/prefab work |
| angr | Symbolic execution; the questions here are data-layout and config-merge, not path solving |
| mitmproxy | No network protocol work in scope |

IDA Pro is present on this machine but the copy is not licensed; only IDA Free or
a real licence should be used through the `ida-pro-mcp` registration.

## What to actually reverse, in order

1. **Resource identity and priority** — how addons register GUIDs, who wins on a
   duplicate, and whether a mod can replace a base-game resource at all.
   *Partial answer obtained:* last registration wins, base game registers last.
2. **Spawn path** — which function instantiates a unit from the entity catalog
   (`SCR_CatalogEntitySpawnerComponent.SpawnEntity` is one candidate), so a mod
   can substitute a prefab at spawn instead of replacing resources.
3. **Workbench registration** — what makes a project resource get a GUID
   (`.meta` + `RegisterResourceFile`), and how `-packAddon` writes the RDB.
4. **Publish backend** — what the CLI can and cannot set, and why the first
   publish needs the dialog (the `summary` field).

## Clean-room loop

```
binary -> REA evidence -> notes/spec -> rebuild -> oracle -> retry
```

For this project the "rebuild" is a mod (scripts + prefabs), and the oracle is
the game log plus in-game observation: a change is only real when
`Loaded addons` contains the mod **and** the spawned unit's prefab resolves to it.
