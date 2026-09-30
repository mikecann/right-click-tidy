param(
    [string]$ToolsDir = 'C:\dev\tools',
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Right Click Tidy requires Windows.' }
. (Join-Path $PSScriptRoot 'install-lib.ps1')

# Check the target before removal so a different clone's install stays intact.
$vbsPath = Join-Path $PSScriptRoot 'right-click-tidy.vbs'
$batPath = Join-Path $ToolsDir 'right-click-tidy.bat'
if ((Test-Path -LiteralPath $batPath) -and
    (Get-Content -LiteralPath $batPath -Raw).Contains("wscript.exe `"$vbsPath`"")) {
    Remove-Item -LiteralPath $batPath -Force
    $bashPath = Join-Path $ToolsDir 'right-click-tidy'
    if ((Test-Path -LiteralPath $bashPath) -and
        (Get-Content -LiteralPath $bashPath -Raw).Contains('exec "$SCRIPT_DIR/right-click-tidy.bat" "$@"')) {
        Remove-Item -LiteralPath $bashPath -Force
    }
}

$wsh = New-Object -ComObject WScript.Shell
$shortcutPaths = @(Get-ShortcutNames | ForEach-Object { Join-Path $StartMenuDir "$_.lnk" })
$shortcutPaths += Join-Path $ToolsDir 'Right Click Tidy.lnk'
foreach ($path in $shortcutPaths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $shortcut = $wsh.CreateShortcut($path)
    if ($shortcut.Arguments -eq "`"$vbsPath`"" -and $shortcut.WorkingDirectory -eq $PSScriptRoot) {
        Remove-Item -LiteralPath $path -Force
    }
}

# PATH is shared with other tools. Registry toggles are the user's choices.
# Neither belongs to the launcher install, so leave both alone.
Write-Host 'Removed Right Click Tidy launchers and shortcuts for this clone.' -ForegroundColor Green
