<#
.SYNOPSIS
    Creates or updates an Azure Storage SFTP local user.

.DESCRIPTION
    Production-ready local-user provisioning module.

    Responsibilities:
    - Validate input.
    - Check whether the local user exists.
    - Create/update the local user.
    - Configure home directory.
    - Configure container permission scope.
    - Enable SSH password authentication.
    - Assign Group ID.
    - Enable ACL authorization.
    - Retrieve the Azure-generated User ID.
    - Return the final local-user configuration.

    GroupId and AllowAclAuthorization are applied through the
    Azure Storage Resource Provider REST API because the current
    Az.Storage PowerShell cmdlet does not expose these properties.

.NOTES
    This module does NOT:
    - Store passwords.
    - Store secrets in files.
    - Configure Key Vault.
    - Modify directory ACLs.
#>

function Ensure-SftpLocalUser {

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
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$HomeDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileSystemName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("r", "rw")]
        [string]$Access,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$GroupId
    )

    try {

        Write-Host "----------------------------------------"
        Write-Host "SFTP Local User Provisioning"
        Write-Host "----------------------------------------"

        # ------------------------------------------------------------
        # 1. Validate required Azure modules
        # ------------------------------------------------------------

        if (-not (Get-Command Set-AzStorageLocalUser -ErrorAction SilentlyContinue)) {
            throw "Set-AzStorageLocalUser cmdlet is not available."
        }

        if (-not (Get-Command Get-AzStorageLocalUser -ErrorAction SilentlyContinue)) {
            throw "Get-AzStorageLocalUser cmdlet is not available."
        }

        # ------------------------------------------------------------
        # 2. Build container permission scope
        #
        # The business access is:
        #
        #     r  = read
        #     rw = read/write
        #
        # List/Create/Delete can be added later if the project
        # requires them explicitly.
        # ------------------------------------------------------------

        $permissionScope = New-AzStorageLocalUserPermissionScope `
            -Permission $Access `
            -Service blob `
            -ResourceName $FileSystemName `
            -ErrorAction Stop

        # ------------------------------------------------------------
        # 3. Check whether user already exists
        # ------------------------------------------------------------

        Write-Host "Checking local user: $UserName"

        $existingUser = Get-AzStorageLocalUser `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -UserName $UserName `
            -ErrorAction SilentlyContinue

        # ------------------------------------------------------------
        # 4. Create or update local user
        # ------------------------------------------------------------

        if ($null -eq $existingUser) {

            Write-Host "Local user does not exist. Creating..."

        }
        else {

            Write-Host "Local user already exists. Updating..."
        }

        $localUser = Set-AzStorageLocalUser `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -UserName $UserName `
            -HomeDirectory $HomeDirectory `
            -PermissionScope $permissionScope `
            -HasSshPassword $true `
            -ErrorAction Stop

        Write-Host "Local user created/updated successfully."

        # ------------------------------------------------------------
        # 5. Obtain Azure Storage Resource Provider API token
        # ------------------------------------------------------------

        Write-Host "Obtaining Azure access token..."

        $token = (Get-AzAccessToken `
            -ResourceUrl "https://management.azure.com/").Token

        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Unable to obtain Azure management access token."
        }

        # ------------------------------------------------------------
        # 6. Get subscription ID
        # ------------------------------------------------------------

        $context = Get-AzContext

        if ($null -eq $context) {
            throw "No Azure context found. Authenticate with Azure first."
        }

        $subscriptionId = $context.Subscription.Id

        # ------------------------------------------------------------
        # 7. Build REST API URI
        # ------------------------------------------------------------

        $apiVersion = "2026-04-01"

        $uri = "https://management.azure.com/subscriptions/$subscriptionId" +
               "/resourceGroups/$ResourceGroupName" +
               "/providers/Microsoft.Storage/storageAccounts/$StorageAccountName" +
               "/localUsers/$UserName" +
               "?api-version=$apiVersion"

        # ------------------------------------------------------------
        # 8. Build REST API body
        #
        # This is where GroupId and AllowAclAuthorization are
        # configured.
        # ------------------------------------------------------------

        $body = @{
            properties = @{
                homeDirectory          = $HomeDirectory
                groupId                = $GroupId
                allowAclAuthorization = $true
                hasSshPassword         = $true
                hasSshKey              = $false
                hasSharedKey           = $false
                permissionScopes      = @(
                    @{
                        permissions  = $Access
                        service      = "blob"
                        resourceName = $FileSystemName
                    }
                )
            }
        } | ConvertTo-Json -Depth 10

        # ------------------------------------------------------------
        # 9. Apply Group ID + ACL authorization
        # ------------------------------------------------------------

        Write-Host "Applying Group ID: $GroupId"
        Write-Host "Enabling ACL authorization..."

        $headers = @{
            Authorization = "Bearer $token"
            "Content-Type" = "application/json"
        }

        Invoke-RestMethod `
            -Uri $uri `
            -Method Put `
            -Headers $headers `
            -Body $body `
            -ErrorAction Stop | Out-Null

        Write-Host "Group ID and ACL authorization configured."

        # ------------------------------------------------------------
        # 10. Retrieve final user configuration
        # ------------------------------------------------------------

        Write-Host "Retrieving final local-user configuration..."

        $finalUser = Get-AzStorageLocalUser `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -UserName $UserName `
            -ErrorAction Stop

        # ------------------------------------------------------------
        # 11. Extract Azure-generated User ID
        #
        # The exact property exposed by Az.Storage can vary by
        # module version. We therefore inspect the returned object.
        # ------------------------------------------------------------

        $userId = $null

        if ($finalUser.PSObject.Properties.Name -contains "UserId") {
            $userId = $finalUser.UserId
        }
        elseif ($finalUser.PSObject.Properties.Name -contains "Sid") {
            $userId = $finalUser.Sid
        }

        # ------------------------------------------------------------
        # 12. Final result
        # ------------------------------------------------------------

        Write-Host ""
        Write-Host "----------------------------------------"
        Write-Host "SFTP USER PROVISIONING COMPLETE"
        Write-Host "----------------------------------------"
        Write-Host "Username              : $UserName"
        Write-Host "Home Directory        : $HomeDirectory"
        Write-Host "File System           : $FileSystemName"
        Write-Host "Access                : $Access"
        Write-Host "Group ID              : $GroupId"
        Write-Host "ACL Authorization     : Enabled"
        Write-Host "Azure User ID         : $userId"
        Write-Host "----------------------------------------"

        # Return structured information to Main.ps1.
        return [PSCustomObject]@{
            UserName              = $UserName
            HomeDirectory         = $HomeDirectory
            FileSystemName        = $FileSystemName
            Access                = $Access
            GroupId               = $GroupId
            AllowAclAuthorization = $true
            UserId                = $userId
            LocalUser             = $finalUser
        }
    }
    catch {

        Write-Error @"
SFTP local-user provisioning failed.

Storage Account : $StorageAccountName
User Name       : $UserName
Home Directory : $HomeDirectory
File System    : $FileSystemName
Access          : $Access
Group ID        : $GroupId

Error:
$($_.Exception.Message)
"@

        throw
    }
}