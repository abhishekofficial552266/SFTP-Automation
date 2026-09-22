<#
.SYNOPSIS
    Validates the final Azure SFTP configuration.

.DESCRIPTION
    This module verifies that the requested SFTP configuration
    exists in the expected state.

    It validates:
    - Storage Account availability
    - SFTP folder existence
    - SFTP local user existence
    - Home directory
    - Group ID
    - ACL authorization
    - Permission scope
    - Key Vault secret existence

    This module does NOT:
    - Create resources
    - Modify resources
    - Generate passwords
    - Change permissions

    It is read-only.

.NOTES
    This module is intended to be called after provisioning.
#>

function Test-SftpProvisioning {

    [CmdletBinding()]
    param (

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StorageAccountName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileSystemName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$HomeDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$ExpectedGroupId,

        [Parameter(Mandatory = $true)]
        [ValidateSet("r", "rw")]
        [string]$ExpectedAccess,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$KeyVaultName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SecretName
    )

    $validationResults = [System.Collections.Generic.List[object]]::new()

    try {

        Write-Host ""
        Write-Host "========================================"
        Write-Host "SFTP PROVISIONING VALIDATION"
        Write-Host "========================================"

        # ------------------------------------------------------------
        # 1. Validate Storage Account
        # ------------------------------------------------------------

        Write-Host "Checking Storage Account..."

        $storageAccount = Get-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -ErrorAction Stop

        if ($null -ne $storageAccount) {

            $validationResults.Add(
                [PSCustomObject]@{
                    Check  = "Storage Account"
                    Status = "PASS"
                    Detail = $StorageAccountName
                }
            )
        }

        $context = $storageAccount.Context

        # ------------------------------------------------------------
        # 2. Validate SFTP folder
        # ------------------------------------------------------------

        Write-Host "Checking SFTP folder..."

        $folder = Get-AzDataLakeGen2Item `
            -Context $context `
            -FileSystem $FileSystemName `
            -Path $FolderPath `
            -ErrorAction Stop

        if ($null -eq $folder) {

            throw "Folder '$FolderPath' was not found."
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "SFTP Folder"
                Status = "PASS"
                Detail = "$FileSystemName/$FolderPath"
            }
        )

        # ------------------------------------------------------------
        # 3. Validate Local User
        # ------------------------------------------------------------

        Write-Host "Checking SFTP local user..."

        $localUser = Get-AzStorageLocalUser `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -UserName $UserName `
            -ErrorAction Stop

        if ($null -eq $localUser) {

            throw "SFTP local user '$UserName' was not found."
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "SFTP Local User"
                Status = "PASS"
                Detail = $UserName
            }
        )

        # ------------------------------------------------------------
        # 4. Validate Home Directory
        # ------------------------------------------------------------

        Write-Host "Checking Home Directory..."

        if ($localUser.HomeDirectory -ne $HomeDirectory) {

            throw @"
Home Directory mismatch.

Expected : $HomeDirectory
Actual   : $($localUser.HomeDirectory)
"@
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "Home Directory"
                Status = "PASS"
                Detail = $HomeDirectory
            }
        )

        # ------------------------------------------------------------
        # 5. Validate Group ID
        # ------------------------------------------------------------

        Write-Host "Checking Group ID..."

        if ($localUser.GroupId -ne $ExpectedGroupId) {

            throw @"
Group ID mismatch.

Expected : $ExpectedGroupId
Actual   : $($localUser.GroupId)
"@
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "Group ID"
                Status = "PASS"
                Detail = $ExpectedGroupId
            }
        )

        # ------------------------------------------------------------
        # 6. Validate ACL Authorization
        # ------------------------------------------------------------

        Write-Host "Checking ACL Authorization..."

        if ($localUser.AllowAclAuthorization -ne $true) {

            throw "ACL authorization is not enabled for '$UserName'."
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "ACL Authorization"
                Status = "PASS"
                Detail = "Enabled"
            }
        )

        # ------------------------------------------------------------
        # 7. Validate Permission Scope
        # ------------------------------------------------------------

        Write-Host "Checking Permission Scope..."

        $matchingScope = $localUser.PermissionScopes |
            Where-Object {
                $_.ResourceName -eq $FileSystemName
            }

        if ($null -eq $matchingScope) {

            throw "No permission scope found for filesystem '$FileSystemName'."
        }

        $actualAccess = $matchingScope.Permissions

        if ($actualAccess -ne $ExpectedAccess) {

            throw @"
Permission mismatch.

Expected : $ExpectedAccess
Actual   : $actualAccess
"@
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "Permission Scope"
                Status = "PASS"
                Detail = $actualAccess
            }
        )

        # ------------------------------------------------------------
        # 8. Validate Key Vault Secret
        # ------------------------------------------------------------

        Write-Host "Checking Key Vault secret..."

        $secret = Get-AzKeyVaultSecret `
            -VaultName $KeyVaultName `
            -Name $SecretName `
            -ErrorAction Stop

        if ($null -eq $secret) {

            throw "Key Vault secret '$SecretName' was not found."
        }

        $validationResults.Add(
            [PSCustomObject]@{
                Check  = "Key Vault Secret"
                Status = "PASS"
                Detail = $SecretName
            }
        )

        # ------------------------------------------------------------
        # 9. Final validation report
        # ------------------------------------------------------------

        Write-Host ""
        Write-Host "========================================"
        Write-Host "VALIDATION RESULT"
        Write-Host "========================================"

        $validationResults | Format-Table -AutoSize

        Write-Host ""
        Write-Host "All SFTP provisioning checks passed."
        Write-Host "========================================"

        return [PSCustomObject]@{
            Success = $true
            Checks  = $validationResults
        }
    }
    catch {

        Write-Error @"
SFTP provisioning validation FAILED.

Storage Account : $StorageAccountName
Folder          : $FolderPath
User            : $UserName

Error:
$($_.Exception.Message)
"@

        return [PSCustomObject]@{
            Success = $false
            Checks  = $validationResults
            Error   = $_.Exception.Message
        }
    }
}