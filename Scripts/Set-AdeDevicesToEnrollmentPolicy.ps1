#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Assigns all Apple ADE devices of an enrollment program token to a given
    enrollment policy (or profile).

.DESCRIPTION
    The Intune GUI has no "select all" option when assigning an enrollment
    profile to devices, and setting a new default policy only affects devices
    that sync from ABM/ASM afterwards. This script reassigns every already
    imported device to the target policy in batches via Microsoft Graph.

.PARAMETER PolicyName
    Optional. Display name of the target enrollment policy (or profile).
    If omitted, the token's default policy for the given platform is used.

.PARAMETER TokenName
    Optional. Limit the run to a single enrollment program token. If omitted,
    every token that contains a policy with the given name is processed.

.PARAMETER SerialNumber
    Optional. One or more device serial numbers. If provided, only these
    devices are reassigned instead of all imported devices of the platform.

.PARAMETER Platform
    Platform of the devices to reassign. Defaults to ios.

.PARAMETER BatchSize
    Number of serial numbers sent per updateDeviceProfileAssignment call.
    Defaults to 100.

.EXAMPLE
    .\Set-AdeDevicesToEnrollmentPolicy.ps1 -PolicyName 'ABM-EnrollmentPolicy-iOS-WithUser-ModernAuthentication-[PI-Baseline]' -WhatIf

.EXAMPLE
    .\Set-AdeDevicesToEnrollmentPolicy.ps1 -PolicyName 'ABM-EnrollmentPolicy-iOS-WithUser-ModernAuthentication-[PI-Baseline]'

.EXAMPLE
    # Assign all iOS devices to whatever policy is currently the default
    .\Set-AdeDevicesToEnrollmentPolicy.ps1 -Platform ios

.EXAMPLE
    # Assign only two specific devices to the default policy
    .\Set-AdeDevicesToEnrollmentPolicy.ps1 -SerialNumber 'C7XXXXXXXXXX', 'F9XXXXXXXXXX'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PolicyName,

    [string]$TokenName,

    [string[]]$SerialNumber,

    [ValidateSet('ios', 'macOS')]
    [string]$Platform = 'ios',

    [ValidateRange(1, 1000)]
    [int]$BatchSize = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-DefaultProfile {
    # Classic profiles (depIOSEnrollmentProfile/depMacOSEnrollmentProfile)
    # track isDefault directly, so that's authoritative whenever it's set.
    #
    # Profiles created via Intune's newer unified "ADE Policy" enrollment
    # experience are Settings Catalog objects under
    # deviceManagement/configurationPolicies instead, and never populate
    # isDefault. Unlike isDefault, their assignment state doesn't reflect
    # default status live - a policy stays isAssigned:false forever whether
    # or not it's the *current* default, so this is only a fallback for when
    # no classic profile is marked default (i.e. an ADE Policy is/was it).
    param(
        [object[]]$Profiles,
        [string]$TokenId,
        [string]$Platform
    )

    $profileType = if ($Platform -eq 'ios') { '#microsoft.graph.depIOSEnrollmentProfile' }
                   else { '#microsoft.graph.depMacOSEnrollmentProfile' }
    $classicDefault = $Profiles | Where-Object { $_.'@odata.type' -eq $profileType -and $_.isDefault }
    if ($classicDefault) { return $classicDefault }

    $templateId    = if ($Platform -eq 'ios') { '27d20e9c-50c1-48f8-a44c-f37de4510051_1' }
                     else { '2e29557d-70fc-405a-8082-d1e5b6be2b8c_1' }
    $odataPlatform = if ($Platform -eq 'ios') { 'ios' } else { 'macOS' }

    $odataFilter = "(technologies has 'enrollment') and (platforms eq '$odataPlatform') and " +
                   "(TemplateReference/templateId eq '$templateId') and " +
                   "(creationSource eq 'DepTokenId_$TokenId') and (isAssigned eq false)"
    $uri = "beta/deviceManagement/configurationPolicies?`$filter=$([System.Uri]::EscapeDataString($odataFilter))&`$select=id,name"
    $unassigned = @(Get-GraphAll -Uri $uri)

    if ($unassigned.Count -gt 1) {
        Write-Warning "  Multiple unassigned $Platform ADE policies found - using '$($unassigned[0].name)' as the default."
    }
    if ($unassigned.Count -gt 0) {
        $match = $Profiles | Where-Object { $_.id -like "*_$($unassigned[0].id)" }
        if ($match) { return $match }
    }

    return $null
}

# Reuse an existing Graph connection if it already carries the required scope.
$requiredScope = 'DeviceManagementServiceConfig.ReadWrite.All'
$context = Get-MgContext
if (-not $context -or $context.Scopes -notcontains $requiredScope) {
    Connect-MgGraph -Scopes $requiredScope -NoWelcome
}

$tokens = Get-GraphAll -Uri 'beta/deviceManagement/depOnboardingSettings'
if ($TokenName) {
    $tokens = @($tokens | Where-Object { $_.tokenName -eq $TokenName })
    if ($tokens.Count -eq 0) { throw "Enrollment program token '$TokenName' not found." }
}

foreach ($token in $tokens) {
    Write-Output "--- Token: $($token.tokenName) ---"

    # The new enrollment policies live in the same Graph collection as the
    # classic profiles, so a plain displayName match finds either kind.
    $profiles = Get-GraphAll -Uri "beta/deviceManagement/depOnboardingSettings/$($token.id)/enrollmentProfiles"

    if ($PolicyName) {
        $target = $profiles | Where-Object { $_.displayName -eq $PolicyName }
    }
    else {
        # No name given: use the default policy of the requested platform.
        $target = Get-DefaultProfile -Profiles $profiles -TokenId $token.id -Platform $Platform
    }

    if (-not $target) {
        $wanted = if ($PolicyName) { "Policy '$PolicyName'" } else { "A default $Platform policy" }
        Write-Warning "  $wanted not found on this token - skipping."
        continue
    }

    Write-Output "  Target policy: $($target.displayName)"

    $devices = Get-GraphAll -Uri "beta/deviceManagement/depOnboardingSettings/$($token.id)/importedAppleDeviceIdentities"

    $toAssign = @($devices | Where-Object {
        $_.platform -eq $Platform -and
        -not $_.isDeleted -and
        -not [string]::IsNullOrWhiteSpace($_.serialNumber) -and
        $_.requestedEnrollmentProfileId -ne $target.id
    })

    if ($SerialNumber) {
        $toAssign = @($toAssign | Where-Object { $_.serialNumber -in $SerialNumber })

        $missing = @($SerialNumber | Where-Object { $_ -notin $devices.serialNumber })
        foreach ($serial in $missing) {
            Write-Warning "  Serial number '$serial' not found on this token."
        }
    }

    Write-Output "  Devices ($Platform): $($devices.Count) imported, $($toAssign.Count) to reassign"

    if ($toAssign.Count -eq 0) { continue }

    for ($i = 0; $i -lt $toAssign.Count; $i += $BatchSize) {
        $chunk   = @($toAssign[$i..([Math]::Min($i + $BatchSize, $toAssign.Count) - 1)])
        $serials = @($chunk | Select-Object -ExpandProperty serialNumber)

        if ($PSCmdlet.ShouldProcess("$($serials.Count) devices ($($serials[0]) ...)", "Assign policy '$($target.displayName)'")) {
            $body = @{ deviceIds = $serials } | ConvertTo-Json

            Invoke-MgGraphRequest `
                -Method POST `
                -Uri    "beta/deviceManagement/depOnboardingSettings/$($token.id)/enrollmentProfiles/$($target.id)/updateDeviceProfileAssignment" `
                -Body   $body | Out-Null

            Write-Output "  Assigned batch of $($serials.Count) devices"
        }
    }

    Write-Output '  Token completed'
}
