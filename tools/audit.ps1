# Static checks for this repo: PowerShell, Python, secrets.
#   powershell -File tools\audit.ps1          # fast tier (seconds)
#   powershell -File tools\audit.ps1 -Deep    # + semgrep / trivy when installed
# Exits 1 when something is reported. Never edits files.
param([switch]$Deep)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$fail = 0
function Section($name) { Write-Host "`n== $name" -ForegroundColor Cyan }

# --- PowerShell: real errors only (warnings are style noise) ----------------
Section 'PSScriptAnalyzer (PowerShell errors)'
# the module may be installed for PowerShell 7 only; it loads fine in 5.1
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    $p7 = Get-ChildItem "$env:USERPROFILE\Documents\PowerShell\Modules\PSScriptAnalyzer" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($p7) { try { Import-Module (Join-Path $p7.FullName 'PSScriptAnalyzer.psd1') -ErrorAction Stop } catch { } }
}
if (Get-Module PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
    $issues = @(Get-ChildItem $repo -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error -ErrorAction SilentlyContinue })
    if ($issues.Count) {
        $issues | Group-Object ScriptName | ForEach-Object {
            Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) -ForegroundColor Red
            $_.Group | Select-Object -First 3 | ForEach-Object { Write-Host "    line $($_.Line): $($_.Message)" -ForegroundColor Yellow }
        }
        $fail++
    } else { Write-Host '  clean' -ForegroundColor Green }
} else { Write-Host '  skipped (Install-Module PSScriptAnalyzer -Scope CurrentUser)' -ForegroundColor DarkGray }

# --- Python: syntax + undefined names --------------------------------------
Section 'ruff (Python syntax / undefined names)'
$ruff = Get-Command ruff -ErrorAction SilentlyContinue
# a string path for the fallback: FileInfo has no .Source, and `& $null` only
# errors into the pipeline, which used to leave the section looking clean
if (-not $ruff -and (Test-Path "$env:USERPROFILE\.local\bin\ruff.exe")) { $ruff = "$env:USERPROFILE\.local\bin\ruff.exe" }
if ($ruff) {
    $pyDirs = @('tools', 'skill\arma-reforger-modding\scripts') | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path $_ }
    $LASTEXITCODE = -1
    $out = & $ruff check --select E9,F --quiet @pyDirs 2>&1
    if ($LASTEXITCODE -ne 0) { $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; $fail++ }
    else { Write-Host '  clean' -ForegroundColor Green }
} else { Write-Host '  skipped (uv tool install ruff)' -ForegroundColor DarkGray }

# --- Secrets in the working tree -------------------------------------------
Section 'gitleaks (secrets)'
$leaks = Get-Command gitleaks -ErrorAction SilentlyContinue
if ($leaks) {
    & $leaks.Source detect --no-git --redact --source $repo --max-target-megabytes 2 --no-banner 2>&1 |
        Select-Object -Last 12 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    if ($LASTEXITCODE -ne 0) { Write-Host '  findings above (or scan error)' -ForegroundColor Red; $fail++ }
    else { Write-Host '  clean' -ForegroundColor Green }
} else { Write-Host '  skipped (winget install gitleaks.gitleaks)' -ForegroundColor DarkGray }

# --- Optional deep tier -----------------------------------------------------
if ($Deep) {
    Section 'semgrep (security patterns)'
    $sg = Get-Command semgrep -ErrorAction SilentlyContinue
    if (-not $sg -and (Test-Path "$env:USERPROFILE\.local\bin\semgrep.exe")) { $sg = "$env:USERPROFILE\.local\bin\semgrep.exe" }
    if ($sg) {
        # p/powershell does NOT exist on the registry (404) - these do
        $LASTEXITCODE = -1
        $out = & $sg --config p/ci --config p/secrets --config p/python --quiet --error --exclude .git --exclude context --exclude work $repo 2>&1
        $code = $LASTEXITCODE
        if ($out) { $out | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
        if ($code -eq 0) { Write-Host '  clean' -ForegroundColor Green }
        elseif ($code -eq 1) { Write-Host '  findings above' -ForegroundColor Red; $fail++ }
        else { Write-Host "  semgrep could not run (exit $code - rule download or config error)" -ForegroundColor Red; $fail++ }
    } else { Write-Host '  skipped (uv tool install semgrep)' -ForegroundColor DarkGray }

    Section 'trivy (dependencies / secrets)'
    $tv = Get-Command trivy -ErrorAction SilentlyContinue
    if ($tv) {
        $env:TRIVY_DB_REPOSITORY = 'ghcr.io/aquasecurity/trivy-db'
        $out = & $tv.Source fs --quiet --scanners vuln,secret --timeout 5m --skip-dirs .git --skip-dirs context --skip-dirs work $repo 2>&1
        $code = $LASTEXITCODE
        if ($out) { $out | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
        if ($code -eq 0) { Write-Host '  clean' -ForegroundColor Green }
        elseif ($out -match 'failed to download vulnerability DB|DB error') {
            # ~100 MB OCI artifact; on a slow link this times out. Not a code finding.
            Write-Host '  skipped: vulnerability DB not downloaded (slow link). Run `trivy fs --download-db-only`. ' -ForegroundColor DarkGray
        }
        else { $fail++ }
    } else { Write-Host '  skipped (winget install aquasecurity.trivy)' -ForegroundColor DarkGray }
}

Write-Host ''
if ($fail) { Write-Host "audit: $fail check(s) reported findings" -ForegroundColor Red; exit 1 }
Write-Host 'audit: clean' -ForegroundColor Green
