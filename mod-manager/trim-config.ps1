# Trim batch1-serverconfig.json to mods not yet assembled in the DS profile.
# the DS fetches a download list for every config mod, and its 1 MB response
# limit chokes once the list gets big - so the config must only hold what's left.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$cfgPath = "$Data\batch1-serverconfig.json"
$addons  = "$Root\serverprofile\addons"

function Save-Json($obj, [string]$Path) {
  # atomic: Set-Content truncates in place and this runs on every DS restart, so
  # a kill mid-write used to leave a config the dashboard could not parse
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}

$done = @{}
function Test-AddonComplete([string]$Path) {
  # the addon's own meta lists every file with its exact size: the one completion
  # rule (README) shared with the dashboard, the client copy and test-rules.
  # A stale Workshop size must not decide - it kept finished mods queued forever.
  $metaPath = Join-Path $Path 'meta'
  if (-not (Test-Path $metaPath)) { return $false }
  try {
    $j = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $files = @(@($j.meta.versions)[0].package.files)
    if (-not $files.Count) { return $false }
    foreach ($f in $files) {
      if (-not $f.name) { continue }
      $p = Join-Path $Path $f.name
      if (-not (Test-Path $p)) { return $false }
      if ((Get-Item $p).Length -ne [long]$f.size) { return $false }
    }
    return $true
  } catch { return $false }
}
# same completion rule as Get-HaveIds in the dashboard: a folder with the 3 marker
# files but unfinished paks is NOT done (the DS writes the markers first), and a
# mod whose Workshop size went stale still counts when its meta list matches.
Get-ChildItem $addons -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object {
    $id = $Matches[1]
    if (Test-AddonComplete $_.FullName) { $done[$id] = $true }
  }
"assembled on disk: $($done.Count)"

$j = Get-Content $cfgPath -Raw | ConvertFrom-Json
if (-not $j -or -not $j.game) {
  # an empty/truncated config is not a queue: recreate the shell instead of dying
  # here, which used to leave it 0 bytes and the watchdog restarting a broken DS
  $j = '{"game":{"mods":[]}}' | ConvertFrom-Json
  "config was empty or unreadable - recreated"
}
# the DS writes "mods": null on shutdown; piping that yields one $null item and
# ContainsKey($null) throws, which left the config unrepaired
if ($null -eq $j.game.mods) { $j.game.mods = @() }
$left = @($j.game.mods | Where-Object { -not $done.ContainsKey($_.modId) })
"config: $(@($j.game.mods).Count) -> remaining: $($left.Count)"

# A partial download has addon.gproj/meta/rdb on disk, so the DS can believe it
# is installed and never fetch it again. Delete only files that have not been
# touched for 15 minutes: a fresh partial may be resumed by the next run and
# deleting it would throw that progress away.
if (-not (Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue)) {
  foreach ($m in $left) {
    $d = Get-ChildItem $addons -Directory -Filter "*_$($m.modId)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d) { continue }
    # the newest FILE, not the folder: the DS appends inside <mod>\temp\ and never
    # touches the directory time, so a 40-minute download looked 40 minutes stale
    # and got deleted - throwing away every fragment it had fetched
    $newest = (Get-ChildItem $d.FullName -File -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if (-not $newest -or $newest -gt (Get-Date).AddMinutes(-15)) { continue }
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    "deleted stale partial download: $($d.Name)"
  }
}

$j.game.mods = $left
Save-Json $j $cfgPath
"saved"
