function Write-BatStub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ToolName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Content,

        [Parameter(Mandatory = $false)]
        [string]$ToolsDir
    )

    if (-not $PSBoundParameters.ContainsKey("ToolsDir")) {
        $ToolsDir = Get-Variable -Name ToolsDir -Scope 1 -ValueOnly
    }

    $batDest = Join-Path $ToolsDir "$ToolName.bat"
    Set-Content -Path $batDest -Value $Content -Encoding ASCII
    Write-Host "  [bat]  $batDest" -ForegroundColor Green

    $bashDest = Join-Path $ToolsDir $ToolName
    $bashContent = @'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/__TOOL_NAME__.bat" "$@"
'@.Replace("__TOOL_NAME__", $ToolName)
    Set-Content -Path $bashDest -Value $bashContent -Encoding ASCII
    Write-Host "  [bash] $bashDest" -ForegroundColor Green
}

# PNG-in-ICO keeps the original alpha channel instead of converting via GetHicon.
function ConvertTo-Ico($pngPath, $icoPath) {
    $pngBytes = [System.IO.File]::ReadAllBytes($pngPath)
    $stream = [System.IO.FileStream]::new($icoPath, [System.IO.FileMode]::Create)
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
        $writer.Write([byte]16); $writer.Write([byte]16); $writer.Write([byte]0)
        $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$pngBytes.Length); $writer.Write([uint32]22)
        $writer.Write($pngBytes)
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Get-ShortcutNames {
    # Keep the original four search aliases, translated to the standalone name.
    @('Right Click Tidy', 'RightClickTidy', 'rct', 'right-click-tidy')
}
