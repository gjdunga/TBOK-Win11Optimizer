#Requires -Version 5.1
<#
.SYNOPSIS
  Inventories installed apps and audits every profile's AppData for folders
  left behind by uninstalled programs. Report-first by design.

.DESCRIPTION
  Installed-app index is built from the Add/Remove Programs registry (HKLM
  64-bit + WOW6432Node + each user's HKCU, including offline profile hives),
  the Appx/MSIX catalog (Get-AppxPackage -AllUsers), and optionally the MSI
  catalog via COM. Win32_Product is deliberately NOT used (querying it runs a
  consistency check against every MSI and can trigger repairs).

  It then walks Roaming, Local and LocalLow for every profile and classifies
  each top-level folder:
    - MATCHED      : maps to an installed app (kept).
    - CANDIDATE    : no match found. Heuristic only. REPORT ONLY, never
                     deleted automatically. Scored by age / size / in-use.
    - ORPHAN-APPX  : a subfolder of AppData\Local\Packages whose package
                     family name is not in the installed Appx set. This is the
                     only exact mapping, so it is the only "high-confidence"
                     bucket eligible for deletion with -DeleteHighConfidence.

  Even ORPHAN-APPX deletion excludes Microsoft/framework packages, anything a
  running process is using, and anything modified within -MinAgeDays.

.PARAMETER DeleteHighConfidence
  Delete the ORPHAN-APPX bucket (third-party Store-app data only). Heuristic
  CANDIDATE folders are never deleted regardless of this switch.

.PARAMETER MinAgeDays       Skip anything modified within this many days (default 7).
.PARAMETER ReportDir        Where to write the CSV/HTML report.
.PARAMETER CurrentUserOnly  Audit only the invoking profile instead of all.
.PARAMETER WhatIfOnly       Classify and report; make no changes even with -DeleteHighConfidence.

.NOTES
  Not tested on live Windows. Logic checked off-box. Test on a VM.
#>
[CmdletBinding()]
param(
    [switch]$DeleteHighConfidence,
    [int]$MinAgeDays = 7,
    [string]$ReportDir = (Join-Path $env:ProgramData 'TBOK\Reports'),
    [switch]$CurrentUserOnly,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$cutoff = (Get-Date).AddDays(-$MinAgeDays)
try { [void][System.IO.Directory]::CreateDirectory($ReportDir) } catch { }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath  = Join-Path $ReportDir ("AppDataAudit-{0}-{1}.csv"  -f $env:COMPUTERNAME, $stamp)
$htmlPath = Join-Path $ReportDir ("AppDataAudit-{0}-{1}.html" -f $env:COMPUTERNAME, $stamp)
$rows = New-Object System.Collections.ArrayList
function Log($m){ Write-Output ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---- normalization + install index ----------------------------------------
function Get-Norm([string]$s){ if(-not $s){return ''}; ($s.ToLowerInvariant() -replace '[^a-z0-9]','') }

function Get-InstalledIndex {
    $tokens = New-Object System.Collections.Generic.HashSet[string]
    $installPaths = New-Object System.Collections.ArrayList
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'

    function Read-UninstallHive([string]$root){
        foreach ($sub in @("$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall","$root\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")) {
            if (-not (Test-Path -LiteralPath $sub)) { continue }
            foreach ($k in (Get-ChildItem -LiteralPath $sub -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                if ($p.SystemComponent -eq 1) { continue }
                foreach ($v in @($p.DisplayName,$p.Publisher)) { $n = Get-Norm $v; if ($n.Length -ge 3) { [void]$tokens.Add($n) } }
                foreach ($loc in @($p.InstallLocation, (Split-Path ([string]$p.DisplayIcon).Trim('"') -Parent -ErrorAction SilentlyContinue))) {
                    if ($loc -and (Test-Path -LiteralPath $loc -ErrorAction SilentlyContinue)) { [void]$installPaths.Add(($loc.TrimEnd('\').ToLowerInvariant())) }
                }
            }
        }
    }
    Read-UninstallHive 'HKLM:'
    # Per-user ARP: loaded hives, then offline profile hives.
    $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users','Registry64')
    $loaded = @($users.GetSubKeyNames() | Where-Object { $_ -match '^S-1-(5-21|12-1)-[\d-]+$' -and $_ -notlike '*_Classes' })
    foreach ($sid in $loaded) { Read-UninstallHive "Registry::HKEY_USERS\$sid" }
    $pl = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
    foreach ($sid in $pl.GetSubKeyNames()) {
        if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$' -or $loaded -contains $sid) { continue }
        $pp = $pl.OpenSubKey($sid); $path=[Environment]::ExpandEnvironmentVariables([string]$pp.GetValue('ProfileImagePath')); $pp.Close()
        $dat = Join-Path $path 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { continue }
        $mount='TBOK_'+[guid]::NewGuid().ToString('N').Substring(0,12)
        & $reg load "HKU\$mount" $dat *> $null
        if ($LASTEXITCODE -ne 0) { continue }
        try { Read-UninstallHive "Registry::HKEY_USERS\$mount" }
        finally { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); for($i=1;$i -le 5;$i++){ & $reg unload "HKU\$mount" *> $null; if($LASTEXITCODE -eq 0){break}; Start-Sleep -Milliseconds (300*$i) } }
    }
    $pl.Close(); $users.Close()

    # Appx: exact package-family-name set.
    $appx = New-Object System.Collections.Generic.HashSet[string]
    try { Get-AppxPackage -AllUsers -ErrorAction Stop | ForEach-Object { [void]$appx.Add($_.PackageFamilyName) } }
    catch { try { Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { [void]$appx.Add($_.PackageFamilyName) } } catch { } }

    [pscustomobject]@{ Tokens=$tokens; InstallPaths=$installPaths; Appx=$appx }
}

# Folders that look like apps but are system/shared: never flag.
$script:SystemFolders = @(
    'microsoft','packages','temp','tmp','d3dscache','connecteddevicesplatform','comms','virtualstore',
    'elevateddiagnostics','iconcache','crashdumps','placeholdertilelogofolder','peerdistrepub','grouppolicy',
    'publishers','packagestaging','tiledatalayer','application data','history','applicationdata',
    'windows','windowsapps','microsoftedge','microsoft onedrive','onedrive'
) | ForEach-Object { $_.ToLowerInvariant() }

# Appx package families we never auto-delete even if unmatched (frameworks/system).
function Test-FrameworkPfn([string]$pfn){
    $p = $pfn.ToLowerInvariant()
    return ($p -like 'microsoft.vclibs*' -or $p -like 'microsoft.net.*' -or $p -like 'microsoft.ui.xaml*' -or
            $p -like 'microsoft.windowsappruntime*' -or $p -like 'microsoft.services.store*' -or
            $p -like 'microsoft.*' -or $p -like 'microsoftwindows.*' -or $p -like 'windows.*')
}

function Get-FolderSize([string]$path){
    try { $s=(Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum; if($s){[int64]$s}else{[int64]0} } catch { [int64]0 }
}
function ConvertTo-HtmlText([string]$s){ ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }

# ---- main ------------------------------------------------------------------
Log 'building installed-app index'
$idx = Get-InstalledIndex
Log ("index: {0} name/publisher tokens, {1} install paths, {2} Appx families" -f $idx.Tokens.Count,$idx.InstallPaths.Count,$idx.Appx.Count)

# running process exe paths, for in-use detection
$procPaths = @{}
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { try { if ($p.Path) { $procPaths[$p.Path.ToLowerInvariant()] = $true } } catch { } }
function Test-InUse([string]$folder){ $f=$folder.ToLowerInvariant(); foreach($pp in $procPaths.Keys){ if($pp.StartsWith($f + '\')){ return $true } }; return $false }

# profiles to audit
$profiles = New-Object System.Collections.ArrayList
if ($CurrentUserOnly) { [void]$profiles.Add([pscustomobject]@{Name=$env:USERNAME; Path=$env:USERPROFILE}) }
else {
    $pl = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
    foreach ($sid in $pl.GetSubKeyNames()) {
        if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { continue }
        $pp=$pl.OpenSubKey($sid); $path=[Environment]::ExpandEnvironmentVariables([string]$pp.GetValue('ProfileImagePath')); $pp.Close()
        if ($path -and (Test-Path -LiteralPath $path)) { [void]$profiles.Add([pscustomobject]@{Name=(Split-Path $path -Leaf); Path=$path}) }
    }
    $pl.Close()
}

$deleted = 0; $reclaim = [int64]0
foreach ($prof in $profiles) {
    foreach ($root in 'AppData\Roaming','AppData\Local','AppData\LocalLow') {
        $base = Join-Path $prof.Path $root
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }   # skip junctions
            $name = $dir.Name; $norm = Get-Norm $name
            if ($script:SystemFolders -contains $name.ToLowerInvariant()) { continue }

            # Appx Packages: the only exact mapping.
            if ($root -eq 'AppData\Local' -and $name -ieq 'Packages') {
                foreach ($pkg in (Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    if ($pkg.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $pfn = $pkg.Name
                    if ($idx.Appx.Contains($pfn)) { continue }                 # installed: keep
                    $inUse = Test-InUse $pkg.FullName
                    $recent = $pkg.LastWriteTime -gt $cutoff
                    $fw = Test-FrameworkPfn $pfn
                    $size = Get-FolderSize $pkg.FullName
                    $action = 'Reported'
                    $eligible = (-not $fw) -and (-not $inUse) -and (-not $recent)
                    if ($DeleteHighConfidence -and $eligible) {
                        if ($WhatIfOnly) { $action = 'WouldDelete' }
                        else { try { Remove-Item -LiteralPath $pkg.FullName -Recurse -Force -ErrorAction Stop; $action='Deleted'; $deleted++; $reclaim+=$size } catch { $action='DeleteFailed:'+$_.Exception.Message } }
                    }
                    [void]$rows.Add([pscustomobject]@{
                        Profile=$prof.Name; Root=$root; Folder="Packages\$pfn"; Class='ORPHAN-APPX'
                        Confidence=$(if($fw){'skip-framework'}elseif($inUse){'skip-inuse'}elseif($recent){'skip-recent'}else{'high'})
                        MatchedApp=''; SizeMB=[math]::Round($size/1MB,1); LastWrite=$pkg.LastWriteTime.ToString('yyyy-MM-dd'); Action=$action
                    })
                }
                continue
            }

            # Heuristic match for ordinary AppData folders (report only).
            $matched = $false; $how = ''
            if ($idx.Tokens.Contains($norm)) { $matched=$true; $how='name==token' }
            if (-not $matched) { foreach ($t in $idx.Tokens) { if ($t.Length -ge 4 -and ($t.Contains($norm) -or $norm.Contains($t))) { $matched=$true; $how='name~token'; break } } }
            if (-not $matched) { $lf=$dir.FullName.ToLowerInvariant(); foreach ($ip in $idx.InstallPaths) { if ($ip -and ($lf.StartsWith($ip) -or $ip.Contains($norm))) { $matched=$true; $how='installpath'; break } } }

            $inUse = Test-InUse $dir.FullName
            $recent = $dir.LastWriteTime -gt $cutoff
            $size = Get-FolderSize $dir.FullName
            if ($matched) {
                [void]$rows.Add([pscustomobject]@{ Profile=$prof.Name; Root=$root; Folder=$name; Class='MATCHED'; Confidence=$how; MatchedApp=$how; SizeMB=[math]::Round($size/1MB,1); LastWrite=$dir.LastWriteTime.ToString('yyyy-MM-dd'); Action='Kept' })
            } else {
                # Heuristic candidate: scored, NEVER auto-deleted.
                $conf = 'low'
                if (-not $inUse -and -not $recent -and $size -gt 0) { $conf = 'review' }
                if (-not $inUse -and $dir.LastWriteTime -lt (Get-Date).AddDays(-180)) { $conf = 'review-stale' }
                [void]$rows.Add([pscustomobject]@{ Profile=$prof.Name; Root=$root; Folder=$name; Class='CANDIDATE'; Confidence=$(if($inUse){'in-use'}else{$conf}); MatchedApp=''; SizeMB=[math]::Round($size/1MB,1); LastWrite=$dir.LastWriteTime.ToString('yyyy-MM-dd'); Action='ReportOnly' })
            }
        }
    }
}

# ---- output ----------------------------------------------------------------
$sorted = $rows | Sort-Object @{e={switch($_.Class){'ORPHAN-APPX'{0}'CANDIDATE'{1}default{2}}}}, @{e={-$_.SizeMB}}
$sorted | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$style = "body{font-family:Segoe UI,Arial,sans-serif;font-size:13px} table{border-collapse:collapse} th,td{border:1px solid #ccc;padding:4px 8px} th{background:#eee;text-align:left} .ORPHANAPPX{background:#fde} .CANDIDATE{background:#ffd} .MATCHED{color:#777}"
$html = "<html><head><meta charset='utf-8'><style>$style</style></head><body><h2>TBOK AppData audit: $env:COMPUTERNAME $stamp</h2>"
$html += "<p>ORPHAN-APPX = unmatched Store-app data (high confidence). CANDIDATE = heuristic, review only, never auto-deleted. MATCHED = kept.</p><table><tr><th>Profile</th><th>Root</th><th>Folder</th><th>Class</th><th>Confidence</th><th>SizeMB</th><th>LastWrite</th><th>Action</th></tr>"
foreach ($r in $sorted) { $cls=($r.Class -replace '[^A-Za-z]',''); $html += "<tr class='$cls'><td>$($r.Profile)</td><td>$($r.Root)</td><td>$(ConvertTo-HtmlText $r.Folder)</td><td>$($r.Class)</td><td>$($r.Confidence)</td><td>$($r.SizeMB)</td><td>$($r.LastWrite)</td><td>$($r.Action)</td></tr>" }
$html += "</table></body></html>"
try { Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8 } catch { }

$orphan = @($rows | Where-Object Class -eq 'ORPHAN-APPX')
$cand   = @($rows | Where-Object Class -eq 'CANDIDATE')
Log ("rows: {0}  orphan-appx: {1}  candidates(review): {2}  deleted: {3}  reclaimed: {4} MB" -f $rows.Count,$orphan.Count,$cand.Count,$deleted,[math]::Round($reclaim/1MB,1))
Log "CSV:  $csvPath"
Log "HTML: $htmlPath"
if (-not $DeleteHighConfidence) { Log 'report only (no deletions). Pass -DeleteHighConfidence to remove the ORPHAN-APPX bucket.' }
exit 0
