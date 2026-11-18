# Shared helpers for the deploy scripts: device code sign-in and a small Web API wrapper.
# Dot-source after setting $EnvironmentUrl, $TenantId and $SolutionName.

$EnvironmentUrl = $EnvironmentUrl.TrimEnd("/")
$Api = "$EnvironmentUrl/api/data/v9.2"

function Get-DataverseToken {
    $clientId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Microsoft Azure CLI (public client)
    $scope = "$EnvironmentUrl/user_impersonation offline_access"
    $dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $clientId; scope = $scope }
    Write-Host ""
    Write-Host $dc.message -ForegroundColor Yellow
    Write-Host ""
    while ($true) {
        Start-Sleep -Seconds $dc.interval
        try {
            $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $clientId
                device_code = $dc.device_code
            }
            return $tok.access_token
        } catch {
            $err = $_.ErrorDetails.Message
            if ($err -match "authorization_pending" -or $err -match "slow_down") { continue }
            throw "Sign-in failed: $err"
        }
    }
}

function Invoke-Dv {
    param([string]$Method, [string]$Path, $Body, [switch]$Solution, [switch]$Return)
    $headers = @{
        Authorization      = "Bearer $script:Token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
    }
    if ($Solution) { $headers["MSCRM.SolutionUniqueName"] = $SolutionName }
    if ($Return)   { $headers["Prefer"] = "return=representation" }
    $params = @{ Method = $Method; Uri = "$Api/$Path"; Headers = $headers; TimeoutSec = 180 }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress }
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = "application/json; charset=utf-8"
    }
    try {
        Invoke-RestMethod @params
    } catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        throw "$Method $Path failed: $msg"
    }
}

function Step([string]$Text) { Write-Host "  - $Text" }
