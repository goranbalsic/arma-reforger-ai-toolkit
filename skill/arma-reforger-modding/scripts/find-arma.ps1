# Resolve the Arma Reforger / Workbench / preset paths on this machine.
# Dot-source this file, then call Find-Arma. Nothing here writes to disk.
function Find-Arma {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) {
        $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    }
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }

    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $libraries += [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value.Replace('\\', '\') }
    }

    $workbench = $null
    $gameAddons = $null
    foreach ($lib in $libraries) {
        $w = Join-Path $lib 'steamapps\common\Arma Reforger Tools\Workbench\ArmaReforgerWorkbenchSteamDiag.exe'
        if (-not $workbench -and (Test-Path $w)) { $workbench = $w }
        $g = Join-Path $lib 'steamapps\common\Arma Reforger\addons'
        if (-not $gameAddons -and (Test-Path $g)) { $gameAddons = $g }
    }

    $userAddons = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\addons'
    $settings = Get-ChildItem (Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\profile\.save') `
        -Directory -Filter 'app*_user*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'settings\ReforgerGameSettings.conf' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1

    [pscustomobject]@{
        Steam       = $steam
        Workbench   = $workbench
        GameAddons  = $gameAddons
        UserAddons  = $userAddons
        Settings    = $settings
    }
}
