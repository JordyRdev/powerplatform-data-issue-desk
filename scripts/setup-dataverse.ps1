<#
.SYNOPSIS
    Creates the Data Issue Desk data model in a Dataverse environment and loads the sample data.

.DESCRIPTION
    Creates, inside the solution "DataIssueDesk" (publisher "JordyRdev", prefix jrd):
      - global choices: Severity, Issue status, Criticality
      - tables: Data source, Issue, Issue log, Flow error
      - lookups: Issue -> Data source, Issue log -> Issue
      - an alternate key on Data source name
      - environment variables: Overdue days, Team mailbox
    Then loads data/datasources.csv, data/issues.csv and data/issuelogs.csv.

    Safe to run more than once: anything that already exists is skipped.
    Works in Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-dataverse.ps1
#>
param(
    [string]$EnvironmentUrl = "https://orgf894f4c2.crm17.dynamics.com",
    [string]$TenantId = "8f2aa460-a99b-402e-b93d-d958227d6f3c",
    [string]$SolutionName = "DataIssueDesk",
    [switch]$SkipData
)

$ErrorActionPreference = "Stop"
$EnvironmentUrl = $EnvironmentUrl.TrimEnd("/")
$Api = "$EnvironmentUrl/api/data/v9.2"
$Root = Split-Path -Parent $PSScriptRoot
$Lcid = 1033
$OptionPrefix = 64800   # choice values start at 648000000

# ------------------------------------------------------------------------------------------
# Sign-in (device code, no modules needed)
# ------------------------------------------------------------------------------------------
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

$Token = Get-DataverseToken
Write-Host "Signed in." -ForegroundColor Green

# ------------------------------------------------------------------------------------------
# Web API helpers
# ------------------------------------------------------------------------------------------
function Invoke-Dv {
    param([string]$Method, [string]$Path, $Body, [switch]$Solution, [switch]$Return)
    $headers = @{
        Authorization      = "Bearer $Token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
    }
    if ($Solution) { $headers["MSCRM.SolutionUniqueName"] = $SolutionName }
    if ($Return)   { $headers["Prefer"] = "return=representation" }
    $params = @{ Method = $Method; Uri = "$Api/$Path"; Headers = $headers }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
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

function Test-Dv([string]$Path) {
    try { Invoke-Dv GET $Path | Out-Null; return $true }
    catch { if ($_.Exception.Message -match "0x80060888|does not exist|Not Found|404|Could not find") { return $false }; throw }
}

function New-Label([string]$Text) {
    @{
        "@odata.type"   = "Microsoft.Dynamics.CRM.Label"
        LocalizedLabels = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"; Label = $Text; LanguageCode = $Lcid })
    }
}

function Req([string]$Level = "None") {
    @{ Value = $Level; CanBeChanged = $true; ManagedPropertyLogicalName = "canmodifyrequirementlevelsettings" }
}

function Step([string]$Text) { Write-Host "  - $Text" }

# ------------------------------------------------------------------------------------------
# Publisher and solution
# ------------------------------------------------------------------------------------------
Write-Host "`nPublisher and solution" -ForegroundColor Cyan
$pub = (Invoke-Dv GET "publishers?`$select=publisherid&`$filter=uniquename eq 'jordyrdev'").value
if (-not $pub) {
    $pub = Invoke-Dv POST "publishers" @{
        uniquename                      = "jordyrdev"
        friendlyname                    = "JordyRdev"
        customizationprefix             = "jrd"
        customizationoptionvalueprefix  = $OptionPrefix
        description                     = "Publisher for the Data Issue Desk demo"
    } -Return
    Step "publisher JordyRdev created"
} else { $pub = $pub[0]; Step "publisher JordyRdev exists" }

$sol = (Invoke-Dv GET "solutions?`$select=solutionid&`$filter=uniquename eq '$SolutionName'").value
if (-not $sol) {
    Invoke-Dv POST "solutions" @{
        uniquename                = $SolutionName
        friendlyname              = "Data Issue Desk"
        version                   = "1.0.0.0"
        description               = "Report, triage and approve data issues."
        "publisherid@odata.bind"  = "/publishers($($pub.publisherid))"
    } | Out-Null
    Step "solution $SolutionName created"
} else { Step "solution $SolutionName exists" }

# ------------------------------------------------------------------------------------------
# Global choices
# ------------------------------------------------------------------------------------------
Write-Host "`nChoices" -ForegroundColor Cyan
$Choices = [ordered]@{
    jrd_severity    = @{ Label = "Severity";     Options = @("Low", "Medium", "High", "Critical") }
    jrd_issuestatus = @{ Label = "Issue status"; Options = @("New", "Awaiting approval", "Approved", "Rejected", "Resolved") }
    jrd_criticality = @{ Label = "Criticality";  Options = @("Low", "Medium", "High") }
}
$ChoiceValue = @{}   # "jrd_severity|High" -> 648000002
$ChoiceId = @{}
foreach ($name in $Choices.Keys) {
    $def = $Choices[$name]
    $i = 0
    foreach ($o in $def.Options) { $ChoiceValue["$name|$o"] = $OptionPrefix * 10000 + $i; $i++ }
    if (-not (Test-Dv "GlobalOptionSetDefinitions(Name='$name')")) {
        $i = 0
        $opts = foreach ($o in $def.Options) { @{ Value = $OptionPrefix * 10000 + $i; Label = (New-Label $o) }; $i++ }
        Invoke-Dv POST "GlobalOptionSetDefinitions" @{
            "@odata.type" = "Microsoft.Dynamics.CRM.OptionSetMetadata"
            Name          = $name
            DisplayName   = (New-Label $def.Label)
            IsGlobal      = $true
            OptionSetType = "Picklist"
            Options       = @($opts)
        } -Solution | Out-Null
        Step "$name created"
    } else { Step "$name exists" }
    $ChoiceId[$name] = (Invoke-Dv GET "GlobalOptionSetDefinitions(Name='$name')").MetadataId
}

# ------------------------------------------------------------------------------------------
# Tables and columns
# ------------------------------------------------------------------------------------------
function New-Table([string]$Schema, [string]$Display, [string]$Plural, [string]$Desc, [string]$PrimarySchema, [string]$PrimaryDisplay) {
    $logical = $Schema.ToLower()
    if (Test-Dv "EntityDefinitions(LogicalName='$logical')") { Step "table $logical exists"; return }
    Invoke-Dv POST "EntityDefinitions" @{
        "@odata.type"         = "Microsoft.Dynamics.CRM.EntityMetadata"
        SchemaName            = $Schema
        DisplayName           = (New-Label $Display)
        DisplayCollectionName = (New-Label $Plural)
        Description           = (New-Label $Desc)
        OwnershipType         = "UserOwned"
        IsActivity            = $false
        HasActivities         = $false
        HasNotes              = $false
        PrimaryNameAttribute  = $PrimarySchema.ToLower()
        Attributes            = @(@{
            "@odata.type" = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
            SchemaName    = $PrimarySchema
            IsPrimaryName = $true
            MaxLength     = 200
            FormatName    = @{ Value = "Text" }
            RequiredLevel = (Req "ApplicationRequired")
            DisplayName   = (New-Label $PrimaryDisplay)
        })
    } -Solution | Out-Null
    Step "table $logical created"
}

function Add-Column([string]$Table, [hashtable]$Meta) {
    $logical = $Meta.SchemaName.ToLower()
    if (Test-Dv "EntityDefinitions(LogicalName='$Table')/Attributes(LogicalName='$logical')") { Step "$Table.$logical exists"; return }
    if (-not $Meta.ContainsKey("RequiredLevel")) { $Meta.RequiredLevel = (Req) }
    Invoke-Dv POST "EntityDefinitions(LogicalName='$Table')/Attributes" $Meta -Solution | Out-Null
    Step "$Table.$logical created"
}

function Col-Text([string]$Schema, [string]$Display, [int]$Max = 200, [string]$Format = "Text") {
    @{ "@odata.type" = "Microsoft.Dynamics.CRM.StringAttributeMetadata"; SchemaName = $Schema; DisplayName = (New-Label $Display); MaxLength = $Max; FormatName = @{ Value = $Format } }
}
function Col-Memo([string]$Schema, [string]$Display) {
    @{ "@odata.type" = "Microsoft.Dynamics.CRM.MemoAttributeMetadata"; SchemaName = $Schema; DisplayName = (New-Label $Display); MaxLength = 4000; Format = "TextArea" }
}
function Col-Date([string]$Schema, [string]$Display) {
    @{ "@odata.type" = "Microsoft.Dynamics.CRM.DateTimeAttributeMetadata"; SchemaName = $Schema; DisplayName = (New-Label $Display); Format = "DateAndTime"; DateTimeBehavior = @{ Value = "UserLocal" } }
}
function Col-Bool([string]$Schema, [string]$Display) {
    @{
        "@odata.type" = "Microsoft.Dynamics.CRM.BooleanAttributeMetadata"; SchemaName = $Schema; DisplayName = (New-Label $Display); DefaultValue = $false
        OptionSet     = @{ OptionSetType = "Boolean"; TrueOption = @{ Value = 1; Label = (New-Label "Yes") }; FalseOption = @{ Value = 0; Label = (New-Label "No") } }
    }
}
function Col-Choice([string]$Schema, [string]$Display, [string]$Global, $Default = $null) {
    $m = @{
        "@odata.type"              = "Microsoft.Dynamics.CRM.PicklistAttributeMetadata"
        SchemaName                 = $Schema
        DisplayName                = (New-Label $Display)
        "GlobalOptionSet@odata.bind" = "/GlobalOptionSetDefinitions($($ChoiceId[$Global]))"
    }
    if ($null -ne $Default) { $m.DefaultFormValue = $Default }
    $m
}

Write-Host "`nTables" -ForegroundColor Cyan
New-Table "jrd_DataSource" "Data source" "Data sources" "A system or dataset that data issues are reported against." "jrd_Name" "Name"
Add-Column "jrd_datasource" (Col-Text "jrd_System" "System")
Add-Column "jrd_datasource" (Col-Text "jrd_OwnerEmail" "Owner email" 100 "Email")
Add-Column "jrd_datasource" (Col-Choice "jrd_Criticality" "Criticality" "jrd_criticality")

New-Table "jrd_Issue" "Issue" "Issues" "A data quality issue reported by a business user." "jrd_Title" "Title"
Add-Column "jrd_issue" (Col-Memo "jrd_Description" "Description")
Add-Column "jrd_issue" (Col-Memo "jrd_Impact" "Impact")
Add-Column "jrd_issue" (Col-Choice "jrd_Severity" "Severity" "jrd_severity" $ChoiceValue["jrd_severity|Medium"])
Add-Column "jrd_issue" (Col-Choice "jrd_Status" "Status" "jrd_issuestatus" $ChoiceValue["jrd_issuestatus|New"])
Add-Column "jrd_issue" (Col-Date "jrd_ReportedOn" "Reported on")
Add-Column "jrd_issue" (Col-Date "jrd_ResolvedOn" "Resolved on")
Add-Column "jrd_issue" (Col-Text "jrd_ReportedBy" "Reported by" 100 "Email")
Add-Column "jrd_issue" (Col-Bool "jrd_Notified" "Owner notified")

New-Table "jrd_IssueLog" "Issue log" "Issue logs" "Audit trail of status changes on an issue." "jrd_Name" "Name"
Add-Column "jrd_issuelog" (Col-Choice "jrd_FromStatus" "From status" "jrd_issuestatus")
Add-Column "jrd_issuelog" (Col-Choice "jrd_ToStatus" "To status" "jrd_issuestatus")
Add-Column "jrd_issuelog" (Col-Date "jrd_ChangedOn" "Changed on")
Add-Column "jrd_issuelog" (Col-Memo "jrd_Comment" "Comment")

New-Table "jrd_FlowError" "Flow error" "Flow errors" "Errors caught by the try/catch scopes in the cloud flows." "jrd_Name" "Flow name"
Add-Column "jrd_flowerror" (Col-Text "jrd_RunUrl" "Run URL" 500 "Url")
Add-Column "jrd_flowerror" (Col-Memo "jrd_Error" "Error")
Add-Column "jrd_flowerror" (Col-Date "jrd_OccurredOn" "Occurred on")

# ------------------------------------------------------------------------------------------
# Relationships
# ------------------------------------------------------------------------------------------
Write-Host "`nRelationships" -ForegroundColor Cyan
function New-Lookup([string]$Name, [string]$Parent, [string]$Child, [string]$LookupSchema, [string]$Display, [string]$OnDelete, [string]$Level) {
    if (Test-Dv "RelationshipDefinitions(SchemaName='$Name')") { Step "$Name exists"; return }
    Invoke-Dv POST "RelationshipDefinitions" @{
        "@odata.type"        = "Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata"
        SchemaName           = $Name
        ReferencedEntity     = $Parent
        ReferencedAttribute  = "$($Parent)id"
        ReferencingEntity    = $Child
        CascadeConfiguration = @{ Assign = "NoCascade"; Delete = $OnDelete; Merge = "NoCascade"; Reparent = "NoCascade"; Share = "NoCascade"; Unshare = "NoCascade" }
        Lookup               = @{
            "@odata.type" = "Microsoft.Dynamics.CRM.LookupAttributeMetadata"
            SchemaName    = $LookupSchema
            DisplayName   = (New-Label $Display)
            RequiredLevel = (Req $Level)
        }
    } -Solution | Out-Null
    Step "$Name created"
}
New-Lookup "jrd_datasource_issue" "jrd_datasource" "jrd_issue" "jrd_DataSourceId" "Data source" "Restrict" "ApplicationRequired"
New-Lookup "jrd_issue_issuelog" "jrd_issue" "jrd_issuelog" "jrd_IssueId" "Issue" "Cascade" "ApplicationRequired"

# ------------------------------------------------------------------------------------------
# Alternate key and environment variables
# ------------------------------------------------------------------------------------------
Write-Host "`nKey and environment variables" -ForegroundColor Cyan
if (-not (Test-Dv "EntityDefinitions(LogicalName='jrd_datasource')/Keys(LogicalName='jrd_datasource_name')")) {
    Invoke-Dv POST "EntityDefinitions(LogicalName='jrd_datasource')/Keys" @{
        "@odata.type"  = "Microsoft.Dynamics.CRM.EntityKeyMetadata"
        SchemaName     = "jrd_DataSource_Name"
        DisplayName    = (New-Label "Data source name")
        KeyAttributes  = @("jrd_name")
    } -Solution | Out-Null
    Step "alternate key on data source name created"
} else { Step "alternate key exists" }

$EnvVars = @(
    @{ schemaname = "jrd_OverdueDays"; displayname = "Overdue after (days)"; type = 100000001; defaultvalue = "5"; description = "Open issues older than this get a reminder." },
    @{ schemaname = "jrd_TeamMailbox"; displayname = "Data team mailbox"; type = 100000000; defaultvalue = "dataquality@issue-desk.example"; description = "Where escalations are sent." }
)
foreach ($v in $EnvVars) {
    $found = (Invoke-Dv GET "environmentvariabledefinitions?`$select=schemaname&`$filter=schemaname eq '$($v.schemaname)'").value
    if (-not $found) { Invoke-Dv POST "environmentvariabledefinitions" $v -Solution | Out-Null; Step "$($v.schemaname) created" }
    else { Step "$($v.schemaname) exists" }
}

Write-Host "`nPublishing customizations (takes a minute)" -ForegroundColor Cyan
Invoke-Dv POST "PublishAllXml" @{} | Out-Null
Step "published"

# ------------------------------------------------------------------------------------------
# Sample data
# ------------------------------------------------------------------------------------------
if ($SkipData) { Write-Host "`nDone (data skipped)." -ForegroundColor Green; return }

Write-Host "`nSample data" -ForegroundColor Cyan
$existing = (Invoke-Dv GET "jrd_issues?`$select=jrd_issueid&`$top=1").value
if ($existing) { Step "issues already loaded, skipping data"; Write-Host "`nDone." -ForegroundColor Green; return }

$sourceIds = @{}
foreach ($r in Import-Csv (Join-Path $Root "data\datasources.csv")) {
    $row = Invoke-Dv POST "jrd_datasources" @{
        jrd_name        = $r.name
        jrd_system      = $r.system
        jrd_owneremail  = $r.owneremail
        jrd_criticality = $ChoiceValue["jrd_criticality|$($r.criticality)"]
    } -Return
    $sourceIds[$r.name] = $row.jrd_datasourceid
}
Step "$($sourceIds.Count) data sources"

$issueIds = @{}
foreach ($r in Import-Csv (Join-Path $Root "data\issues.csv")) {
    $body = @{
        jrd_title                    = $r.title
        jrd_description              = $r.description
        jrd_severity                 = $ChoiceValue["jrd_severity|$($r.severity)"]
        jrd_status                   = $ChoiceValue["jrd_issuestatus|$($r.status)"]
        jrd_reportedon               = $r.reportedon
        jrd_reportedby               = $r.reportedby
        "jrd_DataSourceId@odata.bind" = "/jrd_datasources($($sourceIds[$r.datasource]))"
    }
    if ($r.impact)     { $body.jrd_impact = $r.impact }
    if ($r.resolvedon) { $body.jrd_resolvedon = $r.resolvedon }
    $row = Invoke-Dv POST "jrd_issues" $body -Return
    $issueIds[$r.title] = $row.jrd_issueid
}
Step "$($issueIds.Count) issues"

$n = 0
foreach ($r in Import-Csv (Join-Path $Root "data\issuelogs.csv")) {
    $body = @{
        jrd_name                  = "$($r.fromstatus) -> $($r.tostatus)"
        jrd_fromstatus            = $ChoiceValue["jrd_issuestatus|$($r.fromstatus)"]
        jrd_tostatus              = $ChoiceValue["jrd_issuestatus|$($r.tostatus)"]
        jrd_changedon             = $r.changedon
        "jrd_IssueId@odata.bind"  = "/jrd_issues($($issueIds[$r.issuetitle]))"
    }
    if ($r.comment) { $body.jrd_comment = $r.comment }
    Invoke-Dv POST "jrd_issuelogs" $body | Out-Null
    $n++
}
Step "$n issue log rows"

Write-Host "`nDone. Open https://make.powerapps.com, pick the 'dev' environment and open Solutions > Data Issue Desk." -ForegroundColor Green
