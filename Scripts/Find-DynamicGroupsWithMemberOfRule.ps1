#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Finds Entra ID dynamic groups whose membership rule uses the memberOf
    rule operator.

.DESCRIPTION
    Enumerates every dynamic membership group in the tenant
    (groupTypes contains 'DynamicMembership') and inspects each group's
    membershipRule for the memberOf operator (e.g.
    "user.memberOf -any (group.objectId -eq '...')"). memberOf-based rules
    are nested group rules - they stop evaluating automatically once the
    referenced group's membership changes, so they're worth finding and
    auditing separately from ordinary attribute-based rules.

    Output includes each matching group's id, display name, membership
    processing state, and the full rule text.

.PARAMETER IncludeDisabled
    Also report groups whose membershipRuleProcessingState is 'Paused'.
    Without this switch, only actively processed dynamic groups are checked.

.PARAMETER ClientId
    Application (client) ID of a custom Entra ID app registration to sign in
    with, instead of the default Microsoft Graph PowerShell client. Requires
    -TenantId. The app must have the Group.Read.All delegated (or
    application) permission granted.

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
    .\Find-DynamicGroupsWithMemberOfRule.ps1 -IncludeDisabled | Format-Table -AutoSize

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

$requiredScopes = @('Group.Read.All')
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

$filter = "groupTypes/any(c:c eq 'DynamicMembership')"
$select = 'id,displayName,membershipRule,membershipRuleProcessingState'
$groups = Get-GraphAll -Uri "v1.0/groups?`$filter=$([System.Uri]::EscapeDataString($filter))&`$select=$select"

Write-Output "Found $($groups.Count) dynamic membership group(s) in the tenant."

$candidates = $groups | Where-Object {
    $IncludeDisabled -or $_.membershipRuleProcessingState -eq 'On'
}

$matches = $candidates | Where-Object {
    $_.membershipRule -and $_.membershipRule -match '\bmemberOf\b'
}

if ($matches.Count -eq 0) {
    Write-Output 'No dynamic groups using the memberOf rule operator were found.'
    return
}

$result = $matches | Select-Object `
    @{Name = 'DisplayName'; Expression = { $_.displayName } }, `
    @{Name = 'Id'; Expression = { $_.id } }, `
    @{Name = 'ProcessingState'; Expression = { $_.membershipRuleProcessingState } }, `
    @{Name = 'MembershipRule'; Expression = { $_.membershipRule } }

Write-Output "$($result.Count) dynamic group(s) use the memberOf rule operator:"
$result
