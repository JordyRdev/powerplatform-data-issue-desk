<#
.SYNOPSIS
    Deploys the cloud flows of the Data Issue Desk solution from src/flows.

.DESCRIPTION
    Inside the solution "DataIssueDesk" this script:
      - creates the connection references the flows use (Dataverse, Approvals, Outlook)
      - creates the environment variable "Approver email"; for the demo, it and "Data team mailbox"
        are set to the signed-in user so approvals and emails arrive in your own inbox
      - creates each flow from its definition in src/flows, or updates it when it already exists

    Flows are created turned off. Link the connection references to a connection,
    then turn the flows on (see the README).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\deploy-flows.ps1
#>
param(
    [string]$EnvironmentUrl = "https://orgf894f4c2.crm17.dynamics.com",
    [string]$TenantId = "8f2aa460-a99b-402e-b93d-d958227d6f3c",
    [string]$SolutionName = "DataIssueDesk",
    [string]$ApproverEmail,
    [switch]$UpdateExisting   # also push the definition of flows that already exist (turns them off)
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\dataverse.ps1")

$script:Token = Get-DataverseToken
Write-Host "Signed in." -ForegroundColor Green

# ------------------------------------------------------------------------------------------
# Connection references
# ------------------------------------------------------------------------------------------
Write-Host "`nConnection references" -ForegroundColor Cyan
$ConnectionRefs = @(
    @{ logical = "jrd_dataverse"; display = "Data Issue Desk - Dataverse"; connector = "shared_commondataserviceforapps" },
    @{ logical = "jrd_approvals"; display = "Data Issue Desk - Approvals"; connector = "shared_approvals" },
    @{ logical = "jrd_outlook";   display = "Data Issue Desk - Outlook";   connector = "shared_office365" }
)
foreach ($c in $ConnectionRefs) {
    $found = (Invoke-Dv GET "connectionreferences?`$select=connectionreferenceid&`$filter=connectionreferencelogicalname eq '$($c.logical)'").value
    if ($found) { Step "$($c.logical) exists"; continue }
    Invoke-Dv POST "connectionreferences" @{
        connectionreferencelogicalname  = $c.logical
        connectionreferencedisplayname  = $c.display
        connectorid                     = "/providers/Microsoft.PowerApps/apis/$($c.connector)"
    } -Solution | Out-Null
    Step "$($c.logical) created"
}

# ------------------------------------------------------------------------------------------
# Environment variable: approver email (defaults to the signed-in user)
# ------------------------------------------------------------------------------------------
Write-Host "`nEnvironment variables" -ForegroundColor Cyan
if (-not $ApproverEmail) {
    $me = Invoke-Dv GET "WhoAmI"
    $ApproverEmail = (Invoke-Dv GET "systemusers($($me.UserId))?`$select=internalemailaddress").internalemailaddress
}
function Set-EnvValue([string]$Schema, [string]$Value) {
    $defId = (Invoke-Dv GET "environmentvariabledefinitions?`$select=environmentvariabledefinitionid&`$filter=schemaname eq '$Schema'").value[0].environmentvariabledefinitionid
    $val = (Invoke-Dv GET "environmentvariablevalues?`$select=environmentvariablevalueid&`$filter=_environmentvariabledefinitionid_value eq $defId").value
    if ($val) {
        Invoke-Dv PATCH "environmentvariablevalues($($val[0].environmentvariablevalueid))" @{ value = $Value } | Out-Null
    } else {
        Invoke-Dv POST "environmentvariablevalues" @{
            schemaname                                   = "$($Schema)_value"
            value                                        = $Value
            "EnvironmentVariableDefinitionId@odata.bind" = "/environmentvariabledefinitions($defId)"
        } | Out-Null
    }
    Step "$Schema = $Value"
}

$found = (Invoke-Dv GET "environmentvariabledefinitions?`$select=schemaname&`$filter=schemaname eq 'jrd_ApproverEmail'").value
if (-not $found) {
    Invoke-Dv POST "environmentvariabledefinitions" @{
        schemaname   = "jrd_ApproverEmail"
        displayname  = "Approver email"
        type         = 100000000
        defaultvalue = ""
        description  = "Who approves high and critical issues."
    } -Solution | Out-Null
    Step "jrd_ApproverEmail created"
}
Set-EnvValue "jrd_ApproverEmail" $ApproverEmail
Set-EnvValue "jrd_TeamMailbox" $ApproverEmail

# ------------------------------------------------------------------------------------------
# Flows
# ------------------------------------------------------------------------------------------
Write-Host "`nFlows" -ForegroundColor Cyan
# The notify flow is a child flow: it goes first so the others can point to its id.
$Flows = @(
    @{ file = "NotifySendEmail.json";       name = "Notify | Send email";        description = "Child flow that sends the emails of the other flows." },
    @{ file = "IssueRequestApproval.json";  name = "Issue | Request approval";   description = "Sends high and critical issues for approval and records the outcome." },
    @{ file = "IssueEscalate.json";         name = "Issue | Escalate";           description = "Called from the app: logs the escalation and emails the data team." },
    @{ file = "IssueOverdueReminder.json";  name = "Issue | Overdue reminder";   description = "Every morning: emails the data team a table of issues open too long." }
)
$NotifyId = $null
foreach ($f in $Flows) {
    # ReadAllText returns a plain string; Get-Content adds PS* properties that ConvertTo-Json would try to serialize
    $clientdata = [System.IO.File]::ReadAllText((Join-Path $Root "src\flows\$($f.file)"), [System.Text.Encoding]::UTF8)
    if ($NotifyId) { $clientdata = $clientdata.Replace("__NOTIFY_FLOW_ID__", $NotifyId) }
    $found = (Invoke-Dv GET "workflows?`$select=workflowid,statecode&`$filter=category eq 5 and name eq '$($f.name)'").value
    if ($found -and -not $UpdateExisting) {
        $id = $found[0].workflowid
        Step "$($f.name) exists, skipped (use -UpdateExisting to overwrite)"
    } elseif ($found) {
        $id = $found[0].workflowid
        if ($found[0].statecode -eq 1) {
            Invoke-Dv PATCH "workflows($id)" @{ statecode = 0; statuscode = 1 } | Out-Null
        }
        Invoke-Dv PATCH "workflows($id)" @{ clientdata = $clientdata; description = $f.description } | Out-Null
        Step "$($f.name) updated (turned off: turn it on again)"
    } else {
        $id = (Invoke-Dv POST "workflows" @{
            category      = 5
            type          = 1
            primaryentity = "none"
            name          = $f.name
            description   = $f.description
            clientdata    = $clientdata
        } -Solution -Return).workflowid
        Step "$($f.name) created"
    }
    if ($f.file -eq "NotifySendEmail.json") { $NotifyId = $id }
}

Write-Host "`nDone. Next: link the connection references and turn the flows on (Notify first)." -ForegroundColor Green
