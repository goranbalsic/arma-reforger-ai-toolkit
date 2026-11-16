# Offline self-test for the shared state helpers. No dashboard, no game, no network.
#   powershell -File test-units.ps1      (exit 0 = pass)
# Until now the only test needed a live dashboard and an 86 GB install, so a fresh
# clone could not prove anything. This runs in a second.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\state.ps1"

$fail = 0
function Check([string]$Name, [bool]$Ok) {
  if ($Ok) { "  ok   $Name" } else { "  FAIL $Name"; $script:fail++ }
}
$tmp = Join-Path $env:TEMP "rfmm-units-$PID"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null

# --- the completion rule ---------------------------------------------------
function New-Addon([string]$Id, [string]$Variant) {
  $dir = Join-Path $tmp ("Mod_{0}" -f $Id)
  New-Item -ItemType Directory -Force $dir | Out-Null
  $pak = switch ($Variant) {
    'ok'      { 100 }
    'short'   { 90 }
    'missing' { 100 }
    default   { 100 }
  }
  [IO.File]::WriteAllText((Join-Path $dir 'data.pak'), ('x' * $pak))
  if ($Variant -ne 'missing') {
    [IO.File]::WriteAllText((Join-Path $dir 'addon.gproj'), '{}')
  }
  $files = @(
    [ordered]@{ name = 'data.pak'; size = 100 },
    [ordered]@{ name = 'addon.gproj'; size = 2 }
  )
  $meta = [ordered]@{ meta = [ordered]@{ versions = @([ordered]@{ package = [ordered]@{ files = @($files) } }) } }
  Save-Json $meta (Join-Path $dir 'meta') 6
  $dir
}
$ok = New-Addon 'AAAAAAAAAAAAAAAA' 'ok'
$short = New-Addon 'BBBBBBBBBBBBBBBB' 'short'
$gone = New-Addon 'CCCCCCCCCCCCCCCC' 'missing'
$nometa = Join-Path $tmp 'Mod_DDDDDDDDDDDDDDDD'
New-Item -ItemType Directory -Force $nometa | Out-Null

Write-Host 'completion rule (the addon meta file list)'
Check 'matching file list is complete'        (Test-AddonComplete $ok $null)
Check 'wrong file size is not complete'       (-not (Test-AddonComplete $short $null))
Check 'missing file is not complete'          (-not (Test-AddonComplete $gone $null))
Check 'no meta at all is not complete'        (-not (Test-AddonComplete $nometa $null))
Check 'cache returns the same answer'         ((Test-AddonComplete $ok $null) -eq $true)

Write-Host 'state files (atomic write, tolerant read)'
$f = Join-Path $tmp 'state.json'
Save-Json ([ordered]@{ a = 1; b = @(1, 2) }) $f
Check 'round-trips'                           ((Read-Json $f $null).a -eq 1)
Check 'no .tmp left behind'                   (-not (Test-Path "$f.tmp"))
Save-Json ([ordered]@{ a = 2 }) $f
Check 'replace overwrites'                    ((Read-Json $f $null).a -eq 2)
Set-Content $f '{"a":1,"b":' -NoNewline
$got = Read-Json $f ([pscustomobject]@{ a = -1 })
Check 'corrupt file falls back to default'    ($got.a -eq -1)
Check 'corrupt original is kept, not deleted' (@(Get-ChildItem $tmp -Filter '*.corrupt-*').Count -eq 1)
$threw = $false
try { Save-Json @{} 'notapath' } catch { $threw = $true }
Check 'a non-path is refused loudly'          $threw
Check 'missing file returns the default'      ((Read-Json (Join-Path $tmp 'nope.json') 'dflt') -eq 'dflt')

Write-Host 'engine ownership (only the engine we started)'
$none = Get-OwnEngine (Join-Path $tmp 'no-such-config.json')
Check 'no match is an empty array, not $null' (($null -ne $none) -and (@($none).Count -eq 0))

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
""
if ($fail) { "units: $fail failed"; exit 1 } else { 'units: OK' }


