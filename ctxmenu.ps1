# ctxmenu.ps1 - Windows Explorer context menu manager
#
# Shows shell verbs and COM extension handlers from the registry.
# Toggle entries on/off using HKCU shadow keys - no admin rights needed,
# because Windows merges HKCU on top of HKLM when building HKCR.
#
# Disable mechanisms:
#   Static verbs   - add LegacyDisable (REG_SZ, empty) to the verb key
#   COM handlers   - prefix the CLSID value with '-' in the handler key

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── Model ─────────────────────────────────────────────────────────────────────
Add-Type @'
public class CmEntry {
    public string VerbName;     // registry key name
    public string Label;        // friendly display name
    public string AppliesTo;    // "All Files", "Folders", "Video Files", etc.
    public string Source;       // "HKCU" or "HKLM"
    public string Kind;         // "Verb" or "ShellEx"
    public string ReadPath;     // full HKEY_xxx\... path for reading
    public string ShadowPath;   // HKCU subkey path to write disable value into
    public bool   Enabled;
    public bool   IsSubmenu;
    public string ClsId;        // ShellEx only - clean {GUID} without leading -
}
'@

# ── Registry helpers ──────────────────────────────────────────────────────────
function rOpen([string]$fullPath) {
    $parts = $fullPath -split '\\', 2
    if ($parts.Count -lt 2) { return $null }
    $root = switch ($parts[0]) {
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_CURRENT_USER'  { [Microsoft.Win32.Registry]::CurrentUser  }
        'HKEY_CLASSES_ROOT'  { [Microsoft.Win32.Registry]::ClassesRoot  }
        default              { return $null }
    }
    if (-not $root) { return $null }
    return $root.OpenSubKey($parts[1], $false)
}

function rLabel([Microsoft.Win32.RegistryKey]$k) {
    foreach ($name in @('MUIVerb', '')) {
        $v = $k.GetValue($name)
        if ($v -and [string]$v -ne '') { return [string]$v }
    }
    return $k.Name.Split('\')[-1]
}

function hkuShadow([string]$hive, [string]$subPath) {
    if ($hive -eq 'HKCU') { return $subPath }
    return $subPath -replace '^SOFTWARE\\Classes\\', 'Software\Classes\'
}

function isVerbDisabled([string]$readPath, [string]$shadow) {
    foreach ($p in @($readPath, "HKEY_CURRENT_USER\$shadow")) {
        $k = rOpen $p
        if ($k) {
            $dis = $k.GetValueNames() -icontains 'LegacyDisable'
            $k.Close()
            if ($dis) { return $true }
        }
    }
    return $false
}

function isShellExDisabled([string]$readPath, [string]$shadow) {
    # HKCU shadow takes priority - check it first
    foreach ($p in @("HKEY_CURRENT_USER\$shadow", $readPath)) {
        $k = rOpen $p
        if ($k) {
            $v = [string]$k.GetValue('')
            $k.Close()
            if ($v) { return $v.StartsWith('-') }
        }
    }
    return $false
}

# ── Scanners ──────────────────────────────────────────────────────────────────
function scanVerbs([string]$hive, [string]$subPath, [string]$appliesTo) {
    $results = [System.Collections.Generic.List[CmEntry]]::new()
    $hiveWord = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
    $shell = rOpen "$hiveWord\$subPath"
    if (-not $shell) { return $results }

    $shBase = hkuShadow $hive $subPath

    foreach ($verb in $shell.GetSubKeyNames()) {
        try {
            $vk = $shell.OpenSubKey($verb)
            if (-not $vk) { continue }
            $label     = rLabel $vk
            $isSubmenu = $null -ne $vk.GetValue('SubCommands')
            $vk.Close()

            $e = [CmEntry]::new()
            $e.VerbName   = $verb
            $e.Label      = $label
            $e.AppliesTo  = $appliesTo
            $e.Source     = $hive
            $e.Kind       = 'Verb'
            $e.ReadPath   = "$hiveWord\$subPath\$verb"
            $e.ShadowPath = "$shBase\$verb"
            $e.Enabled    = -not (isVerbDisabled $e.ReadPath $e.ShadowPath)
            $e.IsSubmenu  = $isSubmenu
            $results.Add($e)
        } catch { }
    }
    $shell.Close()
    return $results
}

function scanShellEx([string]$hive, [string]$subPath, [string]$appliesTo) {
    $results = [System.Collections.Generic.List[CmEntry]]::new()
    $hiveWord = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
    $handlers = rOpen "$hiveWord\$subPath"
    if (-not $handlers) { return $results }

    $shBase = hkuShadow $hive $subPath

    foreach ($name in $handlers.GetSubKeyNames()) {
        try {
            $hk = $handlers.OpenSubKey($name)
            if (-not $hk) { continue }
            $clsidRaw = [string]$hk.GetValue('')
            $hk.Close()
            if (-not $clsidRaw) { continue }

            $clsidClean = $clsidRaw.TrimStart('-')
            # Get friendly label from CLSID registry
            $label = $name
            $ck = rOpen "HKEY_CLASSES_ROOT\CLSID\$clsidClean"
            if ($ck) {
                $fn = [string]$ck.GetValue('')
                if ($fn) { $label = "$name  [$fn]" }
                $ck.Close()
            }

            $e = [CmEntry]::new()
            $e.VerbName   = $name
            $e.Label      = $label
            $e.AppliesTo  = $appliesTo
            $e.Source     = $hive
            $e.Kind       = 'ShellEx'
            $e.ReadPath   = "$hiveWord\$subPath\$name"
            $e.ShadowPath = "$shBase\$name"
            $e.ClsId      = $clsidClean
            $e.Enabled    = -not (isShellExDisabled $e.ReadPath $e.ShadowPath)
            $results.Add($e)
        } catch { }
    }
    $handlers.Close()
    return $results
}

function getExtEntries([string[]]$exts, [string]$typeName) {
    # Scan per-extension SystemFileAssociations and de-duplicate by VerbName
    # so "MikesTools" on 14 video extensions shows up as one row, not 14.
    $seen    = [System.Collections.Generic.Dictionary[string,CmEntry]]::new()
    $shadows = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()

    foreach ($ext in $exts) {
        foreach ($hive in @('HKCU', 'HKLM')) {
            $hiveWord = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
            $sub  = if ($hive -eq 'HKLM') { "SOFTWARE\Classes\SystemFileAssociations\$ext\shell" } `
                    else                   { "Software\Classes\SystemFileAssociations\$ext\shell" }
            $shell = rOpen "$hiveWord\$sub"
            if (-not $shell) { continue }

            foreach ($verb in $shell.GetSubKeyNames()) {
                try {
                    $vk = $shell.OpenSubKey($verb)
                    if (-not $vk) { continue }
                    $label     = rLabel $vk
                    $isSubmenu = $null -ne $vk.GetValue('SubCommands')
                    $vk.Close()

                    $shPath = "Software\Classes\SystemFileAssociations\$ext\shell\$verb"

                    if (-not $seen.ContainsKey($verb)) {
                        $e = [CmEntry]::new()
                        $e.VerbName   = $verb
                        $e.Label      = $label
                        $e.AppliesTo  = $typeName
                        $e.Source     = $hive
                        $e.Kind       = 'Verb'
                        $e.ReadPath   = "$hiveWord\$sub\$verb"
                        $e.ShadowPath = $shPath   # first ext's path (used for status check)
                        $e.Enabled    = -not (isVerbDisabled $e.ReadPath $e.ShadowPath)
                        $e.IsSubmenu  = $isSubmenu
                        $seen[$verb]    = $e
                        $shadows[$verb] = [System.Collections.Generic.List[string]]::new()
                    }
                    $shadows[$verb].Add($shPath)
                } catch { }
            }
            $shell.Close()
        }
    }

    # Attach all shadow paths to the entry (stored as semicolon list in ShadowPath)
    foreach ($verb in $seen.Keys) {
        $seen[$verb].ShadowPath = ($shadows[$verb] | Sort-Object -Unique) -join ';'
    }
    return $seen.Values
}

function getAllEntries {
    $all = [System.Collections.Generic.List[CmEntry]]::new()

    $addAll = { param($col) foreach ($e in $col) { if ($e) { $all.Add($e) } } }

    # Static verbs
    @(
        @('HKLM','SOFTWARE\Classes\*\shell',                    'All Files'),
        @('HKCU','Software\Classes\*\shell',                    'All Files'),
        @('HKLM','SOFTWARE\Classes\Directory\shell',            'Folders'),
        @('HKCU','Software\Classes\Directory\shell',            'Folders'),
        @('HKLM','SOFTWARE\Classes\Directory\Background\shell', 'Folder Background'),
        @('HKCU','Software\Classes\Directory\Background\shell', 'Folder Background'),
        @('HKLM','SOFTWARE\Classes\Drive\shell',                'Drives'),
        @('HKCU','Software\Classes\Drive\shell',                'Drives')
    ) | ForEach-Object { & $addAll (scanVerbs $_[0] $_[1] $_[2]) }

    # COM shell extension handlers
    @(
        @('HKLM','SOFTWARE\Classes\*\shellex\ContextMenuHandlers',                    'All Files'),
        @('HKCU','Software\Classes\*\shellex\ContextMenuHandlers',                    'All Files'),
        @('HKLM','SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers',            'Folders'),
        @('HKCU','Software\Classes\Directory\shellex\ContextMenuHandlers',            'Folders'),
        @('HKLM','SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers', 'Folder Background'),
        @('HKCU','Software\Classes\Directory\Background\shellex\ContextMenuHandlers', 'Folder Background')
    ) | ForEach-Object { & $addAll (scanShellEx $_[0] $_[1] $_[2]) }

    # Per-extension entries, grouped by type
    $videoExts = @('.mp4','.mkv','.avi','.mov','.wmv','.webm','.m4v','.mpg','.mpeg','.ts','.mts','.m2ts','.flv','.f4v')
    $imageExts = @('.jpg','.jpeg','.png','.webp','.bmp','.tiff','.tif')
    & $addAll (getExtEntries $videoExts 'Video Files')
    & $addAll (getExtEntries $imageExts 'Image Files')

    return $all
}

# ── Apply enable/disable ──────────────────────────────────────────────────────
function applyEntry([CmEntry]$entry, [bool]$enable) {
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser

    if ($entry.Kind -eq 'Verb') {
        # ShadowPath may be a semicolon-delimited list for per-ext entries
        foreach ($shadow in ($entry.ShadowPath -split ';')) {
            try {
                $k = $hkcu.OpenSubKey($shadow, $true)
                if (-not $k -and -not $enable) { $k = $hkcu.CreateSubKey($shadow) }
                if ($k) {
                    if ($enable) { try { $k.DeleteValue('LegacyDisable') } catch { } }
                    else         { $k.SetValue('LegacyDisable', '', [Microsoft.Win32.RegistryValueKind]::String) }
                    $k.Close()
                }
            } catch { }
        }
    } elseif ($entry.Kind -eq 'ShellEx') {
        try {
            $k = $hkcu.OpenSubKey($entry.ShadowPath, $true)
            if (-not $k) { $k = $hkcu.CreateSubKey($entry.ShadowPath) }
            if ($k) {
                $val = if ($enable) { $entry.ClsId } else { "-$($entry.ClsId)" }
                $k.SetValue('', $val, [Microsoft.Win32.RegistryValueKind]::String)
                $k.Close()
            }
        } catch { }
    }
}

function notifyShell {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class CtxShell {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);
}
'@ -ErrorAction SilentlyContinue
    try { [CtxShell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) } catch { }
}

# ── UI ────────────────────────────────────────────────────────────────────────
$script:entries = [CmEntry[]]@()

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Context Menu Manager'
$form.Size            = New-Object System.Drawing.Size(980, 580)
$form.MinimumSize     = New-Object System.Drawing.Size(700, 400)
$form.StartPosition   = 'CenterScreen'
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

# ── Top toolbar ──
$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock          = 'Top'
$toolbar.Height        = 38
$toolbar.Padding       = New-Object System.Windows.Forms.Padding(6, 6, 6, 0)
$toolbar.FlowDirection = 'LeftToRight'
$toolbar.WrapContents  = $false

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text      = 'Show:'
$lblFilter.AutoSize  = $true
$lblFilter.Anchor    = 'Left'
$lblFilter.Margin    = New-Object System.Windows.Forms.Padding(0, 3, 4, 0)

$cbFilter = New-Object System.Windows.Forms.ComboBox
$cbFilter.DropDownStyle = 'DropDownList'
$cbFilter.Width         = 160
$cbFilter.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$cbFilter.Items.AddRange(@('All', 'All Files', 'Folders', 'Folder Background', 'Video Files', 'Image Files', 'Drives'))
$cbFilter.SelectedIndex = 0

$chkDisabled = New-Object System.Windows.Forms.CheckBox
$chkDisabled.Text    = 'Show disabled'
$chkDisabled.Checked = $true
$chkDisabled.Margin  = New-Object System.Windows.Forms.Padding(0, 2, 12, 0)
$chkDisabled.AutoSize = $true

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text   = 'Refresh'
$btnRefresh.Width  = 70
$btnRefresh.Height = 24

$toolbar.Controls.AddRange(@($lblFilter, $cbFilter, $chkDisabled, $btnRefresh))

# ── ListView ──
$lv = New-Object System.Windows.Forms.ListView
$lv.Dock          = 'Fill'
$lv.View          = 'Details'
$lv.CheckBoxes    = $true
$lv.FullRowSelect = $true
$lv.GridLines     = $true
$lv.Sorting       = 'Ascending'
[void]$lv.Columns.Add('Name',        220)
[void]$lv.Columns.Add('Applies To',  130)
[void]$lv.Columns.Add('Kind',         60)
[void]$lv.Columns.Add('Source',       55)
[void]$lv.Columns.Add('Status',       70)
[void]$lv.Columns.Add('Registry Key', 340)

# ── Bottom bar ──
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock   = 'Bottom'
$bottom.Height = 38

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Text   = 'Enable Selected'
$btnEnable.Width  = 115
$btnEnable.Height = 26
$btnEnable.Left   = 6
$btnEnable.Top    = 6

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text   = 'Disable Selected'
$btnDisable.Width  = 120
$btnDisable.Height = 26
$btnDisable.Left   = 128
$btnDisable.Top    = 6

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $true
$lblStatus.Left     = 262
$lblStatus.Top      = 11
$lblStatus.Text     = 'Loading...'
$lblStatus.ForeColor = [System.Drawing.Color]::Gray

$bottom.Controls.AddRange(@($btnEnable, $btnDisable, $lblStatus))

$form.Controls.AddRange(@($toolbar, $bottom, $lv))

# ── Populate list ──
function populateList {
    $lv.BeginUpdate()
    $lv.Items.Clear()

    $filter      = $cbFilter.SelectedItem
    $showDisabled = $chkDisabled.Checked

    $shown = 0; $disabled = 0

    foreach ($e in $script:entries) {
        if ($filter -ne 'All' -and $e.AppliesTo -ne $filter) { continue }
        if (-not $showDisabled -and -not $e.Enabled) { continue }

        $item = New-Object System.Windows.Forms.ListViewItem($e.Label)
        $item.Checked = $e.Enabled
        $item.Tag     = $e

        $kindLabel = if ($e.Kind -eq 'ShellEx') { 'COM' } else { if ($e.IsSubmenu) { 'Submenu' } else { 'Verb' } }
        $statusTxt = if ($e.Enabled) { 'Enabled' } else { 'Disabled' }

        [void]$item.SubItems.Add($e.AppliesTo)
        [void]$item.SubItems.Add($kindLabel)
        [void]$item.SubItems.Add($e.Source)
        [void]$item.SubItems.Add($statusTxt)
        [void]$item.SubItems.Add($e.ReadPath)

        if (-not $e.Enabled) {
            $item.ForeColor = [System.Drawing.Color]::Gray
            $disabled++
        }

        [void]$lv.Items.Add($item)
        $shown++
    }

    $lv.EndUpdate()
    $total = $script:entries.Count
    $lblStatus.Text = "$shown shown  |  $disabled disabled  |  $total total"
}

function reloadEntries {
    $lblStatus.Text = 'Scanning registry...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lv.Items.Clear()
    $form.Refresh()
    try {
        $script:entries = getAllEntries
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    populateList
}

# ── Event handlers ──
$lv.add_ItemCheck({
    param($s, $e)
    # Prevent the checkbox from changing directly - use the buttons instead
    # so the user doesn't accidentally toggle something by clicking the checkbox
    # while browsing. Actually, let's allow it but apply immediately.
    $item = $lv.Items[$e.Index]
    $entry = [CmEntry]$item.Tag
    $newEnabled = ($e.NewValue -eq 'Checked')
    applyEntry $entry $newEnabled
    $entry.Enabled = $newEnabled
    $item.ForeColor = if ($newEnabled) { [System.Drawing.SystemColors]::WindowText } else { [System.Drawing.Color]::Gray }
    $item.SubItems[4].Text = if ($newEnabled) { 'Enabled' } else { 'Disabled' }
    # Deferred shell notify
    $script:pendingNotify = $true
})

$lv.add_ItemChecked({
    if ($script:pendingNotify) {
        $script:pendingNotify = $false
        notifyShell
        $disabled = ($lv.Items | Where-Object { -not $_.Checked }).Count
        $lblStatus.Text = "$($lv.Items.Count) shown  |  $disabled disabled  |  $($script:entries.Count) total"
    }
})

$btnEnable.add_Click({
    foreach ($item in $lv.CheckedItems) { }  # unused - see below
    $changed = $false
    foreach ($item in @($lv.SelectedItems)) {
        $entry = [CmEntry]$item.Tag
        if (-not $entry.Enabled) {
            applyEntry $entry $true
            $entry.Enabled = $true
            $item.Checked  = $true
            $item.ForeColor = [System.Drawing.SystemColors]::WindowText
            $item.SubItems[4].Text = 'Enabled'
            $changed = $true
        }
    }
    if ($changed) { notifyShell; populateList }
})

$btnDisable.add_Click({
    $changed = $false
    foreach ($item in @($lv.SelectedItems)) {
        $entry = [CmEntry]$item.Tag
        if ($entry.Enabled) {
            applyEntry $entry $false
            $entry.Enabled = $false
            $item.Checked  = $false
            $item.ForeColor = [System.Drawing.Color]::Gray
            $item.SubItems[4].Text = 'Disabled'
            $changed = $true
        }
    }
    if ($changed) { notifyShell; populateList }
})

$btnRefresh.add_Click({ reloadEntries })
$cbFilter.add_SelectedIndexChanged({ populateList })
$chkDisabled.add_CheckedChanged({ populateList })

$form.add_Shown({ reloadEntries })

[void]$form.ShowDialog()
