#Requires -Version 5.1
<#
.SYNOPSIS
  TBOK startup/weekly maintenance for non-Enterprise Windows 10/11 clients
  (Home, Pro, Pro for Workstations). Runs as SYSTEM from a scheduled task:
  no console, no user. Fully non-interactive and fail-open: it never blocks
  or aborts boot. This is the SYSTEM-context port of the original TBOK batch
  feature set, minus the pieces that only make sense interactively or on
  Enterprise.

.DESCRIPTION
  -Mode Light  (runs at every startup): the regression-prone, fast,
      idempotent config: debloat, telemetry minimization, Copilot/Recall and
      widgets policy, the F8 recovery menu, evidence-based network defaults,
      and the full per-user tweak set applied to every profile and the
      Default hive.
  -Mode Heavy  (runs weekly, and once at install): everything in Light, then
      the rest of the config that updates rarely revert (services, hibernation
      policy, pagefile, system-wide registry, gaming) and the maintenance
      (restore point, temp/log/browser cleanup, component-store cleanup, SSD
      retrim, shadow-copy trim to newest, Storage Sense).

  Honest non-Enterprise limits, stated where they bite:
   - Telemetry cannot be set to 0 on Home/Pro (Windows clamps it to 1). This
     minimizes it; it does not disable it.
   - winget is unavailable to SYSTEM, so app UPDATES are handled by a separate
     per-user logon task (see Install-TBOKMaintenance.ps1), not here. App
     REMOVAL here uses the Appx APIs, which do work as SYSTEM.
   - The classic context-menu per-user tweak only takes effect for hives that
     are loaded (signed-in) when it runs, because it lives in UsrClass.dat,
     not NTUSER.DAT. It is written for parity and logged as such.

  Not tested on a live Windows system; parsing and the mode/detection logic
  were checked off-box. Test on a VM before fleet use.
#>
[CmdletBinding()]
param(
    [ValidateSet('Light', 'Heavy')]
    [string]$Mode = 'Light',
    [string]$LogDir = (Join-Path $env:ProgramData 'TBOK\Logs'),
    [int]$RetentionDays = 30,
    [switch]$SkipCrashDumps,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$script:Warnings = 0

# ---------------------------------------------------------------- bootstrap
if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    $sysnative = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        $a = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode',$Mode,'-LogDir',$LogDir)
        if ($WhatIfOnly) { $a += '-WhatIfOnly' }
        & $sysnative @a; exit $LASTEXITCODE
    }
}
try { [void][System.IO.Directory]::CreateDirectory($LogDir) } catch { }
$script:LogFile = Join-Path $LogDir ("TBOK-Maintenance-{0}-{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '[{0}] {1,-6} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Output $line
    if ($Level -eq 'WARN' -or $Level -eq 'ERROR') { $script:Warnings++ }
}
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    if ($WhatIfOnly) { Write-Log 'PLAN' "would run: $Name"; return }
    Write-Log 'STEP' $Name
    try { & $Action } catch { Write-Log 'WARN' ("$Name failed: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- detection
function Get-Context {
    $cv = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    $build = [int]$cv.GetValue('CurrentBuildNumber'); $ubr = [int]$cv.GetValue('UBR',0)
    $edition = [string]$cv.GetValue('EditionID'); $install = [string]$cv.GetValue('InstallationType'); $display = [string]$cv.GetValue('DisplayVersion')
    $cv.Close()
    $hasBattery = $null
    try {
        if (-not ('Tbok.Power' -as [type])) {
            Add-Type -Namespace 'Tbok' -Name 'Power' -MemberDefinition '[DllImport("powrprof.dll")] public static extern byte GetPwrCapabilities(System.IntPtr caps);'
        }
        $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(256)
        try { if ([Tbok.Power]::GetPwrCapabilities($buf) -ne 0) { $hasBattery = ([Runtime.InteropServices.Marshal]::ReadByte($buf,30) -ne 0) } }
        finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
    } catch { }
    $ramMB = $null
    try { $ramMB = [int]((Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum / 1MB) } catch { }
    [pscustomobject]@{
        Build=$build; UBR=$ubr; DisplayVersion=$display
        Version=(New-Object Version 10,0,$build,$ubr)
        EditionID=$edition; InstallationType=$install
        IsServer=($install -eq 'Server'); IsWindows11=($build -ge 22000)
        HasBattery=$hasBattery; IsLaptop=($hasBattery -eq $true); IsDesktop=($hasBattery -eq $false)
        RamMB=$ramMB
    }
}

# ---------------------------------------------------------------- reg + hive helpers
function Set-Reg {
    param([string]$Path,[string]$Name,[object]$Value,[Microsoft.Win32.RegistryValueKind]$Kind='DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}
function Remove-RegValue { param([string]$Path,[string]$Name) try { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop } catch { } }

function Invoke-ForEachUserHive {
    param([scriptblock]$Action)
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users','Registry64')
    $loaded = @($users.GetSubKeyNames() | Where-Object { $_ -match '^S-1-(5-21|12-1)-[\d-]+$' -and $_ -notlike '*_Classes' })
    foreach ($sid in $loaded) { Write-Log 'INFO' "per-user: loaded hive $sid"; & $Action ("Registry::HKEY_USERS\$sid") $true }
    $pl = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
    $targets = New-Object System.Collections.ArrayList
    foreach ($sid in $pl.GetSubKeyNames()) {
        if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$' -or $loaded -contains $sid) { continue }
        $p = $pl.OpenSubKey($sid); $path = [Environment]::ExpandEnvironmentVariables([string]$p.GetValue('ProfileImagePath')); $p.Close()
        if ($path -and (Test-Path -LiteralPath (Join-Path $path 'NTUSER.DAT'))) { [void]$targets.Add(@($sid,(Join-Path $path 'NTUSER.DAT'))) }
    }
    $defDir = [Environment]::ExpandEnvironmentVariables([string]$pl.GetValue('Default')); $pl.Close()
    if ($defDir -and (Test-Path -LiteralPath (Join-Path $defDir 'NTUSER.DAT'))) { [void]$targets.Add(@('DEFAULT',(Join-Path $defDir 'NTUSER.DAT'))) }
    foreach ($t in $targets) {
        $sid=$t[0]; $dat=$t[1]; $mount='TBOK_'+[guid]::NewGuid().ToString('N').Substring(0,12)
        & $reg load "HKU\$mount" $dat *> $null
        if ($LASTEXITCODE -ne 0) { Write-Log 'WARN' "per-user: could not load $sid (in use); skipped"; continue }
        try { Write-Log 'INFO' "per-user: offline hive $sid"; & $Action ("Registry::HKEY_USERS\$mount") $false }
        catch { Write-Log 'WARN' "per-user: $sid error: $($_.Exception.Message)" }
        finally {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            for ($i=1;$i -le 5;$i++){ & $reg unload "HKU\$mount" *> $null; if ($LASTEXITCODE -eq 0){break}; Start-Sleep -Milliseconds (400*$i) }
            if ($LASTEXITCODE -ne 0) { Write-Log 'WARN' "per-user: $sid still mounted at HKU\$mount" }
        }
    }
    $users.Close()
}

# ---------------------------------------------------------------- service helper
function Set-SvcStart {
    param([string]$Name,[ValidateSet('auto','delayed-auto','demand','disabled')][string]$Start,[hashtable]$Current)
    $info = $Current[$Name.ToLowerInvariant()]
    if (-not $info) { return }   # not installed
    if ($info.StartMode -eq 'Disabled' -and $Start -ne 'disabled') {
        Write-Log 'INFO' "service $Name left Disabled (admin choice; requested $Start)"; return
    }
    & (Join-Path $env:SystemRoot 'System32\sc.exe') config $Name start= $Start *> $null
    if ($LASTEXITCODE -ne 0) { Write-Log 'WARN' "service $Name set $Start failed (sc exit $LASTEXITCODE)" }
}

# ================================================================ LIGHT
function Invoke-Telemetry {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'LimitDiagnosticLogCollection' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    # DiagTrack off. dmwappushservice is intentionally left to the services
    # section as demand (the original excludes it here for MDM).
    $s = Get-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
    if ($s) { Set-Service -Name 'DiagTrack' -StartupType Disabled -ErrorAction SilentlyContinue; if ($s.Status -eq 'Running'){ Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue } }
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\Diagtrack-Listener' 'Start' 0
    Write-Log 'INFO' 'telemetry minimized (AllowTelemetry=1 is the Home/Pro floor; not 0)'
}
function Remove-AppxBloat {
    $patterns = @('Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider','Microsoft.BingSearch','Microsoft.WidgetsPlatformRuntime','MicrosoftWindows.Client.WebExperience')
    foreach ($pat in $patterns) {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$pat*" } | ForEach-Object {
            try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null; Write-Log 'INFO' "removed provisioned $($_.DisplayName)" } catch { Write-Log 'WARN' "provisioned $($_.DisplayName): $($_.Exception.Message)" }
        }
        Get-AppxPackage -AllUsers -Name "*$pat*" -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; Write-Log 'INFO' "removed installed $($_.Name)" } catch { Write-Log 'WARN' "remove $($_.Name): $($_.Exception.Message)" }
        }
    }
}
function Invoke-CopilotRecallPolicy {
    param($Ctx)
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot' 'IsCopilotAvailable' 0
    if ($Ctx.Version -ge (New-Object Version 10,0,26100,3915)) {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
        $r = Get-WindowsOptionalFeature -Online -FeatureName 'Recall' -ErrorAction SilentlyContinue
        if ($r -and $r.State -eq 'Enabled') { try { Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -NoRestart -ErrorAction Stop | Out-Null; Write-Log 'INFO' 'Recall feature removal requested' } catch { Write-Log 'WARN' "Recall removal: $($_.Exception.Message)" } }
    } else { Write-Log 'INFO' 'Recall policies skipped (build < 26100.3915)' }
}
function Invoke-WidgetsPolicy {
    param($Ctx)
    if ($Ctx.IsWindows11) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
    else { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0 }
}
function Invoke-F8Recovery {
    $status='Unknown'; try { $status=(Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus } catch { }
    if ($status -eq 'On') {
        & (Join-Path $env:SystemRoot 'System32\manage-bde.exe') -protectors -disable $env:SystemDrive -RebootCount 1 *> $null
        if ($LASTEXITCODE -ne 0) { Write-Log 'WARN' 'could not suspend BitLocker; skipping F8 change'; return }
        Write-Log 'INFO' 'BitLocker suspended one reboot for the boot-menu change'
    }
    & (Join-Path $env:SystemRoot 'System32\bcdedit.exe') /set '{default}' bootmenupolicy legacy *> $null
    if ($LASTEXITCODE -eq 0) { Write-Log 'INFO' 'legacy F8 boot menu enabled' } else { Write-Log 'WARN' 'bcdedit bootmenupolicy failed' }
}
function Invoke-NetworkDefaults {
    try { $t=Get-NetTCPSetting -SettingName InternetCustom -ErrorAction Stop; if ($t.AutoTuningLevelLocal -ne 'Normal'){ Set-NetTCPSetting -SettingName InternetCustom -AutoTuningLevelLocal Normal -ErrorAction Stop; Write-Log 'INFO' 'restored TCP autotuning to Normal' } } catch { Write-Log 'WARN' "autotuning check: $($_.Exception.Message)" }
    foreach ($nic in (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
        Write-Log 'INFO' ("NIC {0}: {1}" -f $nic.Name,$nic.LinkSpeed)
        if ($nic.LinkSpeed -ge 1e9) { try { $rss=Get-NetAdapterRss -Name $nic.Name -ErrorAction Stop; if (-not $rss.Enabled){ Enable-NetAdapterRss -Name $nic.Name -ErrorAction Stop; Write-Log 'INFO' "enabled RSS on $($nic.Name)" } } catch { } }
    }
    Write-Log 'INFO' 'network at evidence-based defaults (autotuning Normal, RSS on >=1Gbps, offloads untouched)'
}
function Invoke-PerUserTweaks {
    Invoke-ForEachUserHive {
        param($base,$isLoaded)
        $adv="$base\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        $cdm="$base\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        $cp ="$base\Control Panel\Desktop"
        # Explorer / shell behavior
        try { Remove-Item -LiteralPath "$base\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath "$base\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Set-Reg $adv 'LaunchTo' 1
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" 'GlobalUserDisabled' 1
        Set-Reg "$base\Software\Microsoft\GameBar" 'AutoGameModeEnabled' 1
        Set-Reg "$adv\TaskbarDeveloperSettings" 'TaskbarEndTask' 1
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled' 0
        Set-Reg $adv 'Start_Layout' 1
        Set-Reg $cp 'MenuShowDelay' '10' String
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 3
        Set-Reg $adv 'TaskbarAnimations' 0
        Set-Reg $adv 'TaskbarAI' 0
        Set-Reg $adv 'ShowCopilotButton' 0
        Set-Reg $adv 'ListviewAlphaSelect' 1
        Set-Reg $adv 'ListviewShadow' 1
        Set-Reg $adv 'TaskbarMn' 0
        Set-Reg $cp 'DragFullWindows' '1' String
        Set-Reg "$cp\WindowMetrics" 'MinAnimate' '0' String
        Set-Reg "$base\Control Panel\Keyboard" 'KeyboardDelay' '0' String
        Set-Reg "$base\Software\Microsoft\Windows\DWM" 'EnableAeroPeek' 0
        Set-Reg $adv 'ShowTaskViewButton' 0
        Set-Reg "$adv\People" 'PeopleBand' 0
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" 'HideSCAMeetNow' 1
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\Search" 'SearchboxTaskbarMode' 1
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration" 'IsResumeAllowed' 0
        Set-Reg "$base\Control Panel\Accessibility\StickyKeys" 'Flags' '58' String
        # classic context menu (effective only for loaded hives; see header)
        if ($isLoaded) { $ctm = "$base\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"; try { if (-not (Test-Path -LiteralPath $ctm)) { New-Item -Path $ctm -Force | Out-Null }; Set-Item -LiteralPath $ctm -Value '' } catch { } }
        # ads / suggestions / tailored experiences
        Set-Reg "$base\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1
        Set-Reg $adv 'ShowSyncProviderNotifications' 0
        Set-Reg $adv 'Start_AccountNotifications' 0
        Set-Reg $adv 'Start_IrisRecommendations' 0
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0
        Set-Reg "$base\Software\Policies\Microsoft\Windows\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1
        Set-Reg "$base\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager" 'EnthusiastMode' 1
        Set-Reg "$base\Software\Microsoft\Siuf\Rules" 'NumberOfSIUFInPeriod' 0
        Remove-RegValue "$base\Software\Microsoft\Siuf\Rules" 'PeriodInNanoSeconds'
        foreach ($v in 'RotatingLockScreenOverlayEnabled','SubscribedContent-310093Enabled','SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-353698Enabled','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','PreInstalledAppsEverEnabled') { Set-Reg $cdm $v 0 }
        # per-user Copilot
        Set-Reg "$base\Software\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
        # Office telemetry/logging (16.0)
        Set-Reg "$base\Software\Microsoft\Office\16.0\Common\ClientTelemetry" 'DisableTelemetry' 1
        Set-Reg "$base\Software\Microsoft\Office\Common\ClientTelemetry" 'DisableTelemetry' 1
        Set-Reg "$base\Software\Microsoft\Office\16.0\Common" 'QMEnable' 0
        Set-Reg "$base\Software\Microsoft\Office\16.0\Common\Feedback" 'Enabled' 0
    }
    Write-Log 'INFO' 'per-user tweaks applied to all profiles + Default'
}

# ================================================================ HEAVY: config
function Invoke-HibernationPolicy {
    param($Ctx)
    if ($Ctx.IsLaptop) { & (Join-Path $env:SystemRoot 'System32\powercfg.exe') /hibernate on *> $null; Write-Log 'INFO' 'laptop: hibernation/Fast Startup left enabled' }
    elseif ($Ctx.IsDesktop) { & (Join-Path $env:SystemRoot 'System32\powercfg.exe') /hibernate off *> $null; Write-Log 'INFO' 'desktop: hibernation/Fast Startup disabled' }
    else { Write-Log 'INFO' 'chassis unknown; hibernation left unchanged' }
}
function Invoke-Services {
    param($Ctx)
    $cur = @{}
    foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) { $cur[$s.Name.ToLowerInvariant()] = $s }
    $disabled = @('AppVClient','NetTcpPortSharing','DialogBlockingService','UevAgentService','ssh-agent')
    $delayed  = @('BITS','W32Time','WSearch','wudfsvc')
    $auto     = @('AudioEndpointBuilder','AudioSrv','BthHFSrv','CryptSvc','DPS','Dhcp','DispBrokerDesktopSvc','dusmsvc','EventLog','EventSystem','FontCache','iphlpsvc','LanmanServer','LanmanWorkstation','nsi','Power','ProfSvc','SENS','SamSs','ShellHWDetection','Spooler','Themes','tiledatamodelsvc','TrkWks','uhssvc','UserManager','Wcmsvc','Winmgmt','WlanSvc')
    $demand   = @('ALG','AppMgmt','AppReadiness','Appinfo','AssignedAccessManagerSvc','AxInstSV','BDESVC','BTAGService','bthserv','CertPropSvc','cloudidsvc','COMSysApp','CscService','DcpSvc','dcsvc','defragsvc','DevQueryBroker','DeviceAssociationService','DeviceInstall','diagnosticshub.standardcollector.service','diagsvc','DisplayEnhancementService','DmEnrollmentSvc','dmwappushservice','dot3svc','fdPHost','fhsvc','hidserv','icssvc','EapHost','edgeupdate','edgeupdatem','EFS','FDResPub','Fax','FrameServer','FrameServerMonitor','GraphicsPerfSvc','HvHost','IEEtwCollectorService','IpxlatCfgSvc','lfsvc','lltdsvc','lmhosts','LxpSvc','McpManagementService','MicrosoftEdgeElevationService','MixedRealityOpenXRSvc','MSDTC','MsKeyboardFilter','MSiSCSI','NaturalAuthentication','NcaSvc','NcbService','NcdAutoSetup','NetSetupSvc','Netman','p2pimsvc','p2psvc','PcaSvc','PeerDistSvc','perceptionsimulation','PerfHost','PhoneSvc','pla','PlugPlay','PNRPAutoReg','PNRPsvc','PolicyAgent','PrintNotify','PushToInstall','QWAVE','RasAuto','RasMan','RetailDemo','RmSvc','RpcLocator','SCPolicySvc','ScDeviceEnum','SCardSvr','SDRSVC','seclogon','SEMgrSvc','SensorDataService','SensorService','SensrSvc','SharedAccess','SharedRealitySvc','shpamsvc','SmsRouter','smphost','SNMPTrap','spectrum','SstpSvc','SSDPSRV','StiSvc','StorSvc','svsvc','swprv','TabletInputService','TapiSrv','TieringEngineService','TimeBroker','TroubleshootingSvc','tzautoupdate','UI0Detect','upnphost','VacSvc','vds','vmicguestinterface','vmicheartbeat','vmickvpexchange','vmicshutdown','vmictimesync','vmicvmsession','vmicvss','VSS','WalletService','wbengine','WcsPlugInService','wcncsvc','WdiServiceHost','WdiSystemHost','WebClient','Wecsvc','wercplsupport','WEPHOSTSVC','WerSvc','WFDSConMgrSvc','WiaRpc','wisvc','wlidsvc','wlpasvc','wmiApSrv','WMPNetworkSvc','WManSvc','WPDBusEnum','WpcMonSvc','workfolderssvc','wuauserv','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc')
    foreach ($s in $disabled){ Set-SvcStart $s 'disabled' $cur }
    foreach ($s in $demand)  { Set-SvcStart $s 'demand'   $cur }
    foreach ($s in $auto)    { Set-SvcStart $s 'auto'     $cur }
    foreach ($s in $delayed) { Set-SvcStart $s 'delayed-auto' $cur }
    Write-Log 'INFO' 'service startup plan applied (admin-disabled services preserved)'
    # SysMain + MMAgent by hardware (the original's resolved policy: keep SysMain
    # Automatic; enable memory compression + page combining on low-memory PCs).
    Set-SvcStart 'SysMain' 'auto' $cur
    if ($Ctx.RamMB -and $Ctx.RamMB -le 12288) {
        try {
            Set-Service -Name SysMain -StartupType Automatic -ErrorAction SilentlyContinue
            if ((Get-Service SysMain -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service SysMain -ErrorAction SilentlyContinue }
            Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue
            Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue
            Write-Log 'INFO' "low-memory profile ($($Ctx.RamMB) MB): memory compression + page combining enabled"
        } catch { Write-Log 'WARN' "MMAgent config: $($_.Exception.Message)" }
    }
}
function Invoke-SystemRegistry {
    param($Ctx)
    $ccs='HKLM:\SYSTEM\CurrentControlSet'
    Set-Reg "$ccs\Control\FileSystem" 'LongPathsEnabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
    Set-Reg "$ccs\Services\Ndu" 'Start' 2
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan' 'ScanAvgCPULoadFactor' 25
    # WPBT: full parity. WARNING: also stops firmware anti-theft (Computrace /
    # Absolute) from re-injecting its agent at boot.
    Set-Reg "$ccs\Control\Session Manager" 'DisableWpbtExecution' 1
    Write-Log 'WARN' 'WPBT execution disabled: firmware anti-theft (Computrace/Absolute) will no longer persist. Intended per full-parity choice.'
    # Webview classic-search override: full parity. WARNING: keyed to a
    # build-specific FeatureManagement override ID that Microsoft can change
    # between releases, so it may be a no-op on some builds.
    $ov="$ccs\Control\FeatureManagement\Overrides\8\1694661260"
    Set-Reg $ov 'EnabledState' 1; Set-Reg $ov 'EnabledStateOptions' 0; Set-Reg $ov 'Variant' 0; Set-Reg $ov 'VariantPayload' 0; Set-Reg $ov 'VariantPayloadKind' 0
    Write-Log 'WARN' 'Webview classic-search override written (build-specific feature ID; may not apply on all builds).'
    # Edge policies (documented)
    $edge='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'StartupBoostEnabled' 0; Set-Reg $edge 'EfficiencyModeEnabled' 1
    Set-Reg $edge 'SleepingTabsEnabled' 1; Set-Reg $edge 'SleepingTabsTimeout' 900
    Set-Reg $edge 'BackgroundModeEnabled' 0; Set-Reg $edge 'HideFirstRunExperience' 1
    Set-Reg $edge 'UserFeedbackAllowed' 0; Set-Reg $edge 'EdgeShoppingAssistantEnabled' 0; Set-Reg $edge 'DiagnosticData' 0
    Write-Log 'INFO' 'system-wide registry applied'
}
function Invoke-Pagefile {
    param($Ctx)
    if (-not $Ctx.RamMB) { Write-Log 'WARN' 'pagefile: RAM unknown; left unchanged'; return }
    if ($Ctx.RamMB -ge 32768) { Write-Log 'INFO' 'pagefile: >=32GB RAM; left unchanged'; return }
    if ($Ctx.RamMB -lt 8192) { $init=4096; $max=16384 } elseif ($Ctx.RamMB -lt 16384) { $init=8192; $max=24576 } else { $init=8192; $max=32768 }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$false} | Out-Null }
        $name = "$($env:SystemDrive)\pagefile.sys"
        $pf = Get-CimInstance Win32_PageFileSetting -Filter ("Name='{0}'" -f $name.Replace('\','\\')) -ErrorAction SilentlyContinue
        if ($pf) { Set-CimInstance -InputObject $pf -Property @{InitialSize=[uint32]$init; MaximumSize=[uint32]$max} | Out-Null }
        else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name=$name; InitialSize=[uint32]$init; MaximumSize=[uint32]$max} | Out-Null }
        Write-Log 'INFO' "pagefile set ${init}-${max} MB on $name (restart to apply)"
    } catch { Write-Log 'WARN' "pagefile: $($_.Exception.Message)" }
}
function Invoke-Gaming {
    param($Ctx)
    $pc = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    & (Join-Path $env:SystemRoot 'System32\bcdedit.exe') /deletevalue useplatformclock *> $null  # HPET redetect
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HWSchMode' 2                 # HAGS where supported
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR\Graphics' 'OptimizationsForWindowedGames' 1
    foreach ($task in 'Games','Audio') {
        $p = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\$task"
        Set-Reg $p 'Priority' 6
        Set-Reg $p 'Scheduling Category' 'Medium' String
        Set-Reg $p 'Latency Sensitive' 'True' String
    }
    if ($Ctx.IsDesktop) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
        & $pc -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2 *> $null
        & $pc -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2 *> $null
        $g=$null
        foreach ($line in (& $pc /list)) { if ($line -match 'Ultimate Performance') { $g=($line -split '\s+')[3] } }
        if (-not $g) { foreach ($line in (& $pc -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61)) { if ($line -match '([0-9a-fA-F-]{36})') { $g=$Matches[1] } } }
        if ($g) { & $pc /setactive $g *> $null; Write-Log 'INFO' "desktop: Ultimate Performance active ($g)" }
        & $pc -setactive SCHEME_CURRENT *> $null
        Write-Log 'INFO' 'desktop gaming power tweaks applied'
    } elseif ($Ctx.IsLaptop) {
        & $pc -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 3 *> $null
        & $pc -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 3 *> $null
        & $pc -setactive SCHEME_CURRENT *> $null
        Write-Log 'INFO' 'laptop: efficient-aggressive boost; no Ultimate Performance'
    }
}
function Invoke-DisableTasks {
    $tasks = @(
        '\Microsoft\Office\OfficeTelemetryAgent','\Microsoft\Office\OfficeTelemetryAgentFallBack','\Microsoft\Office\OfficeTelemetryAgentLogon',
        '\Microsoft\Office\OfficeTelemetryAgentFallBack2016','\Microsoft\Office\OfficeTelemetryAgentLogOn2016',
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient','\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Maps\MapsUpdateTask','\Microsoft\Windows\Windows Error Reporting\QueueReporting')
    foreach ($t in $tasks) {
        $leaf=Split-Path $t -Leaf; $parent=(Split-Path $t -Parent)+'\'
        Get-ScheduledTask -TaskPath $parent -TaskName $leaf -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log 'INFO' 'wasteful scheduled tasks disabled'
}

# ================================================================ HEAVY: cleanup
function New-RestorePointThrottled {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $recent=$false; try { $recent=[bool](Get-ComputerRestorePoint -ErrorAction Stop | Where-Object { $_.CreationTime -gt (Get-Date).AddHours(-24) }) } catch { }
        if (-not $recent) {
            Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
            Checkpoint-Computer -Description 'Before TBOK weekly maintenance' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-Log 'INFO' 'restore point created'
        } else { Write-Log 'INFO' 'recent restore point exists; skipping' }
    } catch { Write-Log 'WARN' "restore point unavailable: $($_.Exception.Message)" }
}
function Invoke-TempCleanup {
    foreach ($p in @("$env:SystemRoot\Temp\*","$env:SystemRoot\Logs\CBS\*.log","$env:SystemDrive\ProgramData\USOShared\Logs\User\*")) { try { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in 'AppData\Local\Temp','AppData\Local\CrashDumps','AppData\Local\Microsoft\Windows\INetCache','AppData\Local\Microsoft\Windows\Explorer\ThumbCacheToDelete') {
            try { Remove-Item -Path (Join-Path $_.FullName "$sub\*") -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    $pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (-not $pending) {
        foreach ($svc in 'wuauserv','bits') { Stop-Service $svc -Force -ErrorAction SilentlyContinue }
        try { Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        foreach ($svc in 'bits','wuauserv') { Start-Service $svc -ErrorAction SilentlyContinue }
    } else { Write-Log 'INFO' 'reboot pending; left SoftwareDistribution alone' }
    Write-Log 'INFO' 'temp and log cleanup done'
}
function Remove-OldFiles {
    # Delete files older than $Days under $Path. Files only, skips reparse
    # points. Returns bytes freed. Never deletes event logs or $PatchCache$
    # (callers do not pass those paths; this is the enforcement of record).
    param([string]$Path,[int]$Days,[switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    if ($Path -match 'winevt\\Logs' -or $Path -match 'Installer\\\$PatchCache\$') { return [int64]0 }
    $cut = (Get-Date).AddDays(-$Days); $freed = [int64]0
    $gci = @{ LiteralPath=$Path; File=$true; Force=$true; ErrorAction='SilentlyContinue' }
    if ($Recurse) { $gci.Recurse = $true }
    foreach ($f in (Get-ChildItem @gci)) {
        if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($f.LastWriteTime -lt $cut) { $sz=$f.Length; try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $sz } catch { } }
    }
    return $freed
}
function Remove-StaleFolder {
    # Remove a whole leftover folder if it exists and has not been touched
    # within $Days. Used for upgrade leftovers only.
    param([string]$Path,[int]$Days)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [int64]0 }
    if ($item.LastWriteTime -ge (Get-Date).AddDays(-$Days)) { return [int64]0 }
    $sz = Get-FolderSize $Path
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $sz } catch { return [int64]0 }
}

function Invoke-AgedCleanup {
    param([int]$Days,[bool]$IncludeDumps)
    $freed = [int64]0
    # Windows log trees (text logs, ETL, CbsPersist cabs). Not event logs.
    foreach ($p in "$env:SystemRoot\Logs","$env:SystemRoot\Panther","$env:SystemRoot\WinREAgent","$env:SystemDrive\`$WinREAgent") {
        $freed += (Remove-OldFiles -Path $p -Days $Days -Recurse)
    }
    $freed += (Remove-OldFiles -Path "$env:SystemRoot\debug" -Days $Days)
    # Windows Error Reporting: machine + per-user.
    foreach ($sub in 'ReportQueue','ReportArchive','Temp') { $freed += (Remove-OldFiles -Path "$env:ProgramData\Microsoft\Windows\WER\$sub" -Days $Days -Recurse) }
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in 'ReportQueue','ReportArchive','Temp') { $freed += (Remove-OldFiles -Path (Join-Path $_.FullName "AppData\Local\Microsoft\Windows\WER\$sub") -Days $Days -Recurse) }
    }
    # Defender support logs, RetailDemo offline content, service-account temp.
    $freed += (Remove-OldFiles -Path "$env:ProgramData\Microsoft\Windows Defender\Support" -Days $Days)
    $freed += (Remove-OldFiles -Path "$env:ProgramData\Microsoft\Windows\RetailDemo\OfflineContent" -Days $Days -Recurse)
    foreach ($svc in "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\Temp","$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Temp","$env:SystemRoot\System32\config\systemprofile\AppData\Local\Temp") {
        $freed += (Remove-OldFiles -Path $svc -Days $Days -Recurse)
    }
    # Upgrade leftovers (whole folders, only if stale).
    foreach ($p in "$env:SystemDrive\Windows10Upgrade","$env:SystemDrive\`$GetCurrent","$env:SystemDrive\`$SysReset\Logs") {
        $freed += (Remove-StaleFolder -Path $p -Days $Days)
    }
    # Crash dumps (age-gated, optional: MEMORY.DMP may be your only BSOD record).
    if ($IncludeDumps) {
        $freed += (Remove-OldFiles -Path "$env:SystemRoot\Minidump" -Days $Days -Recurse)
        $freed += (Remove-OldFiles -Path "$env:SystemRoot\LiveKernelReports" -Days $Days -Recurse)
        $md = "$env:SystemRoot\MEMORY.DMP"
        if ((Test-Path -LiteralPath $md) -and ((Get-Item $md -Force).LastWriteTime -lt (Get-Date).AddDays(-$Days))) {
            $sz=(Get-Item $md -Force).Length; try { Remove-Item -LiteralPath $md -Force -ErrorAction Stop; $freed += $sz } catch { }
        }
    }
    Write-Log 'INFO' ("aged cleanup (older than $Days days): reclaimed {0:N1} MB. Event logs and `$PatchCache`$ left untouched by design." -f ($freed/1MB))
}

function Invoke-BrowserCacheCleanup {
    # Cache only. Never touches profile data, passwords, cookies, or the
    # Office/OneNote caches our earlier fixes protect.
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $u=$_.FullName
        foreach ($chromium in "$u\AppData\Local\Google\Chrome\User Data","$u\AppData\Local\Microsoft\Edge\User Data") {
            if (Test-Path $chromium) {
                foreach ($prof in (Get-ChildItem $chromium -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                    foreach ($c in 'Cache\Cache_Data','Code Cache\js','Code Cache\wasm','GPUCache','Service Worker\CacheStorage') {
                        try { Remove-Item -Path (Join-Path $prof.FullName "$c\*") -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                    }
                }
            }
        }
        foreach ($ff in (Get-ChildItem "$u\AppData\Local\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue)) {
            try { Remove-Item -Path (Join-Path $ff.FullName 'cache2\entries\*') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        foreach ($t in 'AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage','AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache') {
            try { Remove-Item -Path (Join-Path $u "$t\*") -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    Write-Log 'INFO' 'browser and Teams caches cleaned (cache only)'
}
function Invoke-ComponentCleanup {
    & (Join-Path $env:SystemRoot 'System32\Dism.exe') /Online /Cleanup-Image /StartComponentCleanup /Quiet *> $null
    Write-Log 'INFO' "component-store cleanup exit $LASTEXITCODE (no ResetBase)"
}
function Invoke-SsdTrim {
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })) {
        $media='Unknown'
        try { $media=(Get-PhysicalDisk -ErrorAction Stop | Where-Object { ($_ | Get-Disk | Get-Partition | Get-Volume -ErrorAction SilentlyContinue).DriveLetter -contains $v.DriveLetter } | Select-Object -First 1).MediaType } catch { }
        try {
            if ($media -eq 'HDD') { Optimize-Volume -DriveLetter $v.DriveLetter -Defrag -ErrorAction Stop; Write-Log 'INFO' "defrag $($v.DriveLetter): (HDD)" }
            else { Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -ErrorAction Stop; Write-Log 'INFO' "retrim $($v.DriveLetter): ($media)" }
        } catch { Write-Log 'WARN' "optimize $($v.DriveLetter): $($_.Exception.Message)" }
    }
}
function Invoke-ShadowTrim {
    try {
        foreach ($g in (Get-CimInstance Win32_ShadowCopy -ErrorAction Stop | Group-Object VolumeName)) {
            foreach ($s in ($g.Group | Sort-Object InstallDate -Descending | Select-Object -Skip 1)) {
                try { Remove-CimInstance -InputObject $s -ErrorAction Stop; Write-Log 'INFO' "deleted old shadow $($s.ID)" } catch { Write-Log 'WARN' "shadow $($s.ID): $($_.Exception.Message)" }
            }
        }
        Write-Log 'INFO' 'shadow copies trimmed to newest per volume'
    } catch { Write-Log 'WARN' "shadow enumeration: $($_.Exception.Message)" }
}
function Invoke-StorageSense {
    $ss='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
    Set-Reg $ss 'AllowStorageSenseGlobal' 1; Set-Reg $ss 'AllowStorageSenseTemporaryFilesCleanup' 1
}

# ---------------------------------------------------------------- main
$ctx = Get-Context
Write-Log 'INFO' ("start Mode=$Mode build $($ctx.Version) ($($ctx.DisplayVersion)) edition $($ctx.EditionID) chassis=$(if($ctx.IsLaptop){'laptop'}elseif($ctx.IsDesktop){'desktop'}else{'unknown'}) ram=$($ctx.RamMB)MB")
if ($ctx.IsServer) { Write-Log 'ERROR' 'Windows Server is not a target'; exit 2 }
if ($ctx.Build -lt 19045) { Write-Log 'ERROR' 'older than Windows 10 22H2 not supported'; exit 2 }
if ($ctx.EditionID -match '^(Enterprise|Education|IoTEnterprise)') { Write-Log 'WARN' "edition $($ctx.EditionID) has first-party tooling; continuing but some steps are redundant" }

# Light (always)
Invoke-Step 'Minimize telemetry' { Invoke-Telemetry }
Invoke-Step 'Remove Appx bloat' { Remove-AppxBloat }
Invoke-Step 'Copilot/Recall policy' { Invoke-CopilotRecallPolicy $ctx }
Invoke-Step 'Widgets/news policy' { Invoke-WidgetsPolicy $ctx }
Invoke-Step 'F8 recovery menu (BitLocker-safe)' { Invoke-F8Recovery }
Invoke-Step 'Network defaults' { Invoke-NetworkDefaults }
Invoke-Step 'Per-user tweaks (all profiles + Default)' { Invoke-PerUserTweaks }

if ($Mode -eq 'Heavy') {
    Invoke-Step 'Hibernation policy by chassis' { Invoke-HibernationPolicy $ctx }
    Invoke-Step 'Service startup plan' { Invoke-Services $ctx }
    Invoke-Step 'System-wide registry' { Invoke-SystemRegistry $ctx }
    Invoke-Step 'Pagefile sizing' { Invoke-Pagefile $ctx }
    Invoke-Step 'Gaming tweaks (chassis-aware)' { Invoke-Gaming $ctx }
    Invoke-Step 'Disable wasteful scheduled tasks' { Invoke-DisableTasks }
    Invoke-Step 'Restore point (throttled)' { New-RestorePointThrottled }
    Invoke-Step 'Temp and log cleanup' { Invoke-TempCleanup }
    Invoke-Step 'Browser/Teams cache cleanup' { Invoke-BrowserCacheCleanup }
    Invoke-Step 'Aged logs/reports/dumps cleanup' { Invoke-AgedCleanup $RetentionDays (-not $SkipCrashDumps) }
    Invoke-Step 'Component-store cleanup' { Invoke-ComponentCleanup }
    Invoke-Step 'SSD retrim / HDD defrag' { Invoke-SsdTrim }
    Invoke-Step 'Trim shadow copies to newest' { Invoke-ShadowTrim }
    Invoke-Step 'Ensure Storage Sense on' { Invoke-StorageSense }
}
Write-Log 'INFO' "done Mode=$Mode warnings=$script:Warnings"
exit 0
