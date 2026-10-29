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
  restore point, temp/log/browser cleanup, aged log/report/dump cleanup,
  component-store cleanup, SSD retrim, shadow-copy trim to newest, Storage
  Sense.

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

## Coverage vs the original batch

Covered: F8 menu; hibernation by chassis; pagefile sizing; the service plan
(disable/demand/auto/delayed, SysMain + MMAgent by RAM); system-wide registry
(long paths, responsiveness, device metadata, Ndu, verbose status, OOBE,
Defender scan CPU, WPBT, Webview override, Edge block); telemetry
minimization; debloat (Copilot, Bing, Widgets, WebExperience) via Appx; Recall
policy; wasteful scheduled tasks; the full per-user list; gaming (HPET, HAGS,
windowed-games, MMCS, chassis power plan and boost mode); cleanup (temp, logs,
browser/Teams caches, aged logs/reports/dumps, component store, SSD trim,
shadow trim); winget updates
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
