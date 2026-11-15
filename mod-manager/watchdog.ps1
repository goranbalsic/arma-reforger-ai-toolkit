# Keeps the dedicated server (used as a downloader) alive.
#
# The DS downloads the queued mods, then exits: it cannot create a game world
# while mods are still missing. It can also hang for minutes when the Workshop
# API/CDN fails. This process restarts it, and skips a mod the Workshop keeps
# refusing so one bad mod cannot stall the whole queue.
#
# Started by download-web.ps1. Single instance (named mutex).
$ErrorActionPreference = 'Continue'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$Cfg = "$Data\batch1-serverconfig.json"
$Exe = "$Root\armar-server\ArmaReforgerServer.exe"
$Profile = "$Root\serverprofile"
$LogFile = "$Data\watchdog.log"
$PauseFlag = "$Data\paused.flag"
$SkipFile = "$Data\skipped.json"

function Write-Wd([string]$t) { try { "[$(Get-Date -f HH:mm:ss)] $t" | Add-Content $LogFile } catch { } }
function Get-Queued {
  try { return @((Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods) } catch { return @() }
}
function Get-LatestLog {
  Get-ChildItem "$Profile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$mutex = [System.Threading.Mutex]::new($false, 'ReforgerDownloaderWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }

$fail = @{}
while ($true) {
  Start-Sleep 15
  if (-not (Test-Path $Cfg)) { continue }
  if (Test-Path $PauseFlag) { continue }          # user pressed Pause
  $queued = Get-Queued
  $ds = @(Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue)

  if (-not $ds.Count) {
    if ($queued.Count -eq 0) { continue }         # nothing left to download

    # remember Workshop failures from the run that just ended, drop repeat offenders
    $lg = Get-LatestLog
    if ($lg -and $lg.LastWriteTime -gt (Get-Date).AddMinutes(-20)) {
      $tail = @(Get-Content $lg.FullName -Tail 80 -ErrorAction SilentlyContinue)
      if (@($tail | Select-String 'Failed to fetch addon details|Fragmentizer: Download error').Count) {
        foreach ($id in @($tail | Select-String 'Addon Download started ([0-9A-F]{16})' |
                          ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)) {
          if ($fail.ContainsKey($id)) { $fail[$id]++ } else { $fail[$id] = 1 }
        }
        $drop = @($fail.Keys | Where-Object { $fail[$_] -ge 3 })
        if ($drop.Count) {
          $j = Get-Content $Cfg -Raw | ConvertFrom-Json
          $gone = @($j.game.mods | Where-Object { $drop -contains $_.modId } | ForEach-Object { $_.name })
          $j.game.mods = @($j.game.mods | Where-Object { $drop -notcontains $_.modId })
          $j | ConvertTo-Json -Depth 5 | Set-Content $Cfg -Encoding UTF8
          $queued = @($j.game.mods)
          Write-Wd "skipped after 3 Workshop errors: $($gone -join ', ')"
          try {
            $prev = if (Test-Path $SkipFile) { @(Get-Content $SkipFile -Raw | ConvertFrom-Json) } else { @() }
            @($prev + $gone | Select-Object -Unique) | ConvertTo-Json | Set-Content $SkipFile -Encoding UTF8
          } catch { }
        }
      }
    }

    & "$PSScriptRoot\trim-config.ps1" | Out-Null
    $queued = Get-Queued
    if ($queued.Count -eq 0) { Write-Wd 'queue empty - downloader done'; continue }
    Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$Profile`"" `
      -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    Write-Wd "restarted downloader ($($queued.Count) mods left)"
    continue
  }

  # running: kill it if it stopped writing its log while mods are still queued
  if ($queued.Count -gt 0) {
    $lg = Get-LatestLog
    if (-not $lg -or $lg.LastWriteTime -lt (Get-Date).AddMinutes(-3)) {
      Write-Wd "downloader stalled 3 min with $($queued.Count) mods queued - restarting it"
      $ds | Stop-Process -Force
      Start-Sleep 2
      Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$Profile`"" `
        -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    }
  }
}
