<#
.SYNOPSIS
    Ensures that a requested directory exists in an Azure Storage account.

.DESCRIPTION
    This script is responsible only for folder creation/validation.

    It:
    1. Connects to the specified Azure Storage account.
    2. Checks whether the requested directory already exists.
    3. Creates the directory if it does not exist.
    4. Returns the directory path when successful.

    This script does NOT:
    - Create SFTP local users.
    - Configure permissions.
    - Generate passwords.
    - Manage Key Vault secrets.

.NOTES
    This script is designed to be called by Main.ps1.
#>

function Ensure-SftpFolder {

    [CmdletBinding()]
    param (

        # Azure Resource Group containing the Storage Account
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        # Azure Storage Account name
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StorageAccountName,

        # Container / filesystem name
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileSystemName,

        # Folder path to create
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderPath
    )

    try {

        Write-Verbose "Getting storage account context..."

        # Get the Azure Storage Account.
        $storageAccount = Get-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -ErrorAction Stop

        # Create a storage context from the Storage Account.
        $context = $storageAccount.Context

        Write-Verbose "Checking whether folder '$FolderPath' exists..."

        # Check whether the requested directory already exists.
        $directory = Get-AzDataLakeGen2Item `
            -Context $context `
            -FileSystem $FileSystemName `
            -Path $FolderPath `
            -ErrorAction SilentlyContinue

        if ($null -ne $directory) {

            Write-Host "Folder already exists: $FileSystemName/$FolderPath"

            return $FolderPath
        }

        Write-Host "Folder does not exist. Creating: $FileSystemName/$FolderPath"

        # Create the directory.
        New-AzDataLakeGen2Item `
            -Context $context `
            -FileSystem $FileSystemName `
            -Path $FolderPath `
            -Directory `
            -ErrorAction Stop | Out-Null

        Write-Host "Folder created successfully: $FileSystemName/$FolderPath"

        return $FolderPath
    }
    catch {

        Write-Error "Failed to ensure folder '$FolderPath'. Error: $($_.Exception.Message)"

        throw
    }
}