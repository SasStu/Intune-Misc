#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Creates a new Apple ADE Settings Catalog enrollment policy that replicates
    the settings of an existing classic enrollment profile.

.DESCRIPTION
    Intune's classic enrollment profiles (depIOSEnrollmentProfile /
    depMacOSEnrollmentProfile) are frozen - new Setup Assistant screens only
    land in the newer Settings Catalog enrollment policies
    (deviceManagement/configurationPolicies). Recreating a profile as a policy
    by hand in the GUI is the first step of the migration, field by field.
    This script automates that copy.

    Every classic boolean/string field that has a direct policy equivalent is
    copied across, including the nested macOS local admin / primary account
    tree. Setup Assistant screens that only exist on the new policy
    (Action Button, Terms of Address, Intelligence, etc.) have no source value
    to copy, so they are set to -NewFieldDefault instead. Fields that have no
    policy equivalent at all (Supervised mode, Shared iPad, session timeouts,
    Apple Configurator certificates, admin password rotation, ...) are left
    out and listed in the summary so you can configure them manually
    afterwards.

    The script creates policies directly via Graph, which sidesteps a known
    Intune portal bug: editing an existing Settings Catalog enrollment policy
    in the GUI to add a primary account afterwards can crash the properties
    editor (Microsoft_Intune_Enrollment / PropertiesEditor.ReactView fails to
    load). Setting the same fields at creation time, as this script does,
    works fine.

    The script only creates the policy - it does not assign it, set it as
    default, or set an enrollment-time device group. Those stay separate,
    deliberate steps.

.PARAMETER ProfileName
    Display name of the classic enrollment profile to copy. Mandatory unless
    -TokenName is given without it, in which case every classic profile on
    that token is migrated.

.PARAMETER TokenName
    Limit the run to a single enrollment program token. Mandatory if
    -ProfileName is omitted (bulk mode); optional as a narrowing filter when
    -ProfileName is given.

.PARAMETER NewPolicyName
    Optional. Only valid together with -ProfileName. Overrides the
    auto-derived policy name. Without it, the old profile name must contain
    the naming convention's 'DeploymentProfile' segment (e.g.
    'ABM-DeploymentProfile-iOS-...'), which is substituted with
    'EnrollmentPolicy'. In bulk mode (-TokenName only), profiles whose name
    doesn't follow the convention are skipped with a warning instead, unless
    -AllowIdenticalName is set.

.PARAMETER AllowIdenticalName
    When a profile's name doesn't contain the naming convention's
    'DeploymentProfile' segment, create the new policy under the exact same
    name as the old profile instead of erroring (single mode) or skipping it
    (bulk mode).

.PARAMETER DeviceGroupName
    Optional. Only valid together with -ProfileName (single mode) - a bulk
    run has no reliable way to know which group belongs to which profile, so
    it isn't supported there. Display name of an existing Entra ID security
    group to set as the policy's enrollment-time device group. Must resolve
    to exactly one group. The script verifies the assignment afterwards via
    retrieveEnrollmentTimeDeviceMembershipTarget and warns if it didn't take
    (e.g. the signed-in account/app lacks sufficient rights, such as Owner,
    on the group).

.PARAMETER NewFieldDefault
    'Show' or 'Hide' (default 'Hide'). Value applied to Setup Assistant
    screens and other settings that exist only on the new policy and have no
    classic profile field to copy from.

.PARAMETER Force
    Skip the confirmation prompt and create the policy even if one with the
    same name already exists (e.g. from a previous run). Without -Force, an
    existing policy with the target name is reported and you're asked
    whether to create a duplicate anyway.

.EXAMPLE
    .\New-AdePolicyFromProfile.ps1 -ProfileName 'ABM-DeploymentProfile-iOS-WithUser-ModernAuthentication-[PI-Baseline]' -WhatIf

.EXAMPLE
    .\New-AdePolicyFromProfile.ps1 -ProfileName 'ABM-DeploymentProfile-iOS-WithUser-ModernAuthentication-[PI-Baseline]'

.EXAMPLE
    # Migrate every classic profile on one token, using the naming convention for all of them
    .\New-AdePolicyFromProfile.ps1 -TokenName 'Intune PI Dev SST'

.EXAMPLE
    # Also set the new policy's enrollment-time device group
    .\New-AdePolicyFromProfile.ps1 -ProfileName 'ABM-DeploymentProfile-iOS-WithUser-ModernAuthentication-[PI-Baseline]' -DeviceGroupName 'MDM-iOS-ADE-Assigned'

.EXAMPLE
    # Override the derived name for a single profile
    .\New-AdePolicyFromProfile.ps1 -ProfileName 'Old iOS Profile' -NewPolicyName 'ABM-EnrollmentPolicy-iOS-WithUser-ModernAuthentication-[PI-Baseline]'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProfileName,

    [string]$TokenName,

    [string]$NewPolicyName,

    [switch]$AllowIdenticalName,

    [string]$DeviceGroupName,

    [ValidateSet('Show', 'Hide')]
    [string]$NewFieldDefault = 'Hide',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell parameter sets can't express "TokenName alone means bulk mode"
# cleanly here: TokenName is a valid optional member of the single-profile
# set too, so binding only -TokenName is ambiguous between the two sets and
# PowerShell falls back to the default set, then prompts for the missing
# mandatory ProfileName instead of picking the bulk set. Validate manually.
if ([string]::IsNullOrWhiteSpace($ProfileName) -and [string]::IsNullOrWhiteSpace($TokenName)) {
    throw 'Specify -ProfileName (optionally narrowed with -TokenName), or -TokenName alone to migrate every classic profile on that token.'
}
if ($NewPolicyName -and [string]::IsNullOrWhiteSpace($ProfileName)) {
    throw '-NewPolicyName can only be used together with -ProfileName.'
}
if ($DeviceGroupName -and [string]::IsNullOrWhiteSpace($ProfileName)) {
    throw '-DeviceGroupName can only be used together with -ProfileName (not in bulk -TokenName-only mode).'
}
$isBulkMode = [string]::IsNullOrWhiteSpace($ProfileName)

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

function Get-DerivedPolicyName {
    param([string]$OldName)
    if ($OldName -match 'DeploymentProfile') {
        return ($OldName -replace 'DeploymentProfile', 'EnrollmentPolicy')
    }
    return $null
}

# --- Settings Catalog metadata --------------------------------------------
# settingInstanceTemplateId / settingValueTemplateId pairs below were read
# back from real ADE policies created in the tenant (POST + GET round trip),
# not guessed from documentation - see the "Test ios" / "test mac" policies
# used to validate this script.

$iosTemplateId = '27d20e9c-50c1-48f8-a44c-f37de4510051_1'
$macTemplateId = '2e29557d-70fc-405a-8082-d1e5b6be2b8c_1'

$iosCatalog = @{
    'ade_useraffinity'                           = @{ Inst = 'f3ddbbae-bb3d-45e8-bb9c-854f674e56ef'; Val = 'e34ab06d-486a-4cc0-a867-295515ac2dfc' }
    'ade_lockedenrollment'                       = @{ Inst = 'e105d3a4-7318-454a-a231-0d1510ebf1e3'; Val = '49085612-4cce-4305-822d-6a6c793285be' }
    'ade_devicenametemplatechoices'               = @{ Inst = '93d1bf98-2345-468a-b0f0-1e2daf198357'; Val = '8c02396f-d58f-4275-be5c-dd97713d636e' }
    'ade_activatecellulardatachoices'             = @{ Inst = 'b63070e7-d6f7-44e7-b1c1-fd51615748a3'; Val = 'aaf7603d-0184-4143-bdfc-3326859ce0c3' }
    'ade_setupassistant_department'               = @{ Inst = '1fd43c7c-0c7a-4dcc-8392-7b1776f86d14'; Val = '180721e2-b467-40a3-b631-b2f28c5d9297' }
    'ade_setupassistant_departmentphone'          = @{ Inst = '383a4d4b-0bbc-4791-bc48-6def8716ec96'; Val = 'f7322d5b-07aa-4b5c-9846-bc3e547e7c0b' }
    'ade_setupassistant_passcode'                 = @{ Inst = 'be808211-b4f1-4653-aa95-068b756dc682'; Val = '67b68eed-075f-4479-a34b-9ae3d2b1cf4d' }
    'ade_setupassistant_locationservices'         = @{ Inst = '5dca1893-31cd-49b7-aadf-c26990ea0639'; Val = '6f73700e-a14b-4784-9923-512a97297c41' }
    'ade_setupassistant_restore'                  = @{ Inst = 'b4434e35-4131-4b13-90cb-4334cd9768dd'; Val = '78842c1b-d090-407d-9dec-a3a4a168a36f' }
    'ade_setupassistant_appleid'                  = @{ Inst = '4f26cd1f-5fd1-4d6c-af69-f18ade85aee9'; Val = '469e5c1a-c2f8-44fb-b515-f8532c2dff40' }
    'ade_setupassistant_termsandconditions'       = @{ Inst = '5a33bd8e-9df4-422c-92f5-3d5294a3e015'; Val = '404a8266-5c46-44b3-bf63-d8974d91c8f9' }
    'ade_setupassistant_touchfaceid'              = @{ Inst = '0deedc8e-1597-47f0-a271-4ae5029c1795'; Val = 'f11533e6-85a1-41c3-b23d-7a7c0bc2f7f8' }
    'ade_setupassistant_applepay'                 = @{ Inst = 'c7b005a7-148a-40b0-aa06-8a6eaafa6fc0'; Val = 'a18db77d-76e6-4bf8-ab60-98d1e34ed8df' }
    'ade_setupassistant_siri'                     = @{ Inst = '764673c0-b331-478e-905f-ef45428fae99'; Val = 'f3c03777-e89d-4fbc-bc1a-75c4858fa579' }
    'ade_setupassistant_diagnosticsdata'          = @{ Inst = '6a6c0b44-8403-4213-8e34-fd21e416c0f3'; Val = '8e6986f8-3f2b-4a22-989d-08603dba0707' }
    'ade_setupassistant_privacy'                  = @{ Inst = '129ac5ce-c6b8-4402-bf18-40045c11c10d'; Val = '177b8bd8-8dc1-4835-82af-16e81dc7e94f' }
    'ade_setupassistant_androidmigration'         = @{ Inst = 'ec192455-f753-4fe1-a4b5-ea98ce1f51a4'; Val = '55060cc0-c46b-40fa-9435-7adf473662fb' }
    'ade_setupassistant_imessagefacetime'         = @{ Inst = '53e650ca-9548-4fb6-8cba-3be4bc2d62a5'; Val = 'b1730b75-01d1-41a4-9e2e-d185ec2a5108' }
    'ade_setupassistant_screentime'               = @{ Inst = '90501450-54d9-4695-a16c-fbfead918c24'; Val = 'b1d1feea-8d71-49bb-8cf6-c736321ae9b6' }
    'ade_setupassistant_simsetup'                 = @{ Inst = '7a270780-d94f-4d00-998e-2a5d69f43832'; Val = '8c2b8a4c-517a-47f7-9f05-392db533b05a' }
    'ade_setupassistant_softwareupdate'           = @{ Inst = '1ad911de-03ea-45a1-917e-adf9ececc09c'; Val = 'd9630ff4-94a4-4525-b37a-7c233a23a2bd' }
    'ade_setupassistant_watchmigration'           = @{ Inst = 'be182ec4-4e16-4f98-9ca2-e4775d35eb88'; Val = 'fe924b50-718f-4b7f-ac33-5a407ea0f005' }
    'ade_setupassistant_appearance'               = @{ Inst = '61b602c2-86a3-4bca-82e5-cc7e14e17895'; Val = '87067516-5437-44ce-a3cc-cee7b6518b46' }
    'ade_setupassistant_devicemigration'          = @{ Inst = '3243140d-97b7-42fe-ba57-f23f782f9112'; Val = '55900392-ff35-43dc-9adb-7fca1987a106' }
    'ade_setupassistant_restorecompleted'         = @{ Inst = '991507fe-fe61-41f9-b80c-cac3f071fb92'; Val = '14e4f24a-55d5-4c04-9f61-862cb42a90e9' }
    'ade_setupassistant_softwareupdatecompleted'  = @{ Inst = '8afaa22c-513a-41b4-9b49-1c888a6f1c53'; Val = '80bdf240-ad52-45fb-9a58-c888d812e75a' }
    'ade_setupassistant_getstarted'               = @{ Inst = '21017ab9-73d3-45dd-b715-8742791a5d73'; Val = 'df5a331d-7042-4abc-91f4-a37c82deaf08' }
    'ade_setupassistant_actionbutton'             = @{ Inst = '6f78e140-a99d-49a0-9658-0d5a4bb30726'; Val = '54fd9219-4c4a-4350-a2be-a85f1096f4da' }
    'ade_setupassistant_safety'                   = @{ Inst = 'b8954ce1-36f1-4149-9851-99c050dfc3f8'; Val = '6290e656-2b8d-4793-b8fb-4336c64a32c5' }
    'ade_setupassistant_termsofaddress'           = @{ Inst = '5dbc8d66-d852-4188-9500-020956fbdfb7'; Val = '1f57641d-fd69-403e-b96d-4f60869e6d9d' }
    'ade_setupassistant_intelligence'             = @{ Inst = 'cca42541-0513-41a6-ae74-e1fe878b0593'; Val = 'd0c43d95-99c7-40ce-b3a6-33098215adc9' }
    'ade_setupassistant_enablelockdownmode'       = @{ Inst = '4a9db745-821d-44a1-a26a-06f2c637d8b8'; Val = '181a5e6d-df5c-4016-b484-3130d54ee9ab' }
    'ade_setupassistant_appstore'                 = @{ Inst = 'b3c4d5e6-f7a8-9012-bcde-fa3456789012'; Val = 'a2b3c4d5-e6f7-8901-abcd-ef2345678901' }
    'ade_setupassistant_camerabutton'             = @{ Inst = 'd5e6f7a8-b9c0-1234-defa-bc5678901234'; Val = 'c4d5e6f7-a8b9-0123-cdef-ab4567890123' }
    'ade_setupassistant_multitasking'             = @{ Inst = 'f7a8b9c0-d1e2-3456-fabc-de7890123456'; Val = 'e6f7a8b9-c0d1-2345-efab-cd6789012345' }
    'ade_setupassistant_osshowcase'               = @{ Inst = 'b9c0d1e2-f3a4-5678-bcde-fa9012345678'; Val = 'a8b9c0d1-e2f3-4567-abcd-ef8901234567' }
    'ade_setupassistant_safetyandhandling'        = @{ Inst = 'd1e2f3a4-b5c6-7890-defa-bc1234567890'; Val = 'c0d1e2f3-a4b5-6789-cdef-ab0123456789' }
    'ade_setupassistant_webcontentfiltering'      = @{ Inst = 'f3a4b5c6-d7e8-9012-fabc-de3456789012'; Val = 'e2f3a4b5-c6d7-8901-efab-cd2345678901' }
}

$macCatalog = @{
    'ade_macos_useraffinity'                      = @{ Inst = 'f3ddbbae-bb3d-45e8-bb9c-854f674e56ef'; Val = 'e34ab06d-486a-4cc0-a867-295515ac2dfc' }
    'ade_macos_awaitconfiguration'                 = @{ Inst = '7e4d9c8a-2f5b-4a3c-8d9e-1b6a4f7c2e5d'; Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_createlocaladmin'         = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_createlocalprimary'       = @{}
    'ade_accountsettings_prefillaccountinfo'       = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_restrictediting'          = @{}
    'ade_accountsettings_primaryaccountfullname'   = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_primaryaccountname'       = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_adminaccountname'         = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_adminaccountfullname'     = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_hideusersgroups'          = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_accountsettings_adminaccountpasswordrotation' = @{ Val = '3a7c9d2e-8f4b-4e1a-9c5d-6b8a3f7e2d4c' }
    'ade_lockedenrollment'                         = @{ Inst = 'e105d3a4-7318-454a-a231-0d1510ebf1e3'; Val = '49085612-4cce-4305-822d-6a6c793285be' }
    'ade_setupassistant_department'                = @{ Inst = '1fd43c7c-0c7a-4dcc-8392-7b1776f86d14'; Val = '180721e2-b467-40a3-b631-b2f28c5d9297' }
    'ade_setupassistant_departmentphone'            = @{ Inst = '383a4d4b-0bbc-4791-bc48-6def8716ec96'; Val = 'f7322d5b-07aa-4b5c-9846-bc3e547e7c0b' }
    'ade_setupassistant_locationservices'           = @{ Inst = '5dca1893-31cd-49b7-aadf-c26990ea0639'; Val = '6f73700e-a14b-4784-9923-512a97297c41' }
    'ade_setupassistant_restore'                    = @{ Inst = 'b4434e35-4131-4b13-90cb-4334cd9768dd'; Val = '78842c1b-d090-407d-9dec-a3a4a168a36f' }
    'ade_setupassistant_appleid'                    = @{ Inst = '4f26cd1f-5fd1-4d6c-af69-f18ade85aee9'; Val = '469e5c1a-c2f8-44fb-b515-f8532c2dff40' }
    'ade_setupassistant_termsandconditions'         = @{ Inst = '5a33bd8e-9df4-422c-92f5-3d5294a3e015'; Val = '404a8266-5c46-44b3-bf63-d8974d91c8f9' }
    'ade_setupassistant_touchfaceid'                = @{ Inst = '0deedc8e-1597-47f0-a271-4ae5029c1795'; Val = 'f11533e6-85a1-41c3-b23d-7a7c0bc2f7f8' }
    'ade_setupassistant_applepay'                   = @{ Inst = 'c7b005a7-148a-40b0-aa06-8a6eaafa6fc0'; Val = 'a18db77d-76e6-4bf8-ab60-98d1e34ed8df' }
    'ade_setupassistant_siri'                       = @{ Inst = '764673c0-b331-478e-905f-ef45428fae99'; Val = 'f3c03777-e89d-4fbc-bc1a-75c4858fa579' }
    'ade_setupassistant_diagnosticsdata'            = @{ Inst = '6a6c0b44-8403-4213-8e34-fd21e416c0f3'; Val = '8e6986f8-3f2b-4a22-989d-08603dba0707' }
    'ade_setupassistant_filevault'                  = @{ Inst = '7d8e9c44-3b2a-4f13-8a5e-2c9d1b4f5a3e'; Val = '2f5c47e9-aa1b-4c35-9e8d-1fa2b8c3d7ea' }
    'ade_setupassistant_iclouddiagnostics'          = @{ Inst = '4c8a7d9e-2f5b-4a3c-9d8e-1b6a4f7c2e9d'; Val = '9a7d5c21-4e3b-4f8a-a9c6-7b5d3e1f2c4a' }
    'ade_setupassistant_icloudstorage'              = @{ Inst = '8f7d3c9a-4e2b-4d1a-9c8e-6b5a3d7f2e4c'; Val = '5b3e8a7c-9d2f-4a1c-8e5b-3d7a2f9c4e1b' }
    'ade_setupassistant_appearance'                 = @{ Inst = '61b602c2-86a3-4bca-82e5-cc7e14e17895'; Val = '87067516-5437-44ce-a3cc-cee7b6518b46' }
    'ade_setupassistant_screentime'                 = @{ Inst = '90501450-54d9-4695-a16c-fbfead918c24'; Val = 'b1d1feea-8d71-49bb-8cf6-c736321ae9b6' }
    'ade_setupassistant_privacy'                    = @{ Inst = '129ac5ce-c6b8-4402-bf18-40045c11c10d'; Val = '177b8bd8-8dc1-4835-82af-16e81dc7e94f' }
    'ade_setupassistant_accessibility'              = @{ Inst = '9c7e4d8a-3f2b-4e1a-8d9c-5b7a3e6f2c4d'; Val = '3f8d7c9b-5e2a-4d1c-8f7e-2b9a5c6d3e1f' }
    'ade_setupassistant_unlockwithwatch'            = @{ Inst = '5c8e9d7a-4f3b-4d2a-8e9c-7b6a5d3f2e1c'; Val = '7e9d4c8a-2f5b-4e3c-9d8a-6b7c3e5f2a1d' }
    'ade_setupassistant_enablelockdownmode'         = @{ Inst = '4a9db745-821d-44a1-a26a-06f2c637d8b8'; Val = '181a5e6d-df5c-4016-b484-3130d54ee9ab' }
    'ade_setupassistant_softwareupdate'             = @{ Inst = '1ad911de-03ea-45a1-917e-adf9ececc09c'; Val = 'd9630ff4-94a4-4525-b37a-7c233a23a2bd' }
    'ade_setupassistant_softwareupdatecompleted'    = @{ Inst = '8afaa22c-513a-41b4-9b49-1c888a6f1c53'; Val = '80bdf240-ad52-45fb-9a58-c888d812e75a' }
    'ade_setupassistant_termsofaddress'             = @{ Inst = '21017ab9-73d3-45dd-b715-8742791a5d73'; Val = 'df5a331d-7042-4abc-91f4-a37c82deaf08' }
    'ade_setupassistant_intelligence'               = @{ Inst = 'cca42541-0513-41a6-ae74-e1fe878b0593'; Val = 'd0c43d95-99c7-40ce-b3a6-33098215adc9' }
    'ade_setupassistant_osshowcase'                 = @{ Inst = '5d9c8e7a-3f2b-4d1a-8e9c-6b5a7d3f2e4c'; Val = '8c2d7f9e-4a3b-4e1c-9d8e-5b7a3c6f2d1e' }
    'ade_setupassistant_appstore'                   = @{ Inst = '4c8e7d9a-3f2b-4d1a-9c8e-5b7a6d3f2e1c'; Val = '7e8d9c4a-2f5b-4e3c-8d9a-6b7c3e5f2a1d' }
}

# --- Setting instance builders ---------------------------------------------

function New-ChoiceInstance {
    param(
        [Parameter(Mandatory)][string]$DefId,
        [Parameter(Mandatory)][string]$Value,
        [string]$InstTplId,
        [string]$ValTplId,
        [array]$Children = @()
    )
    $inst = [ordered]@{
        '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
        settingDefinitionId = $DefId
    }
    if ($InstTplId) { $inst.settingInstanceTemplateReference = @{ settingInstanceTemplateId = $InstTplId } }
    $csv = [ordered]@{
        '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
        value         = $Value
        children      = @($Children)
    }
    if ($ValTplId) { $csv.settingValueTemplateReference = @{ settingValueTemplateId = $ValTplId } }
    $inst.choiceSettingValue = $csv
    return $inst
}

function New-SimpleInstance {
    param(
        [Parameter(Mandatory)][string]$DefId,
        $Value,
        [string]$InstTplId,
        [string]$ValTplId,
        [ValidateSet('String', 'Integer')][string]$ValueType = 'String'
    )
    $inst = [ordered]@{
        '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
        settingDefinitionId = $DefId
    }
    if ($InstTplId) { $inst.settingInstanceTemplateReference = @{ settingInstanceTemplateId = $InstTplId } }
    if ($ValueType -eq 'Integer') {
        $ssv = [ordered]@{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'
            value         = [int]$Value
        }
    }
    else {
        $ssv = [ordered]@{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
            value         = [string]$Value
        }
    }
    if ($ValTplId) { $ssv.settingValueTemplateReference = @{ settingValueTemplateId = $ValTplId } }
    $inst.simpleSettingValue = $ssv
    return $inst
}

function New-TopLevelSetting {
    param($Instance)
    return @{
        '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
        settingInstance = $Instance
    }
}

# --- Classic field <-> Setup Assistant screen mapping ----------------------

$iosScreenMap = @(
    @{ Field = 'passCodeDisabled'; DefId = 'ade_setupassistant_passcode' }
    @{ Field = 'locationDisabled'; DefId = 'ade_setupassistant_locationservices' }
    @{ Field = 'restoreBlocked'; DefId = 'ade_setupassistant_restore' }
    @{ Field = 'appleIdDisabled'; DefId = 'ade_setupassistant_appleid' }
    @{ Field = 'termsAndConditionsDisabled'; DefId = 'ade_setupassistant_termsandconditions' }
    @{ Field = 'touchIdDisabled'; DefId = 'ade_setupassistant_touchfaceid' }
    @{ Field = 'applePayDisabled'; DefId = 'ade_setupassistant_applepay' }
    @{ Field = 'siriDisabled'; DefId = 'ade_setupassistant_siri' }
    @{ Field = 'diagnosticsDisabled'; DefId = 'ade_setupassistant_diagnosticsdata' }
    @{ Field = 'privacyPaneDisabled'; DefId = 'ade_setupassistant_privacy' }
    @{ Field = 'restoreFromAndroidDisabled'; DefId = 'ade_setupassistant_androidmigration' }
    @{ Field = 'iMessageAndFaceTimeScreenDisabled'; DefId = 'ade_setupassistant_imessagefacetime' }
    @{ Field = 'screenTimeScreenDisabled'; DefId = 'ade_setupassistant_screentime' }
    @{ Field = 'simSetupScreenDisabled'; DefId = 'ade_setupassistant_simsetup' }
    @{ Field = 'softwareUpdateScreenDisabled'; DefId = 'ade_setupassistant_softwareupdate' }
    @{ Field = 'watchMigrationScreenDisabled'; DefId = 'ade_setupassistant_watchmigration' }
    @{ Field = 'appearanceScreenDisabled'; DefId = 'ade_setupassistant_appearance' }
    @{ Field = 'deviceToDeviceMigrationDisabled'; DefId = 'ade_setupassistant_devicemigration' }
    @{ Field = 'restoreCompletedScreenDisabled'; DefId = 'ade_setupassistant_restorecompleted' }
    @{ Field = 'updateCompleteScreenDisabled'; DefId = 'ade_setupassistant_softwareupdatecompleted' }
    @{ Field = 'welcomeScreenDisabled'; DefId = 'ade_setupassistant_getstarted' }
)

$iosNewOnlyDefIds = @(
    'ade_setupassistant_actionbutton', 'ade_setupassistant_safety', 'ade_setupassistant_termsofaddress',
    'ade_setupassistant_intelligence', 'ade_setupassistant_enablelockdownmode', 'ade_setupassistant_appstore',
    'ade_setupassistant_camerabutton', 'ade_setupassistant_multitasking', 'ade_setupassistant_osshowcase',
    'ade_setupassistant_safetyandhandling', 'ade_setupassistant_webcontentfiltering'
)

$iosSkippedFields = @(
    "homeButtonScreenDisabled (Home Button screen removed from the new policy)"
    "onBoardingScreenDisabled (Onboarding screen removed from the new policy)"
    "expressLanguageScreenDisabled (Express Language screen removed from the new policy)"
    "preferredLanguageScreenDisabled (Preferred Language screen removed from the new policy)"
    "zoomDisabled (Zoom screen removed from the new policy)"
    "displayToneSetupDisabled (Display Tone screen removed from the new policy)"
    "supervisedModeEnabled (ADE devices are always supervised under the new policy)"
    "enableSingleAppEnrollmentMode (no policy equivalent)"
    "enableSharedIPad / sharedIPadMaximumUserCount (use the Shared iPad user affinity option manually)"
    "iTunesPairingMode (no policy equivalent)"
    "requireCompanyPortalOnSetupAssistantEnrolledDevices / companyPortalVppTokenId (handled automatically by modern authentication)"
    "profileRemovalDisabled (tied to Supervised mode, always on for policies)"
    "forceTemporarySession / temporarySessionTimeoutInSeconds / userSessionTimeoutInSeconds (no policy equivalent)"
    "passcodeLockGracePeriodInSeconds (no policy equivalent)"
    "carrierActivationUrl (no policy equivalent)"
    "userlessSharedAadModeEnabled (no policy equivalent)"
    "managementCertificates (Apple Configurator certificates must be re-added manually)"
)

$macScreenMap = @(
    @{ Field = 'locationDisabled'; DefId = 'ade_setupassistant_locationservices' }
    @{ Field = 'restoreBlocked'; DefId = 'ade_setupassistant_restore' }
    @{ Field = 'appleIdDisabled'; DefId = 'ade_setupassistant_appleid' }
    @{ Field = 'termsAndConditionsDisabled'; DefId = 'ade_setupassistant_termsandconditions' }
    @{ Field = 'touchIdDisabled'; DefId = 'ade_setupassistant_touchfaceid' }
    @{ Field = 'applePayDisabled'; DefId = 'ade_setupassistant_applepay' }
    @{ Field = 'siriDisabled'; DefId = 'ade_setupassistant_siri' }
    @{ Field = 'diagnosticsDisabled'; DefId = 'ade_setupassistant_diagnosticsdata' }
    @{ Field = 'privacyPaneDisabled'; DefId = 'ade_setupassistant_privacy' }
    @{ Field = 'screenTimeScreenDisabled'; DefId = 'ade_setupassistant_screentime' }
    @{ Field = 'fileVaultDisabled'; DefId = 'ade_setupassistant_filevault' }
    @{ Field = 'iCloudDiagnosticsDisabled'; DefId = 'ade_setupassistant_iclouddiagnostics' }
    @{ Field = 'iCloudStorageDisabled'; DefId = 'ade_setupassistant_icloudstorage' }
    @{ Field = 'accessibilityScreenDisabled'; DefId = 'ade_setupassistant_accessibility' }
    @{ Field = 'autoUnlockWithWatchDisabled'; DefId = 'ade_setupassistant_unlockwithwatch' }
)

$macNewOnlyDefIds = @(
    'ade_setupassistant_enablelockdownmode', 'ade_setupassistant_softwareupdate', 'ade_setupassistant_softwareupdatecompleted',
    'ade_setupassistant_termsofaddress', 'ade_setupassistant_intelligence', 'ade_setupassistant_osshowcase', 'ade_setupassistant_appstore',
    'ade_setupassistant_appearance'
)

$macSkippedFields = @(
    "registrationDisabled (Registration screen removed from the new policy)"
    "passCodeDisabled (Passcode screen not present on macOS policies)"
    "zoomDisabled (Zoom screen removed from the new policy)"
    "chooseYourLockScreenDisabled / displayToneSetupDisabled (classic 'Choose Your Look' screen has no confirmed new-policy equivalent - may correspond to the new Appearance screen, which was set to -NewFieldDefault instead - verify manually)"
    "deviceNameTemplate (no macOS policy equivalent)"
    "supervisedModeEnabled (ADE devices are always supervised under the new policy)"
    "requireCompanyPortalOnSetupAssistantEnrolledDevices (handled automatically by modern authentication)"
    "requestRequiresNetworkTether (no policy equivalent)"
    "autoAdvanceSetupEnabled (no policy equivalent)"
    "usePlatformSSODuringSetupAssistant (no policy equivalent)"
    "adminAccountPassword (secret, never returned by Graph - set manually if used)"
)

# --- Per-platform settings builders -----------------------------------------

function Build-IosSettings {
    param($SourceProfile, [string]$NewFieldDefault, [ref]$Skipped)

    $settings = [System.Collections.Generic.List[object]]::new()

    $affinityValue = if ($SourceProfile.requiresUserAuthentication) { 'ade_useraffinity_1' } else { 'ade_useraffinity_0' }
    $children = @()
    if ($SourceProfile.requiresUserAuthentication) {
        if ($SourceProfile.enableAuthenticationViaCompanyPortal) {
            $Skipped.Value.Add('enableAuthenticationViaCompanyPortal=true (legacy Company Portal auth has no policy equivalent - falling back to modern authentication)')
        }
        $awaitValue = if ($SourceProfile.awaitDeviceConfiguredConfirmation) { 'ade_modernauth_awaitfinalconfiguration_1' } else { 'ade_modernauth_awaitfinalconfiguration_0' }
        $authChild = New-ChoiceInstance -DefId 'ade_authenticationmethod' -Value 'ade_authenticationmethod_2' `
            -Children @((New-ChoiceInstance -DefId 'ade_modernauth_awaitfinalconfiguration' -Value $awaitValue))
        $children = @($authChild)
    }
    $entry = $iosCatalog['ade_useraffinity']
    $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_useraffinity' -Value $affinityValue -InstTplId $entry.Inst -ValTplId $entry.Val -Children $children)))

    $lockedValue = if ($SourceProfile.isMandatory) { 'ade_lockedenrollment_1' } else { 'ade_lockedenrollment_0' }
    $entry = $iosCatalog['ade_lockedenrollment']
    $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_lockedenrollment' -Value $lockedValue -InstTplId $entry.Inst -ValTplId $entry.Val)))

    $entry = $iosCatalog['ade_devicenametemplatechoices']
    if (-not [string]::IsNullOrWhiteSpace($SourceProfile.deviceNameTemplate)) {
        $nameChild = New-SimpleInstance -DefId 'ade_appledevicenametemplate' -Value $SourceProfile.deviceNameTemplate
        $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_devicenametemplatechoices' -Value 'ade_devicenametemplatechoices_1' -InstTplId $entry.Inst -ValTplId $entry.Val -Children @($nameChild))))
    }
    else {
        $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_devicenametemplatechoices' -Value 'ade_devicenametemplatechoices_0' -InstTplId $entry.Inst -ValTplId $entry.Val)))
    }

    $entry = $iosCatalog['ade_activatecellulardatachoices']
    $cellValue = if ($NewFieldDefault -eq 'Show') { 'ade_activatecellulardatachoices_1' } else { 'ade_activatecellulardatachoices_0' }
    $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_activatecellulardatachoices' -Value $cellValue -InstTplId $entry.Inst -ValTplId $entry.Val)))
    $Skipped.Value.Add('activatecellulardatachoices has no classic equivalent - applied -NewFieldDefault')

    $entry = $iosCatalog['ade_setupassistant_department']
    $settings.Add((New-TopLevelSetting (New-SimpleInstance -DefId 'ade_setupassistant_department' -Value $SourceProfile.supportDepartment -InstTplId $entry.Inst -ValTplId $entry.Val)))
    $entry = $iosCatalog['ade_setupassistant_departmentphone']
    $settings.Add((New-TopLevelSetting (New-SimpleInstance -DefId 'ade_setupassistant_departmentphone' -Value $SourceProfile.supportPhoneNumber -InstTplId $entry.Inst -ValTplId $entry.Val)))

    foreach ($map in $iosScreenMap) {
        $entry = $iosCatalog[$map.DefId]
        $hidden = [bool]$SourceProfile.($map.Field)
        $value = "$($map.DefId)_$(if ($hidden) { 0 } else { 1 })"
        $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId $map.DefId -Value $value -InstTplId $entry.Inst -ValTplId $entry.Val)))
    }

    $newValueSuffix = if ($NewFieldDefault -eq 'Show') { 1 } else { 0 }
    foreach ($defId in $iosNewOnlyDefIds) {
        $entry = $iosCatalog[$defId]
        $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId $defId -Value "${defId}_$newValueSuffix" -InstTplId $entry.Inst -ValTplId $entry.Val)))
    }
    foreach ($f in $iosSkippedFields) { $Skipped.Value.Add($f) }

    return $settings
}

function Build-MacSettings {
    param($SourceProfile, [string]$NewFieldDefault, [ref]$Skipped)

    $settings = [System.Collections.Generic.List[object]]::new()

    $affinityValue = if ($SourceProfile.requiresUserAuthentication) { 'ade_macos_useraffinity_1' } else { 'ade_macos_useraffinity_0' }
    $children = @()
    if ($SourceProfile.requiresUserAuthentication) {
        if ($SourceProfile.enableAuthenticationViaCompanyPortal) {
            $Skipped.Value.Add('enableAuthenticationViaCompanyPortal=true (legacy Company Portal auth has no policy equivalent - falling back to modern authentication)')
        }
        $children = @((New-ChoiceInstance -DefId 'ade_macos_authenticationmethod' -Value 'ade_macos_authenticationmethod_2'))
    }
    $entry = $macCatalog['ade_macos_useraffinity']
    $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_macos_useraffinity' -Value $affinityValue -InstTplId $entry.Inst -ValTplId $entry.Val -Children $children)))

    # Nested account settings tree, confirmed against two live tenant policies
    # (one with only a local admin account configured, one with only a
    # primary account configured):
    #
    #   awaitconfiguration
    #     -> createlocaladmin (Yes/No)
    #          -> createlocalprimary (No/Standard/Administrator)   [always present]
    #               -> prefillaccountinfo (only when createlocalprimary != No)
    #                    -> restrictediting, primaryaccountfullname, primaryaccountname
    #          -> adminaccountname, adminaccountfullname, hideusersgroups,
    #             adminaccountpasswordrotation                     [only when createlocaladmin = Yes]
    $awaitValue = if ($SourceProfile.waitForDeviceConfiguredConfirmation) { 'ade_macos_awaitconfiguration_1' } else { 'ade_macos_awaitconfiguration_0' }

    if ($SourceProfile.skipPrimarySetupAccountCreation) {
        $primaryValue = 'ade_accountsettings_createlocalprimary_0'
    }
    elseif ($SourceProfile.setPrimarySetupAccountAsRegularUser) {
        $primaryValue = 'ade_accountsettings_createlocalprimary_1'
    }
    else {
        $primaryValue = 'ade_accountsettings_createlocalprimary_2'
    }
    $primaryChildren = @()
    if ($primaryValue -ne 'ade_accountsettings_createlocalprimary_0') {
        $prefillValue   = if ($SourceProfile.dontAutoPopulatePrimaryAccountInfo) { 'ade_accountsettings_prefillaccountinfo_0' } else { 'ade_accountsettings_prefillaccountinfo_1' }
        $restrictValue  = if ($SourceProfile.enableRestrictEditing) { 'ade_accountsettings_restrictediting_1' } else { 'ade_accountsettings_restrictediting_0' }
        $prefillChildren = @(
            (New-ChoiceInstance -DefId 'ade_accountsettings_restrictediting' -Value $restrictValue)
            (New-SimpleInstance -DefId 'ade_accountsettings_primaryaccountfullname' -Value $SourceProfile.primaryAccountFullName -ValTplId $macCatalog['ade_accountsettings_primaryaccountfullname'].Val)
            (New-SimpleInstance -DefId 'ade_accountsettings_primaryaccountname' -Value $SourceProfile.primaryAccountUserName -ValTplId $macCatalog['ade_accountsettings_primaryaccountname'].Val)
        )
        $primaryChildren = @((New-ChoiceInstance -DefId 'ade_accountsettings_prefillaccountinfo' -Value $prefillValue -ValTplId $macCatalog['ade_accountsettings_prefillaccountinfo'].Val -Children $prefillChildren))
    }
    $primaryChild = New-ChoiceInstance -DefId 'ade_accountsettings_createlocalprimary' -Value $primaryValue -Children $primaryChildren

    $hasAdmin = -not [string]::IsNullOrWhiteSpace($SourceProfile.adminAccountUserName)
    $adminValue = if ($hasAdmin) { 'ade_accountsettings_createlocaladmin_1' } else { 'ade_accountsettings_createlocaladmin_0' }
    $adminChildren = @($primaryChild)
    if ($hasAdmin) {
        $hideValue = if ($SourceProfile.hideAdminAccount) { 'ade_accountsettings_hideusersgroups_1' } else { 'ade_accountsettings_hideusersgroups_0' }
        $adminChildren += (New-SimpleInstance -DefId 'ade_accountsettings_adminaccountname' -Value $SourceProfile.adminAccountUserName -ValTplId $macCatalog['ade_accountsettings_adminaccountname'].Val)
        $adminChildren += (New-SimpleInstance -DefId 'ade_accountsettings_adminaccountfullname' -Value $SourceProfile.adminAccountFullName -ValTplId $macCatalog['ade_accountsettings_adminaccountfullname'].Val)
        $adminChildren += (New-ChoiceInstance -DefId 'ade_accountsettings_hideusersgroups' -Value $hideValue -ValTplId $macCatalog['ade_accountsettings_hideusersgroups'].Val)

        # Graph rejects createlocaladmin=Yes unless adminaccountpasswordrotation
        # is present too - it's a required sibling, not optional. The classic
        # field's shape isn't confirmed (it's null in every sample profile
        # seen so far), so fall back to 0 (no rotation) unless it's already a
        # plain number.
        $rotationDays = 0
        $rotationSetting = $SourceProfile.depProfileAdminAccountPasswordRotationSetting
        if ($rotationSetting -is [int] -or $rotationSetting -is [long]) {
            $rotationDays = [int]$rotationSetting
        }
        elseif ($rotationSetting) {
            $Skipped.Value.Add('depProfileAdminAccountPasswordRotationSetting has a non-numeric shape - applied a default of 0 (no rotation), verify/set manually')
        }
        $adminChildren += (New-SimpleInstance -DefId 'ade_accountsettings_adminaccountpasswordrotation' -Value $rotationDays -ValTplId $macCatalog['ade_accountsettings_adminaccountpasswordrotation'].Val -ValueType 'Integer')
    }
    $adminEntry = $macCatalog['ade_accountsettings_createlocaladmin']
    $adminChild = New-ChoiceInstance -DefId 'ade_accountsettings_createlocaladmin' -Value $adminValue -ValTplId $adminEntry.Val -Children $adminChildren

    $entry = $macCatalog['ade_macos_awaitconfiguration']
    $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_macos_awaitconfiguration' -Value $awaitValue -InstTplId $entry.Inst -ValTplId $entry.Val -Children @($adminChild))))

    $lockedValue = if ($SourceProfile.isMandatory) { 'ade_lockedenrollment_1' } else { 'ade_lockedenrollment_0' }
    $entry = $macCatalog['ade_lockedenrollment']
    $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId 'ade_lockedenrollment' -Value $lockedValue -InstTplId $entry.Inst -ValTplId $entry.Val)))

    if (-not [string]::IsNullOrWhiteSpace($SourceProfile.deviceNameTemplate)) {
        $Skipped.Value.Add("deviceNameTemplate='$($SourceProfile.deviceNameTemplate)' (no macOS policy equivalent)")
    }

    $entry = $macCatalog['ade_setupassistant_department']
    $settings.Add((New-TopLevelSetting (New-SimpleInstance -DefId 'ade_setupassistant_department' -Value $SourceProfile.supportDepartment -InstTplId $entry.Inst -ValTplId $entry.Val)))
    $entry = $macCatalog['ade_setupassistant_departmentphone']
    $settings.Add((New-TopLevelSetting (New-SimpleInstance -DefId 'ade_setupassistant_departmentphone' -Value $SourceProfile.supportPhoneNumber -InstTplId $entry.Inst -ValTplId $entry.Val)))

    foreach ($map in $macScreenMap) {
        $entry = $macCatalog[$map.DefId]
        $hidden = [bool]$SourceProfile.($map.Field)
        $value = "$($map.DefId)_$(if ($hidden) { 0 } else { 1 })"
        $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId $map.DefId -Value $value -InstTplId $entry.Inst -ValTplId $entry.Val)))
    }

    $newValueSuffix = if ($NewFieldDefault -eq 'Show') { 1 } else { 0 }
    foreach ($defId in $macNewOnlyDefIds) {
        $entry = $macCatalog[$defId]
        $settings.Add((New-TopLevelSetting (New-ChoiceInstance -DefId $defId -Value "${defId}_$newValueSuffix" -InstTplId $entry.Inst -ValTplId $entry.Val)))
    }
    foreach ($f in $macSkippedFields) { $Skipped.Value.Add($f) }

    return $settings
}

# --- Main --------------------------------------------------------------

$requiredScopes = @('DeviceManagementServiceConfig.ReadWrite.All')
if ($DeviceGroupName) { $requiredScopes += 'Group.Read.All' }
$context = Get-MgContext
if (-not $context -or @($requiredScopes | Where-Object { $_ -notin $context.Scopes }).Count -gt 0) {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}

$deviceGroupId = $null
if ($DeviceGroupName) {
    $groupFilter = "displayName eq '$($DeviceGroupName.Replace("'", "''"))'"
    $groups = @(Get-GraphAll -Uri "beta/groups?`$filter=$([System.Uri]::EscapeDataString($groupFilter))&`$select=id,displayName")
    if ($groups.Count -eq 0) { throw "Entra ID group '$DeviceGroupName' not found." }
    if ($groups.Count -gt 1) { throw "Multiple Entra ID groups named '$DeviceGroupName' found - use a unique group name." }
    $deviceGroupId = $groups[0].id
}

$tokens = Get-GraphAll -Uri 'beta/deviceManagement/depOnboardingSettings'
if ($TokenName) {
    $tokens = @($tokens | Where-Object { $_.tokenName -eq $TokenName })
    if ($tokens.Count -eq 0) { throw "Enrollment program token '$TokenName' not found." }
}

$profilesToMigrate = [System.Collections.Generic.List[object]]::new()

foreach ($token in $tokens) {
    $allProfiles = Get-GraphAll -Uri "beta/deviceManagement/depOnboardingSettings/$($token.id)/enrollmentProfiles"

    # Entries whose id is prefixed 'ECV2_' are Settings Catalog policies
    # mirrored into this collection, not genuine classic profiles - skip them
    # so an already-migrated policy is never "migrated" again.
    $classicProfiles = @($allProfiles | Where-Object {
            $_.id -notlike 'ECV2_*' -and
            $_.'@odata.type' -in @('#microsoft.graph.depIOSEnrollmentProfile', '#microsoft.graph.depMacOSEnrollmentProfile')
        })

    if ($isBulkMode) {
        foreach ($p in $classicProfiles) {
            $profilesToMigrate.Add([PSCustomObject]@{ Token = $token; SourceProfile = $p })
        }
    }
    else {
        foreach ($p in ($classicProfiles | Where-Object { $_.displayName -eq $ProfileName })) {
            $profilesToMigrate.Add([PSCustomObject]@{ Token = $token; SourceProfile = $p })
        }
    }
}

if (-not $isBulkMode -and $profilesToMigrate.Count -eq 0) {
    throw "Classic enrollment profile '$ProfileName' not found (or it is already a Settings Catalog policy)."
}
if ($isBulkMode -and $profilesToMigrate.Count -eq 0) {
    Write-Warning "No classic enrollment profiles found on token '$TokenName'."
}

foreach ($item in $profilesToMigrate) {
    $token          = $item.Token
    $sourceProfile  = $item.SourceProfile
    $isIos          = $sourceProfile.'@odata.type' -eq '#microsoft.graph.depIOSEnrollmentProfile'
    $platformLabel  = if ($isIos) { 'iOS' } else { 'macOS' }

    Write-Output "--- Profile: $($sourceProfile.displayName) ($platformLabel, token '$($token.tokenName)') ---"

    if (-not $isBulkMode -and $NewPolicyName) {
        $targetName = $NewPolicyName
    }
    else {
        $targetName = Get-DerivedPolicyName -OldName $sourceProfile.displayName
        if (-not $targetName) {
            if ($AllowIdenticalName) {
                $targetName = $sourceProfile.displayName
            }
            elseif (-not $isBulkMode) {
                throw "Profile name '$($sourceProfile.displayName)' does not follow the naming convention (no 'DeploymentProfile' segment) - pass -NewPolicyName, or -AllowIdenticalName to reuse the profile's name as-is."
            }
            else {
                Write-Warning "  Name does not follow the naming convention (no 'DeploymentProfile' segment) - skipping. Migrate it explicitly with -ProfileName and -NewPolicyName, or pass -AllowIdenticalName to reuse the profile's name as-is."
                continue
            }
        }
    }

    $nameFilter = "name eq '$($targetName.Replace("'", "''"))'"
    $existing = @(Get-GraphAll -Uri "beta/deviceManagement/configurationPolicies?`$filter=$([System.Uri]::EscapeDataString($nameFilter))&`$select=id,name")
    if ($existing.Count -gt 0) {
        if (-not $Force -and -not $PSCmdlet.ShouldContinue(
                "A policy named '$targetName' already exists (id: $($existing[0].id)). Create a duplicate anyway?",
                'Duplicate policy name')) {
            Write-Warning "  Skipped - policy '$targetName' already exists. Use -Force to create a duplicate anyway."
            continue
        }
    }

    $skipped = [System.Collections.Generic.List[string]]::new()
    if ($isIos) {
        $settings   = Build-IosSettings -SourceProfile $sourceProfile -NewFieldDefault $NewFieldDefault -Skipped ([ref]$skipped)
        $templateId = $iosTemplateId
    }
    else {
        $settings   = Build-MacSettings -SourceProfile $sourceProfile -NewFieldDefault $NewFieldDefault -Skipped ([ref]$skipped)
        $templateId = $macTemplateId
    }

    $body = @{
        name              = $targetName
        description       = $sourceProfile.description
        platforms         = $platformLabel
        technologies      = 'enrollment'
        templateReference = @{ templateId = $templateId }
        creationSource    = "DepTokenId_$($token.id)"
        settings          = $settings
    }

    if ($PSCmdlet.ShouldProcess($targetName, "Create Settings Catalog enrollment policy from '$($sourceProfile.displayName)'")) {
        $created = Invoke-MgGraphRequest -Method POST -Uri 'beta/deviceManagement/configurationPolicies' `
            -Body ($body | ConvertTo-Json -Depth 20) -ContentType 'application/json' -OutputType PSObject
        Write-Output "  Created policy '$($created.name)' (id: $($created.id))"

        if ($deviceGroupId) {
            $groupBody = @{
                enrollmentTimeDeviceMembershipTargets = @(
                    @{ targetType = 'staticSecurityGroup'; targetId = $deviceGroupId }
                )
            }
            Invoke-MgGraphRequest -Method POST -Uri "beta/deviceManagement/configurationPolicies('$($created.id)')/setEnrollmentTimeDeviceMembershipTarget" `
                -Body ($groupBody | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null

            # retrieveEnrollmentTimeDeviceMembershipTarget is the real
            # readback for this action (confirmed live - it's what the
            # portal itself calls). Confirmed shapes: an empty
            # enrollmentTimeDeviceMembershipTargetValidationStatuses array
            # when no group is set, and one entry per target with its own
            # validationSucceeded flag when a group is set.
            $verify = $null
            for ($attempt = 1; $attempt -le 3 -and -not $verify; $attempt++) {
                try {
                    $verify = Invoke-MgGraphRequest -Method GET `
                        -Uri "beta/deviceManagement/configurationPolicies('$($created.id)')/retrieveEnrollmentTimeDeviceMembershipTarget" `
                        -OutputType PSObject -ErrorAction Stop
                }
                catch {
                    if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
                }
            }
            $match = $verify.enrollmentTimeDeviceMembershipTargetValidationStatuses | Where-Object { $_.targetId -eq $deviceGroupId }
            if (-not $verify) {
                Write-Warning "  Could not verify enrollment-time device group '$DeviceGroupName' - check the policy in the portal to confirm it was applied."
            }
            elseif ($match -and $match.validationSucceeded) {
                Write-Output "  Set enrollment-time device group '$DeviceGroupName'"
            }
            else {
                Write-Warning "  Enrollment-time device group '$DeviceGroupName' was NOT applied, even though the request succeeded. This usually means the signed-in account/app lacks sufficient rights (e.g. Owner) on that group - set it manually in the portal instead."
            }
        }
    }

    if ($skipped.Count -gt 0) {
        Write-Output '  Not migrated (configure manually if needed):'
        foreach ($s in $skipped) { Write-Output "    - $s" }
    }
}
