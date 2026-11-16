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
. "$PSScriptRoot\state.ps1"
$Cfg = "$Data\batch1-serverconfig.json"
$Exe = "$Root\armar-server\ArmaReforgerServer.exe"
$DsProfile = "$Root\serverprofile"
$LogFile = "$Data\watchdog.log"
$PauseFlag = "$Data\paused.flag"
$SkipFile = "$Data\skipped.json"

function Write-Wd([string]$t) { try { "[$(Get-Date -f HH:mm:ss)] $t" | Add-Content $LogFile } catch { } }
function Get-Queued {
  try {
    $m = (Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods
    # the DS writes "mods": null on shutdown and @($null).Count is 1, so the
    # watchdog believed one mod was queued forever and restarted the DS in a loop.
    if ($null -eq $m) { return ,@() }
    # the comma matters: returning a 1-element array unrolls it into a plain
    # object, and a plain object's .Count is $null in Windows PowerShell 5.1 -
    # which silently disabled the stall killer for a single-mod queue
    return ,@($m)
  } catch { return ,@() }
}
function Get-LatestLog {
  Get-ChildItem "$DsProfile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Start-EngineLocked {
  # the dashboard can start the engine at the same moment: a named mutex + a
  # re-check means never two processes on one profile
  $ctl = Lock-Engine
  if (-not $ctl) { return $false }
  try {
    $cur = Get-OwnEngine $Cfg
    if ($null -eq $cur) { return $false }   # cannot ask: do not risk a second engine
    if ($cur) { return $false }
    Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$DsProfile`"" `
      -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    return $true
  } finally { $ctl.ReleaseMutex() }
}

$mutex = [System.Threading.Mutex]::new($false, 'ReforgerDownloaderWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }

$fail = @{}
$saidEmpty = $false   # "queue empty" is logged once per transition, not every 15 s
$saidBlind = $false   # same for "cannot read the process list"
while ($true) {
  Start-Sleep 15
  if (-not (Test-Path $Cfg)) { continue }
  if (Test-Path $PauseFlag) { continue }          # user pressed Pause
  $queued = Get-Queued
  $ds = Get-OwnEngine $Cfg
  # log the transition, not every tick: a busy machine made this fire 25 times in a
  # row (25 lines that hid the rest of the log) while nothing was being done
  if ($null -eq $ds) {
    if (-not $saidBlind) {
      Write-Wd 'cannot read the process list right now - waiting for it to recover'
      $saidBlind = $true
    }
    continue
  }
  if ($saidBlind) { Write-Wd 'process list readable again'; $saidBlind = $false }

  if (-not $ds.Count) {
    if ($queued.Count -eq 0) {
      # log the transition only: this branch runs every 15 s forever once the
      # batch is done, and used to grow watchdog.log without bound. A finished
      # batch also forgets the strikes, so a mod re-queued later starts clean.
      if (-not $saidEmpty) { Write-Wd 'queue empty - downloader done'; $saidEmpty = $true; $fail = @{} }
      continue
    }
    $saidEmpty = $false

    # remember Workshop refusals from the run that just ended. Walk the WHOLE run
    # log: a refusal follows the "started" line of the mod that caused it, and a
    # run logs ~20 "started" lines, so a last-80-lines window usually held none and
    # the skip almost never fired (the 5-minute stall killer did the work instead).
    $lg = Get-LatestLog
    if ($lg -and $lg.LastWriteTime -gt (Get-Date).AddMinutes(-20)) {
      $cur = $null
      foreach ($ln in (Get-Content $lg.FullName -ErrorAction SilentlyContinue)) {
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
    if (-not (Start-EngineLocked)) { Write-Wd 'a start/stop is in progress - retrying next tick'; continue }
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
      $null = Start-EngineLocked
    }
  }
}
