# Driver Automation Tool (DAT)

**Version 2.8.2** · PowerShell 7.4+ · Windows (ConfigMgr / SCCM, with Intune groundwork)

Automates downloading, packaging, and distributing **Dell and Lenovo driver and BIOS
updates** for Configuration Manager environments. DAT pulls each vendor's published
catalogs, builds the content into the ConfigMgr object of your choice (Package, Driver
Package, or Application), distributes it, and ships a self-contained client-side apply
script that performs the install with full CMTrace logging.

The headline capability as of the 2.x line is a **Dell Command Update (DCU) install
engine** for per-driver "Driver Updates" packages that installs *only* the drivers you
curated — never Dell's cloud catalog — and a defense-in-depth security posture around it
(vulnerable-driver screening, driver exclusions, and a DCU lockdown that keeps the tool
the sole update source).

---

## Table of contents

- [Concepts](#concepts)
- [How it works (admin side vs. client side)](#how-it-works)
- [The GUI — tab by tab](#the-gui)
  - [Models](#tab-models)
  - [SCCM Settings](#tab-sccm-settings)
  - [Progress](#tab-progress)
  - [Package Management](#tab-package-management)
  - [Deploy Applications](#tab-deploy-applications)
- [Sync types & deployment platforms](#sync-types)
- [The Driver Updates (DCU) engine](#dcu-engine)
- [Security features](#security)
- [The client apply script](#apply-script)
- [Public cmdlets / automation](#cmdlets)
- [Compliance dashboard & reporting](#reporting)
- [Logging & diagnostics](#logging)
- [Requirements](#requirements)
- [Lenovo & Microsoft support](#lenovo)
- [Change highlights (2.2 → 2.8)](#changelog)

---

<a name="concepts"></a>
## Concepts

DAT produces three different *shapes* of content, depending on what you're updating and
how you want ConfigMgr to deliver it:

| Content type | What it contains | Vendor | Install mechanism on the client |
| --- | --- | --- | --- |
| **Drivers** | A driver pack (INF tree / WIM) for a model | Dell, Lenovo | `pnputil` against the INF tree |
| **BIOS Updates** | The vendor BIOS flash utility + payload | Dell, Lenovo | Dell Flash64W / Lenovo SRSETUP |
| **Driver Updates** | Dell: a flat set of individual **DUP** `.exe`s + a `manifest.json` + a DCU repository catalog. Lenovo: one subfolder per catalog package (payload + descriptor XML) + a `manifest.json` | Dell, Lenovo | Dell: DCU engine, or the built-in DUP loop as fallback. Lenovo: built-in engine driving each package's own catalog install command |

"Driver Updates" is the newest and most capable shape: instead of one monolithic driver
pack, it tracks the vendor's per-model update catalog and packages each individual driver
update so devices receive exactly the drivers that have changed, installed the way the
vendor's own tooling would. For Dell that's the per-model catalog of DUPs (Dell Update
Packages) that Dell Command Update consumes; for Lenovo it's the per-machine-type
catalog that Lenovo System Update / Thin Installer consume, with each package's silent
extract/install command and PnPID applicability rules carried into the manifest.

---

<a name="how-it-works"></a>
## How it works (admin side vs. client side)

**Admin side** (the machine running the GUI / `Invoke-DATSync`):
1. Connects to your ConfigMgr site (WinRM + the ConfigurationManager module).
2. Downloads and caches the vendor catalogs (Dell `CatalogIndexPC` chain + per-model
   catalogs; Lenovo catalogs).
3. Resolves which drivers/BIOS apply to the selected models, downloads the content, and
   builds the chosen ConfigMgr object.
4. Stages the **client apply script** (`Invoke-DATApply.ps1`) into the package source and
   wires it as the install command.
5. Distributes content and (for Applications) creates/updates the deployment type,
   requirement rules, and folder placement.

**Client side** (the managed endpoint, via the ConfigMgr deployment):
- Runs `Invoke-DATApply.ps1` from the delivered content (ccmcache).
- Detects manufacturer, picks the correct install engine, performs the install, writes a
  detection marker to `HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation`, and logs everything
  to `DATApply.log` in CMTrace format.

The admin-side module requires **PowerShell 7.4+**; the client apply scripts remain
**Windows PowerShell 5.1 compatible** so they run anywhere ConfigMgr does.

---

<a name="the-gui"></a>
## The GUI

Launch with `Start-DATGui`. The window is WPF, follows the Windows light/dark app theme,
and hosts five tabs.

<a name="tab-models"></a>
### Models

Pick what to sync and kick off the run.

- **Manufacturer** — Dell / Lenovo / Microsoft (enabled per the selected OS).
- **OS / Architecture** — target operating system and arch the content is built for.
- **Type** — the sync shape: `Drivers`, `BIOS Updates`, `Drivers + BIOS`, or
  `Driver Updates (Catalog Only)` (Dell and Lenovo).
- **Model grid** — searchable list of catalog models; multi-select. "Known models only"
  filters to models DAT recognizes.
- **Options** (shared with the run):
  - *Remove superseded packages*, *Clean source content*, *Clean up download files*,
    *Enable Binary Differential Replication*, *Clean up unused drivers* (driver-package
    deployments only).
  - *Update individual drivers (Dell)*, *Verify download hash (Dell)*.
  - **Driver exclusions** — semicolon-separated name/filename patterns (wildcards or plain
    substrings, e.g. `Realtek Card Reader`) that are dropped from every Dell package. See
    [Security](#security).
  - **Deployment Platform** — which ConfigMgr object to build (see
    [deployment platforms](#sync-types)).
- **Sync** runs in a background runspace; live output streams to the Progress tab.

<a name="tab-sccm-settings"></a>
### SCCM Settings

Connection and path configuration, saved with the tool's settings:

- **Site server / Site code / Use SSL** — ConfigMgr connection.
- **Download path / Package (source) path** — where content is downloaded and where the
  package source share lives.
- **Distribution Points / DP Groups** — selectable grids for content distribution targets.
- Auto-connects on launch when a site server is saved.

<a name="tab-progress"></a>
### Progress

Live, color-coded log of the running sync (INFO / WARN / ERROR), plus a progress bar and a
final `Success / Skipped / Errors` summary line. This is the admin-side equivalent of
`DriverAutomationTool.log`.

When the sync finishes, a **Sync Report** grid appears above the log: one row per
model/package attempted, color-coded by outcome — updated (with the new version and
package ID), already current, nothing to package (e.g. no driver pack published for the
model/OS), or failed (with the error message) — errors sorted to the top, so there is no
need to comb the log to see what happened.

<a name="tab-package-management"></a>
### Package Management

Inventory and clean up existing DAT-built ConfigMgr objects:

- **Refresh** with a type filter (Drivers / BIOS / All), optionally including driver
  packages.
- **Grid** of existing packages (ID, name, version, manufacturer, type, source path).
- **Delete** selected packages, or **Clean up overlay packages** (removes superseded
  overlay revisions).

<a name="tab-deploy-applications"></a>
### Deploy Applications

Bulk-deploy DAT-built **Applications** to collections without leaving the tool:

- **Filter** the app list by content type (Driver / Driver Updates / BIOS), manufacturer,
  model substring, and whether to include `(Test)` apps; searchable app grid with
  select-all/none.
- **Target collection** — picker with refresh.
- **Purpose** — Available or Required; **Action** — Install or Uninstall.
- **User notifications**, **scheduling** (available time / deadline), **service-window
  overrides**, **reboot-outside-service-window**.
- **Maintenance window** — optionally create/ensure a DAT-named maintenance window on the
  target collection (start, duration, recurrence, day) so reboots the install signals are
  deferred to that window. Idempotent by name; the deploy confirmation warns before
  applying a general window to broad collections.

The same bulk deployment (including the maintenance-window option) is available headless
via `Invoke-DATDeployApplications` and the standalone `Scripts\Deploy-DATApplications.ps1`
wrapper.

---

<a name="sync-types"></a>
## Sync types & deployment platforms

**Sync types** (Models tab → Type): `Drivers`, `BIOS Updates`, `Drivers + BIOS`,
`Driver Updates (Catalog Only)`.

**Deployment platforms** (Models tab → Deployment Platform) — what ConfigMgr object the
content is built into:

- `ConfigMgr - Standard Pkg` — classic Package/Program.
- `ConfigMgr - Driver Pkg` — a ConfigMgr Driver Package (INF import).
- `ConfigMgr - Application` — a script-install Application with a deployment type,
  requirement rules (manufacturer / SystemSKU / model, plus a "Model does not contain
  Virtual" rule to exclude VMs), custom return codes, and folder placement.
- Each has a `(Test)` variant that builds the object with a test-named suffix for piloting.

Application deployment types use `BasedOnExitCode` reboot behavior, so a device only
restarts when the install script signals `3010`.

---

<a name="osd"></a>
## OSD / task-sequence driver injection

`Invoke-DATApply.ps1` is one script for both contexts. In the **full OS** it installs
drivers with `pnputil` and flashes firmware with the vendor utility (Application /
Intune / maintenance-window path). In **WinPE during a task sequence** it switches to
**offline** mode and injects the pack's INFs into the *offline* image with `dism.exe`
instead.

- **Auto-detected** in WinPE (the `X:` system drive / the `MiniNT` marker key); force it
  anywhere with `-Offline`.
- **Target volume** comes from `-TargetPath '<drive>:\'`, else the `OSDTargetSystemDrive`
  task-sequence variable, else an auto-detected fixed volume that carries `\Windows`.
- **Firmware is skipped offline.** Firmware-class INFs (`ClassGuid f2e7dd72-…` — Surface
  UEFI/SAM/ME and any OEM firmware) only install in the full OS, so they're left out of
  the offline pass; run them as a full-OS step. This is what lets a Surface pack inject
  in a task sequence at all.
- **BIOS / BIOSDCU / DriverUpdates** modes are skipped in WinPE (they need the running
  OS), and no detection marker / `3010` is written offline — the task sequence owns the
  reboot.

For a **known** package, wire a single **Run PowerShell Script** step against the staged
content:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-DATApply.ps1 ^
  -Mode Driver -PackageName "Drivers - Surface Pro 12th Edition Intel - Win11 24H2" -Version "1.0"
```

### Dynamic matching via the AdminService

`-DiscoverFromAdminService` makes one step service **every** model — the full replacement
for the legacy `Invoke-CMApplyDriverPackage.ps1`. In WinPE the script:

1. **Identifies the device** — manufacturer, model, `SystemSKU` (from `root\wmi`
   `MS_SystemInformation`), and the Lenovo 4-char machine type.
2. **Queries the ConfigMgr AdminService** (`SMS_Package` + `SMS_DriverPackage` over HTTPS),
   authenticating with a dedicated read-only service account (or default credentials).
3. **Selects the best package** — matches the device SystemSKU / machine type / model
   against each package's existing `(Models included:…)` description and DAT name
   conventions, gated by target OS / architecture, newest version wins. (No package
   rebuild needed — it reuses metadata the sync already writes.)
4. **Downloads** the match with the task sequence's `OSDDownloadContent` agent and
   **injects** it via the offline path above.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-DATApply.ps1 ^
  -Mode Driver -PackageName "DAT OSD" -Version "1.0" ^
  -DiscoverFromAdminService -AdminServiceServer "cm.contoso.com" ^
  -TargetOperatingSystem "Windows 11 24H2" -Architecture "x64"
```

Server / credentials may instead come from the TS variables `DATAdminServiceServer` /
`DATAdminServiceUser` / `DATAdminServicePassword`. The resolved PackageID is also written
to `DATDriverPackageID`, so a native **Download Package Content** step can be used in
place of the built-in download if you prefer. Stage the script itself in a small package
referenced by the step (`-File .\Invoke-DATApply.ps1`).

> The AdminService matching and content download run only in WinPE and **can't be
> exercised in CI** — validate them in a real OSD task sequence before relying on them.

---

<a name="dcu-engine"></a>
## The Driver Updates (DCU) engine

For **Dell** "Driver Updates" packages, the client apply script prefers **Dell Command
Update** as the install engine, run against the package itself as a **local repository**.
This gives device-accurate applicability (DCU inventories the real hardware rather than
trusting catalog metadata), installs spawned by the Dell-signed DCU service (which
endpoint security already trusts), and Dell's own extraction/orchestration.

**Curation guarantee — DCU installs your set or nothing.** The engine is *fail-closed*:

1. **Dell-only gate** — non-Dell devices fall straight through to the built-in engine.
2. **Lockdown (pre-run)** — DCU is put into DAT-managed passive mode (see
   [Security](#security)).
3. **Local repository** — the package's DUPs are hardlinked into a working repo; the
   package's `DCUCatalog.xml` is localized (baseLocation rewritten) and wrapped as a CAB
   (DCU 5.x requires a CAB catalog).
4. **Dell cloud disabled** — `defaultSourceLocation` is turned off for the run, restricting
   scans to the package catalog.
5. **Offline inventory** — the package embeds Dell's **Inventory Collector** (`InvColPC`),
   so DCU can inventory the system with no internet dependency.
6. **Read-only scan gate** — a `/scan` runs first; the engine refuses to install unless
   **every** proposed update is provably from your catalog. Any of these → install nothing,
   fall back to the built-in engine: a catalog-rejection signature, an inventory failure,
   or a proposed update that isn't one of your staged DUPs. Dell's own add-on channel
   (TPM/BIOS/DCU self-update) is fenced out with a per-run `-updateType` filter when it's
   cleanly separable, and the gate stays closed otherwise.
7. **Apply + re-verify** — `/applyUpdates` runs; the apply log is re-checked for catalog
   rejection so a silent cloud fallback can never be reported as success.
8. **Persistent end state** — resident DCU is left pointed at a persistent copy of your
   curated catalog with the cloud disabled, so even a tech pressing **Check** in the DCU
   GUI scans your set.

**Fallback — the built-in DUP engine.** When DCU isn't used (non-Dell device, no DCU
installed, DCU < 4.0, no catalog, a configure/inventory failure, or a gate rejection) the
script runs each DUP's own silent installer directly, with hardening learned in the field:

- Correct working directory and per-DUP `TMP`/`TEMP`.
- Pre-creates and write-probes Dell's default extract roots (`C:\dell\drivers`,
  `C:\ProgramData\Dell\Drivers`); when a DUP still fails with
  *"Error locating default extractpath"* it is re-run with the documented `/e=` extract-only
  switch and its INFs installed via `pnputil`.
- Per-DUP Dell framework log (`/l=`) captured; failure lines quote the real reason.
- Vendor exit-code mapping (0/2/6 success, 3/4/5 not-applicable, etc.), per-DUP version-skip
  markers, a hardware/GPU applicability advisory, and a Defender correlator (see below).

**The Lenovo engine.** For **Lenovo** "Driver Updates" packages there is no DCU-style
resident engine to delegate to (Thin Installer isn't factory-present the way DCU is on
Dell), so the built-in Lenovo engine drives each package exactly the way Lenovo's own
tooling would, using the install contract the sync captured from Lenovo's per-machine-type
catalog (the same feed Lenovo System Update / Thin Installer consume):

- Per-package **PnPID applicability gate** from the catalog's `Dependencies` rules —
  a package whose declared hardware isn't present is skipped as not-applicable
  (fail-open when hardware enumeration fails). BIOS, applications, component firmware
  (opt-in), and forced-reboot packages are already excluded at sync time.
- Runs the package's own `ExtractCommand` and silent `Install` command line
  (`%PACKAGEPATH%` substitution, per-package work dirs under `C:\Temp`), honoring the
  descriptor's `rc` success codes; INF-type installs go through the same `pnputil`
  machinery as driver packs.
- Reboot-required (`3010`/reboot-type 3) is signaled to ConfigMgr, never forced.
- The same per-package version-skip markers, two-strike failure quarantine, marker GC,
  and Defender correlator as the Dell loop.

---

<a name="security"></a>
## Security features

**Driver exclusions.** A configurable list (Models tab → *Driver exclusions*,
`options.excludeDrivers`, or `-ExcludeDrivers`) of name/filename patterns dropped at the
catalog-match level — so an excluded driver never enters the package, the manifest, the
allowlist, or the DCU catalog, and can't be installed by *any* engine, Dell or Lenovo.
Adding/removing a pattern changes the package fingerprint and rebuilds the model once.

**The exclusion ledger.** On top of the typed list, the tool keeps its own persistent
ledger (`Settings\DriverExclusions.json`), merged into the effective exclusions at every
sync start and managed with **`Get-DATDriverExclusion`** / **`Add-DATDriverExclusion`** /
**`Remove-DATDriverExclusion`**. Screening hits land here automatically (below), and
`Add-DATDriverExclusion -Pattern 'X' -Reason '...'` is the one-command response when a
*client's* `DATApply.log` Defender correlator flags a driver — no GUI editing, and the
entry records why and where it was seen.

**Vulnerable-driver screening + auto-exclusion.** Driver content is screened at sync time
against the **Microsoft Vulnerable Driver Blocklist** (the list Defender's *"Block abuse of
in-the-wild exploited vulnerable signed drivers"* ASR rule enforces) across all three makes:

- **Driver Updates payloads** (Dell DUPs, Lenovo catalog packages) are extracted (no
  install; Lenovo via their own `ExtractCommand`) and their `.sys` files matched on name +
  file version, with verdicts cached per payload hash. A match is **auto-excluded by
  default**: added to the ledger and dropped before it enters the manifest, on that sync
  and every future one.
- **Base Drivers packs** — Dell CAB, Lenovo pack, and **Surface MSI** (the only shape
  Surface ships in, and what OSD task sequences consume) — are scanned after the pack tree
  is fully assembled, and each matching driver's folder is **pruned from the package
  source** so neither `pnputil` (online) nor `dism` (offline OSD) can install it.
  Enforcement is the per-sync scan itself; rebuilds re-prune deterministically.

Every hit logs a red line plus an end-of-sync summary. `-AutoExcludeVulnerableDrivers:$false`
(`options.autoExcludeVulnerableDrivers`) downgrades both behaviors to advisory-only (log and
ship until excluded by hand); `-ScreenVulnerableDrivers` (default on) controls screening
itself. The standalone cmdlet **`Test-DATVulnerableDrivers -Path <folder>`** audits any
existing package on demand. One residual gap: the blocklist's hash-only entries can't be
evaluated without installing — the apply-side Defender correlator remains the net for those,
and `Add-DATDriverExclusion` turns a client-log flag into a permanent exclusion with one
command.

**Apply-side Defender correlator.** After every DUP run (success or failure — a DUP can
exit 0 while Defender silently blocks its driver write), the client checks the Defender
Operational log for ASR/quarantine events in that DUP's window, recognizes the
vulnerable-driver rule specifically, and writes the exact exclusion to add into
`DATApply.log`. Hash-only blocklist entries that sync screening can't evaluate are caught
here.

**DCU lockdown (DAT-managed mode).** Because the tool is meant to be the sole update source,
the apply engine puts DCU into a passive mode on every Dell device it runs on — no cloud
source, no scheduled scans, no auto-installs, no notifications — so resident DCU can't
self-deploy cloud content between tool runs. Asserted pre-run and re-asserted post-run; a
registry marker (`DcuManagedMode`) records state for inventory. Opt a device out with
`Set-DATDellCommandUpdateMode -Mode Default`. Available standalone for pre-staging via the
cmdlet or `Scripts\Set-DATDcuManaged.ps1` (SCCM Scripts / Intune ready).

---

<a name="apply-script"></a>
## The client apply script

`Invoke-DATApply.ps1` is staged into every package and runs on the endpoint. Highlights:

- **Self-identifying** — logs its own SHA-256 `Rev=` at start; the sync logs the same rev
  when staging, so "which script actually ran" is answered at a glance.
- **CMTrace logging** with a correctly-signed timezone bias and invariant-culture timestamps.
- **Content-completeness check** — verifies every file the DCU catalog references is present
  in the delivered content, and names anything missing (catches a stale manual copy or an
  unfinished content refresh).
- **VM guard** — exits cleanly as Installed on virtual machines (no OEM drivers apply);
  physical Surface hardware is not misclassified.
- **Self-capping log** — `DATApply.log` rolls over at a size cap to a single companion file.

Modes: `Driver`, `BIOS`, `DriverUpdates`. Reboots are signaled via exit `3010` and handled
by the deployment type's `BasedOnExitCode` behavior.

---

<a name="cmdlets"></a>
## Public cmdlets / automation

| Cmdlet | Purpose |
| --- | --- |
| `Invoke-DATSync` | The core sync — download, package, distribute. All GUI options have parameters. |
| `Start-DATGui` | Launch the WPF GUI. |
| `Get-DATDriverPack` / `Get-DATBIOSUpdate` | Query vendor catalogs for a model. |
| `Test-DATCatalogHealth` | Validate catalog source reachability/health. |
| `Update-DATCatalogSources` | Refresh cached vendor catalogs. |
| `Invoke-DATDeployApplications` | Bulk-deploy Applications to a collection (+ optional maintenance window). |
| `Update-DATApplicationCommands` | Repair install commands / return codes on existing Applications. |
| `Invoke-DATRemovePackages` / `Invoke-DATCleanupOverlayPackages` | Package cleanup. |
| `Test-DATVulnerableDrivers` | Screen a folder of DUPs / `.sys` files against the Microsoft blocklist. |
| `Set-DATDellCommandUpdateMode` | Put DCU into DAT-managed (passive) mode, or revert/opt-out. |
| `Export-DATReport` | Export a sync report (`HTML`/`CSV`) or a compliance dashboard (`Dashboard`/`Json`). |
| `Get-DATComplianceSnapshot` | Collect driver-security and storage posture as one structured object. |
| `Connect-DATIntune` / `Disconnect-DATIntune` / `Test-DATIntuneConnection` / `Get-DATIntuneWin32App` / `Find-DATIntuneEntraGroup` | Intune groundwork for upcoming Win32/driver-profile support. |

Standalone scripts (module-free, deployment-ready): `Scripts\Deploy-DATApplications.ps1`,
`Scripts\Set-DATDcuManaged.ps1`.

---

<a name="reporting"></a>
## Compliance dashboard & reporting

`Export-DATReport` has four formats. Two read the job-summary CSVs and describe
what sync *did*; two are built from `Get-DATComplianceSnapshot` and describe
what the estate *is*, so they work on a host that has never run a sync.

| Format | What it produces |
| --- | --- |
| `HTML` | The job-summary activity table (the original report). |
| `CSV` | The same rows, unformatted. |
| `Dashboard` | A self-contained interactive HTML compliance dashboard. |
| `Json` | The same snapshot as structured JSON, for Power BI. |

```powershell
# Full dashboard, including the package-share rollup
Export-DATReport -OutputPath 'C:\Reports\Compliance.html' -Format Dashboard `
    -PackagePath '\\nas01\DriverPackages'

# Snapshot only - no share walk, no network, nothing mutated
Get-DATComplianceSnapshot | Select-Object -ExpandProperty Exclusions
```

**What the dashboard shows.** Driver-security posture — the exclusion ledger
broken down by source, manufacturer, model and age, with the entries whose
`LastSeenAt` has gone quiet flagged as a review queue — plus vulnerable-driver
screening coverage and how fresh the cached Microsoft blocklist is. Then storage
consumption: package-share bytes by OEM, content type, production-vs-test
channel and OS target, the largest individual package sources, and what the tool
has accumulated on the admin host itself.

**Self-contained by design.** No CDN, no external stylesheet, no chart library —
charts are hand-built inline SVG. The file renders completely on a locked-down or
air-gapped admin host, and survives being emailed. Every chart carries a table
view underneath, so no value is reachable only by hovering, and the page prints.

**Power BI.** Point a Power BI *folder* query at wherever you drop the JSON and
refresh on a schedule; the schema is stable and carries a `SchemaVersion`. There
is deliberately no OData endpoint — OData is an HTTP protocol needing a hosted
service, not a file format, and a scheduled JSON drop on a share gets the same
dashboards with no server to run, secure or patch.

**Cost.** The snapshot never touches the network and never mutates state:
blocklist metadata is read from the existing cache rather than refreshed. The
only expensive part is the package-share walk, which is why it is opt-in behind
`-PackagePath`. That walk is a single pass — every file is visited once and its
bytes added to each bucket it belongs to.

Screening runs are recorded to `Settings\ScreeningHistory.json` (capped, newest
kept) so screening coverage survives the console scrollback.

---

<a name="logging"></a>
## Logging & diagnostics

- **Admin side:** `DriverAutomationTool.log` (CMTrace) and the live Progress tab; optional
  JSON-lines log and Teams/Slack webhook notifications; per-run job-summary CSV.
- **Client side:** `%WINDIR%\CCM\Logs\DATApply.log` (CMTrace), with per-DUP Dell framework
  logs and DCU output logs under `C:\Temp\DriverAutomationTool\`.
- **Detection / state:** `HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation` (install markers,
  per-DUP version markers, `DcuManagedMode`).

When the DCU scan finds nothing applicable, the apply log dumps the manifest summary, the
scan report, and DCU's own reasoning so a "nothing to do" verdict is verifiable rather than
blind.

---

<a name="requirements"></a>
## Requirements

- **Admin host:** PowerShell 7.4+, the ConfigMgr console / `ConfigurationManager` module,
  network access to the vendor catalogs and to your site server.
- **Clients:** Windows PowerShell 5.1+ (the apply scripts target it). For the DCU engine:
  **Dell Command Update 4.0+** installed (5.x recommended). Without DCU, Dell devices use
  the built-in DUP engine automatically.
- **ConfigMgr:** rights to create/distribute packages & applications and to deploy to
  collections.

---

<a name="lenovo"></a>
## Lenovo & Microsoft support

- **Lenovo** devices are fully supported for **Drivers**, **BIOS Updates**, and
  **Driver Updates (Catalog Only)** — the latter built from Lenovo's per-machine-type
  update catalog and installed by the built-in Lenovo engine (see
  [The Driver Updates (DCU) engine](#dcu-engine)). The DCU engine itself,
  vulnerable-driver **screening at sync time**, and DCU lockdown remain **Dell-only** by
  design (the apply-side Defender correlator and driver exclusions cover Lenovo too).
  Universal improvements (CMTrace timestamps, VM guard, revision-churn fixes, rev
  stamping, log rotation) apply to all manufacturers.
- **Microsoft (Surface)** is selectable for driver content; Surface hardware is explicitly
  protected from the VM guard's Microsoft-manufacturer heuristic.

---

<a name="changelog"></a>
## Change highlights (2.2 → 2.8)

- **2.2.x** — Dell Command Update engine for Driver Updates: local-repository install, CAB
  catalog with the `openmanifest` namespace, reserved-folder/path handling for DCU 5.x,
  self-update collision hardening, and a **fail-closed scan gate** that never lets DCU pull
  from Dell's cloud catalog.
- **2.3.0** — configurable driver-exclusion list applied at the catalog-match level.
- **2.4.x** — vulnerable-driver screening at sync + Defender correlator at apply
  (`Test-DATVulnerableDrivers`); per-run `-updateType` fence; restore hardening.
- **2.5.0 – 2.6.x** — DAT-managed DCU lockdown, made default-on in the application; corrected
  dcu-cli option grammar; durable dell.com-off via a persistent catalog end state; script
  **Rev** stamping in both logs.
- **2.7.x** — embedded Dell **Inventory Collector** so DCU scans run fully offline;
  inventory-failure → safe fallback; evidence-grade embed diagnostics.
- **2.8.x** — built-in engine **extractpath** fix (default-root pre-flight + `/e=`+`pnputil`
  fallback), all-payload repo staging (so the collector ships regardless of extension), and
  an apply-time **content-completeness check**.

---

*This README reflects version 2.8.2. The module version in
`DriverAutomationTool/DriverAutomationTool.psd1` is bumped on every change and its
`Description` field doubles as a detailed release note.*
