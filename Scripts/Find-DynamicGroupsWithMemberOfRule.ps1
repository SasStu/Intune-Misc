#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Finds every Entra ID object affected by the memberOf rule operator
    retirement (MC1448379): dynamic groups, dynamic administrative units,
    and entitlement management automatic assignment policies.

.DESCRIPTION
    Per https://mc.merill.net/message/MC1448379, the memberOf rule operator
    is retiring on November 3, 2026. After that date, any rule that uses it
    stops being evaluated (dynamic groups/administrative units) or is
    quarantined (entitlement management automatic assignment policies),
    which can cause stale group/AU membership, incorrect Conditional Access
    scoping, broken group-based licensing, and dropped access package
    assignments.

    This script scans all three affected surfaces for rules containing the
    memberOf operator:

      - Dynamic membership groups (groupTypes contains 'DynamicMembership')
      - Dynamic administrative units (membershipType eq 'Dynamic')
      - Entitlement management automatic assignment policies
        (accessPackageAssignmentPolicies with automaticRequestSettings,
        whose specificAllowedTargets attributeRuleMembers membershipRule
        contains memberOf)

    Output is a single unified list with a Type column so every match can be
    triaged together, plus separate CSV exports per surface for easier
    follow-up.

.PARAMETER IncludeDisabled
    Also report dynamic groups/administrative units whose
    membershipRuleProcessingState is 'Paused'. Without this switch, only
    actively processed ones are checked. Has no effect on entitlement
    management policies (they have no equivalent paused state).

.PARAMETER OutputFolder
    Folder to write the per-surface CSV reports to. Defaults to the current
    directory. Files are only created for surfaces that returned at least
    one match, unless -AlwaysWriteCsv is specified.

.PARAMETER AlwaysWriteCsv
    Write a CSV (with headers only) for every surface even when no matches
    were found, so a scan run always leaves a record behind.

.PARAMETER ClientId
    Application (client) ID of a custom Entra ID app registration to sign in
    with, instead of the default Microsoft Graph PowerShell client. Requires
    -TenantId. The app must have the required delegated (or application)
    permissions granted (Group.Read.All, AdministrativeUnit.Read.All,
    EntitlementManagement.Read.All).

.PARAMETER TenantId
    Tenant ID or verified domain to sign in against. Required when -ClientId
    is used; optional otherwise (falls back to the default/common tenant).

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate installed in the local certificate store to
    use for app-only (application permission) authentication with -ClientId.
    Without this, -ClientId alone signs in interactively (delegated
    permissions) as that app.

.EXAMPLE
    .\Find-DynamicGroupsWithMemberOfRule.ps1

.EXAMPLE
    .\Find-DynamicGroupsWithMemberOfRule.ps1 -IncludeDisabled -OutputFolder C:\Reports

.EXAMPLE
    # Sign in interactively as a custom app registration
    .\Find-DynamicGroupsWithMemberOfRule.ps1 -ClientId '11111111-2222-3333-4444-555555555555' -TenantId 'contoso.onmicrosoft.com'

.EXAMPLE
    # App-only auth via a certificate
    .\Find-DynamicGroupsWithMemberOfRule.ps1 -ClientId '11111111-2222-3333-4444-555555555555' -TenantId 'contoso.onmicrosoft.com' -CertificateThumbprint 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
#>

[CmdletBinding()]
param(
    [switch]$IncludeDisabled,

    [string]$OutputFolder = '.',

    [switch]$AlwaysWriteCsv,

    [string]$ClientId,

    [string]$TenantId,

    [string]$CertificateThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ClientId -and -not $TenantId) {
    throw '-TenantId is required when -ClientId is specified.'
}
if ($CertificateThumbprint -and -not $ClientId) {
    throw '-CertificateThumbprint can only be used together with -ClientId.'
}

function Get-GraphAll {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    do {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        foreach ($item in $page.value) { $results.Add($item) }
        $Uri = $page.PSObject.Properties['@odata.nextLink']?.Value
    } while ($Uri)
    return $results
}

function Export-MatchCsv {
    param(
        [string]$Name,
        [array]$Rows,
        [string]$Folder,
        [string[]]$Columns
    )
    if ($Rows.Count -eq 0 -and -not $AlwaysWriteCsv) { return }
    $path = Join-Path $Folder "$Name.csv"
    if ($Rows.Count -eq 0) {
        $Columns -join ',' | Set-Content -Path $path -Encoding UTF8
    }
    else {
        $Rows | Select-Object $Columns | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    }
    Write-Output "  Report written to $path"
}

# --- Auth --------------------------------------------------------------

$requiredScopes = @('Group.Read.All', 'AdministrativeUnit.Read.All', 'EntitlementManagement.Read.All')
$context = Get-MgContext

if ($ClientId) {
    $sameApp = $context -and $context.ClientId -eq $ClientId -and (-not $TenantId -or $context.TenantId -eq $TenantId)
    $hasScopes = $context -and @($requiredScopes | Where-Object { $_ -notin $context.Scopes }).Count -eq 0
    if (-not $sameApp -or ($CertificateThumbprint -and -not $hasScopes)) {
        if ($CertificateThumbprint) {
            Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -CertificateThumbprint $CertificateThumbprint -NoWelcome
        }
        else {
            Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -Scopes $requiredScopes -NoWelcome
        }
    }
}
elseif (-not $context -or @($requiredScopes | Where-Object { $_ -notin $context.Scopes }).Count -gt 0) {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$allMatches = [System.Collections.Generic.List[object]]::new()

# --- Dynamic groups ------------------------------------------------------

Write-Output '--- Dynamic membership groups ---'
$groupRows = @()
try {
    $groupFilter = "groupTypes/any(c:c eq 'DynamicMembership')"
    $groupSelect = 'id,displayName,membershipRule,membershipRuleProcessingState'
    $groups = Get-GraphAll -Uri "v1.0/groups?`$filter=$([System.Uri]::EscapeDataString($groupFilter))&`$select=$groupSelect"
    Write-Output "Found $($groups.Count) dynamic membership group(s)."

    $groupCandidates = $groups | Where-Object { $IncludeDisabled -or $_.membershipRuleProcessingState -eq 'On' }
    $groupMatches = $groupCandidates | Where-Object { $_.membershipRule -and $_.membershipRule -match '(?i)\bmemberOf\b' }

    $groupRows = $groupMatches | ForEach-Object {
        [PSCustomObject]@{
            Type            = 'Group'
            DisplayName     = $_.displayName
            Id              = $_.id
            ProcessingState = $_.membershipRuleProcessingState
            MembershipRule  = $_.membershipRule
        }
    }
    foreach ($row in $groupRows) { $allMatches.Add($row) }
    Write-Output "$($groupRows.Count) dynamic group(s) use the memberOf rule operator."
    Export-MatchCsv -Name 'memberof-dynamic-groups' -Rows $groupRows -Folder $OutputFolder -Columns @('DisplayName', 'Id', 'ProcessingState', 'MembershipRule')
}
catch {
    Write-Warning "  Skipped dynamic groups - $($_.Exception.Message)"
}

# --- Dynamic administrative units -----------------------------------------

Write-Output '--- Dynamic administrative units ---'
$auRows = @()
try {
    $auSelect = 'id,displayName,membershipRule,membershipRuleProcessingState,membershipType'
    $aus = Get-GraphAll -Uri "v1.0/directory/administrativeUnits?`$select=$auSelect"
    $aus = @($aus | Where-Object { $_.membershipType -eq 'Dynamic' })
    Write-Output "Found $($aus.Count) dynamic administrative unit(s)."

    $auCandidates = $aus | Where-Object { $IncludeDisabled -or $_.membershipRuleProcessingState -eq 'On' }
    $auMatches = $auCandidates | Where-Object { $_.membershipRule -and $_.membershipRule -match '(?i)\bmemberOf\b' }

    $auRows = $auMatches | ForEach-Object {
        [PSCustomObject]@{
            Type            = 'AdministrativeUnit'
            DisplayName     = $_.displayName
            Id              = $_.id
            ProcessingState = $_.membershipRuleProcessingState
            MembershipRule  = $_.membershipRule
        }
    }
    foreach ($row in $auRows) { $allMatches.Add($row) }
    Write-Output "$($auRows.Count) dynamic administrative unit(s) use the memberOf rule operator."
    Export-MatchCsv -Name 'memberof-dynamic-administrative-units' -Rows $auRows -Folder $OutputFolder -Columns @('DisplayName', 'Id', 'ProcessingState', 'MembershipRule')
}
catch {
    Write-Warning "  Skipped dynamic administrative units - $($_.Exception.Message)"
}

# --- Entitlement management automatic assignment policies -----------------

Write-Output '--- Entitlement management automatic assignment policies ---'
$policyRows = [System.Collections.Generic.List[object]]::new()
try {
    $policies = Get-GraphAll -Uri 'v1.0/identityGovernance/entitlementManagement/assignmentPolicies?$expand=accessPackage&$top=50'
    $autoPolicies = @($policies | Where-Object { $_.automaticRequestSettings })
    Write-Output "Found $($autoPolicies.Count) automatic assignment policy(ies) out of $($policies.Count) total assignment policy(ies)."

    foreach ($policy in $autoPolicies) {
        foreach ($target in @($policy.specificAllowedTargets)) {
            if ([string]$target.'@odata.type' -notlike '*attributeRuleMembers*') { continue }
            $rule = [string]$target.membershipRule
            if ($rule -match '(?i)\bmemberOf\b') {
                $policyRows.Add([PSCustomObject]@{
                        Type              = 'AccessPackageAssignmentPolicy'
                        DisplayName       = $policy.displayName
                        Id                = $policy.id
                        AccessPackageName = $policy.accessPackage.displayName
                        AccessPackageId   = $policy.accessPackage.id
                        ProcessingState   = 'n/a'
                        MembershipRule    = $rule
                    })
            }
        }
    }
    foreach ($row in $policyRows) { $allMatches.Add($row) }
}
catch {
    Write-Warning "  Skipped entitlement management policies - $($_.Exception.Message)"
}
Write-Output "$($policyRows.Count) automatic assignment policy(ies) use the memberOf rule operator."
Export-MatchCsv -Name 'memberof-entitlement-management-policies' -Rows $policyRows -Folder $OutputFolder -Columns @('AccessPackageName', 'AccessPackageId', 'DisplayName', 'Id', 'MembershipRule')

# --- Summary ---------------------------------------------------------------

Write-Output '--- Summary ---'
if ($allMatches.Count -eq 0) {
    Write-Output 'No objects using the memberOf rule operator were found across groups, administrative units, or entitlement management policies.'
}
else {
    Write-Output "$($allMatches.Count) object(s) across the tenant use the memberOf rule operator (see per-surface reports above for details):"
    $allMatches | Select-Object Type, DisplayName, Id, ProcessingState, MembershipRule
}
