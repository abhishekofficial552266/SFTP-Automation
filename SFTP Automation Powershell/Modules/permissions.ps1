<#
.SYNOPSIS
    Manages Azure Data Lake Storage Gen2 ACL permissions for SFTP directories.

.DESCRIPTION
    This module manages directory-level ACLs for Azure Storage SFTP.

    Responsibilities:
    - Obtain the storage account context.
    - Validate the requested access level.
    - Build the required ACL.
    - Apply ACLs to the requested directory.
    - Optionally apply ACLs recursively.
    - Return the result to the calling script.

    IMPORTANT:
    Container-level SFTP permission scopes are managed separately by
    LocalUser.ps1.

    This module manages directory/file ACLs only.

.NOTES
    Supported business access values:
        r  = Read
        rw = Read + Write

    Technical ACL permissions use:
        r = Read
        w = Write
        x = Execute / Traverse

    Recursive ACL updates replace the ACL on the targeted hierarchy.
    Therefore this script intentionally does not overwrite ACLs recursively
    unless -Recursive is explicitly requested.
#>

function Set-SftpDirectoryPermission {

    [CmdletBinding(SupportsShouldProcess)]
    param (

        # Azure Resource Group containing the Storage Account
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        # Azure Storage Account name
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StorageAccountName,

        # ADLS Gen2 filesystem/container
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileSystemName,

        # Directory path inside the filesystem
        # Example: Sailpoint_Rock
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DirectoryPath,

        # Business-level access requested by the client
        [Parameter(Mandatory = $true)]
        [ValidateSet("r", "rw")]
        [string]$Access,

        # Apply the ACL to the directory and everything underneath it
        [Parameter(Mandatory = $false)]
        [bool]$Recursive = $false
    )

    try {

        Write-Verbose "Getting Azure Storage Account..."

        $storageAccount = Get-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -ErrorAction Stop

        $context = $storageAccount.Context

        Write-Verbose "Building ACL for access level '$Access'..."

        # ------------------------------------------------------------
        # Convert business access into technical ACL permissions.
        #
        # Read access:
        #   r-x
        #
        # Read/Write access:
        #   rwx
        #
        # Execute (x) is required for directory traversal.
        # ------------------------------------------------------------

        switch ($Access) {

            "r" {
                $ownerPermission = "r-x"
            }

            "rw" {
                $ownerPermission = "rwx"
            }

            default {
                throw "Unsupported access level: $Access"
            }
        }

        # ------------------------------------------------------------
        # Build the ACL.
        #
        # owner  -> requested access
        # group  -> traverse only
        # other  -> no access
        #
        # We deliberately keep 'other' restricted.
        # ------------------------------------------------------------

        $acl = Set-AzDataLakeGen2ItemAclObject `
            -AccessControlType user `
            -Permission $ownerPermission

        $acl = Set-AzDataLakeGen2ItemAclObject `
            -AccessControlType group `
            -Permission "---" `
            -InputObject $acl

        $acl = Set-AzDataLakeGen2ItemAclObject `
            -AccessControlType other `
            -Permission "---" `
            -InputObject $acl

        # ------------------------------------------------------------
        # Apply ACL.
        # ------------------------------------------------------------

        if ($Recursive) {

            Write-Host "Applying ACL recursively to '$DirectoryPath'..."

            if ($PSCmdlet.ShouldProcess(
                "$FileSystemName/$DirectoryPath",
                "Apply ACL recursively"
            )) {

                $result = Set-AzDataLakeGen2AclRecursive `
                    -Context $context `
                    -FileSystem $FileSystemName `
                    -Path $DirectoryPath `
                    -Acl $acl `
                    -ContinueOnFailure `
                    -ErrorAction Stop

                if ($result.TotalFailureCount -gt 0) {

                    throw @"
Recursive ACL operation completed with failures.

Successful directories : $($result.TotalDirectoriesSuccessfulCount)
Successful files       : $($result.TotalFilesSuccessfulCount)
Failed entries         : $($result.TotalFailureCount)
"@
                }
            }

        }
        else {

            Write-Host "Applying ACL to directory '$DirectoryPath'..."

            if ($PSCmdlet.ShouldProcess(
                "$FileSystemName/$DirectoryPath",
                "Apply ACL"
            )) {

                Update-AzDataLakeGen2Item `
                    -Context $context `
                    -FileSystem $FileSystemName `
                    -Path $DirectoryPath `
                    -Acl $acl `
                    -ErrorAction Stop | Out-Null
            }
        }

        Write-Host "ACL applied successfully."

        # ------------------------------------------------------------
        # Read the ACL back from Azure.
        #
        # This gives us an actual verification instead of assuming
        # the operation succeeded.
        # ------------------------------------------------------------

        $updatedItem = Get-AzDataLakeGen2Item `
            -Context $context `
            -FileSystem $FileSystemName `
            -Path $DirectoryPath `
            -ErrorAction Stop

        if ($null -eq $updatedItem.ACL) {
            throw "ACL verification failed. Azure returned no ACL for '$DirectoryPath'."
        }

        Write-Host "ACL verification completed successfully."

        return $updatedItem

    }
    catch {

        Write-Error @"
Failed to configure SFTP permissions.

Storage Account : $StorageAccountName
Filesystem      : $FileSystemName
Directory       : $DirectoryPath
Access          : $Access
Recursive       : $Recursive

Error: $($_.Exception.Message)
"@

        throw
    }
}