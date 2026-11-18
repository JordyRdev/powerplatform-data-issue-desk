<#
.SYNOPSIS
    Creates the service principal that GitHub Actions uses to export, check and deploy the solution.

.DESCRIPTION
    - registers the app "Data Issue Desk - GitHub Actions" in Entra ID with a client secret
    - adds it as an application user with the System Administrator role in the dev and test environments
    - prints the values to store as GitHub secrets and variables

    One device code sign-in covers Microsoft Graph and both environments.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-alm.ps1 -TestEnvironmentUrl https://orgxxxx.crm17.dynamics.com
#>
param(
    [Parameter(Mandatory = $true)][string]$TestEnvironmentUrl,
    [string]$DevEnvironmentUrl = "https://orgf894f4c2.crm17.dynamics.com",
    [string]$TenantId = "8f2aa460-a99b-402e-b93d-d958227d6f3c",
    [string]$AppName = "Data Issue Desk - GitHub Actions"
)

$ErrorActionPreference = "Stop"
$DevEnvironmentUrl = $DevEnvironmentUrl.TrimEnd("/")
$TestEnvironmentUrl = $TestEnvironmentUrl.TrimEnd("/")
$ClientId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Microsoft Azure CLI (public client)
$SysAdminTemplate = "627090ff-40a3-4053-8790-584edc5be201"

function Step([string]$Text) { Write-Host "  - $Text" }

# ------------------------------------------------------------------------------------------
# Sign-in once, then reuse the refresh token for each resource
# ------------------------------------------------------------------------------------------
$dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $ClientId; scope = "https://graph.microsoft.com/.default offline_access" }
Write-Host ""; Write-Host $dc.message -ForegroundColor Yellow; Write-Host ""
while ($true) {
    Start-Sleep -Seconds $dc.interval
    try {
        $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $dc.device_code }
        break
    } catch {
        if ($_.ErrorDetails.Message -match "authorization_pending|slow_down") { continue }
        throw "Sign-in failed: $($_.ErrorDetails.Message)"
    }
}
$script:Refresh = $tok.refresh_token
$GraphToken = $tok.access_token
Write-Host "Signed in." -ForegroundColor Green

function Get-Token([string]$Resource) {
    $t = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        grant_type = "refresh_token"; client_id = $ClientId; refresh_token = $script:Refresh; scope = "$Resource/.default offline_access" }
    $script:Refresh = $t.refresh_token
    $t.access_token
}

function Invoke-Api([string]$Method, [string]$Uri, [string]$Token, $Body) {
    $p = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }; TimeoutSec = 120 }
    if ($null -ne $Body) {
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
        $p.ContentType = "application/json; charset=utf-8"
    }
    try { Invoke-RestMethod @p }
    catch { $m = $_.ErrorDetails.Message; if (-not $m) { $m = $_.Exception.Message }; throw "$Method $Uri failed: $m" }
}

# ------------------------------------------------------------------------------------------
# App registration and client secret
# ------------------------------------------------------------------------------------------
Write-Host "`nApp registration" -ForegroundColor Cyan
$graph = "https://graph.microsoft.com/v1.0"
$app = (Invoke-Api GET "$graph/applications?`$filter=displayName eq '$AppName'" $GraphToken).value | Select-Object -First 1
if (-not $app) {
    $app = Invoke-Api POST "$graph/applications" $GraphToken @{ displayName = $AppName; signInAudience = "AzureADMyOrg" }
    Step "app registration created"
} else { Step "app registration exists" }

$sp = (Invoke-Api GET "$graph/servicePrincipals?`$filter=appId eq '$($app.appId)'" $GraphToken).value | Select-Object -First 1
if (-not $sp) { Invoke-Api POST "$graph/servicePrincipals" $GraphToken @{ appId = $app.appId } | Out-Null; Step "service principal created" }
else { Step "service principal exists" }

$secret = Invoke-Api POST "$graph/applications/$($app.id)/addPassword" $GraphToken @{
    passwordCredential = @{ displayName = "github-actions"; endDateTime = (Get-Date).AddMonths(12).ToString("o") } }
Step "client secret created (valid 12 months)"

# ------------------------------------------------------------------------------------------
# Application user with System Administrator in both environments
# ------------------------------------------------------------------------------------------
foreach ($url in @($DevEnvironmentUrl, $TestEnvironmentUrl)) {
    Write-Host "`nApplication user in $url" -ForegroundColor Cyan
    $api = "$url/api/data/v9.2"
    $t = Get-Token $url
    $bu = (Invoke-Api GET "$api/businessunits?`$select=businessunitid&`$filter=_parentbusinessunitid_value eq null" $t).value[0].businessunitid
    $user = (Invoke-Api GET "$api/systemusers?`$select=systemuserid&`$filter=applicationid eq $($app.appId)" $t).value | Select-Object -First 1
    if (-not $user) {
        # Dataverse can take a minute to see a brand new service principal
        for ($i = 1; $i -le 6; $i++) {
            try {
                Invoke-Api POST "$api/systemusers" $t @{ applicationid = $app.appId; "businessunitid@odata.bind" = "/businessunits($bu)" } | Out-Null
                break
            } catch { if ($i -eq 6) { throw }; Step "waiting for the service principal to sync..."; Start-Sleep -Seconds 20 }
        }
        $user = (Invoke-Api GET "$api/systemusers?`$select=systemuserid&`$filter=applicationid eq $($app.appId)" $t).value[0]
        Step "application user created"
    } else { Step "application user exists" }

    $role = (Invoke-Api GET "$api/roles?`$select=roleid&`$filter=_roletemplateid_value eq $SysAdminTemplate and _businessunitid_value eq $bu" $t).value
    if (-not $role) { $role = (Invoke-Api GET "$api/roles?`$select=roleid&`$filter=_roletemplateid_value eq $SysAdminTemplate" $t).value }
    try {
        Invoke-Api POST "$api/systemusers($($user.systemuserid))/systemuserroles_association/`$ref" $t @{ "@odata.id" = "$api/roles($($role[0].roleid))" } | Out-Null
        Step "System Administrator role assigned"
    } catch { if ($_.Exception.Message -match "duplicate|already") { Step "role already assigned" } else { throw } }
}

# ------------------------------------------------------------------------------------------
# Remove connection references left over from earlier mail connector tries, so they are not exported
# ------------------------------------------------------------------------------------------
$t = Get-Token $DevEnvironmentUrl
foreach ($old in @("jrd_mail", "jrd_gmail")) {
    $ref = (Invoke-Api GET "$DevEnvironmentUrl/api/data/v9.2/connectionreferences?`$select=connectionreferenceid&`$filter=connectionreferencelogicalname eq '$old'" $t).value
    if ($ref) { Invoke-Api DELETE "$DevEnvironmentUrl/api/data/v9.2/connectionreferences($($ref[0].connectionreferenceid))" $t | Out-Null; Step "removed unused connection reference $old" }
}

# ------------------------------------------------------------------------------------------
Write-Host "`nAdd these to GitHub: repository Settings > Secrets and variables > Actions" -ForegroundColor Green
Write-Host "`n  Secrets:"
Write-Host "    PP_TENANT_ID      $TenantId"
Write-Host "    PP_APP_ID         $($app.appId)"
Write-Host "    PP_CLIENT_SECRET  $($secret.secretText)"
Write-Host "`n  Variables:"
Write-Host "    PP_DEV_URL        $DevEnvironmentUrl"
Write-Host "    PP_TEST_URL       $TestEnvironmentUrl"
Write-Host "`nThe secret is shown only once. Close this window after copying it." -ForegroundColor Yellow
