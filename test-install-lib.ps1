param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-lib.ps1')

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
[void](New-Item -ItemType Directory -Path $tempDir)
try {
    $content = "@echo off`r`nwscript.exe `"C:\a folder\right-click-tidy.vbs`""
    Write-BatStub 'right-click-tidy' $content -ToolsDir $tempDir
    $batPath = Join-Path $tempDir 'right-click-tidy.bat'
    $bytes = [System.IO.File]::ReadAllBytes($batPath)
    Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'BAT must contain only ASCII bytes.'
    Assert-True ((Get-Content $batPath -Raw).TrimEnd() -eq $content) 'BAT must preserve the quoted launcher path.'
    $bash = Get-Content (Join-Path $tempDir 'right-click-tidy') -Raw
    Assert-True ($bash.Contains('exec "$SCRIPT_DIR/right-click-tidy.bat" "$@"')) 'Git Bash wrapper must forward arguments.'

    # Conversion must preserve PNG alpha by embedding its original bytes.
    $pngPath = Join-Path $PSScriptRoot 'icons/right-click-tidy.png'
    $icoPath = Join-Path $tempDir 'right-click-tidy.ico'
    ConvertTo-Ico $pngPath $icoPath
    $png = [System.IO.File]::ReadAllBytes($pngPath)
    $ico = [System.IO.File]::ReadAllBytes($icoPath)
    Assert-True ($ico.Length -eq $png.Length + 22) 'ICO must have a 22-byte header plus the PNG.'
    Assert-True ([BitConverter]::ToUInt16($ico, 2) -eq 1) 'ICO type must be an icon.'
    Assert-True ([BitConverter]::ToUInt16($ico, 4) -eq 1) 'ICO must contain one image.'
    Assert-True ([BitConverter]::ToUInt32($ico, 14) -eq $png.Length) 'ICO image length must match PNG.'
    Assert-True ([BitConverter]::ToUInt32($ico, 18) -eq 22) 'ICO image offset must be 22.'
    Assert-True ([Convert]::ToBase64String($ico[22..($ico.Length - 1)]) -eq [Convert]::ToBase64String($png)) 'ICO must preserve all PNG bytes.'
    Write-Host '[PASS] installer launcher and icon tests' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
