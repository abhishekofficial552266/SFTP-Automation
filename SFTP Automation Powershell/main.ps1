<#
.SYNOPSIS
    Main orchestrator for Azure SFTP provisioning.

.DESCRIPTION
    Reads client requests from Request.json and coordinates:

        1. Folder.ps1
        2. LocalUser.ps1
        3. Permissions.ps1
        4. KeyVault.ps1
        5. Validation.ps1

    The script is designed to:
        - Process multiple requests.
        - Stop a request when a critical step fails.
        - Keep secrets out of logs.
        - Provide a clear final provisioning result.
        - Support repeatable/idempotent execution.

.NOTES
    Run this script from the SFTP-Automation root directory.
#>

[CmdletBinding()]
param (

    # Path to the client request file.
    [Parameter(Mandatory = $false)]
    [string]$RequestFile = ".\Config\Request.json",

    # Azure Resource Group.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    # Azure Storage Account.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountName,

    # Azure Storage filesystem/container.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$FileSystemName,

    # Azure Key Vault.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$KeyVaultName,

    # Group ID used by the SFTP project.
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$GroupId
)

# ================================================================
# 1. INITIALIZATION
# ================================================================

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$modulesPath = Join-Path $scriptRoot "Modules"
$logsPath    = Join-Path $scriptRoot "Logs"

# Create Logs directory if it doesn't exist.
if (-not (Test-Path $logsPath)) {
    New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
}

# Create a timestamped log file.
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $logsPath "Provisioning-$timestamp.log"

# ================================================================
# 2. LOGGING
# ================================================================

function Write-Log {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $logEntry = "[$time] [$Level] $Message"

    # Display normal operational information.
    Write-Host $logEntry

    # Write only non-secret information to the log.
    Add-Content -Path $logFile -Value $logEntry
}

# ================================================================
# 3. LOAD MODULES
# ================================================================

$requiredModules = @(
    "Folder.ps1",
    "LocalUser.ps1",
    "Permissions.ps1",
    "KeyVault.ps1",
    "Validation.ps1"
)

foreach ($module in $requiredModules) {

    $modulePath = Join-Path $modulesPath $module

    if (-not (Test-Path $modulePath)) {

        Write-Log `
            -Message "Required module not found: $modulePath" `
            -Level "ERROR"

        throw "Required module '$module' is missing."
    }

    Write-Log "Loading module: $module"

    . $modulePath
}

# ================================================================
# 4. VALIDATE REQUEST FILE
# ================================================================

Write-Log "Validating request file..."

if (-not (Test-Path $RequestFile)) {

    Write-Log `
        -Message "Request file not found: $RequestFile" `
        -Level "ERROR"

    throw "Request file '$RequestFile' does not exist."
}

try {

    $requestContent = Get-Content `
        -Path $RequestFile `
        -Raw `
        -ErrorAction Stop

    $request = $requestContent | ConvertFrom-Json -ErrorAction Stop
}
catch {

    Write-Log `
        -Message "Request.json contains invalid JSON." `
        -Level "ERROR"

    throw
}

if ($null -eq $request.requests) {

    Write-Log `
        -Message "Request.json does not contain a 'requests' array." `
        -Level "ERROR"

    throw "Invalid request structure."
}

if ($request.requests.Count -eq 0) {

    Write-Log `
        -Message "No requests were found in Request.json." `
        -Level "WARNING"

    return
}

Write-Log "Found $($request.requests.Count) request(s)."

# ================================================================
# 5. PROCESS REQUESTS
# ================================================================

$results = [System.Collections.Generic.List[object]]::new()

foreach ($requestItem in $request.requests) {

    $sourceName = $requestItem.sourceName
    $folderName = $requestItem.folderName
    $access     = $requestItem.access
    $requestType = $requestItem.requestType

    Write-Log ""
    Write-Log "========================================"
    Write-Log "Starting request"
    Write-Log "Source : $sourceName"
    Write-Log "Folder : $folderName"
    Write-Log "Access : $access"
    Write-Log "Type   : $requestType"
    Write-Log "========================================"

    try {

        # --------------------------------------------------------
        # Validate request fields
        # --------------------------------------------------------

        if ([string]::IsNullOrWhiteSpace($sourceName)) {
            throw "sourceName is missing."
        }

        if ([string]::IsNullOrWhiteSpace($folderName)) {
            throw "folderName is missing."
        }

        if ($access -notin @("r", "rw")) {
            throw "Unsupported access level '$access'. Allowed values: r, rw."
        }

        if ($requestType -ne "Create") {
            throw "Request type '$requestType' is not implemented yet."
        }

        # --------------------------------------------------------
        # Generate a safe SFTP username
        # --------------------------------------------------------

        # Example:
        #
        # Sailpoint_Rock + rw
        #
        # becomes:
        #
        # sailpoint-rock-rw
        #

        $safeFolderName = $folderName.ToLower() `
            -replace '[^a-z0-9-]', '-'

        $safeFolderName = $safeFolderName.Trim("-")

        $sftpUserName = "$safeFolderName-$access"

        Write-Log "SFTP username generated: $sftpUserName"

        # --------------------------------------------------------
        # Home directory
        # --------------------------------------------------------

        $homeDirectory = "$FileSystemName/$folderName"

        # ========================================================
        # STEP 1 — FOLDER
        # ========================================================

        Write-Log "Step 1: Ensuring SFTP folder exists."

        Ensure-SftpFolder `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -FileSystemName $FileSystemName `
            -FolderPath $folderName `
            -Verbose

        Write-Log "Folder step completed."

        # ========================================================
        # STEP 2 — LOCAL USER
        # ========================================================

        Write-Log "Step 2: Ensuring SFTP local user exists."

        $userResult = Ensure-SftpLocalUser `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -UserName $sftpUserName `
            -HomeDirectory $homeDirectory `
            -FileSystemName $FileSystemName `
            -Access $access `
            -GroupId $GroupId `
            -Verbose

        Write-Log "Local user step completed."

        # ========================================================
        # STEP 3 — PERMISSIONS
        # ========================================================

        Write-Log "Step 3: Applying folder permissions."

        # Default is deliberately FALSE.
        #
        # Recursive access should only be enabled when the
        # business requirement explicitly requires it.

        Set-SftpDirectoryPermission `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -FileSystemName $FileSystemName `
            -DirectoryPath $folderName `
            -Access $access `
            -Recursive $false `
            -Verbose

        Write-Log "Permission step completed."

        # ========================================================
        # STEP 4 — PASSWORD GENERATION
        # ========================================================

        Write-Log "Step 4: Generating SFTP password."

        $passwordResult = New-AzStorageLocalUserSshPassword `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -UserName $sftpUserName `
            -ErrorAction Stop

        if ($null -eq $passwordResult) {
            throw "Azure did not return an SFTP password."
        }

        # Convert generated password to SecureString.
        #
        # IMPORTANT:
        # Do not write $passwordResult to logs.

        $securePassword = ConvertTo-SecureString `
            -String $passwordResult `
            -AsPlainText `
            -Force

        Write-Log "SFTP password generated successfully."

        # ========================================================
        # STEP 5 — KEY VAULT
        # ========================================================

        Write-Log "Step 5: Storing SFTP password in Key Vault."

        $secretName = "$sftpUserName-password"

        $keyVaultResult = Set-SftpPasswordInKeyVault `
            -KeyVaultName $KeyVaultName `
            -SecretName $secretName `
            -Password $securePassword `
            -Verbose

        Write-Log "Password stored successfully in Key Vault."

        # ========================================================
        # STEP 6 — VALIDATION
        # ========================================================

        Write-Log "Step 6: Running final validation."

        $validationResult = Test-SftpProvisioning `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -FileSystemName $FileSystemName `
            -FolderPath $folderName `
            -UserName $sftpUserName `
            -HomeDirectory $homeDirectory `
            -ExpectedGroupId $GroupId `
            -ExpectedAccess $access `
            -KeyVaultName $KeyVaultName `
            -SecretName $secretName

        if (-not $validationResult.Success) {

            throw "Final validation failed."
        }

        # ========================================================
        # REQUEST SUCCESS
        # ========================================================

        Write-Log "Request completed successfully."

        $results.Add(
            [PSCustomObject]@{
                Source       = $sourceName
                Folder       = $folderName
                UserName     = $sftpUserName
                Access       = $access
                GroupId      = $GroupId
                KeyVaultSecret = $secretName
                Status       = "SUCCESS"
            }
        )
    }
    catch {

        # --------------------------------------------------------
        # REQUEST FAILURE
        # --------------------------------------------------------

        Write-Log `
            -Message "Request failed: $($_.Exception.Message)" `
            -Level "ERROR"

        $results.Add(
            [PSCustomObject]@{
                Source       = $sourceName
                Folder       = $folderName
                UserName     = $sftpUserName
                Access       = $access
                GroupId      = $GroupId
                KeyVaultSecret = ""
                Status       = "FAILED"
            }
        )

        # Continue processing other requests.
        continue
    }
}

# ================================================================
# 6. FINAL SUMMARY
# ================================================================

Write-Host ""
Write-Host "========================================"
Write-Host "SFTP AUTOMATION SUMMARY"
Write-Host "========================================"

$results | Format-Table -AutoSize

$failedRequests = @(
    $results | Where-Object {
        $_.Status -eq "FAILED"
    }
)

if ($failedRequests.Count -gt 0) {

    Write-Log `
        -Message "$($failedRequests.Count) request(s) failed." `
        -Level "ERROR"

    Write-Host ""
    Write-Host "Automation completed with failures."

    exit 1
}

Write-Log "All requests completed successfully."

Write-Host ""
Write-Host "Automation completed successfully."
Write-Host "Log file: $logFile"