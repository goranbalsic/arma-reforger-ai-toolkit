# One-shot migration for THIS machine: move the 63 GB download data and the DS
# binary into this project folder so it is fully standalone (no env vars needed).
# Run only AFTER the batch finishes (703/703) or after pressing Pause - it
# refuses to run while the dedicated server is downloading.
$ErrorActionPreference = 'Stop'
$mm  = $PSScriptRoot
$old = "$env:USERPROFILE\Documents\ArmaReforger-DL"
$dp  = "$env:USERPROFILE\Documents\Default Project"
$repoCmd = "$mm\download-web.ps1"

if (Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue) {
  throw 'DS is still running - let the batch finish or press Pause first'
}
# stop dashboard + sync loop: they hold handles on the folders we move
Get-CimInstance Win32_Process -Filter "name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'download-web|sync-addons' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep 2

foreach ($n in 'serverprofile', 'armar-server', 'steamcmd') {
  if (Test-Path "$old\$n") {
    if (Test-Path "$mm\$n") { throw "$mm\$n already exists - resolve manually" }
    Move-Item "$old\$n" "$mm\$n"   # same volume: instant rename, no copy
    "moved $n"
  }
}
foreach ($f in 'batch1-serverconfig.json', 'batch1-sizes.json', 'batch1-servers.json') {
  if (Test-Path "$dp\$f") {
    Copy-Item "$dp\$f" "$mm\data\$f" -Force
    Remove-Item "$dp\$f" -Force
    "moved data\$f"
  }
}

# Desktop launcher: repo script, no env vars (data now lives inside the project)
@'
@echo off
title Arma Reforger Mods Download
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\Documents\Default Project\arma-reforger-ai-toolkit\mod-manager\download-web.ps1"
'@ | Set-Content "$env:USERPROFILE\Desktop\Arma Reforger Mods Download.cmd" -Encoding ASCII
'desktop .cmd rewritten'

Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $repoCmd
Start-Process 'http://localhost:8123/'
"done - everything now lives in $mm; the old Documents\ArmaReforger-DL folder is scripts-free data residue and can be deleted"
