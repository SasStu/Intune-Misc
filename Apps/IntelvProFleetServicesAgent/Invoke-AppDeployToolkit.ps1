<#

.SYNOPSIS
PSAppDeployToolkit - Installs, uninstalls or repairs the Intel vPro Fleet Services Agent.

.DESCRIPTION
- Install: verifies that Files\vProFleetAgent.Installer.msi and Files\PairingToken are present, then installs the MSI
  with INSTALLATION_TYPE=STANDARD. The MSI picks up the PairingToken file from its own directory and pairs the device.
- Uninstall: runs "IntelvProFleetServicesAgent.exe un-pair" (best effort), then uninstalls the MSI.
- Repair: same file checks as Install, then repairs the MSI.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

.NOTES
Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1, and Invoke-AppDeployToolkit.exe
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

Custom exit codes used by this package:
- 69001: MSI or PairingToken file missing/empty in Files\

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

# Zero-Config MSI support is provided when "AppName" is null or empty.
# By setting the "AppName" property, Zero-Config MSI will be disabled.
$adtSession = @{
    # App variables.
    AppVendor = 'Intel'
    AppName = 'vPro Fleet Services Agent'
    AppVersion = '1.2.7'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-10-22'
    AppScriptAuthor = 'Sascha Stumpler'
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
    InstallTitle = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

# Package files (relative to Files\) and agent settings.
$msiFileName = 'vProFleetAgent.Installer.msi'
$pairingTokenFileName = 'PairingToken'
$agentExeName = 'IntelvProFleetServicesAgent.exe'
$msiProperties = 'INSTALLATION_TYPE=STANDARD'

function Assert-PackageFiles
{
    [CmdletBinding()]
    param
    (
    )

    # The MSI reads PairingToken from its own directory. Without it the agent installs but never pairs, so fail hard.
    foreach ($fileName in $msiFileName, $pairingTokenFileName)
    {
        $filePath = Join-Path -Path $adtSession.DirFiles -ChildPath $fileName
        if (!(Test-Path -LiteralPath $filePath -PathType Leaf) -or ((Get-Item -LiteralPath $filePath).Length -eq 0))
        {
            Write-ADTLogEntry -Message "Required file [$filePath] is missing or empty. Aborting." -Severity 3
            Close-ADTSession -ExitCode 69001
        }
    }
    Write-ADTLogEntry -Message "Found [$msiFileName] and [$pairingTokenFileName] in [$($adtSession.DirFiles)]."
}

function Get-FleetAgentPath
{
    [CmdletBinding()]
    param
    (
    )

    # Prefer the install location registered for the MSI's product code, fall back to searching the Intel folders.
    $msiPath = Join-Path -Path $adtSession.DirFiles -ChildPath $msiFileName
    $productCode = (Get-ADTMsiTableProperty -LiteralPath $msiPath -Table Property).ProductCode
    $app = Get-ADTApplication -ProductCode $productCode
    if ($app -and $app.InstallLocation)
    {
        $agentPath = Join-Path -Path $app.InstallLocation.FullName -ChildPath $agentExeName
        if (Test-Path -LiteralPath $agentPath -PathType Leaf)
        {
            return $agentPath
        }
    }

    $searchRoots = "$env:ProgramFiles\Intel*", "${env:ProgramFiles(x86)}\Intel*"
    $agent = Get-ChildItem -Path $searchRoots -Filter $agentExeName -Recurse -File -ErrorAction Ignore | Select-Object -First 1
    if ($agent)
    {
        return $agent.FullName
    }
}

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    Assert-PackageFiles


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    # Relative FilePath resolves to Files\, so msiexec runs next to the PairingToken file.
    Start-ADTMsiProcess -Action Install -FilePath $msiFileName -AdditionalArgumentList $msiProperties


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    # Un-pair is best effort: a failure here must not block removing the MSI.
    try
    {
        $agentPath = Get-FleetAgentPath
        if ($agentPath)
        {
            $result = Start-ADTProcess -FilePath $agentPath -ArgumentList 'un-pair' -CreateNoWindow -Timeout (New-TimeSpan -Minutes 5) -IgnoreExitCodes '*' -PassThru
            if ($result.ExitCode -ne 0)
            {
                Write-ADTLogEntry -Message "Un-pair returned exit code [$($result.ExitCode)]. Continuing with uninstall." -Severity 2
            }
        }
        else
        {
            Write-ADTLogEntry -Message "[$agentExeName] not found, skipping un-pair." -Severity 2
        }
    }
    catch
    {
        Write-ADTLogEntry -Message "Un-pair failed, continuing with uninstall.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 2
    }


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Start-ADTMsiProcess -Action Uninstall -FilePath $msiFileName


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    Assert-PackageFiles


    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Start-ADTMsiProcess -Action Repair -FilePath $msiFileName -AdditionalArgumentList $msiProperties


    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
