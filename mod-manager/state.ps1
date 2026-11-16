# Shared state helpers. Dot-source this; do not copy it.
#
# These three functions were pasted into five scripts (download-web, watchdog,
# trim-config, add-server, test-rules, get-sizes) and drifted: the File.Replace
# null-argument bug had to be fixed five times, and test-rules asserted its own
# copy of the completion rule. One copy, one rule.
$script:exactCache = @{}

function Lock-Engine {
  # the dashboard and the watchdog both start/stop the engine. A named mutex
  # removes the check-then-act race that could put two DS processes on one profile
  # (both write <mod>\temp\, so an assembled pak can be a mix of two downloads).
  $m = [Threading.Mutex]::new($false, 'ReforgerEngineCtl')
  if (-not $m.WaitOne(20000)) { return $null }
  $m
}

function Save-Json($obj, [string]$Path, [int]$Depth = 5) {
  # atomic: closing the console kills the process, Set-Content truncates in place,
  # so a half-written state file would be unrecoverable. A path that is not a path
  # means a shadowed variable upstream - fail loudly instead of writing a file
  # named after a .NET type.
  if ($Path -notmatch '[\\/]') { throw "Save-Json: refusing to write to '$Path'" }
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth $Depth | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}

function Read-Json([string]$Path, $Default) {
  # an unreadable state file must never stop the program: a parse failure moves it
  # aside (never deletes it) so the next step can run on defaults. An IO error is
  # not a parse error - leave the file alone and try again later.
  if (-not (Test-Path $Path)) { return $Default }
  try { $raw = Get-Content $Path -Raw -ErrorAction Stop } catch { return $Default }
  if (-not $raw) { return $Default }
  try { return ($raw | ConvertFrom-Json) }
  catch {
    $bad = "$Path.corrupt-$(Get-Date -f yyyyMMdd-HHmmss)"
    Move-Item $Path $bad -Force -ErrorAction SilentlyContinue
    Write-Host "WARNING: $([IO.Path]::GetFileName($Path)) was unreadable - moved to $(Split-Path $bad -Leaf), using defaults" -ForegroundColor Red
    return $Default
  }
}

function Test-AddonComplete([string]$Path, $Mtime) {
  # THE completion rule: the addon's own meta lists every file with its exact
  # size, and the game itself reads it that way. Never use a folder total.
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
