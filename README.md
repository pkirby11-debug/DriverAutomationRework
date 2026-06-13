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
| **Driver Updates** | A flat set of individual Dell **DUP** `.exe`s + a `manifest.json` + a DCU repository catalog | **Dell only** | DCU engine, or the built-in DUP loop as fallback |

"Driver Updates" is the newest and most capable shape: instead of one monolithic driver
pack, it tracks Dell's per-model catalog and packages each individual driver update (a
"DUP" — Dell Update Package) so devices receive exactly the drivers that have changed,
installed by Dell's own tooling.

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
  `Driver Updates (Catalog Only)` (Dell-only).
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

---

<a name="security"></a>
## Security features

**Driver exclusions.** A configurable list (Models tab → *Driver exclusions*,
`options.excludeDrivers`, or `-ExcludeDrivers`) of name/filename patterns dropped at the
catalog-match level — so an excluded driver never enters the package, the manifest, the
allowlist, or the DCU catalog, and can't be installed by *either* engine. Adding/removing a
pattern changes the package fingerprint and rebuilds the model once. Primary use: keep a
DUP that trips Defender's ASR vulnerable-driver rule out of the fleet entirely.

**Vulnerable-driver screening.** Every Dell DUP is screened at sync time against the
**Microsoft Vulnerable Driver Blocklist** (the list Defender's *"Block abuse of in-the-wild
exploited vulnerable signed drivers"* ASR rule enforces). DUPs are extracted (no install)
and their `.sys` files matched on name + file version; a match logs a red warning naming the
exact exclusion to add, plus an end-of-sync summary. Verdicts are cached per DUP. Controlled
by `-ScreenVulnerableDrivers` (default on). The standalone cmdlet
**`Test-DATVulnerableDrivers -Path <folder>`** audits any existing package on demand.

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
| `Export-DATReport` | Export a job/inventory report. |
| `Connect-DATIntune` / `Disconnect-DATIntune` / `Test-DATIntuneConnection` / `Get-DATIntuneWin32App` / `Find-DATIntuneEntraGroup` | Intune groundwork for upcoming Win32/driver-profile support. |

Standalone scripts (module-free, deployment-ready): `Scripts\Deploy-DATApplications.ps1`,
`Scripts\Set-DATDcuManaged.ps1`.

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

- **Lenovo** devices are fully supported for **Drivers** and **BIOS Updates**. The DCU
  engine, vulnerable-driver screening, exclusions, and DCU lockdown are **Dell-only** by
  design — the apply script's manufacturer gate sends Lenovo (and any non-Dell) devices to
  the classic driver-pack / BIOS-flash paths untouched. Universal improvements (CMTrace
  timestamps, VM guard, revision-churn fixes, rev stamping, log rotation) apply to all
  manufacturers.
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
