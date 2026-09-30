# Agent guidance

This repo is Right Click Tidy, a Windows Explorer context menu manager written
in PowerShell with built-in .NET WinForms. All source lives at the repo root.

## Working here

- Keep source in this clone. `C:\dev\tools` holds generated launchers and
  shortcuts, never source files. Do not commit `.exe` or `.dll` binaries.
- Use test-first development for non-trivial behaviour changes. If there is
  no clean test seam, extract one first and add the test.
- Update tests when behaviour, UI copy, layout, persistence, startup or other
  tested contracts change, then rerun the relevant tests.
- Before committing, parse every `.ps1`, run the tests below, then run the
  actual tool on Windows. Check exit codes. On other platforms, report which
  Windows checks could not run.
- GUI launches must use `right-click-tidy.vbs` through `wscript.exe` with
  window style 0. Do not point shortcuts straight at PowerShell, which can
  flash a console window.
- Generated `.bat` files must use `-Encoding ASCII`. Keep their content ASCII.
- `deps.ps1` must be idempotent, self-contained and give clear output. The
  installer runs it unless `-SkipDeps` is passed. This tool has no external
  dependencies or API keys.
- Re-run `install.ps1` when changing installed shortcut/launcher definitions
  or moving the clone. Ordinary source edits are picked up by the launchers.
- Do not add UI eyebrows or kickers. Keep docs plain and friendly, without
  em dashes. PR descriptions start with `## Why` and explain the reason.

## Right Click Tidy specifics

- `right-click-tidy.ps1` contains registry scanning, per-user toggles and the
  owner-drawn menu preview. `right-click-tidy.vbs` starts it silently.
- All registry writes must stay in HKCU. Scan HKCU and HKLM; never change HKLM
  or require elevation for toggles.
- Static verbs use `LegacyDisable` on HKCU shadow keys. COM handlers use
  `Shell Extensions\Blocked` CLSIDs. Open With registrations use `NoOpenWith`.
  Preserve compatibility with legacy negative CLSID markers.
- User choices live in Windows registry entries, with no tool-specific config
  directory. Uninstall removes launchers and shortcuts, not those choices.
- Keep icons under `icons/`; do not import assets from sibling repos. These
  PNGs are from Mark James's famfamfam silk set, CC BY 2.5. Keep the README
  attribution when changing them.
- Installer tests use temporary clone, tools and Start Menu directories. Do
  not run a normal install on CI. Uninstall must preserve unrelated files,
  shared PATH entries and shortcuts owned by a different clone. This tool
  has no Explorer menu registration, so its installer must not alter the
  shared Mike's Tools submenu.

## Checks

Run these on Windows, in separate PowerShell processes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-install-lib.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-tests.ps1
wscript.exe ".\right-click-tidy.vbs"
```

`test-install-lib.ps1` also runs under `pwsh` on macOS. CI parses all `.ps1`
files, runs the installer checks and exercises the registry tests on Windows.
`diag.ps1`, `diag2.ps1` and `test-compare.ps1` are optional Windows diagnostics;
the comparison script needs a real file and shell COM support.
