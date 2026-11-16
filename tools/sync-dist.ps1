# Publishes mod-manager to the public distribution repo and builds the release zip.
#   powershell -File tools\sync-dist.ps1
#   powershell -File tools\sync-dist.ps1 -ZipPath C:\tmp\arma-reforger-mod-downloader-v1.0.4.zip
#
# The public repo is a copy, so every hand copy drifts: a file added here never
# arrives, a file deleted here stays there and ships in the zip. This does both
# from the source, prunes what no longer exists, and never touches data/ or the
# engine folders.
param(
  [string]$Dest = (Join-Path $PSScriptRoot '..\..\reforger-mod-manager'),
  [string]$ZipPath = (Join-Path $env:TEMP 'arma-reforger-mod-downloader.zip')
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\mod-manager'
if (-not (Test-Path (Join-Path $Dest '.git'))) { throw "not the distribution repo: $Dest" }

Copy-Item "$src\*.ps1" $Dest -Force
$keep = @(Get-ChildItem $src -Filter *.ps1 | Select-Object -ExpandProperty Name)
# files the public repo owns: the installer does not exist in mod-manager, so the
# prune below must never remove it
$own = @('Setup.ps1')
foreach ($f in @(Get-ChildItem $Dest -Filter *.ps1 | Where-Object { $keep -notcontains $_.Name -and $own -notcontains $_.Name })) {
  Remove-Item $f.FullName -Force
  "pruned $($f.Name) (no longer in mod-manager)"
}
"copied $($keep.Count) scripts into $Dest"

# the zip ships what git tracks - docs and the install scripts included, state excluded
$stage = Join-Path ([IO.Path]::GetTempPath()) "rfmm-zip-$PID"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Push-Location $Dest
try {
  foreach ($f in (git ls-files)) {
    if ($f -match '^(data|serverprofile|armar-server|steamcmd)/') { continue }
    if (-not (Test-Path $f)) { "WARNING: tracked but missing, not zipped: $f"; continue }
    $target = Join-Path $stage $f
    New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
    Copy-Item $f $target -Force
  }
  Compress-Archive -Path "$stage\*" -DestinationPath $ZipPath -Force
  "zip: $ZipPath ($([Math]::Round((Get-Item $ZipPath).Length / 1KB)) KB)"
  "--- review, then commit and publish:"
  git status --short
  "  gh release create <tag> '$ZipPath' --repo goranbalsic/arma-reforger-mod-downloader --title '<title>' --notes '<notes>'"
} finally { Pop-Location; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
