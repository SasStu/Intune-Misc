<#

.SYNOPSIS
PSAppDeployToolkit - Installs, uninstalls or repairs the Intel Management Engine Interface (MEI) driver, the Intel Local Manageability Service (LMS),
the Intel ME WMI provider and the Intel AMT Serial Over LAN (SOL) driver.

.DESCRIPTION
- Install: verifies that the driver folders in Files\ (MEI, LMS, WMIProvider, SOL, SOL_LMS_Extension, named as in Intel's Drivers\ folder)
  contain INF files and that the MEI INF version matches AppVersion, then adds and installs the drivers with "pnputil /add-driver /install" in that order.
- Uninstall: removes the driver store packages published from this package's INFs with "pnputil /delete-driver /uninstall"
  in reverse order. The devices fall back to the next best driver in the store.
- Repair: same as Install.

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
- 69001: A driver folder in Files\ contains no INF file
- 69002: MEI INF DriverVer does not match AppVersion

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
    AppName = 'Management Engine Driver'
    AppVersion = '2603.9.4.0'    # DriverVer of the MEI INF in Files\MEI (bundle ME_2618.9.30.0), the install fails with 69002 if no MEI INF has it
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-10-26'
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

# Driver folders (relative to Files\, same names as in Intel's Drivers\ folder), in install order. Uninstall runs in reverse.
# LMS and WMIProvider are software components of the MEI device, SOL binds to the separate AMT serial port (vPro only).
$driverFolders = 'MEI', 'LMS', 'WMIProvider', 'SOL', 'SOL_LMS_Extension'

# pnputil only exists as a 64-bit binary, use Sysnative when running in a 32-bit process.
$pnputilPath = "$env:SystemRoot\Sysnative\pnputil.exe"
if (!(Test-Path -LiteralPath $pnputilPath -PathType Leaf))
{
    $pnputilPath = "$env:SystemRoot\System32\pnputil.exe"
}

function Get-PackageInf
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]$Folder
    )

    # Intel ships legacy drivers next to the Windows 10/11 ones (e.g. MEI\win8), those must not end up in the driver store.
    $folderPath = Join-Path -Path $adtSession.DirFiles -ChildPath $Folder
    Get-ChildItem -LiteralPath $folderPath -Filter *.inf -Recurse -File -ErrorAction Ignore |
        Where-Object { $_.FullName -notmatch '\\win(7|8|81)\\' } |
        Sort-Object -Property FullName
}

function Get-InfDriverVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]$LiteralPath
    )

    # DriverVer = mm/dd/yyyy,w.x.y.z
    $match = Select-String -LiteralPath $LiteralPath -Pattern '^\s*DriverVer\s*=\s*[^,]+,\s*([\d.]+)' | Select-Object -First 1
    if ($match)
    {
        return $match.Matches[0].Groups[1].Value
    }
}

function Assert-PackageFiles
{
    [CmdletBinding()]
    param
    (
    )

    foreach ($folder in $driverFolders)
    {
        if (!(Get-PackageInf -Folder $folder))
        {
            Write-ADTLogEntry -Message "No INF file found in [$(Join-Path -Path $adtSession.DirFiles -ChildPath $folder)]. Aborting." -Severity 3
            Close-ADTSession -ExitCode 69001
        }
    }

    # Detection.ps1 checks the MEI device's driver version, so the packaged MEI driver must be the version the package claims.
    $meiInfs = foreach ($inf in Get-PackageInf -Folder 'MEI')
    {
        [pscustomobject]@{ Path = $inf.FullName; Version = Get-InfDriverVersion -LiteralPath $inf.FullName }
    }
    $meiInf = $meiInfs | Where-Object { $_.Version -eq $adtSession.AppVersion } | Select-Object -First 1
    if (!$meiInf)
    {
        Write-ADTLogEntry -Message "No MEI INF has DriverVer [$($adtSession.AppVersion)] (found: $(($meiInfs | ForEach-Object { "[$($_.Path)] $($_.Version)" }) -join ', ')). Update AppVersion and Detection.ps1. Aborting." -Severity 3
        Close-ADTSession -ExitCode 69002
    }
    Write-ADTLogEntry -Message "Found MEI driver [$($meiInf.Path)] version [$($meiInf.Version)] and INFs for [$($driverFolders -join ', ')] in [$($adtSession.DirFiles)]."
}

function Install-PackageDriver
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]$Folder
    )

    # 259 (ERROR_NO_MORE_ITEMS): driver was added to the store, but no device needed an update (same or newer driver already installed,
    # or no matching device, e.g. SOL on a non-vPro platform).
    # One call per INF instead of /subdirs, so the legacy folders filtered out by Get-PackageInf stay out.
    foreach ($inf in Get-PackageInf -Folder $Folder)
    {
        Start-ADTProcess -FilePath $pnputilPath -ArgumentList "/add-driver `"$($inf.FullName)`" /install" -CreateNoWindow -SuccessExitCodes 0, 259
    }
}

function Uninstall-PackageDriver
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]$Folder
    )

    # pnputil publishes INFs as oemNN.inf, so find them by original file name and version.
    $storeDrivers = Get-WindowsDriver -Online
    foreach ($inf in Get-PackageInf -Folder $Folder)
    {
        $version = Get-InfDriverVersion -LiteralPath $inf.FullName
        $published = $storeDrivers | Where-Object { ((Split-Path -Path $_.OriginalFileName -Leaf) -eq $inf.Name) -and ($_.Version -eq $version) }
        if (!$published)
        {
            Write-ADTLogEntry -Message "[$($inf.Name)] version [$version] is not in the driver store, nothing to remove." -Severity 2
            continue
        }
        foreach ($driver in $published)
        {
            Write-ADTLogEntry -Message "Removing [$($driver.Driver)] ([$($inf.Name)] version [$version]) from the driver store."
            Start-ADTProcess -FilePath $pnputilPath -ArgumentList "/delete-driver $($driver.Driver) /uninstall" -CreateNoWindow
        }
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

    foreach ($folder in $driverFolders)
    {
        Install-PackageDriver -Folder $folder
    }


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # LMS and WMIProvider are software components of the MEI device, they only appear once the MEI driver is active.
    if (!(Get-Service -Name 'LMS' -ErrorAction Ignore))
    {
        Write-ADTLogEntry -Message "LMS service not present after install. It may appear after a reboot, otherwise check the LMS INF in Files\LMS." -Severity 2
    }
    if (!(Get-CimInstance -Namespace 'root' -ClassName '__NAMESPACE' -Filter "Name = 'Intel_ME'" -ErrorAction Ignore) -and
        !(Get-CimInstance -Namespace 'root\CIMV2' -ClassName '__NAMESPACE' -Filter "Name = 'Intel_ME'" -ErrorAction Ignore))
    {
        Write-ADTLogEntry -Message "Intel_ME WMI namespace not present after install. It may appear after a reboot, otherwise check the INF in Files\WMIProvider." -Severity 2
    }
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


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    foreach ($folder in $driverFolders[-1..0])
    {
        Uninstall-PackageDriver -Folder $folder
    }


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

    foreach ($folder in $driverFolders)
    {
        Install-PackageDriver -Folder $folder
    }


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
