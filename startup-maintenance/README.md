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
  restore point, temp/log/browser cleanup, component-store cleanup, SSD
  retrim, shadow-copy trim to newest, Storage Sense.

## Coverage vs the original batch

Covered: F8 menu; hibernation by chassis; pagefile sizing; the service plan
(disable/demand/auto/delayed, SysMain + MMAgent by RAM); system-wide registry
(long paths, responsiveness, device metadata, Ndu, verbose status, OOBE,
Defender scan CPU, WPBT, Webview override, Edge block); telemetry
minimization; debloat (Copilot, Bing, Widgets, WebExperience) via Appx; Recall
policy; wasteful scheduled tasks; the full per-user list; gaming (HPET, HAGS,
windowed-games, MMCS, chassis power plan and boost mode); cleanup (temp, logs,
browser/Teams caches, component store, SSD trim, shadow trim); winget updates
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
