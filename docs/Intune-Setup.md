# Connecting the Driver Automation Tool to Intune (Microsoft Graph)

The tool talks to Intune through the Microsoft Graph API. Because driver delivery
is an unattended, back-end operation, the recommended model is **app-only
authentication**: your Entra admin registers an application, grants it the Graph
permissions below with **admin consent**, and the tool authenticates *as that app*.
This means **you do not personally need Graph/Intune rights** — the app itself is
authorized.

There are three ways to sign in, in order of how most shops run this:

| Mode | Who is authorized | Credential | Best for |
|------|-------------------|-----------|----------|
| **App-only, certificate** | the app | a certificate (private key on the run host) | unattended / scheduled, most secure (recommended) |
| **App-only, client secret** | the app | a client secret string | unattended, where certs aren't practical |
| **Interactive, device code** | the signing-in admin | none (browser sign-in) | an admin who already has Intune rights |

---

## 1. Graph permissions the app needs

Grant these as **Application permissions** on the app registration (for app-only),
or they are requested as **Delegated permissions** for interactive device-code
sign-in. Either way an admin must **grant admin consent**.

| Permission | Why |
|------------|-----|
| `DeviceManagementApps.ReadWrite.All` | Create, upload, and assign the Win32 LOB driver apps. |
| `DeviceManagementConfiguration.ReadWrite.All` | Create and assign Windows driver-update profiles. |
| `Group.Read.All` | Resolve the Entra ID groups you assign deployments to. |
| `DeviceManagementManagedDevices.Read.All` | *Optional* — read managed-device inventory for targeting. |

> The first three are required for the core flows; the last is optional. The tool
> also surfaces this list at runtime via `Get-DATIntuneRequiredPermission` (or the
> Intune tab in the GUI), so it always matches the build you're running.

---

## 2. Register the app (Entra admin)

In **Entra admin center → Identity → Applications → App registrations → New
registration**:

1. **Name**: e.g. `Driver Automation Tool`.
2. **Supported account types**: *Accounts in this organizational directory only*.
3. **Redirect URI**: leave blank for app-only. For device-code sign-in, no redirect
   URI is needed but set **Authentication → Allow public client flows = Yes**.
4. Create it, then copy the **Application (client) ID** and **Directory (tenant) ID**
   from the Overview page — you'll hand these to whoever runs the tool.

Then **API permissions → Add a permission → Microsoft Graph**:

- For app-only: choose **Application permissions** and add the permissions from the
  table above.
- For device-code: choose **Delegated permissions** and add the same names.
- Click **Grant admin consent for <tenant>** (this is the step that makes the app
  "allowed", and it requires a Privileged Role / Global Administrator).

---

## 3. Add a credential (app-only only)

Pick **one**:

**Certificate (recommended).** Create or obtain a certificate, install it (with its
private key) on the machine that will run the tool — typically
`Cert:\LocalMachine\My` for a server/scheduled task or `Cert:\CurrentUser\My` for a
desktop — and upload the **public** `.cer` to the app registration under
**Certificates & secrets → Certificates → Upload certificate**. A quick self-signed
cert for testing:

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=DriverAutomationTool' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeySpec Signature -KeyExportPolicy Exportable
Export-Certificate -Cert $cert -FilePath 'DriverAutomationTool.cer'   # upload this .cer
$cert.Thumbprint                                                       # use this to connect
```

**Client secret.** Under **Certificates & secrets → Client secrets → New client
secret**, copy the **Value** immediately (it's shown once). Note that some tenants
disable client secrets by policy — if so, use a certificate.

---

## 4. Connect from the tool

After your admin gives you the **Tenant ID**, **Client ID**, and a **certificate
thumbprint** or **client secret**:

```powershell
Import-Module DriverAutomationTool

# App-only with a certificate (looks the cert up in CurrentUser\My then LocalMachine\My)
Connect-DATIntune -AuthMode ClientCredentials -TenantId '<tenant-id>' `
    -ClientId '<client-id>' -CertificateThumbprint '<thumbprint>'

# App-only with a client secret
$secret = Read-Host -AsSecureString 'Client secret'
Connect-DATIntune -AuthMode ClientCredentials -TenantId '<tenant-id>' `
    -ClientId '<client-id>' -ClientSecret $secret

# Interactive (only if YOUR account has Intune rights) - browser device-code sign-in
Connect-DATIntune -TenantId '<tenant-id>' -ClientId '<client-id>'

# Verify
Test-DATIntuneConnection
```

`Test-DATIntuneConnection` returns `Connected = $true` / `Message = OK` when the
token and the app-management permission are both good. In the GUI, the Intune tab
provides the same connect fields and a Test button.

---

## 5. Token handling

The access token is cached in memory for the session and auto-refreshes on expiry
or a `401`. App-only tokens have no refresh token, so the tool silently re-acquires
using the stored certificate or secret. `Disconnect-DATIntune` wipes all of it.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `AADSTS650056` / consent error at sign-in | Admin consent wasn't granted on the app's API permissions (step 2). |
| `403 Forbidden` on a publish/assign call | A required permission is missing, or consent wasn't granted for it. Compare against `Get-DATIntuneRequiredPermission`. |
| `AADSTS700027` / assertion/certificate error | The public cert on the app doesn't match the private key on the run host, or the cert lacks a private key locally. |
| `invalid_client` with a secret | Secret expired or was mistyped; create a new one. Some tenants block secrets — use a certificate. |
| Device-code sign-in works for an admin but not you | Delegated mode is limited by *your* directory roles. Use app-only so authorization comes from the app, not your account. |
