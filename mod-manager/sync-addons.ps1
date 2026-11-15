# Mirrors completed mods into the client addons folder. robocopy /MIR = exact
# replica, safe to re-run. The dashboard's /status completed list is the SINGLE
# completion rule (assembled + quiet + size match) - this script never guesses.
param([switch]$Loop)

$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$src = "$Root\serverprofile\addons"
$dst = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"
$Url = 'http://localhost:8123/status'

function Sync-Completed {
  try { $s = Invoke-RestMethod $Url -TimeoutSec 10 } catch { return $false }   # dashboard down -> caller decides
  Get-ChildItem $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_([0-9A-F]{16})$' -and $s.recent.id -contains $Matches[1] } |
    ForEach-Object {
      robocopy $_.FullName "$dst\$($_.Name)" /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
      if ($LASTEXITCODE -ge 8) { Write-Host "copy failed: $($_.Name)" -ForegroundColor Red }
    }
  $true
}

if (-not $Loop) { if (Sync-Completed) { exit 0 } else { Write-Host 'dashboard not reachable' -ForegroundColor Red; exit 1 } }

# one loop instance only: named mutex kills the check-then-start race
$mutex = [System.Threading.Mutex]::new($false, 'ReforgerSyncLoop')
if (-not $mutex.WaitOne(0)) { exit 0 }

while ($true) {
  if (-not (Sync-Completed)) { exit 0 }   # dashboard gone -> loop dies with it
  Start-Sleep 60
}
