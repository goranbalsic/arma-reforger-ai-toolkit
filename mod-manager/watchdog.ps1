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
function Save-Json($obj, [string]$Path) {
  # atomic: this runs while the dashboard may be reading the same files, and a
  # kill mid-write would leave a config/queue the dashboard cannot parse
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}
function Get-Queued {
  try {
    $m = (Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods
    # the DS writes "mods": null on shutdown and @($null).Count is 1, so the
    # watchdog believed one mod was queued forever and restarted the DS in a loop
    if ($null -eq $m) { return @() }
    return @($m)
  } catch { return @() }
}
function Get-LatestLog {
  Get-ChildItem "$Profile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$mutex = [System.Threading.Mutex]::new($false, 'ReforgerDownloaderWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }

$fail = @{}
$saidEmpty = $false   # "queue empty" is logged once per transition, not every 15 s
while ($true) {
  Start-Sleep 15
  if (-not (Test-Path $Cfg)) { continue }
  if (Test-Path $PauseFlag) { continue }          # user pressed Pause
  $queued = Get-Queued
  $ds = @(Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue)

  if (-not $ds.Count) {
    if ($queued.Count -eq 0) {
      # log the transition only: this branch runs every 15 s forever once the
      # batch is done, and used to grow watchdog.log without bound
      if (-not $saidEmpty) { Write-Wd 'queue empty - downloader done'; $saidEmpty = $true }
      continue
    }
    $saidEmpty = $false

    # remember Workshop refusals from the run that just ended, drop repeat
    # offenders. Blame ONLY the mod that was being fetched when the Workshop
    # refused it: the old code struck every mod named in the last 80 lines, so one
    # bad patch of network could remove innocent mods from the queue for good.
    # "Fragmentizer: Download error" is not a refusal - the DS retries it itself.
    $lg = Get-LatestLog
    if ($lg -and $lg.LastWriteTime -gt (Get-Date).AddMinutes(-20)) {
      $tail = @(Get-Content $lg.FullName -Tail 80 -ErrorAction SilentlyContinue)
      $cur = $null
      foreach ($ln in $tail) {
        if ($ln -match 'Addon Download started ([0-9A-F]{16})') { $cur = $Matches[1]; continue }
        if ($cur -and $ln -match 'Failed to fetch addon details') {
          if ($fail.ContainsKey($cur)) { $fail[$cur]++ } else { $fail[$cur] = 1 }
          $cur = $null
        }
      }
      if ($fail.Count) {
        $drop = @($fail.Keys | Where-Object { $fail[$_] -ge 3 })
        if ($drop.Count) {
          $j = Get-Content $Cfg -Raw | ConvertFrom-Json
          $gone = @($j.game.mods | Where-Object { $drop -contains $_.modId } | ForEach-Object { $_.name })
          $j.game.mods = @($j.game.mods | Where-Object { $drop -notcontains $_.modId })
          Save-Json $j $Cfg
          $queued = @($j.game.mods)
          Write-Wd "skipped after 3 Workshop errors: $($gone -join ', ')"
          try {
            $prev = if (Test-Path $SkipFile) { @(Get-Content $SkipFile -Raw | ConvertFrom-Json) } else { @() }
            Save-Json @($prev + $gone | Select-Object -Unique) $SkipFile
          } catch { }
        }
      }
    }

    try { & "$PSScriptRoot\trim-config.ps1" | Out-Null }
    catch { Write-Wd "trim failed: $($_.Exception.Message)"; continue }   # never start an untrimmed list (1 MB trap)
    $queued = Get-Queued
    if ($queued.Count -eq 0) {
      if (-not $saidEmpty) { Write-Wd 'queue empty - downloader done'; $saidEmpty = $true }
      continue
    }
    Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$Profile`"" `
      -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    Write-Wd "restarted downloader ($($queued.Count) mods left)"
    continue
  }

  # running: kill it if it stopped writing its log while mods are still queued.
  # A single fragment takes minutes on a slow line, so allow 5 minutes of silence
  # before declaring it hung - every restart throws away the fragment in flight.
  if ($queued.Count -gt 0) {
    $lg = Get-LatestLog
    if (-not $lg -or $lg.LastWriteTime -lt (Get-Date).AddMinutes(-5)) {
      Write-Wd "downloader silent 5 min with $($queued.Count) mods queued - restarting it"
      $ds | Stop-Process -Force
      Start-Sleep 2
      # trim before restarting: a finished mod left in the list pushes the download
      # request over the DS's ~1 MB limit, and the restart would insta-crash
      try { & "$PSScriptRoot\trim-config.ps1" | Out-Null }
      catch { Write-Wd "trim failed: $($_.Exception.Message)" }
      Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$Profile`"" `
        -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    }
  }
}
