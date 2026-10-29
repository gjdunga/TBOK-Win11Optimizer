#Requires -Version 5.1
<#
.SYNOPSIS
  Updates installed apps with winget. Runs in the USER's context from a logon
  scheduled task, because winget is a per-user app alias and does not exist for
  the SYSTEM account (so it cannot run in the SYSTEM boot task).

.NOTES
  - Resolves winget.exe from its WindowsApps location, since a scheduled task's
    PATH does not always include the alias directory.
  - Logs to the user's TEMP (a standard user cannot write to the SYSTEM log
    folder under %ProgramData%\TBOK).
  - Some packages ignore the no-reboot request; this does not force a reboot,
    but an individual installer still can. Intended for interactive logon, so
    the user is present.
#>
[CmdletBinding()]
param([switch]$IncludeUnknown)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP ("TBOK-WinGet-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Log($m) { $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -LiteralPath $log -Value $l; Write-Output $l }

# Locate winget.exe (alias dir is not always on a scheduled task's PATH).
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) {
    $winget = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $winget) {
    $winget = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $winget) { Log 'winget.exe not found for this user; nothing to do.'; exit 0 }

Log "using $winget"
$wgArgs = @('upgrade','--all','--silent','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
if ($IncludeUnknown) { $wgArgs += '--include-unknown' }   # off by default: can downgrade apps whose version winget cannot read
try {
    & $winget @wgArgs *>&1 | ForEach-Object { Log $_ }
    Log "winget exit code $LASTEXITCODE"
} catch { Log "winget failed: $($_.Exception.Message)" }
exit 0
