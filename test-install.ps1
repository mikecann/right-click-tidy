param()

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Installer integration tests require Windows.' }
. (Join-Path $PSScriptRoot 'install-lib.ps1')

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$toolsDir = Join-Path $tempDir 'tools with spaces'
$startMenuDir = Join-Path $tempDir 'Start Menu'
[void](New-Item -ItemType Directory -Path $toolsDir -Force)
try {
    # Run in a copied clone so icon generation cannot touch the real checkout.
    $clone = Join-Path $tempDir 'clone with spaces'
    [void](New-Item -ItemType Directory -Path (Join-Path $clone 'icons') -Force)
    foreach ($file in @('install.ps1', 'uninstall.ps1', 'install-lib.ps1', 'deps.ps1', 'right-click-tidy.vbs', 'right-click-tidy.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $clone
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'icons\right-click-tidy.png') -Destination (Join-Path $clone 'icons')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $otherTool = Join-Path $toolsDir 'other-tool.bat'
    Set-Content -LiteralPath $otherTool -Value '@echo other tool' -Encoding ASCII

    & (Join-Path $clone 'install.ps1') -ToolsDir $toolsDir -StartMenuDir $startMenuDir -SkipPathCheck
    & (Join-Path $clone 'install.ps1') -ToolsDir $toolsDir -StartMenuDir $startMenuDir -SkipPathCheck

    $wsh = New-Object -ComObject WScript.Shell
    $paths = @(Get-ShortcutNames | ForEach-Object { Join-Path $startMenuDir "$_.lnk" })
    $paths += Join-Path $toolsDir 'Right Click Tidy.lnk'
    foreach ($path in $paths) {
        Assert-True (Test-Path -LiteralPath $path) "Missing shortcut: $path"
        $shortcut = $wsh.CreateShortcut($path)
        Assert-True ($shortcut.TargetPath -like '*\wscript.exe') 'GUI shortcut must use the silent VBS launcher.'
        Assert-True ($shortcut.Arguments -eq "`"$(Join-Path $clone 'right-click-tidy.vbs')`"") 'Shortcut must quote this clone path.'
        Assert-True ($shortcut.WorkingDirectory -eq $clone) 'Shortcut must work from this clone.'
        Assert-True ($shortcut.IconLocation -like '*right-click-tidy.ico*') 'Shortcut must use the local icon.'
    }

    # A shortcut belonging to another clone must survive our uninstall.
    $foreignPath = $paths[0]
    $foreign = $wsh.CreateShortcut($foreignPath)
    $foreign.Arguments = '"C:\another clone\right-click-tidy.vbs"'
    $foreign.WorkingDirectory = 'C:\another clone'
    $foreign.Save()
    & (Join-Path $clone 'uninstall.ps1') -ToolsDir $toolsDir -StartMenuDir $startMenuDir
    Assert-True (Test-Path -LiteralPath $foreignPath) 'Uninstall must preserve another clone shortcut.'
    foreach ($path in $paths[1..($paths.Count - 1)]) {
        Assert-True (-not (Test-Path -LiteralPath $path)) "Uninstall left our shortcut: $path"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $toolsDir 'right-click-tidy.bat'))) 'Uninstall must remove our BAT.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $toolsDir 'right-click-tidy'))) 'Uninstall must remove our Git Bash wrapper.'
    Assert-True ((Get-Content -LiteralPath $otherTool).Trim() -eq '@echo other tool') 'Uninstall must preserve unrelated tools.'
    Assert-True ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $userPath) 'Isolated install/uninstall must not change user PATH.'

    $batPath = Join-Path $toolsDir 'right-click-tidy.bat'
    Set-Content -LiteralPath $batPath -Value 'wscript.exe "C:\another clone\right-click-tidy.vbs"' -Encoding ASCII
    & (Join-Path $clone 'uninstall.ps1') -ToolsDir $toolsDir -StartMenuDir $startMenuDir
    Assert-True (Test-Path -LiteralPath $batPath) 'Uninstall must preserve another clone BAT.'
    Write-Host '[PASS] isolated install, repeat install, and uninstall ownership tests' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
