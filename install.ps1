# Install from this clone. Launchers continue to use the live source files.
param(
    [switch]$SkipDeps,
    [switch]$SkipPathCheck,
    [string]$ToolsDir = 'C:\dev\tools',
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Right Click Tidy requires Windows.' }
. (Join-Path $PSScriptRoot 'install-lib.ps1')

if (-not $SkipDeps) { & (Join-Path $PSScriptRoot 'deps.ps1') }
foreach ($dir in @($ToolsDir, $StartMenuDir)) {
    [void](New-Item -ItemType Directory -Path $dir -Force)
}

$vbsPath = Join-Path $PSScriptRoot 'right-click-tidy.vbs'
Write-BatStub 'right-click-tidy' @"
@echo off
wscript.exe "$vbsPath"
"@ -ToolsDir $ToolsDir

$icoPath = Join-Path $PSScriptRoot 'icons\right-click-tidy.ico'
ConvertTo-Ico (Join-Path $PSScriptRoot 'icons\right-click-tidy.png') $icoPath
$wsh = New-Object -ComObject WScript.Shell
$shortcutPaths = @(Get-ShortcutNames | ForEach-Object { Join-Path $StartMenuDir "$_.lnk" })
$shortcutPaths += Join-Path $ToolsDir 'Right Click Tidy.lnk'
foreach ($path in $shortcutPaths) {
    $shortcut = $wsh.CreateShortcut($path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = 'Right Click Tidy'
    $shortcut.IconLocation = $icoPath
    $shortcut.Save()
    Write-Host "  [lnk] $path" -ForegroundColor Green
}

if (-not $SkipPathCheck) {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onPath = ($machinePath -split ';') + ($userPath -split ';') |
        Where-Object { $_.TrimEnd('\') -ieq $ToolsDir.TrimEnd('\') }
    if (-not $onPath) {
        $answer = Read-Host "Add '$ToolsDir' to your user PATH? [Y/n]"
        if ($answer -eq '' -or $answer -imatch '^y') {
            $newUserPath = ("$userPath".TrimEnd(';') + ";$ToolsDir").TrimStart(';')
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
            $env:PATH += ";$ToolsDir"
            Write-Host 'Open a new terminal to use right-click-tidy.' -ForegroundColor Green
        }
    }
}

Write-Host 'Installed Right Click Tidy. Pin the shortcut in your tools directory to the taskbar if you like.' -ForegroundColor Green
