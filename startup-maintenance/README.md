# TBOK startup/weekly maintenance (SYSTEM context, non-Enterprise)

A PowerShell port of the TBOK batch feature set, built to run **at machine
startup and on a weekly schedule as SYSTEM** (no user logged in), for Home,
Pro and Pro for Workstations. It is fully non-interactive and fail-open: it
never blocks or aborts boot.

> Status: tested off-box only (parsing, detection and gating logic, service
> list parity, helper logic under PowerShell 7). Registry writes, hive
> load/unload, BitLocker suspend, scheduled-task creation and the cleanup
> actions are **not** yet tested on live Windows. Test on a VM first.

## Files

- `TBOK-Maintenance.ps1` : the SYSTEM maintenance script. `-Mode Light`
  (startup) or `-Mode Heavy` (weekly + once at install).
- `TBOK-WinGetUpdate.ps1` : per-user winget updater, run from a **logon**
  task in the user's context, because winget does not exist for SYSTEM.
- `Install-TBOKMaintenance.ps1` : registers the tasks, stages the scripts to
  an admin-only `%ProgramData%\TBOK`, and runs one Heavy pass immediately.
- `TBOK-AppDataAudit.ps1` : inventories installed apps (Add/Remove Programs
  registry across HKLM 64/32 + every user hive, plus the Appx catalog) and
  audits every profile's AppData for folders left by uninstalled programs.
  Writes a ranked CSV/HTML report. Report-first.

## AppData leftover audit

Run standalone, elevated:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\TBOK-AppDataAudit.ps1

It classifies every top-level AppData folder across all profiles:

- **MATCHED** : maps to an installed app; kept.
- **CANDIDATE** : no match found. This is a heuristic and is **report only**,
  never auto-deleted, because an AppData folder with no matching installed app
  is frequently still wanted (portable apps, shared vendor folders, data an
  uninstaller left on purpose). Review these by hand.
- **ORPHAN-APPX** : a subfolder of `AppData\Local\Packages` whose package
  family name is not in the installed Appx set. This is the one exact mapping,
  so it is the only bucket eligible for deletion.

`-Delete` deletes the ORPHAN-APPX bucket only (alias `-DeleteHighConfidence`), and even then it
skips Microsoft/framework packages, anything a running process is using, and
anything modified within `-MinAgeDays` (default 7). Microsoft and first-party
orphans are reported, not deleted. Every deletion is appended to a log under
`%ProgramData%\TBOK\Logs`. Run without `-Delete` to report only. `Win32_Product` is deliberately not used
(querying it runs a consistency check against every MSI and can trigger
repairs). Reports land in `%ProgramData%\TBOK\Reports`.

Deliberately NOT wired into the unattended weekly task: deletion of leftovers,
even the high-confidence bucket, stays a manual/opt-in run.

The component store (WinSxS) is handled here too: report mode runs the
read-only `DISM /AnalyzeComponentStore` and includes its output (and whether
cleanup is recommended) in the report; `-Delete` also runs
`StartComponentCleanup` (never `/ResetBase`, so installed updates stay
removable), logs the result, and shows a before/after analysis.

## Install

From an elevated PowerShell:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TBOKMaintenance.ps1

Remove everything:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TBOKMaintenance.ps1 -Uninstall

Tasks created: `TBOK Maintenance (Boot)`, `TBOK Maintenance (Weekly)`,
`TBOK WinGet Update (Logon)`. Logs in `%ProgramData%\TBOK\Logs`.

## Cadence

- **Light, every boot:** debloat, telemetry minimization, Copilot/Recall and
  widgets policy, F8 recovery menu, network defaults, and the full per-user
  tweak set to every profile and the Default hive. Fast and idempotent; this
  is what guards against feature updates re-adding bloat.
- **Heavy, weekly (and once at install):** Light, then services, hibernation
  policy, pagefile, system-wide registry, gaming, scheduled-task disabling,
  re-enabling beneficial Windows maintenance, restore point, temp/log/browser
  cleanup, aged log/report/dump cleanup, regenerating caches (Delivery
  Optimization, GPU shader, thumbnail/icon), component-store cleanup, .NET ngen
  queue drain, SSD retrim, shadow-copy trim to newest, Storage Sense, and a
  read-only health report. Opt-in extras (`-ClearEventLogs`,
  `-EmptyRecycleBin`) run here too when their switch is set.

## Scheduling: Automatic Maintenance (Heavy)

The Heavy task is registered as a Windows **Automatic Maintenance** task, not a
plain timed job. The reason is the failure mode of the obvious approach: a
fixed Sunday 03:00 run is useless on a home PC that is asleep or off at 3am,
and a run that fires while someone is gaming or on a call is worse than none.
Windows already solves this, so the task hands timing to the maintenance
engine. It runs only when the machine is idle and on AC power, suspends the
moment the user returns, resumes at the next idle window, and if idle never
arrives it forces the task through by a 14-day deadline (extending the
maintenance window to finish). Period is 7 days. The weekly trigger remains as
a nominal anchor and `StartWhenAvailable` still catches a missed run when the
box next wakes; the engine picks the actual moment.

This is safe only because the Heavy pass is interrupt-safe: every step is
idempotent and the two heaviest operations, defrag and file deletion, are safe
to stop mid-stride and repeat next window. The Light/boot task is deliberately
NOT a maintenance task; it must run promptly at every startup, so it keeps the
plain startup trigger.

Defrag itself is left to Windows where possible: `Optimize-Volume` and the
built-in `ScheduledDefrag` task are already media-aware (HDD gets defrag, an
SSD gets TRIM/retrim and is never defragged, tiered Storage Spaces get tier
optimization) and already idle/AC-gated. The Heavy pass re-enables that task
if a prior debloat disabled it, rather than fighting it.

## Aged log/report/dump cleanup (Heavy)

A conservative, age-gated sweep of stale system cruft that the temp pass and
the original tool do not touch. Controlled by two params on
`TBOK-Maintenance.ps1`:

- `-RetentionDays <n>` (default 30): only items whose last-write time is older
  than this are removed.
- `-SkipCrashDumps`: leave crash dumps alone (see below).

Removed (files older than the cutoff only, reparse points skipped):

- Windows log trees: `%SystemRoot%\Logs` (CBS/DISM logs and CbsPersist*.cab),
  `Panther`, `WinREAgent`, `%SystemDrive%\$WinREAgent`, and `%SystemRoot%\debug`.
- Windows Error Reporting queues and archives, machine-wide and per profile.
- Defender support logs, RetailDemo offline content, and the three built-in
  service-account TEMP folders (LocalService, NetworkService, systemprofile).
- Upgrade leftovers as whole folders, and only when stale:
  `Windows10Upgrade`, `$GetCurrent`, `$SysReset\Logs`.
- Protected upgrade trees, only when stale: `Windows.old`, `$Windows.~BT`,
  `$Windows.~WS`. These are TrustedInstaller-owned with locked ACLs, so the
  cleanup takes ownership (`takeown` + `icacls` to Administrators) before
  removing; a plain delete as SYSTEM fails partway and leaves a stub. This is
  the biggest single reclaim on an upgraded box (`Windows.old` alone is often
  10+ GB). The age gate keeps an in-progress upgrade and the 10-day rollback
  window safe: by the time the 30-day cutoff passes, rollback is already gone.
- The tool's own logs under `%ProgramData%\TBOK\Logs`, past retention. The
  current run's log is dated now, so it is never caught.
- Crash dumps (`Minidump`, `LiveKernelReports`, `MEMORY.DMP`) **unless**
  `-SkipCrashDumps` is set. These are age-gated like everything else, but a
  recent `MEMORY.DMP` may be your only record of a bugcheck, so the switch
  exists to preserve them.

Deliberately NOT touched by the age sweep, because deleting them is unsafe or
destroys forensic/servicing state:

- Event logs (`%SystemRoot%\System32\winevt\Logs\*.evtx`). Enforced in code,
  not just by omission. Age-gating by file date is meaningless for them anyway:
  an active log's timestamp tracks its newest event, so it never reads as old,
  and the Event Log service holds the files open so a plain delete fails. See
  `-ClearEventLogs` below for the one lever that actually empties them.
- `Installer\$PatchCache$` (needed for repair/uninstall of MSI products).
  Also enforced in code.
- Prefetch and the SRU database (handled by the carried-in network/perf fixes;
  wiping them hurts, does not help).
- WinSxS beyond what `StartComponentCleanup` does.
- Pagefile, hiberfil, and `Windows.edb`.

Every run logs the reclaimed MB and restates that event logs and
`$PatchCache$` were left untouched.

### Regenerating caches (not age-gated, cleared in full)

Alongside the age-gated sweep, the Heavy pass clears a few caches that
regenerate on demand, so there is no reason to keep stale copies and no age
gate to apply:

- Delivery Optimization peer cache, via the supported
  `Delete-DeliveryOptimizationCache` cmdlet. It re-downloads update/Store
  chunks on demand, so clearing it loses nothing.
- Per-profile GPU shader caches (`D3DSCache`, NVIDIA `DXCache`/`GLCache`, AMD
  `DxCache`/`DxcCache`). The only cost is a brief one-time shader recompile on
  the next game launch.
- Per-profile Explorer thumbnail and icon databases (`thumbcache_*.db`,
  `iconcache_*.db`). These are skipped silently while a logged-on user's
  Explorer holds them, so the weekly SYSTEM pass mainly catches logged-off
  profiles. They rebuild automatically.

### Internet / WinINET cache

Temporary Internet Files are cleared as cache content only, never the index or
the sign-in state. Per profile the temp pass clears `INetCache`, and the
browser pass clears the Edge/Chrome/Firefox cache trees; the machine and
service accounts (SYSTEM, LocalService, NetworkService) have their own
`INetCache` cleared too, since Windows Update, CryptoAPI and BITS browse there
as those accounts.

Deliberately never touched, because this is what breaks things: the WebCache
ESE index (`WebCacheV01.dat`), which is held open by the WebCache service and
only indexes the cache (delete it and you risk corruption or a forced rebuild,
and can drop WinINET auth state), and any cookie or credential store
(`INetCookies`, the browsers' `Cookies`/`Login Data`), which is sign-in state,
not junk. Clearing content alone recaches on demand with nothing lost; the
stale index entries reconcile themselves on next use.

### `-ClearEventLogs` (opt-in, off by default)

Home machines do not audit, and event logs already self-bound (Windows
overwrites oldest within a per-log size cap, roughly 20 MB each), so they are
not where the disk space is. When you do want them emptied, `-ClearEventLogs`
runs `wevtutil cl` across every enumerable channel through the Event Log
service, which is the only way to clear the live, locked `.evtx` files.

This switch is sharper than the rest of the sweep and is why it is opt-in:
`wevtutil` clears a whole channel at once, so it is NOT age-gated. Every event
in each cleared log is removed, including a crash or boot failure recorded
minutes ago. Disabled and analytic/debug channels refuse the clear and are
counted as skipped, which is expected, not an error. The default (switch
absent) leaves all event logs alone.

### `-EmptyRecycleBin` (opt-in, off by default)

The Recycle Bin can hold GBs, but it is the user's undo-delete safety net, so
emptying it unattended is a data-loss trap and never a default. When the
switch is set, the Heavy pass purges only items that have been **in the bin
longer than `-RetentionDays`**, not the whole bin. The in-bin age is read from
each item's `$I` metadata file (created at deletion time), not from the `$R`
data file (which keeps the original file's modified time), so a file that was
old on disk but deleted yesterday is correctly kept. Both halves of a purged
pair are removed together. Runs across every fixed drive's `$Recycle.Bin`.

## Health report (Heavy, read-only)

The Heavy pass ends by writing a read-only health snapshot to
`%ProgramData%\TBOK\Reports` (admin-readable only). Nothing in this step
changes system state; it exists so the servicing tech sees problems before the
client calls.

- `TBOK-Health-<host>-<stamp>.txt`:
  - **Auto-start inventory**, report only: `Run`/`RunOnce` across HKLM and
    every loaded user hive, the common and per-profile Startup folders, and
    enabled logon scheduled tasks. Accumulated auto-starts are the number-one
    cause of a sluggish home box, but they are listed, never disabled, because
    killing a user's startup entries unattended breaks things.
  - **Disk health and free space**: `Get-PhysicalDisk` with the SMART
    reliability counters where the drive exposes them (wear, temperature, read
    errors, reallocated sectors) and per-volume free space, with volumes under
    10 percent free flagged.
- `TBOK-SleepStudy-<host>-<stamp>.html`: `powercfg /sleepstudy` output, a power
  and idle timeline. Empty on hardware without Modern Standby, which is normal.

Also enabled in Heavy, because a performant box needs the good maintenance
running as much as the wasteful work removed: the Automatic Maintenance master
switch (`MaintenanceDisabled=0`), the media-aware `ScheduledDefrag` task, and
the `.NET Framework NGEN` tasks, all re-enabled if a prior debloat turned them
off. The `.NET` native-image queue is also drained (`ngen executeQueuedItems`)
so managed apps start faster.

## Coverage vs the original batch

Covered: F8 menu; hibernation by chassis; pagefile sizing; the service plan
(disable/demand/auto/delayed, SysMain + MMAgent by RAM); system-wide registry
(long paths, responsiveness, device metadata, Ndu, verbose status, OOBE,
Defender scan CPU, WPBT, Webview override, Edge block); telemetry
minimization; debloat (Copilot, Bing, Widgets, WebExperience) via Appx; Recall
policy; wasteful scheduled tasks; the full per-user list; gaming (HPET, HAGS,
windowed-games, MMCS, chassis power plan and boost mode); cleanup (temp, logs,
browser/Teams caches, aged logs/reports/dumps, Windows.old and upgrade
staging, Delivery Optimization and GPU/thumbnail caches, component store, SSD
trim, shadow trim); re-enabling beneficial Windows maintenance (ScheduledDefrag,
Automatic Maintenance, NGEN) and draining the ngen queue; a read-only health
report (auto-start inventory, disk SMART and free space, sleep-study timeline);
Automatic Maintenance scheduling for the Heavy pass; winget updates
via the per-user logon task.

Deliberately different from the original:

- **Telemetry is minimized, not disabled.** `AllowTelemetry=0` is clamped to 1
  on Home/Pro; only Enterprise/Education/LTSC can reach 0.
- **No network folklore.** Network throttling index and IRP stack size are
  omitted; they do not affect throughput. Autotuning is kept Normal and RSS is
  enabled on >=1 Gbps links.
- **Data-loss cleanup fixes are carried in.** No deletion of Word/Excel
  AutoRecover, OneNote cache or the Office Document Cache; Prefetch and the SRU
  database are left alone; shadows are trimmed to the newest, not wiped.
- **Admin-disabled services are never re-enabled.**

Full-parity items included with caveats (logged as warnings at runtime):

- **WPBT disable** also stops firmware anti-theft (Computrace/Absolute) from
  persisting.
- **Webview classic-search override** is keyed to a build-specific
  FeatureManagement ID and may be a no-op on some builds.
- **Pagefile** is resized by RAM; systems with 32 GB or more are left alone.
- **Page combining** is enabled only on low-memory (<=12 GB) machines, matching
  the original; it is memory de-duplication, which has had cross-process
  side-channel research against it.
