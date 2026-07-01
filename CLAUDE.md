# DriverAutomationTool - Working Notes

## Versioning rule

Every change to the module bumps `ModuleVersion` in
`DriverAutomationTool/DriverAutomationTool.psd1`. The user uses the version
string to confirm the new build loaded on their box, so the bump is required
even for one-line fixes.

Semver:
- Patch (1.10.0 -> 1.10.1) for bug fixes and small internal changes.
- Minor (1.10.1 -> 1.11.0) for new features, new parameters, or new GUI
  controls.
- Major (1.x.y -> 2.0.0) for breaking changes to public functions, removed
  parameters, or anything that would force callers to update their scripts.

Update the `Description` field on the same line when the change introduces
user-visible behavior (the description doubles as a short release note).

## Adding a Surface model

Surface has no machine-readable driver catalog (unlike Dell and Lenovo), so
the model list is maintained by hand in
`DriverAutomationTool/Config/OEMSources.json` under `surface.models`.
`Get-SurfaceModelList` returns exactly these entries, so a Surface device
that isn't listed here can never appear in the GUI Models list.

Source of truth: Microsoft's official driver/firmware table at
https://learn.microsoft.com/en-us/surface/manage-surface-driver-and-firmware-updates

To add a model, add one line mapping the model name to its Microsoft
Download Center ID, plus the SystemSKU(s) the device reports:

```json
"Surface Pro 12th Edition Intel": { "id": "108671", "sku": ["Surface_Pro_for_Business_13in_12th_Ed_Intel_2103", "Surface_Pro_for_Business_13in_12th_Ed_Intel_2134"] }
```

The `id` is the `details.aspx?id=<NNNNNN>` number from that model's Download
Center page.

The `sku` is the device's System SKU - what
`(Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation).SystemSKU`
returns on the hardware. It is written into the package's
`(Models included:...)` description, which the OSD/task-sequence apply path
matches against the device. **Without a `sku`, the description falls back to
the model name, which never matches a real device** - `Get-SurfaceDriverPack`
logs a Severity-2 warning when it's missing. Use a string for one value or an
array when a model has consumer/commercial/region variants (Microsoft lists
them all in the
[Surface System SKU reference](https://learn.microsoft.com/en-us/surface/surface-system-sku-reference)).

Watch for these gotchas:
- **Per-chipset SKUs.** Microsoft now splits most models into separate Intel
  and Snapdragon (and older ones into Intel/AMD, Wi-Fi/LTE, or 5G) downloads,
  each with its own Download Center ID. Add one entry per chipset and suffix
  the name to disambiguate (e.g. `Surface Pro 11` vs `Surface Pro 11 Intel`).
- **Verify it's actually a driver pack.** Open the page and confirm its MSI
  files follow the `Product_Win<release>_<build>_<version>.msi` convention,
  which is what `Get-SurfaceDriverPack` scrapes. A wrong id can silently point
  at an unrelated download - the old `Surface Pro 9 with 5G` entry pointed at
  a Windows Group Policy spreadsheet (`104678`) instead of the real pack
  (`105941`).
- **Out of scope.** Surface Hub (ships an OS image, not a driver MSI) and
  Surface Docks (accessories, not imaging targets) are deliberately omitted.

Adding a model is user-visible, so bump `ModuleVersion` per the versioning
rule above.
