#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Creates a self-signed certificate for use with Azure App Registrations.

.DESCRIPTION
    Generates an RSA self-signed certificate for App Registration certificate
    authentication. Two key-storage strategies are supported via -KeyStorage:

    Software (default):
        Creates the certificate directly in Cert:\LocalMachine\My. By default the key
        is NonExportable and only the .cer (public key) is written to disk. If a
        -Password is supplied, a portable .pfx is also produced: an exportable scratch
        copy is created in the CurrentUser store, the .pfx is exported from it, and a
        NonExportable copy is imported into LocalMachine - so the installed key stays
        locked down while you still get a backup you can deploy to other machines.

    Tpm:
        Generates the key directly inside the TPM using the Microsoft Platform Crypto
        Provider. The private key is NonExportable and never leaves the TPM, so no .pfx
        is produced and the key cannot be backed up or moved to another machine. The
        certificate is created straight into Cert:\LocalMachine\My. Requires a working
        TPM 2.0 (or vTPM on virtual machines).

    In both cases the .cer file is intended to be uploaded to the Azure App Registration
    under "Certificates & secrets". Azure only ever holds the public key.

    In Software mode a .pfx is produced only when -Password is supplied. Without a
    password no .pfx is created at all - the key is generated directly in LocalMachine
    as NonExportable and only the .cer is kept.

    Re-running with the same -CertName does not replace an existing certificate; a new
    certificate (with a new thumbprint) is created and the script warns when a matching
    subject already exists in the store.

    Requires administrator privileges to write into Cert:\LocalMachine\My (enforced by
    the #Requires -RunAsAdministrator statement above).

.PARAMETER CertName
    The common name (CN) for the certificate and the base name for the exported files.
    Defaults to "AppCert".

.PARAMETER OutputPath
    Directory where the .cer (and optionally .pfx) files will be saved.
    Defaults to the script's own directory ($PSScriptRoot).

.PARAMETER ValidityMonths
    Number of months the certificate should be valid.
    Defaults to 24.

.PARAMETER KeyStorage
    Where the private key is stored. Valid values:
        Software - exportable software key with a .pfx export (default).
        Tpm      - key generated in the TPM, NonExportable, no .pfx produced.

.PARAMETER KeyLength
    RSA key size in bits. Valid values: 2048, 3072, 4096. Defaults to 2048.

.PARAMETER FriendlyName
    Friendly name shown for the certificate in the store (e.g. in certlm.msc).
    Defaults to "<CertName> - App Registration (<KeyStorage>)".

.PARAMETER Password
    SecureString password used to protect the .pfx file (Software mode only).
    Supplying it is what triggers .pfx creation; if omitted, no .pfx is produced and
    the key is created directly in LocalMachine as NonExportable.
    Ignored when -KeyStorage is Tpm (there is no .pfx to protect).

.EXAMPLE
    .\script.ps1

    Creates "AppCert" directly in LocalMachine with a NonExportable software key,
    valid for 24 months. No .pfx is produced; only the .cer is kept on disk.

.EXAMPLE
    $pwd = Read-Host "Enter PFX password" -AsSecureString
    .\script.ps1 -CertName "MyCorp" -ValidityMonths 12 -Password $pwd

    Creates "MyCorp" software-key certificate valid for 12 months, protected with the
    supplied password. Both .cer and .pfx are kept on disk.

.EXAMPLE
    .\script.ps1 -CertName "MyCorp" -KeyStorage Tpm -KeyLength 3072

    Creates "MyCorp" with a 3072-bit private key generated inside the TPM. The key is
    NonExportable and machine-bound; no .pfx is produced. Only the .cer is kept on disk.

.OUTPUTS
    PSCustomObject with properties:
        CertName      - Name of the certificate
        Thumbprint    - Certificate thumbprint
        KeyStorage    - "Software" or "Tpm"
        Provider      - The cryptographic provider that backs the private key
        CerPath       - Full path to the exported .cer file
        PfxPath       - Full path to the .pfx file, or $null if deleted / not applicable
        NotAfter      - Expiry date of the certificate
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [string] $CertName = "AppCert",

    [Parameter()]
    [string] $OutputPath = $PSScriptRoot,

    [Parameter()]
    [int] $ValidityMonths = 24,

    [Parameter()]
    [ValidateSet("Software", "Tpm")]
    [string] $KeyStorage = "Software",

    [Parameter()]
    [ValidateSet(2048, 3072, 4096)]
    [int] $KeyLength = 2048,

    [Parameter()]
    [string] $FriendlyName,

    [Parameter()]
    [SecureString] $Password
)

# A failed cmdlet should stop the script immediately rather than letting execution
# continue with a half-built state (e.g. a null $cert flowing into Export-Certificate).
$ErrorActionPreference = 'Stop'

# Ensure the output directory exists
if (-not (Test-Path -Path $OutputPath)) {
    $null = New-Item -Path $OutputPath -ItemType Directory
    Write-Verbose "Created output directory: $OutputPath"
}

$cerPath = Join-Path $OutputPath "$CertName.cer"
$pfxPath = Join-Path $OutputPath "$CertName.pfx"
$expiry  = (Get-Date).AddMonths($ValidityMonths)

if (-not $FriendlyName) {
    $FriendlyName = "$CertName - App Registration ($KeyStorage)"
}

# Warn (don't block) if a certificate with the same subject already lives in the store -
# re-running always mints a brand new certificate with a fresh thumbprint.
$existing = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -eq "CN=$CertName" }
if ($existing) {
    Write-Warning "A certificate with subject 'CN=$CertName' already exists in Cert:\LocalMachine\My (thumbprint $($existing.Thumbprint -join ', ')). A new, separate certificate will be created."
}

# In Software mode, nudge towards the stronger hardware-backed option when a ready TPM
# is present. Purely informational - it never changes what the script does, and a
# detection failure (no TPM, no TPM cmdlets) is silently ignored.
if ($KeyStorage -eq "Software") {
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($tpm.TpmPresent -and $tpm.TpmReady) {
            Write-Information "A TPM is available on this machine. Consider -KeyStorage Tpm for a hardware-backed, non-exportable key." -InformationAction Continue
        }
    }
    catch {
        # No TPM or no TPM cmdlets available - nothing to suggest.
    }
}

# Honour -WhatIf / -Confirm for the state-changing operation
$shouldProcessTarget = "Cert:\LocalMachine\My"
$shouldProcessAction = "Create $KeyStorage-backed certificate 'CN=$CertName' ($KeyLength-bit, expires $expiry)"
if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
    return
}

if ($KeyStorage -eq "Tpm") {
    # ---- TPM-backed key -------------------------------------------------
    # The key is generated inside the TPM and is NonExportable, so there is
    # no .pfx and the key cannot be moved off this machine.

    $tpmProvider = "Microsoft Platform Crypto Provider"

    if ($Password) {
        Write-Warning "The -Password parameter is ignored when -KeyStorage is Tpm (no .pfx is produced)."
    }

    # Note: -KeySpec is deliberately omitted. It is a legacy CSP concept (AT_SIGNATURE)
    # and is incompatible with CNG Key Storage Providers like the Platform Crypto
    # Provider - supplying it raises NTE_PROV_TYPE_NOT_DEF (0x80090017).
    Write-Verbose "Creating TPM-backed self-signed certificate '$CertName' (valid until $expiry)..."
    try {
        $cert = New-SelfSignedCertificate `
            -Subject            "CN=$CertName" `
            -FriendlyName       $FriendlyName `
            -CertStoreLocation  "Cert:\LocalMachine\My" `
            -KeyExportPolicy    NonExportable `
            -KeyLength          $KeyLength `
            -KeyAlgorithm       RSA `
            -HashAlgorithm      SHA256 `
            -Provider           $tpmProvider `
            -NotAfter           $expiry
    }
    catch {
        throw "Failed to create a TPM-backed key with '$tpmProvider'. A working TPM 2.0 (or vTPM on a virtual machine) is required for -KeyStorage Tpm. Underlying error: $($_.Exception.Message)"
    }

    # Export public key (.cer) - upload this to the Azure App Registration
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
    Write-Verbose "Exported public certificate: $cerPath"

    $pfxPath  = $null
    $provider = $tpmProvider
}
elseif ($Password) {
    # ---- Software key WITH a portable .pfx -------------------------------
    # A .pfx was requested. Create an exportable scratch copy in CurrentUser, export
    # the .pfx from it, then import a NonExportable copy into LocalMachine. This yields
    # a portable backup while keeping the installed key locked down. The imported copy
    # shares the same thumbprint, so $cert remains valid for the output object.

    $cert = $null
    try {
        Write-Verbose "Creating exportable scratch certificate '$CertName' in CurrentUser (valid until $expiry)..."
        $cert = New-SelfSignedCertificate `
            -Subject            "CN=$CertName" `
            -FriendlyName       $FriendlyName `
            -CertStoreLocation  "Cert:\CurrentUser\My" `
            -KeyExportPolicy    Exportable `
            -KeySpec            Signature `
            -KeyLength          $KeyLength `
            -KeyAlgorithm       RSA `
            -HashAlgorithm      SHA256 `
            -NotAfter           $expiry

        # Export public key (.cer) - upload this to the Azure App Registration
        Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
        Write-Verbose "Exported public certificate: $cerPath"

        # Export private key bundle (.pfx) - portable backup / deployment artifact
        Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $Password | Out-Null
        Write-Verbose "Exported PFX: $pfxPath"

        # Import into LocalMachine as NonExportable (default) so the installed key
        # cannot be re-exported, while the .pfx on disk remains the only portable copy.
        Import-PfxCertificate -FilePath $pfxPath -Password $Password -CertStoreLocation "Cert:\LocalMachine\My" | Out-Null
        Write-Verbose "Imported certificate into Cert:\LocalMachine\My (NonExportable)"
    }
    finally {
        # Always remove the temporary CurrentUser entry, even if a later step failed -
        # the private key belongs in LocalMachine, not in the user store.
        if ($cert -and (Test-Path -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)")) {
            Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
            Write-Verbose "Removed temporary entry from Cert:\CurrentUser\My"
        }
    }

    $provider = "Microsoft Software Key Storage Provider"
}
else {
    # ---- Software key, NO .pfx -------------------------------------------
    # No .pfx requested, so there is no need for the CurrentUser export path. Create
    # the certificate straight into LocalMachine as NonExportable - one step, nothing
    # to clean up, and the private key can never be extracted.

    Write-Verbose "Creating NonExportable software certificate '$CertName' directly in LocalMachine (valid until $expiry)..."
    $cert = New-SelfSignedCertificate `
        -Subject            "CN=$CertName" `
        -FriendlyName       $FriendlyName `
        -CertStoreLocation  "Cert:\LocalMachine\My" `
        -KeyExportPolicy    NonExportable `
        -KeySpec            Signature `
        -KeyLength          $KeyLength `
        -KeyAlgorithm       RSA `
        -HashAlgorithm      SHA256 `
        -NotAfter           $expiry

    # Export public key (.cer) - upload this to the Azure App Registration
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
    Write-Verbose "Exported public certificate: $cerPath"

    $pfxPath  = $null
    $provider = "Microsoft Software Key Storage Provider"
}

[PSCustomObject]@{
    CertName   = $CertName
    Thumbprint = $cert.Thumbprint
    KeyStorage = $KeyStorage
    Provider   = $provider
    CerPath    = $cerPath
    PfxPath    = $pfxPath
    NotAfter   = $cert.NotAfter
}
