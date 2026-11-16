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
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if ($p7) {
        try { Import-Module (Join-Path $p7.FullName 'PSScriptAnalyzer.psd1') -ErrorAction Stop }
        catch {
            # silence here meant "the only PowerShell analysis did not run" and the
            # audit still finished green
            Write-Host "  PSScriptAnalyzer could not load: $($_.Exception.Message)" -ForegroundColor Red
            $fail++
        }
    }
}
if (Get-Module PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
    # Error severity plus every warning rule except the pure style ones: a shadowed
    # automatic variable ($Profile, $args, $Error) or a variable/parameter that is
    # written and never read is a defect, and this used to be the documented promise
    # that -Severity Error alone could not keep.
    $styleRules = 'PSAvoidUsingWriteHost', 'PSAvoidUsingEmptyCatchBlock', 'PSUseSingularNouns',
                  'PSUseShouldProcessForStateChangingFunctions', 'PSUseBOMForUnicodeEncodedFile'
    $issues = @(Get-ChildItem $repo -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error, Warning -ExcludeRule $styleRules -ErrorAction SilentlyContinue })
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
    $LASTEXITCODE = -1   # a failed launch must not read as clean
    & $leaks detect --no-git --redact --source $repo --max-target-megabytes 2 --no-banner 2>&1 |
        Select-Object -Last 12 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    if ($LASTEXITCODE -ne 0) { Write-Host '  findings above (or scan error)' -ForegroundColor Red; $fail++ }
    else { Write-Host '  clean' -ForegroundColor Green }
} else { Write-Host '  skipped (winget install gitleaks.gitleaks)' -ForegroundColor DarkGray }

# --- Dashboard page JavaScript ---------------------------------------------
Section 'node --check (dashboard page JavaScript)'
# the page script lives in a here-string inside download-web.ps1; a syntax slip
# there leaves the whole UI stuck at "connecting to dashboard..." and no other
# check catches it without the dashboard running
$dw = Join-Path $repo 'mod-manager\download-web.ps1'
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Write-Host '  skipped (install node)' -ForegroundColor DarkGray }
elseif (-not (Test-Path $dw)) { Write-Host '  skipped (mod-manager\download-web.ps1 not found)' -ForegroundColor DarkGray }
else {
    $m = [regex]::Match((Get-Content $dw -Raw), "(?s)\`$html = @'(.*?)'\@")
    $js = if ($m.Success) { [regex]::Match($m.Groups[1].Value, '(?s)<script>(.*)</script>').Groups[1].Value } else { '' }
    if (-not $js) { Write-Host '  page here-string not found - did the layout change?' -ForegroundColor Red; $fail++ }
    else {
        $tmpJs = Join-Path ([IO.Path]::GetTempPath()) 'rfmm-audit-page.js'
        Set-Content $tmpJs $js -Encoding UTF8
        $LASTEXITCODE = -1
        $o = & $node --check $tmpJs 2>&1
        if ($LASTEXITCODE -ne 0) { $o | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; $fail++ }
        else { Write-Host '  clean' -ForegroundColor Green }
        Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
    }
}

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
    if (-not $tv -and (Test-Path "$env:USERPROFILE\.local\bin\trivy.exe")) { $tv = "$env:USERPROFILE\.local\bin\trivy.exe" }
    if ($tv) {
        $env:TRIVY_DB_REPOSITORY = 'ghcr.io/aquasecurity/trivy-db'
        $LASTEXITCODE = -1
        $out = & $tv fs --quiet --scanners vuln,secret --timeout 5m --skip-dirs .git --skip-dirs context --skip-dirs work $repo 2>&1
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
