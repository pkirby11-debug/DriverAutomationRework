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
