# Mirrors each completed mod folder from the DS profile into the client addons
# folder. robocopy /MIR = exact replica (removes stale extra files), so repeated
# runs are safe and self-healing.
param([switch]$Loop)

$src = "$PSScriptRoot\serverprofile\addons"
$dst = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"
$Url = 'http://localhost:8123/status'

function Sync-Stable {
  Get-ChildItem $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_[0-9A-F]{16}$' -and $_.Name -notmatch '^RHS-ContentPack0[12]_' -and
                   $_.LastWriteTime -lt (Get-Date).AddMinutes(-2) } |
    ForEach-Object {
      robocopy $_.FullName "$dst\$($_.Name)" /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
      if ($LASTEXITCODE -ge 8) { Write-Host "copy failed: $($_.Name)" -ForegroundColor Red }
    }
}

if (-not $Loop) { Sync-Stable; exit 0 }

# one loop instance only
if (Get-CimInstance Win32_Process -Filter "name='powershell.exe'" |
      Where-Object { $_.CommandLine -match 'sync-addons.ps1 -Loop' -and $_.ProcessId -ne $PID }) { exit 0 }

while ($true) {
  Sync-Stable
  try { Invoke-WebRequest $Url -TimeoutSec 5 -UseBasicParsing | Out-Null }   # dashboard alive?
  catch { exit 0 }                                                          # no -> loop dies with it
  Start-Sleep 60
}
