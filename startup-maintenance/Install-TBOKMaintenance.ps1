#Requires -Version 5.1
<#
.SYNOPSIS
  Installs (or removes) the TBOK maintenance scheduled tasks. Run once,
  elevated. No Group Policy or Intune required, so it works on Home and Pro.

.DESCRIPTION
  Copies the payload scripts to an admin-only folder under %ProgramData%\TBOK
  and registers three scheduled tasks:

    "TBOK Maintenance (Boot)"    At startup, 2-min delay, SYSTEM, highest.
                                 Runs TBOK-Maintenance.ps1 -Mode Light.
    "TBOK Maintenance (Weekly)"  Automatic Maintenance task, SYSTEM, highest.
                                 Weekly anchor (default Sunday 03:00) but runs
                                 when the machine is idle and on AC, deadline
                                 14 days. Runs TBOK-Maintenance.ps1 -Mode Heavy.
    "TBOK WinGet Update (Logon)" At logon, in the logging-on user's context
                                 (winget does not exist for SYSTEM).
                                 Runs TBOK-WinGetUpdate.ps1.

  After registering, it runs one -Mode Heavy pass synchronously so the machine
  is fully configured immediately rather than waiting for the first weekly fire.

.PARAMETER Uninstall      Remove all three tasks and the installed folder.
.PARAMETER NoWinGetTask   Skip the per-user winget logon task.
.PARAMETER NoInitialRun   Do not run the Heavy pass at install time.
.PARAMETER WeeklyDay      Day for the heavy run (default Sunday).
.PARAMETER WeeklyTime     Local HH:mm for the heavy run (default 03:00).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TBOKMaintenance.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TBOKMaintenance.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoWinGetTask,
    [switch]$NoInitialRun,
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
    [string]$WeeklyDay = 'Sunday',
    [string]$WeeklyTime = '03:00',
    [int]$BootDelayMinutes = 2
)

$ErrorActionPreference = 'Stop'
$InstallDir   = Join-Path $env:ProgramData 'TBOK'
$MaintName    = 'TBOK-Maintenance.ps1'
$WinGetName   = 'TBOK-WinGetUpdate.ps1'
$MaintTarget  = Join-Path $InstallDir $MaintName
$WinGetTarget = Join-Path $InstallDir $WinGetName
$BootTask     = 'TBOK Maintenance (Boot)'
$WeeklyTask   = 'TBOK Maintenance (Weekly)'
$LogonTask    = 'TBOK WinGet Update (Logon)'
$PsExe        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this installer from an elevated PowerShell.' }
}
function Remove-Tasks {
    foreach ($t in $BootTask,$WeeklyTask,$LogonTask) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Write-Host "Removed task: $t" }
    }
}

Assert-Admin

if ($Uninstall) {
    Remove-Tasks
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "Removed $InstallDir" }
    Write-Host 'TBOK maintenance uninstalled.'
    return
}

# --- stage payload into an admin-only folder --------------------------------
$srcMaint  = Join-Path $PSScriptRoot $MaintName
$srcWinGet = Join-Path $PSScriptRoot $WinGetName
if (-not (Test-Path -LiteralPath $srcMaint)) { throw "Cannot find $MaintName next to this installer." }

if (-not (Test-Path -LiteralPath $InstallDir)) {
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18','S-1-5-32-544') {   # SYSTEM, Administrators
        $acct = New-Object System.Security.Principal.SecurityIdentifier $sid
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($acct,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $sec.AddAccessRule($rule)
    }
    # Users need Read+Execute so the per-user winget task can read its script.
    $usr = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usr,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    [void][System.IO.Directory]::CreateDirectory($InstallDir, $sec)
}
Copy-Item -LiteralPath $srcMaint -Destination $MaintTarget -Force
if (Test-Path -LiteralPath $srcWinGet) { Copy-Item -LiteralPath $srcWinGet -Destination $WinGetTarget -Force }
Write-Host "Installed scripts to $InstallDir"

# --- (re)register tasks ------------------------------------------------------
Remove-Tasks
$sysPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$common = @{ Principal = $sysPrincipal
             Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) }

$bootAction = New-ScheduledTaskAction -Execute $PsExe -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$MaintTarget`" -Mode Light"
$bootTrigger = New-ScheduledTaskTrigger -AtStartup; $bootTrigger.Delay = "PT${BootDelayMinutes}M"
Register-ScheduledTask -TaskName $BootTask -Action $bootAction -Trigger $bootTrigger @common -Description 'TBOK light maintenance at startup (debloat, telemetry, Copilot/Recall, F8, network, per-user).' | Out-Null
Write-Host "Registered: $BootTask"

# The Heavy task is registered as an Automatic Maintenance task: Windows runs
# it only when the machine is idle and on AC power, suspends it the moment the
# user returns, resumes it at the next idle window, and if idle never comes it
# forces the task through by the deadline (extending the maintenance window to
# finish). Period 7 days with a 14-day deadline. The weekly trigger stays as a
# nominal anchor and StartWhenAvailable still fires a missed run when the box
# next wakes; the maintenance engine decides the actual moment. This is why the
# Heavy pass must be interrupt-safe, which it is: every step is idempotent and
# the heavy operations (defrag, file deletion) are safe to stop mid-stride.
# A separate settings object is used so the Light/boot task is NOT made a
# maintenance task (it must run promptly at every startup, not wait for idle).
$weeklySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MaintenancePeriod (New-TimeSpan -Days 7) -MaintenanceDeadline (New-TimeSpan -Days 14)
$weeklyAction = New-ScheduledTaskAction -Execute $PsExe -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$MaintTarget`" -Mode Heavy"
$weeklyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $WeeklyDay -At $WeeklyTime
Register-ScheduledTask -TaskName $WeeklyTask -Action $weeklyAction -Trigger $weeklyTrigger -Principal $sysPrincipal -Settings $weeklySettings -Description 'TBOK weekly maintenance as an Automatic Maintenance task (services, registry, gaming, cleanup, trim, shadow trim, enable-maintenance, ngen, health report). Runs when idle/on AC, deadline 14 days.' | Out-Null
Write-Host "Registered: $WeeklyTask ($WeeklyDay $WeeklyTime, Automatic Maintenance, 14-day deadline)"

if (-not $NoWinGetTask -and (Test-Path -LiteralPath $WinGetTarget)) {
    # Runs as whoever logs on, in their context, so winget resolves.
    $usersPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $wgSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $wgAction = New-ScheduledTaskAction -Execute $PsExe -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WinGetTarget`""
    $wgTrigger = New-ScheduledTaskTrigger -AtLogOn; $wgTrigger.Delay = 'PT3M'
    Register-ScheduledTask -TaskName $LogonTask -Action $wgAction -Trigger $wgTrigger -Principal $usersPrincipal -Settings $wgSettings -Description 'TBOK winget app updates at logon, in the user context (winget is unavailable to SYSTEM).' | Out-Null
    Write-Host "Registered: $LogonTask (per-user, at logon)"
} else { Write-Host "Skipped: $LogonTask" }

# --- run one full pass now so the machine is configured immediately ----------
if (-not $NoInitialRun) {
    Write-Host 'Running initial Heavy pass now...'
    & $PsExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $MaintTarget -Mode Heavy
    Write-Host "Initial pass exit code $LASTEXITCODE"
}

Write-Host ''
Write-Host "Done. Logs: $(Join-Path $InstallDir 'Logs')"
Write-Host "Test the light pass:   Start-ScheduledTask -TaskName `"$BootTask`""
Write-Host "Remove everything:     .\Install-TBOKMaintenance.ps1 -Uninstall"
