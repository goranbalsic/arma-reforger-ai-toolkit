param([switch]$Check)
# Arma Reforger mod manager - local web dashboard: batch downloader, live server
# browser, per-server queue-first, launcher presets, client addon sync.
# double-click the .cmd: serves http://localhost:8123 and opens your browser.
#
# Paths: everything is relative to this folder, so the project folder is portable.
#   RFMM_HOME  where the big data lives (serverprofile\, airmar-server\, steamcmd\)
#   RFMM_DATA  where the json state lives (data\)   [both optional; default = here]
# On this machine they are set until migrate-here.ps1 moves the folders in here.
$ErrorActionPreference = 'Stop'
$Root    = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data    = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$Exe     = "$Root\armar-server\ArmaReforgerServer.exe"
$Cfg     = "$Data\batch1-serverconfig.json"
$Sizes   = "$Data\batch1-sizes.json"
$ServersPath = "$Data\batch1-servers.json"
$DsProfile = "$Root\serverprofile"
$Addons  = "$DsProfile\addons"
$Url     = 'http://localhost:8123/'

# first run on any machine: create empty state files instead of failing
if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Force $Data | Out-Null }
if (-not (Test-Path $Sizes))       { '{"totalBytes":0,"mods":{}}' | Set-Content $Sizes -Encoding UTF8 }
if (-not (Test-Path $Cfg))         { '{"game":{"mods":[]}}'     | Set-Content $Cfg -Encoding UTF8 }
if (-not (Test-Path $ServersPath)) { '{"servers":[]}'           | Set-Content $ServersPath -Encoding UTF8 }

function Save-Json($obj, [string]$Path, [int]$Depth = 5) {
  # atomic: Set-Content truncates in place, so a kill mid-write (closing the
  # console window kills this process) left broken JSON and the next start died
  # on it. Replace is atomic on the same volume; the DS holds no handle on these.
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth $Depth | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}
function Read-Json([string]$Path, $Default) {
  # an unreadable state file must never brick the start: a parse failure means
  # the file is gone, so quarantine it (never delete) and carry on with defaults.
  # An IO error is not a parse error - retry later and leave the file alone.
  if (-not (Test-Path $Path)) { return $Default }
  try { $raw = Get-Content $Path -Raw -ErrorAction Stop } catch { return $Default }
  try { return ($raw | ConvertFrom-Json) }
  catch {
    $bad = "$Path.corrupt-$(Get-Date -f yyyyMMdd-HHmmss)"
    Move-Item $Path $bad -Force -ErrorAction SilentlyContinue
    Write-Host "WARNING: $([IO.Path]::GetFileName($Path)) was unreadable - moved to $(Split-Path $bad -Leaf), using defaults" -ForegroundColor Red
    return $Default
  }
}
function Get-Cfg {
  $j = Read-Json $Cfg ('{"game":{"mods":[]}}' | ConvertFrom-Json)
  if ($null -eq $j -or $null -eq $j.game) { $j = '{"game":{"mods":[]}}' | ConvertFrom-Json }
  # the DS writes "mods": null back into the config on shutdown, and @($null).Count
  # is 1 - so every caller believed one mod was still queued when the queue was
  # empty (Start skipped the partial resume, trim started an empty DS)
  if ($null -eq $j.game.mods) { $j.game.mods = @() }
  $j
}

$j = Read-Json $Sizes ('{"totalBytes":0,"mods":{}}' | ConvertFrom-Json)
$sizeMap = @{}
foreach ($p in $j.mods.PSObject.Properties) { $sizeMap[$p.Name] = $p.Value }
$TotalBytes = $j.totalBytes

$serverList = @((Read-Json $ServersPath ('{"servers":[]}' | ConvertFrom-Json)).servers)
foreach ($sv in $serverList) { foreach ($m in $sv.mods) {
  $sm = $sizeMap[$m.id]
  $m | Add-Member -NotePropertyName e -NotePropertyValue ([double]($(if ($sm) { $sm.bytes } else { 0 }))) -Force
} }

$verify = $null   # last verify result shown on the page
$script:maxDone = [double]0; $script:maxDoneTotal = [double]0   # high-water progress: the DS deletes temp files, so raw bytes dip
$script:pausedByUser = $false                                   # explicit Pause flag for watchdog.ps1
$script:skipped = @(); $script:skippedAt = (Get-Date).AddMinutes(-10)
$script:rateSamples = @()                                      # rolling byte-rate for a live speed
$script:activeMax = @{}                                        # per-mod high-water progress
$script:exactCache = @{}                                       # path -> exact package check
$script:logCache = $null; $script:logCacheAt = (Get-Date).AddMinutes(-1)
$script:speedCache = @{ b = 0; age = 999 }; $script:speedCacheAt = (Get-Date).AddMinutes(-5)

$ApiBase = 'https://api.reforgermods.net/v2'
$ApiH = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$script:bCache = @{}; $script:bCacheAt = @{}   # /browse search cache
$script:dCache = @{}; $script:dCacheAt = @{}   # /browse-server detail cache

function Get-SkippedNames {
  # written by watchdog.ps1 when the Workshop refuses a mod three times in a row
  if (((Get-Date) - $script:skippedAt).TotalSeconds -lt 10) { return $script:skipped }
  $p = Join-Path $Data 'skipped.json'
  $script:skipped = if (Test-Path $p) { @(Get-Content $p -Raw | ConvertFrom-Json) } else { @() }
  $script:skippedAt = Get-Date
  $script:skipped
}

function Get-DS { Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue }

function Get-Log {
  # newest console.log; cached 3 s because the DS is writing to disk while we scan
  if ($script:logCache -and ((Get-Date) - $script:logCacheAt).TotalSeconds -lt 3) { return $script:logCache }
  $script:logCache = Get-ChildItem "$DsProfile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $script:logCacheAt = Get-Date
  $script:logCache
}

$script:dirCache = $null; $script:dirCacheAt = (Get-Date).AddMinutes(-10)
$script:clCache = @(); $script:clCacheAt = (Get-Date).AddMinutes(-10)

function Get-ClientIds {
  # exact rule (the addon's own meta file list), same as Get-HaveIds and verify.
  # The old ±2 MB folder-size tolerance reported mods as installed when only a
  # fifth of their paks were on disk (WCS_LoadoutEditor: 202 KB there, 921 KB
  # expected), so the dashboard said 980/980 over a broken client copy.
  # Cost is paid once: Test-AddonComplete caches per folder + mtime.
  if (((Get-Date) - $script:clCacheAt).TotalSeconds -lt 10) { return $script:clCache }
  $ids = [Collections.Generic.List[string]]::new()
  $root = [IO.DirectoryInfo]::new("$env:USERPROFILE\Documents\My Games\ArmaReforger\addons")
  if ($root.Exists) {
    foreach ($d in $root.EnumerateDirectories()) {
      $m = [regex]::Match($d.Name, '_([0-9A-F]{16})$')
      if (-not $m.Success) { continue }
      if (Test-AddonComplete $d.FullName $d.LastWriteTime) { $ids.Add($m.Groups[1].Value) }
    }
  }
  $script:clCache = $ids.ToArray(); $script:clCacheAt = Get-Date
  $script:clCache
}

function Test-AddonComplete([string]$Path, $Mtime) {
  # Exact check against the addon's own meta: versions[0].package.files lists
  # every file with its size, and the game itself uses it. Folder totals are a
  # bad proxy (a 2 MB tolerance let partial small mods pass as installed).
  $c = $script:exactCache[$Path]
  if ($c -and $c.mtime -eq $Mtime) { return $c.ok }
  $ok = $false
  $metaPath = Join-Path $Path 'meta'
  if (Test-Path $metaPath) {
    try {
      $j = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json
      $files = @(@($j.meta.versions)[0].package.files)
      if ($files.Count -gt 0) {
        $ok = $true
        foreach ($f in $files) {
          if (-not $f.name) { continue }
          $p = Join-Path $Path $f.name
          if (-not (Test-Path $p)) { $ok = $false; break }
          if ((Get-Item $p).Length -ne [long]$f.size) { $ok = $false; break }
        }
      }
    } catch { $ok = $false }
  }
  $script:exactCache[$Path] = @{ mtime = $Mtime; ok = $ok }
  $ok
}

function Get-DirMap {
  # one .NET enumeration pass, grouped by folder: 111 ms for 6k files where
  # Get-ChildItem -Recurse took 236 ms. mtime = the folder's newest file time:
  # the DS appends to preallocated chunks without touching directory times.
  # 3 s, not 0.5: a cold /status took longer than its own cache TTL, so with the
  # page polling every ~0.4 s the cache never hit and every poll rescanned the disk
  if (((Get-Date) - $script:dirCacheAt).TotalSeconds -lt 3) { return $script:dirCache }
  $map = @{}
  $root = [IO.DirectoryInfo]::new($Addons)
  if ($root.Exists) {
    $baseLen = $root.FullName.TrimEnd('\').Length + 1
    try {
      foreach ($f in $root.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
        # first path segment = the mod folder: the DS downloads into <mod>\temp\,
        # so the immediate parent name is not the mod (it would hide all progress)
        $rel = $f.FullName.Substring($baseLen); $cut = $rel.IndexOf('\')
        if ($cut -lt 0) { continue }   # file directly in addons\, not a mod
        $dir = $rel.Substring(0, $cut)
        $m = [regex]::Match($dir, '_([0-9A-F]{16})$')
        if (-not $m.Success) { continue }
        if ($dir -match '^RHS-ContentPack0[12]_') { continue }   # old pre-batch installs, not batch mods
        $g = $m.Groups[1].Value
        $e = $map[$g]
        if (-not $e) {
          $e = $map[$g] = @{ name = $dir -replace '_[0-9A-F]{16}$', ''; bytes = [double]0
                             assembled = 0; mtime = $f.LastWriteTime
                             path = (Join-Path $Addons $dir) }
        }
        $e.bytes += $f.Length
        if ($f.LastWriteTime -gt $e.mtime) { $e.mtime = $f.LastWriteTime }
        if ($f.Name -in 'addon.gproj','meta','resourceDatabase.rdb') { $e.assembled++ }
      }
    } catch { }   # an unreadable folder must not take the dashboard down
  }
  foreach ($e in $map.Values) { $e.assembled = ($e.assembled -eq 3) }
  $script:dirCache = $map; $script:dirCacheAt = Get-Date
  $map
}

function Get-GlobalSpeed {
  # the DS prints its own "Download speed" once per mod (measured 30 s+ apart)
  # and preallocated chunk files make a disk-byte delta useless (0 B growth while
  # downloading) - so return the number WITH its age and let the page say how old
  # it is. Cached 3 s: this runs on every /status poll (~0.4 s apart) and reading
  # 200 log lines each time cost ~80 ms of the single listener thread.
  if (((Get-Date) - $script:speedCacheAt).TotalSeconds -lt 3) { return $script:speedCache }
  $res = @{ b = 0; age = 999 }
  $lg = Get-Log
  if ($lg -and $lg.LastWriteTime -ge (Get-Date).AddMinutes(-2)) {
    $line = Get-Content $lg.FullName -Tail 200 | Select-String 'Download speed ([0-9.]+) KB/s' | Select-Object -Last 1
    if ($line) {
      $b = [Math]::Round([double]$line.Matches[0].Groups[1].Value * 1024)
      $age = 999
      try {
        $ts = [datetime]::ParseExact($line.Line.Substring(0, 8), 'HH:mm:ss', $null)
        if ($ts -gt (Get-Date).AddMinutes(1)) { $ts = $ts.AddDays(-1) }   # log line from before midnight
        $age = [Math]::Round(((Get-Date) - $ts).TotalSeconds)
      } catch { }
      $res = @{ b = $b; age = $age }
    }
  }
  $script:speedCache = $res; $script:speedCacheAt = Get-Date
  $res
}

function Get-Status {
  $dirs = Get-DirMap
  $runningNow = [bool](Get-DS)
  $sp = Get-GlobalSpeed
  # live rate from the bytes actually landing on disk: the DS's own log line
  # appears once per mod (up to 30 s old). The DS writes in ~3 MB fragments, so a
  # short window is mostly empty - average over 60 s to show real throughput.
  $diskTotal = [double]0
  foreach ($e in $dirs.Values) { $diskTotal += [double]$e.bytes }
  $nowRate = Get-Date
  $script:rateSamples = @(@($script:rateSamples) + @(, @{ t = $nowRate; b = $diskTotal }) |
    Where-Object { ($nowRate - $_.t).TotalSeconds -le 60 })
  $rate = 0
  if ($script:rateSamples.Count -ge 2) {
    $first = $script:rateSamples[0]; $last = $script:rateSamples[-1]
    $dt = ($last.t - $first.t).TotalSeconds
    if ($dt -ge 5) { $rate = [Math]::Round([Math]::Max(0, $last.b - $first.b) / $dt) }
  }
  if ($rate -gt 0) { $sp = @{ b = $rate; age = 0 } }
  elseif ($sp.age -gt 20) { $sp = @{ b = 0; age = 999 } }   # no movement and an old log line = idle
  $clIds = Get-ClientIds
  $clSet = @{}
  foreach ($i in $clIds) { $clSet[$i] = $true }
  # progress = per mod min(bytes on disk, Workshop size) + mods installed only in
  # the client. Without the cap, temp chunk copies make doneB exceed the total
  # (measured 63.56 GB of 63.27 GB with 53 mods still missing => a full bar).
  $doneBytes = [double]0
  foreach ($id in $sizeMap.Keys) {
    $exp = [double]$sizeMap[$id].bytes
    $d = $dirs[$id]
    if ($d -and $d.bytes -gt 0) {
      $doneBytes += if ($exp -gt 0) { [Math]::Min([double]$d.bytes, $exp) } else { [double]$d.bytes }
    } elseif ($clSet.ContainsKey($id)) { $doneBytes += $exp }
  }
  # never let the bar walk backwards: the DS removes <mod>\temp\ before assembling,
  # which briefly lowers the byte count (that was the "goes up and down" effect)
  if ($script:maxDoneTotal -ne $TotalBytes) { $script:maxDoneTotal = [double]$TotalBytes; $script:maxDone = [double]0 }
  if ($doneBytes -gt $script:maxDone) { $script:maxDone = $doneBytes }
  $doneBytes = [Math]::Min($script:maxDone, [double]$TotalBytes)

  # complete = folder stable (no writes 2 min) AND size matches the Workshop size.
  # The 3 marker files are only used when the size is unknown: many Workshop mods
  # ship without addon.gproj (8-file packs), and requiring it left them unfinished
  # forever - never synced, so the launcher showed them as missing.
  $now = Get-Date
  $completed = @{}
  foreach ($e in $dirs.GetEnumerator()) {
    $d = $e.Value
    if ($d.mtime -gt $now.AddMinutes(-2)) { continue }   # still being written
    # the addon's own meta file list decides - the one rule (README), same as
    # Get-HaveIds/verify/trim. The Workshop size in $sizeMap goes stale when a mod
    # updates; SagesFramework sat at 203 MB there while 268 MB was on disk, so a
    # finished mod stayed "missing" forever: it held the queue open, the DS saw it
    # installed and served a world, and the watchdog restarted it every 5 min.
    if (-not (Test-AddonComplete $d.path $d.mtime)) { continue }
    $completed[$e.Key] = $true
  }
  $doneCount = @($sizeMap.Keys | Where-Object { $completed.ContainsKey($_) -or $clSet.ContainsKey($_) }).Count

  # active = every folder currently being written (no cap: the page shows all).
  # Only when the downloader is actually running: a stopped process leaves
  # partial folders behind and they used to appear as "downloading".
  $logProgress = @{}
  $lgNow = Get-Log
  if ($lgNow) {
    foreach ($ln in @(Get-Content $lgNow.FullName -Tail 40 -ErrorAction SilentlyContinue)) {
      $pm = [regex]::Match($ln, '([^:]+):\s*\[[^\]]*\]\s*\d+%\s*(\d+)/(\d+) MB')
      if ($pm.Success) { $logProgress[$pm.Groups[1].Value.Trim()] = [double]$pm.Groups[2].Value * 1MB }
    }
  }
  $active = @($dirs.GetEnumerator() |
    Where-Object { $runningNow -and -not $completed.ContainsKey($_.Key) -and $_.Value.bytes -gt 0 -and $_.Value.mtime -gt $now.AddMinutes(-5) } |
    Sort-Object { $_.Value.mtime } -Descending) | ForEach-Object {
    $sm = $sizeMap[$_.Key]; $exp = if ($sm) { [double]$sm.bytes } else { 0 }
    $b = [double]$_.Value.bytes
    if ($logProgress.ContainsKey($_.Value.name) -and $logProgress[$_.Value.name] -gt $b) { $b = $logProgress[$_.Value.name] }
    if ($script:activeMax.ContainsKey($_.Key) -and $script:activeMax[$_.Key] -gt $b) { $b = $script:activeMax[$_.Key] }
    $script:activeMax[$_.Key] = $b
    @{ id = $_.Key; name = $_.Value.name; b = $b; expB = $exp
       pct = if ($exp) { [Math]::Min(100, [Math]::Round(100 * $b / $exp, 1)) } else { 0 } }
  }
  # forget high-water marks of mods that are no longer downloading
  foreach ($k in @($script:activeMax.Keys)) {
    if (-not ($active | Where-Object { $_.id -eq $k })) { $script:activeMax.Remove($k) }
  }

  # all completed mods, newest first (full list - the page shows every one).
  # ids go with them: sync-addons mirrors exactly this set (single completion rule)
  $recent = @($dirs.GetEnumerator() | Where-Object { $completed.ContainsKey($_.Key) } |
    Sort-Object { $_.Value.mtime } -Descending) | ForEach-Object {
    @{ id = $_.Key; name = $_.Value.name; b = [double]$_.Value.bytes }
  }

  $queueList = @()
  try { $queueList = @((Get-Cfg).game.mods |
        ForEach-Object { @{ id = $_.modId; name = $_.name } }) } catch { }

  @{ running = $runningNow; speedB = $sp.b; speedAge = $sp.age
     doneB = [double]$doneBytes; totalB = [double]$TotalBytes
     pct = if ($TotalBytes -gt 0) { [Math]::Min(100, [int](100 * $doneBytes / $TotalBytes)) } else { 0 }
     pctF = if ($TotalBytes -gt 0) { [Math]::Round([Math]::Min(100, 100 * $doneBytes / $TotalBytes), 2) } else { 0 }
     doneCount = $doneCount; totalMods = $sizeMap.Count
     active = @($active); recent = @($recent); cl = $clIds; failed = (Get-SkippedNames)
     queue = @($queueList); tok = $token; verify = $verify }
}

if ($Check) {
  try { Get-Status | ConvertTo-Json -Depth 5 | Out-String -Width 300 }
  catch { "GET-STATUS FAILED: $($_.Exception.Message)"; "at: $($_.InvocationInfo.PositionMessage)" }
  exit 0
}

function Start-DS {
  $script:pausedByUser = $false
  Remove-Item (Join-Path $Data 'paused.flag') -Force -ErrorAction SilentlyContinue
  if (Get-DS) { return 'already running' }
  # resume interrupted work: a partial download is not in the queue after Clear
  # queue, but Start / Resume should continue it instead of saying "empty"
  $j0 = Get-Cfg
  if (@($j0.game.mods).Count -eq 0) {
    $partial = @(Get-PartialMods)
    if ($partial.Count) {
      $j0.game.mods = $partial
      Save-Json $j0 $Cfg
      Write-Host "resuming $($partial.Count) unfinished download(s)" -ForegroundColor Cyan
    }
  }
  # the 1 MB download-list trap: trimming is lossless (DS skips done mods anyway),
  # skipping it makes the DS insta-crash ~30 s after a false "started"
  & "$PSScriptRoot\trim-config.ps1" | Out-Null
  $dsArgs = "-config `"$Cfg`" -profile `"$DsProfile`""
  foreach ($try in 1, 2) {
    Start-Process -FilePath $Exe -ArgumentList $dsArgs `
      -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    Start-Sleep 25   # the DS either settles into downloading or dies within ~20 s
    if (Get-DS) { return 'started' }
  }
  $lg = Get-Log
  $why = if ($lg) { @(Get-Content $lg.FullName -Tail 20 -ErrorAction SilentlyContinue |
    Select-String 'error|ERROR' | Select-Object -Last 2 | ForEach-Object { $_.Line.Trim() }) -join ' | ' }
  "FAILED to start$(if ($why) { " - last log: $why" } else { ' - no log written, check serverprofile\logs' })"
}

function Stop-DS {
  $script:pausedByUser = $true   # the watchdog must not undo an explicit pause
  New-Item -ItemType File -Force (Join-Path $Data 'paused.flag') | Out-Null
  $p = Get-DS
  if (-not $p) { return 'not running' }
  $p | Stop-Process -Force
  # wait for the process to actually die: a 1 s sleep can be too short, and
  # Start-DS would then see the dying process and report "already running"
  foreach ($i in 1..20) { if (-not (Get-DS)) { break }; Start-Sleep -Milliseconds 500 }
  'paused - progress kept'
}

function Invoke-Verify {
  # shortcut: verifies only the batch mods against Workshop sizes; dependency
  # mods the DS auto-pulls are outside sizeMap and skipped - upgrade by adding
  # their ids to the sizes file if deps ever need checking
  $dirs = Get-DirMap
  $clSet = @{}
  foreach ($i in (Get-ClientIds)) { $clSet[$i] = $true }
  $queued = @{}
  try { foreach ($m in (Get-Cfg).game.mods) { $queued[$m.modId] = $true } } catch { }
  $ok = 0; $partial = 0; $pending = 0; $suspects = @()
  foreach ($id in $sizeMap.Keys) {
    $sm = $sizeMap[$id]; $exp = [double]$sm.bytes
    $d = $dirs[$id]
    $dsOk = $d -and (Test-AddonComplete $d.path $d.mtime)
    if ($dsOk -or $clSet.ContainsKey($id)) { $ok++; continue }   # installed somewhere is installed
    if (-not $d) { $pending++; continue }
    $partial++
    # a mod that is still queued is downloading, not a re-download candidate
    if ($exp -and -not $queued.ContainsKey($id)) { $suspects += @{ name = $d.name; expB = [double]$exp; actB = [double]$d.bytes } }
  }
  $script:verify = @{ at = (Get-Date -f 'HH:mm:ss'); ok = $ok; partial = $partial
                      pending = $pending; suspects = $suspects }
  "verify: $ok ok, $partial partial, $pending pending, $($suspects.Count) suspects"
}

function Get-HaveIds {
  # on disk = COMPLETED in the DS profile (same rule as Get-Status: assembled AND
  # size matches - the DS writes the 3 marker files before the data paks, so a
  # killed download would otherwise be treated as done and never re-fetched),
  # or present in the client addons folder
  $have = @{}
  foreach ($e in (Get-DirMap).GetEnumerator()) {
    if (Test-AddonComplete $e.Value.path $e.Value.mtime) { $have[$e.Key] = $true }
  }
  # client copies: same exact check (the launcher reads that folder)
  $croot = [IO.DirectoryInfo]::new("$env:USERPROFILE\Documents\My Games\ArmaReforger\addons")
  if ($croot.Exists) {
    foreach ($d in $croot.EnumerateDirectories()) {
      if ($d.Name -notmatch '_([0-9A-F]{16})$') { continue }
      if (Test-AddonComplete $d.FullName $d.LastWriteTime) { $have[$Matches[1]] = $true }
    }
  }
  $have
}

function Invoke-QueueServer([string]$Id) {
  # this server's missing mods download first, then the rest of the batch as a
  # full deterministic rebuild (every batch mod not on disk) - never a stale
  # leftover config, so the order after the server's mods is stable
  $srv = @($serverList | Where-Object { $_.id -eq $Id })[0]
  if (-not $srv) { throw 'unknown server id' }
  $name = if ($srv.PSObject.Properties['key'] -and $srv.key) { [string]$srv.key } else { ([string]$srv.name -split '\|')[0].Trim() }
  $have = Get-HaveIds
  $first = @($srv.mods | Where-Object { -not $have.ContainsKey($_.id) } |
    ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  if (-not $first) { return "nothing to do - all $($srv.mods.Count) mods of '$name' are already installed" }
  $ids = @($first | ForEach-Object { $_.modId })
  $rest = @($sizeMap.Keys | Where-Object { -not $have.ContainsKey($_) -and $ids -notcontains $_ } |
    ForEach-Object { [PSCustomObject]@{ modId = $_; name = [string]$sizeMap[$_].name } })
  $j = Get-Cfg
  $j.game.mods = @($first + $rest)
  Save-Json $j $Cfg
  Stop-DS | Out-Null
  $r = Start-DS
  $already = @($srv.mods).Count - $first.Count
  "queue: $($first.Count) missing mods of '$name' download first, then the other $($rest.Count) batch mods follow ($already of $($srv.mods.Count) already installed) ($r)"
}

function Invoke-ResumeBatch {
  # the full batch is deterministic: every sizeMap mod not yet on disk
  $have = Get-HaveIds
  $mods = @($sizeMap.Keys | Where-Object { -not $have.ContainsKey($_) } |
    ForEach-Object { [PSCustomObject]@{ modId = $_; name = [string]$sizeMap[$_].name } })
  $j = Get-Cfg
  $j.game.mods = $mods
  Save-Json $j $Cfg
  Stop-DS | Out-Null
  $r = Start-DS
  "full batch resumed: $($mods.Count) mods remaining ($r)"
}

function Get-PartialMods {
  # mods that were started but are not complete (the resume set)
  $dirs = Get-DirMap
  @($dirs.GetEnumerator() | Where-Object {
      $sm = $sizeMap[$_.Key]
      $sm -and [double]$sm.bytes -gt 0 -and $_.Value.bytes -gt 0 -and
      $_.Value.bytes -lt [double]$sm.bytes -and $_.Value.mtime -lt (Get-Date).AddMinutes(-1)
    } | ForEach-Object { [PSCustomObject]@{ modId = $_.Key; name = $_.Value.name } })
}

function Invoke-StartQueue {
  # start whatever is queued. If the queue is empty but a download was interrupted,
  # resume just those. It never refills from the servers - that is "Queue all missing".
  $j = Get-Cfg
  if (@($j.game.mods).Count -eq 0) {
    $partial = @(Get-PartialMods)
    if ($partial.Count) {
      $j.game.mods = $partial
      Save-Json $j $Cfg
      $r = Start-DS
      return "resuming $($partial.Count) unfinished download(s) ($r)"
    }
    return 'queue is empty - press Queue all missing to fetch every missing mod of your servers'
  }
  & "$PSScriptRoot\trim-config.ps1" | Out-Null
  $r = Start-DS
  $left = @((Get-Cfg).game.mods).Count
  "started with $left queued mods ($r)"
}

function Invoke-MakePreset([string]$Id) {
  $out = & "$PSScriptRoot\make-preset.ps1" -ServerId $Id
  ($out | Out-String).Trim()
}

function Get-Browse([string]$q) {
  # live server list from the public reforgermods API, cached 15 s per query
  $key = $q.ToLower()
  if ($script:bCache[$key] -and ((Get-Date) - $script:bCacheAt[$key]).TotalSeconds -lt 15) { return $script:bCache[$key] }
  $u = "$ApiBase/servers?includeOffline=true"
  if ($q) { $u += "&search=$([uri]::EscapeDataString($q))" }
  $r = Invoke-RestMethod -Uri $u -Headers $ApiH -TimeoutSec 30
  $list = @($r.data | Sort-Object online, players -Descending |
    Select-Object -First 60 | ForEach-Object {
      [PSCustomObject]@{ id = $_.id; name = $_.name; players = $_.players; maxPlayers = $_.maxPlayers
                         region = $_.region; online = [bool]$_.online; modCount = $_.modCount
                         scenarioName = $_.scenarioName } })
  $script:bCache[$key] = $list; $script:bCacheAt[$key] = Get-Date
  $list
}

function Get-Detail([string]$Id) {
  # one server with its full modlist (the API sends exact Workshop sizes), cached 30 s
  if ($script:dCache[$Id] -and ((Get-Date) - $script:dCacheAt[$Id]).TotalSeconds -lt 30) { return $script:dCache[$Id] }
  $d = Invoke-RestMethod -Uri "$ApiBase/servers/$Id" -Headers $ApiH -TimeoutSec 30
  if (-not $d.server -or -not @($d.server.mods).Count) { throw 'server has no modlist (offline or password protected)' }
  $script:dCache[$Id] = $d.server; $script:dCacheAt[$Id] = Get-Date
  $d.server
}

function Invoke-AddServer([string]$Id) {
  # add a server from the live browser: queue its missing mods at the END of the
  # batch (adding must not jump the queue), with real sizes from the API
  $s = Get-Detail $Id
  if ($s.passwordProtected) { return 'server is password protected - its modlist is not public' }
  $name = ([string]$s.name -split '\|')[0].Trim()
  if ($name.Length -gt 60) { $name = $name.Substring(0, 60).Trim() }
  $have = Get-HaveIds
  foreach ($m in (Get-Cfg).game.mods) { $have[$m.modId] = $true }
  $new = @($s.mods | Where-Object { -not $have.ContainsKey($_.id) })
  if (-not $new) { return "nothing to add - all $(@($s.mods).Count) mods of '$name' are on disk or queued" }

  $j = Get-Cfg
  $j.game.mods = @($j.game.mods) + @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  Save-Json $j $Cfg

  # merge the real sizes into the sizes file (merge-only: never replace it)
  $sz = Read-Json $Sizes $j
  foreach ($m in $new) {
    if (-not $sizeMap.ContainsKey($m.id)) {
      $sizeMap[$m.id] = @{ name = $m.name; bytes = [double]$m.size; exact = [bool]$m.sizeKnown }
      $sz.mods | Add-Member -NotePropertyName $m.id -NotePropertyValue ([PSCustomObject]@{ name = $m.name; bytes = [double]$m.size; exact = [bool]$m.sizeKnown }) -Force
    }
  }
  $script:TotalBytes = ($sizeMap.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
  $sz.totalBytes = [double]$script:TotalBytes
  Save-Json $sz $Sizes 4

  # show the new server in the Servers card immediately, and remember it
  $script:serverList = @($serverList) + @([PSCustomObject]@{ id = $Id; name = $s.name; mods = @($s.mods | ForEach-Object {
    [PSCustomObject]@{ id = $_.id; name = $_.name; e = [double]$_.size } }) })
  Save-Json @{ servers = $serverList } $ServersPath 6

  $gb = [Math]::Round(($new | ForEach-Object { [double]$_.size } | Measure-Object -Sum).Sum / 1GB, 2)
  Stop-DS | Out-Null
  $r = Start-DS
  "added '$name': $($new.Count) new mods (~$gb GB) queued at the end, $(@($s.mods).Count - $new.Count) already on disk ($r)"
}

function Invoke-RefreshServers {
  # global refresh: re-read local state, pull a fresh modlist for every tracked
  # server, resolve sizes for mods we have never seen, and queue the new ones
  # (appended - installed and already-queued mods are never downloaded twice)
  $script:bCache = @{}; $script:bCacheAt = @{}
  $script:dCache = @{}; $script:dCacheAt = @{}
  $script:dirCacheAt = (Get-Date).AddMinutes(-10)   # force a disk rescan
  $script:clCacheAt = (Get-Date).AddMinutes(-10)
  $sz = Read-Json $Sizes $j
  foreach ($p in $sz.mods.PSObject.Properties) { $sizeMap[$p.Name] = $p.Value }
  $ok = 0; $fail = 0
  $needSize = [ordered]@{}
  foreach ($sv in $serverList) {
    try {
      $d = Invoke-RestMethod -Uri "$ApiBase/servers/$($sv.id)" -Headers $ApiH -TimeoutSec 30
      if (-not $d.server -or -not @($d.server.mods).Count) { $fail++; continue }
      $sv.mods = @($d.server.mods | ForEach-Object {
        $m = $_
        if (-not $sizeMap.ContainsKey($m.id)) {
          if ($m.sizeKnown -and $m.size) {
            $sizeMap[$m.id] = @{ name = $m.name; bytes = [double]$m.size; exact = $true }
            $sz.mods | Add-Member -NotePropertyName $m.id -NotePropertyValue ([PSCustomObject]@{ name = $m.name; bytes = [double]$m.size; exact = $true }) -Force
          } else { $needSize[$m.id] = $m.name }
        }
        $e = if ($sizeMap[$m.id]) { [double]$sizeMap[$m.id].bytes } else { [double]0 }
        [PSCustomObject]@{ id = $m.id; name = $m.name; e = $e }
      })
      $ok++
    } catch { $fail++ }
    Start-Sleep -Milliseconds 300   # stay under the free tier (60/min)
  }
  if ($needSize.Count) {
    $ids = @($needSize.Keys)
    for ($i = 0; $i -lt $ids.Count; $i += 400) {
      $chunk = @($ids[$i..([Math]::Min($i + 399, $ids.Count - 1))])
      try {
        $body = @{ mode = 'replace'; desired = @($chunk | ForEach-Object { @{ id = $_ } }) } | ConvertTo-Json -Depth 5
        $plan = Invoke-RestMethod -Uri "$ApiBase/tools/storage-plan" -Method Post -Body $body -Headers $ApiH -ContentType 'application/json' -TimeoutSec 120
        foreach ($x in $plan.data.downloads) {
          $sizeMap[$x.id] = @{ name = $x.name; bytes = [double]$x.bytes; exact = [bool]$x.exact }
          $sz.mods | Add-Member -NotePropertyName $x.id -NotePropertyValue ([PSCustomObject]@{ name = $x.name; bytes = [double]$x.bytes; exact = [bool]$x.exact }) -Force
        }
      } catch { }
    }
  }
  $script:TotalBytes = ($sizeMap.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
  $sz.totalBytes = [double]$script:TotalBytes
  Save-Json $sz $Sizes 4
  Save-Json @{ servers = $serverList } $ServersPath 6

  # queue what the servers run today and we do not have yet (append only)
  $have = Get-HaveIds
  $j = Get-Cfg
  $queued = @{}
  foreach ($m in $j.game.mods) { $queued[$m.modId] = $true }
  $want = [ordered]@{}
  foreach ($sv in $serverList) { foreach ($m in $sv.mods) { $want[$m.id] = $m.name } }
  $new = @($want.Keys | Where-Object { -not $have.ContainsKey($_) -and -not $queued.ContainsKey($_) })
  if ($new.Count) {
    # the DS rewrites the config on exit, so an append made while it runs is
    # discarded: stop it first, like every other handler that writes the queue
    $restart = [bool](Get-DS)
    if ($restart) { Stop-DS | Out-Null }
    $j.game.mods = @($j.game.mods) + @($new | ForEach-Object { [PSCustomObject]@{ modId = $_; name = [string]$want[$_] } })
    Save-Json $j $Cfg
    if ($restart) { $r = Start-DS; "downloader restarted for the new mods ($r)" }
  }
  $onDisk = 0
  foreach ($sv in $serverList) { $onDisk += @($sv.mods | Where-Object { $have.ContainsKey($_.id) }).Count }
  "refreshed $ok/$(@($serverList).Count) servers$(if ($fail) { " ($fail unreachable)" }): $($sizeMap.Count) mods tracked, $onDisk server mod slots installed, $($new.Count) new mods queued"
}

function Invoke-ClearQueue {
  # empty the queue and stop the downloader - nothing is deleted from disk.
  # Stop FIRST: the DS writes its config back on shutdown, which would refill it.
  $n = @((Get-Cfg).game.mods).Count
  Stop-DS | Out-Null
  Start-Sleep 2
  $j = Get-Cfg
  $j.game.mods = @()
  Save-Json $j $Cfg
  "queue cleared ($n mods removed) - installed mods are untouched"
}

function Invoke-ResumeAll {
  # queue every mod of every tracked server that is not installed yet
  $have = Get-HaveIds
  $want = [ordered]@{}
  foreach ($sv in $serverList) { foreach ($m in $sv.mods) { $want[$m.id] = $m.name } }
  foreach ($id in $sizeMap.Keys) { if (-not $want.Contains($id)) { $want[$id] = [string]$sizeMap[$id].name } }
  $j = Get-Cfg
  $mods = @($want.Keys | Where-Object { -not $have.ContainsKey($_) } |
    ForEach-Object { [PSCustomObject]@{ modId = $_; name = [string]$want[$_] } })
  $j.game.mods = $mods
  Save-Json $j $Cfg
  Stop-DS | Out-Null
  $r = Start-DS
  "resume all: $($mods.Count) mods queued, $(@($want.Keys).Count - $mods.Count) already installed ($r)"
}

# per-run token: the six state-changing endpoints only answer requests that carry
# it, so another website open in the browser cannot drive this server (CSRF)
$token = [guid]::NewGuid().ToString('N')
$mutating = '/start','/pause','/verify','/queue-server','/resume-batch','/resume-all','/clear-queue','/make-preset','/add-server','/refresh-servers'

$html = @'
<!doctype html><html><head><meta charset="utf-8"><title>Reforger Mods Download</title>
<style>
 body{background:#17181c;color:#d6d8de;font-family:Segoe UI,Arial,sans-serif;margin:0;padding:24px}
 .card{background:#1f2127;border-radius:10px;padding:16px 20px;margin:0 auto 14px;max-width:920px}
 h1{font-size:18px;margin:0 0 12px;color:#fff}
 .dot{display:inline-block;width:10px;height:10px;border-radius:5px;margin-right:6px}
 .bar{background:#2a2d34;border-radius:6px;height:14px;overflow:hidden}
 .bar>div{height:14px;background:#4cc35e;transition:width .5s linear}
 .bar.amber>div{background:#e0b13e}
 .row{display:flex;justify-content:space-between;margin:6px 0 4px;font-size:13px}
 button{background:#3b6fe0;border:0;color:#fff;padding:9px 18px;border-radius:7px;font-size:14px;cursor:pointer;margin-right:8px}
 button.grey{background:#4a4e58} button.amber{background:#b3872e}
 button.mini{padding:2px 10px;font-size:12px;margin:0 0 0 6px} button.mini.grey{background:#4a4e58} button.mini.amber{background:#b3872e}
 button:disabled{opacity:.5;cursor:default}
 input{background:#26282e;border:1px solid #3a3d45;color:#d6d8de;border-radius:7px;padding:8px 12px;font-size:14px;width:420px}
 ul{list-style:none;margin:6px 0 0;padding:0;font-size:13px}
 li{padding:3px 0;border-bottom:1px solid #26282e}
 details{margin:2px 0} summary{cursor:pointer;font-size:13px;padding:3px 0;color:#fff}
 details.card>summary{list-style:none}
 details.card>summary::-webkit-details-marker{display:none}
 details.card>summary h2{display:inline;margin:0}
 details.card>summary::before{content:'\25B8';display:inline-block;width:14px;color:#8a8e98}
 details.card[open]>summary::before{content:'\25BE'}
 .cols{display:flex;gap:14px;max-width:920px;margin:0 auto 14px;align-items:flex-start}
 .cols>.card{flex:1;margin:0;min-width:0}
 #queue{max-height:300px;overflow:auto}
 .f{background:#26282e;border:1px solid #3a3d45;color:#d6d8de;border-radius:6px;padding:5px 9px;font-size:12px;width:100%;box-sizing:border-box;margin:6px 0}
 #queue ol{margin:0;padding-left:22px;font-size:13px;line-height:1.6}
 #srv{max-height:360px;overflow:auto}
 #rec{max-height:360px;overflow:auto}
 #act{max-height:340px;overflow:auto}
 details.card>summary #qpreview{display:none}
 details.card:not([open])>summary #qpreview{display:inline}
 details.card:not([open])>summary{margin-bottom:0}
 #srv ul,#bs ul{margin:4px 0 0 16px}
 #bs .bs{margin:4px 0 0 16px}
 .ok{color:#7ed07e} .warn{color:#e0b13e} .bad{color:#e06c6c} .dim{color:#8a8e98}
 #vres{display:none}
 .big{font-size:26px;font-weight:600;color:#fff}
</style></head><body>
<div class="card"><h1>Arma Reforger Mods <span id="st"></span></h1>
 <div class="dim" id="boot">connecting to dashboard...</div>
 <div class="row"><span id="gbtxt" class="big"></span><span id="spd" class="dim"></span></div>
 <div class="bar"><div id="tbar" style="width:0%"></div></div>
 <div class="row"><span id="cnt" class="dim"></span><span class="dim" id="etabox"></span></div>
 <div style="margin-top:14px">
  <button id="bstart" onclick="act('start')">Start</button>
  <button id="bresumeall" onclick="act('resume-all')">Queue all missing</button>
  <button id="bpause" class="grey" onclick="act('pause')">Pause</button>
  <button id="bclear" class="grey" onclick="act('clear-queue')">Clear queue</button>
  <button id="bverify" class="amber" onclick="act('verify')">Verify mods</button>
 </div>
 <div id="vres" class="card" style="margin:14px 0 0;padding:10px 14px"></div>
 <div id="say" class="dim" style="margin-top:10px;font-size:13px;min-height:18px"></div>
 <div id="failed" class="bad" style="font-size:13px;margin-top:4px"></div>
</div>
<div class="cols">
 <details class="card" open><summary><h2 style="font-size:15px;color:#fff">Queue <span id="qcount" class="dim"></span> <span id="qpreview" class="dim" style="font-size:13px"></span></h2></summary>
  <input class="f" id="fq" placeholder="filter queue by name..." oninput="FILTER.queue=this.value;renderAll()">
  <div id="queue" class="dim">-</div></details>
 <details class="card" open><summary><h2 style="font-size:15px;color:#fff">Downloading now <span id="actcount" class="dim"></span></h2></summary>
  <input class="f" id="fa" placeholder="filter downloads by name..." oninput="FILTER.act=this.value;renderAll()">
  <div id="act">-</div></details>
</div>
<details class="card" open><summary><h2 style="font-size:15px;color:#fff">Server browser <span class="dim">live</span></h2></summary>
 <div style="margin-top:8px"><input id="bq" placeholder="search servers (e.g. PVE, Cold Front, Vietnam)..." oninput="browseCleared()" onkeydown="if(event.key==='Enter')browse()"><button onclick="browse()">Search</button></div>
 <div id="bs" class="dim" style="margin-top:8px">type a server name and press Enter</div>
</details>
<details class="card" open><summary><h2 style="font-size:15px;color:#fff">Servers <span id="srvcount" class="dim"></span><button class="mini" onclick="refreshSrv(event)" title="re-read disk + pull fresh modlists from reforgermods.net">Refresh all</button></h2></summary><div id="srv" class="dim" style="margin-top:8px">loading server lists...</div></details>
<details class="card"><summary><h2 style="font-size:15px;color:#fff">Completed <span id="reccount" class="dim"></span></h2></summary>
 <input class="f" id="fr" placeholder="filter completed mods by name..." oninput="FILTER.rec=this.value;renderAll()">
 <ul id="rec"></ul></details>
<script>
let T='__T__';   // refreshed from /status so an open page survives dashboard restarts
function esc(x){return String(x).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
// ids land inside onclick="...('id')" and data-id="...": esc() alone leaves
// quotes alone, so an id from the API could break out of the handler
function escAttr(x){return esc(x).replace(/"/g,'&quot;').replace(/'/g,'&#39;')}
function sz(b){return b>=1073741824?(b/1073741824).toFixed(b>=107374182400?2:3)+' GB':b>=1048576?(b/1048576).toFixed(1)+' MB':b>=1024?(b/1024).toFixed(1)+' KB':Math.round(b)+' B'}
function left(sec){ if(!isFinite(sec)||sec<=0) return '--'; const h=Math.floor(sec/3600), m=Math.round((sec%3600)/60); return h>0?(h+'h '+m+'m'):(m+' min'); }
let SRV=null,BR=null,lastKey='';
let FILTER={queue:'',act:'',rec:''},LAST=null;
function match(name,q){ return !q || String(name).toLowerCase().indexOf(q.toLowerCase())>=0; }
function renderActive(list,A){
  const el=document.getElementById('act'); if(!el)return;
  const shown=list.filter(a=>match(a.name,FILTER.act));
  document.getElementById('actcount').textContent=list.length?'('+list.length+')':'';
  el.innerHTML=shown.length
   ?shown.map(a=>'<div class="row"><span>'+esc(a.name)+'</span><span class="dim">'+(a.expB>0?(sz(a.b)+' / '+sz(a.expB)):sz(a.b)+' (size unknown)')+'</span></div>'+
     (a.expB>0?'<div class="bar amber"><div style="width:'+a.pct+'%"></div></div>':'')).join('')
   :(list.length?'<span class="dim">no download matches the filter</span>':'<span class="dim">nothing downloading right now</span>');
}
function renderQueue(queue,A){
  const el=document.getElementById('queue'); if(!el)return;
  document.getElementById('qcount').textContent='('+queue.length+')';
  const qp=document.getElementById('qpreview');
  if(qp)qp.textContent=queue.length?(' - '+queue.slice(0,3).map(q=>q.name).join(' · ')+(queue.length>3?' …':'')):'';
  const shown=queue.filter(q=>match(q.name,FILTER.queue));
  el.innerHTML=shown.length
   ?'<ol>'+shown.map(q=>'<li>'+(A[q.id]?'<span class="warn">&#10227;</span> ':'')+esc(q.name)+'</li>').join('')+'</ol>'
   :'<span class="dim">'+(queue.length?'no mod matches the filter':'queue is empty')+'</span>';
}
function renderRec(recent){
  const el=document.getElementById('rec'); if(!el)return;
  document.getElementById('reccount').textContent='('+recent.length+')';
  const shown=recent.filter(r=>match(r.name,FILTER.rec)).slice(0,400);
  el.innerHTML=shown.length
   ?shown.map(r=>'<li class="ok">&#10003; '+esc(r.name)+' <span class="dim">'+sz(r.b)+'</span></li>').join('')
   :'<li class="dim">'+(recent.length?'nothing matches the filter':'nothing finished yet')+'</li>';
}
function renderAll(){
  if(!LAST)return;
  renderActive(LAST.active,LAST.A);
  renderQueue(LAST.queue,LAST.A);
  renderRec(LAST.recent);
}
let SRVAt=0;
async function loadSrv(){
 // /servers costs a full disk scan: retry at most every 5 s, and never accept an
 // error body - a 500 body parses as json, which made SRV truthy and froze the
 // servers card (renderSrv threw on SRV.servers) for the rest of the session
 if(Date.now()-SRVAt<5000)return; SRVAt=Date.now();
 try{const r=await fetch('/servers'),j=await r.json(); if(r.ok&&j&&j.servers){SRV=j;lastKey='';}}catch(e){}
}
function renderSrv(D,A,B){
 if(!SRV)return;
 document.getElementById('srvcount').textContent='('+SRV.servers.length+')';
 document.getElementById('srv').innerHTML=SRV.servers.map(v=>{
  const done=v.haveCount!=null?v.haveCount:v.mods.filter(m=>D[m.id]).length;
  return '<details><summary>'+esc(v.name)+' <span class="dim">'+done+' / '+v.mods.length+' downloaded</span>'+
   '<button class="mini" onclick="queueSrv(\''+escAttr(v.id)+'\',event)">Queue first</button>'+
   '<button class="mini amber" onclick="presetSrv(\''+escAttr(v.id)+'\',event)">Make preset</button></summary><ul>'+
   v.mods.map(m=>{
    const t=D[m.id]?'<span class="ok">&#10003;</span>':A[m.id]?'<span class="warn">&#10227;</span>':'<span class="dim">&#8226;</span>';
    const s2=B[m.id]!=null?sz(B[m.id]):(m.e>0?sz(m.e):'');
    return '<li>'+t+' '+esc(m.name)+' <span class="dim">'+s2+'</span></li>';
   }).join('')+'</ul></details>';
 }).join('');
}
async function browse(){
 const q=document.getElementById('bq').value.trim();
 const el=document.getElementById('bs');
 if(!q){ BR=null; el.innerHTML='<span class="dim">type a server name and press Enter</span>'; return; }
 el.textContent='searching live servers...';
 try{
  const r=await (await fetch('/browse?q='+encodeURIComponent(q))).json();
  if(r.error)throw new Error(r.error);
  if(!r.servers)throw new Error('unexpected response');
  BR=r.servers; renderBrowse();
 }catch(e){ el.innerHTML='<span class="bad">search failed: '+esc(String(e))+'</span>'; }
}
function browseCleared(){
 if(document.getElementById('bq').value.trim())return;
 BR=null;
 document.getElementById('bs').innerHTML='<span class="dim">type a server name and press Enter</span>';
}
function renderBrowse(){
 const el=document.getElementById('bs');
 if(!BR||!BR.length){el.innerHTML='<span class="dim">no servers found</span>';return;}
 el.innerHTML=BR.map(v=>{
  const pl=(v.players==null?'?':v.players)+'/'+(v.maxPlayers==null?'?':v.maxPlayers)+' players';
  const md=v.haveCount>=0 ? v.haveCount+'/'+v.totalMods+' on disk' : v.modCount+' mods';
  return '<details ontoggle="bsToggle(this,\''+escAttr(v.id)+'\')"><summary>'+esc(v.name)+
  ' <span class="dim">'+pl+(v.online?'':' &middot; offline')+' &middot; '+md+'</span>'+
  '<button class="mini" onclick="addSrv(\''+escAttr(v.id)+'\',event)">Add server</button></summary>'+
  '<div class="bs" data-id="'+escAttr(v.id)+'"><span class="dim">loading modlist...</span></div></details>';
 }).join('');
}
function bsToggle(d,id){ if(d.open&&!d.dataset.l)loadBS(id,d); }
async function loadBS(id,d){
 const box=d.querySelector('.bs');
 try{
  const j=await (await fetch('/browse-server?id='+id)).json();
  if(j.error)throw new Error(j.error);       // e.g. "no modlist (offline or password protected)"
  if(!j.mods)throw new Error('unexpected response');
  const ok=j.mods.filter(m=>m.have).length;
  d.dataset.l=1;   // latch only after a real answer, so reopening retries a failure
  box.innerHTML='<div class="dim">'+ok+' / '+j.mods.length+' mods on disk - '+sz(j.missingBytes||0)+' to download</div><ul>'+
   j.mods.map(m=>'<li>'+(m.have?'<span class="ok">&#10003;</span>':'<span class="dim">&#8226;</span>')+' '+esc(m.name)+' <span class="dim">'+(m.expB>0?sz(m.expB):'')+'</span></li>').join('')+'</ul>';
 }catch(e){ box.innerHTML='<span class="bad">'+esc(String(e).replace('Error: ',''))+'</span>'; }
}
function say(t,ok){const e=document.getElementById('say'); if(!e)return; e.textContent=t||''; e.className=t?(ok===false?'bad':ok===true?'ok':'dim'):'dim';}
async function addSrv(id,ev){
 ev.stopPropagation();
 const b=ev.target; b.disabled=true; b.textContent='adding...';
 say('adding server - its missing mods go to the end of the queue...');
 await post('add-server?id='+id);
 b.disabled=false; b.textContent='Add server';
 loadSrv();
}
async function tick(){
 try{
  if(!SRV)loadSrv();
  const s=await (await fetch('/status')).json();
  if(s.tok)T=s.tok;
  const boot=document.getElementById('boot'); if(boot)boot.remove();
  document.getElementById('st').innerHTML=s.running
    ?'<span class="dot" style="background:#4cc35e"></span><span class="ok">running</span>'
    :'<span class="dot" style="background:#e06c6c"></span><span class="bad">stopped</span>';
  document.getElementById('gbtxt').textContent=sz(s.doneB)+' / '+sz(s.totalB);
  document.getElementById('tbar').style.width=(s.pctF!=null?s.pctF:s.pct)+'%';
  document.getElementById('spd').textContent=s.running
    ?(s.speedB>0?sz(s.speedB)+'/s'+(s.speedAge>15?' ('+Math.round(s.speedAge)+' s ago)':''):'idle')
    :'paused';
  document.getElementById('cnt').textContent=s.doneCount+' / '+s.totalMods+' mods assembled';
  const eta=(s.speedB>51200)?left((s.totalB-s.doneB)/s.speedB):'--';
  document.getElementById('etabox').textContent=eta;
  const D={},A={},B={};
  s.recent.forEach(r=>{D[r.id]=1;B[r.id]=r.b});
  s.active.forEach(a=>{A[a.id]=1});
  (s.cl||[]).forEach(id=>{D[id]=1});   // installed client-side before the batch counts as on disk
  LAST={recent:s.recent||[],active:s.active||[],queue:s.queue||[],D:D,A:A,B:B};
  renderActive(s.active||[],A);
  const key=s.recent.length+'|'+(s.cl||[]).length+'|'+(s.queue||[]).length+'|'+s.active.map(a=>a.id).join(',');
  if(key!==lastKey){          // lists only re-render when something actually finished/started
   lastKey=key;
   renderQueue(LAST.queue,A);
   renderRec(LAST.recent);
   renderSrv(D,A,B);
  }
  const f=document.getElementById('failed');
  if(f)f.textContent=(s.failed&&s.failed.length)?('skipped after repeated Workshop errors: '+s.failed.join(', ')):'';
  const v=document.getElementById('vres');
  if(s.verify){v.style.display='block';const x=s.verify;
   let t='<b>Verify '+x.at+'</b> - <span class="ok">'+x.ok+' ok</span>, '+x.partial+' partial, '+x.pending+' pending';
   if(x.suspects&&x.suspects.length){t+='<br><span class="bad">Size mismatch (re-download candidates):</span><ul>'+
     x.suspects.map(z=>'<li class="bad">'+esc(z.name)+' - expected '+sz(z.expB)+', on disk '+sz(z.actB)+'</li>').join('')+'</ul>';}
   else t+='<br><span class="ok">No size mismatches - installed mods look intact.</span>';
   v.innerHTML=t;}
 }catch(e){say('status error: '+((e&&e.message)||e),false);}
}
async function post(w){
 try{
  const r=await fetch('/'+w+(w.indexOf('?')>=0?'&':'?')+'t='+T,{method:'POST'});
  const j=await r.json();
  if(j.error)say('failed: '+j.error,false);
  else if(j.msg)say(String(j.msg),true);
  await tick();
 }catch(e){say('failed: '+e,false); await tick();}
}
async function queueSrv(id,ev){
 ev.stopPropagation();
 const b=ev.target; b.disabled=true; b.textContent='queuing...';
 say('reordering the queue...');
 await post('queue-server?id='+id);
 b.disabled=false; b.textContent='Queue first';
}
async function presetSrv(id,ev){
 ev.stopPropagation();
 const b=ev.target; b.disabled=true; b.textContent='building...';
 say('building launcher preset...');
 await post('make-preset?id='+id);
 b.disabled=false; b.textContent='Make preset';
}
async function refreshSrv(ev){
 ev.stopPropagation();   // the button sits inside the card's <summary>
 const b=ev.target; b.disabled=true; b.textContent='refreshing...';
 say('refreshing servers: rescanning disk and pulling fresh modlists...');
 await post('refresh-servers');
 b.disabled=false; b.textContent='Refresh all';
 loadSrv();
}
async function act(w){
 const b=event?event.target:null; if(b){b.disabled=true;b.textContent='...';}
 say(w==='start'?'starting / resuming the download...':w==='pause'?'pausing...':w==='clear-queue'?'clearing the queue...':w==='resume-all'?'queuing every missing mod of your servers...':'checking installed mods against the Workshop...');
 await post(w);
 if(b){b.disabled=false;b.textContent=w==='start'?'Start / Resume':w==='pause'?'Pause':w==='clear-queue'?'Clear queue':w==='resume-all'?'Queue all missing':'Verify mods';}
}
loadSrv();   // self-gated (5 s); tick retries it too, so this is the only call site
(async function loop(){ await tick(); setTimeout(loop,200); })();   // one request in flight, ~0.4 s cadence
</script></body></html>
'@


$l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url)
try { $l.Start() }
catch {
  # port busy: a just-killed dashboard's keep-alive sockets linger for a while.
  # retry once before concluding another instance is actually serving.
  Start-Sleep 5
  try { $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url); $l.Start() }
  catch {
    Write-Host 'dashboard already running - opening browser' -ForegroundColor Cyan
    Start-Process $Url
    exit 0
  }
}
Write-Host '=== Arma Reforger Mods - web dashboard ===' -ForegroundColor White
Write-Host "open: $Url   (keep this window open; closing it only stops the UI, not the download)" -ForegroundColor Cyan
# -Command + quoted path: -File breaks on a repo path containing a space,
# which silently disabled the client-addon mirror
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',`
  '-Command',"& '$PSScriptRoot\sync-addons.ps1' -Loop"   # auto-mirror completed mods into client addons
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',`
 '-Command',"& '$PSScriptRoot\watchdog.ps1'"            # restarts the downloader when it exits or stalls
Start-Process $Url

while ($l.IsListening) {
  $ctx = $l.GetContext()
  try {
    $msg = $null   # must reset per request or it leaks into the next response body
    $path = $ctx.Request.Url.AbsolutePath
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    if ($path -in $mutating -and $ctx.Request.QueryString['t'] -ne $token) {
      $ctx.Response.StatusCode = 403
      $b = [Text.Encoding]::UTF8.GetBytes('{"error":"bad or missing token"}')
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      continue
    }
    switch ($path) {
      '/' {
        $b = [Text.Encoding]::UTF8.GetBytes($html.Replace('__T__', $token))
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.ContentLength64 = $b.Length
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/status' {
        $b = [Text.Encoding]::UTF8.GetBytes((Get-Status | ConvertTo-Json -Depth 5 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/servers' {
        # exact per-server counts: a mod only counts when its own file list matches
        $have = Get-HaveIds
        $rows = @($serverList | ForEach-Object {
          $s = $_
          [PSCustomObject]@{ id = $s.id; name = $s.name; mods = $s.mods
                             haveCount = @($s.mods | Where-Object { $have.ContainsKey($_.id) }).Count } })
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = $rows } | ConvertTo-Json -Depth 6 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse' {
        $have = Get-HaveIds
        $tracked = @{}
        foreach ($sv in $serverList) { $tracked[$sv.id] = $sv }
        $rows = @(Get-Browse $ctx.Request.QueryString['q'] | ForEach-Object {
          # tracked servers get a real on-disk count; others only the API's total
          $haveCount = -1; $total = $_.modCount
          if ($tracked.ContainsKey($_.id)) {
            $mods = @($tracked[$_.id].mods)
            $haveCount = @($mods | Where-Object { $have.ContainsKey($_.id) }).Count
            $total = $mods.Count
          }
          [PSCustomObject]@{ id = $_.id; name = $_.name; players = $_.players; maxPlayers = $_.maxPlayers
                             region = $_.region; online = $_.online; modCount = $_.modCount
                             scenarioName = $_.scenarioName; haveCount = $haveCount; totalMods = $total } })
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = $rows } | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse-server' {
        $s = Get-Detail $ctx.Request.QueryString['id']
        $have = Get-HaveIds
        $rows = @($s.mods | ForEach-Object {
          $exp = if ($sizeMap.ContainsKey($_.id)) { [double]$sizeMap[$_.id].bytes } else { [double]$_.size }
          [PSCustomObject]@{ id = $_.id; name = $_.name; expB = $exp; have = [bool]$have.ContainsKey($_.id) } })
        $missing = @($rows | Where-Object { -not $_.have })
        $out = @{ name = $s.name; online = [bool]$s.online; mods = $rows
                  haveCount = @($rows | Where-Object { $_.have }).Count
                  missingBytes = [double]($missing | ForEach-Object { $_.expB } | Measure-Object -Sum).Sum }
        $b = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/start'  { $msg = Invoke-StartQueue;  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/pause'  { $msg = Stop-DS;         Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/verify' { $msg = Invoke-Verify;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      '/queue-server' { $msg = Invoke-QueueServer $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/resume-batch' { $msg = Invoke-ResumeBatch; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/resume-all'   { $msg = Invoke-ResumeAll;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/clear-queue'  { $msg = Invoke-ClearQueue;  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/make-preset'  { $msg = Invoke-MakePreset $ctx.Request.QueryString['id'];  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      '/add-server'   { $msg = Invoke-AddServer $ctx.Request.QueryString['id'];   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/refresh-servers' { $msg = Invoke-RefreshServers; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      default   {
        $ctx.Response.StatusCode = 404
        $b = [Text.Encoding]::UTF8.GetBytes('{"error":"no such route"}')
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
    }
    if ($null -ne $msg) {
      $b = [Text.Encoding]::UTF8.GetBytes((@{ ok = $true; msg = [string]$msg } | ConvertTo-Json -Compress))
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    }
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    # never hand-roll this json: a Windows path in the message ("C:\Users\...")
    # contains \U, an illegal escape, so the page's r.json() threw a SyntaxError
    # and showed that instead of the real error
    $b = [Text.Encoding]::UTF8.GetBytes((@{ error = [string]$_.Exception.Message } | ConvertTo-Json -Compress))
    $ctx.Response.StatusCode = 500
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
  }
  finally { $ctx.Response.OutputStream.Close() }
}


