<#
.SYNOPSIS
    Offboards a leaver from Microsoft 365 / Entra ID so they keep no access.

.DESCRIPTION
    Steps (in order):
      1. Block sign-in
      2. Revoke all refresh tokens / sessions
      3. Reset password to a random value
      4. Remove from all groups (records them first for the ticket)
      5. Convert mailbox to shared and grant the manager Full Access
      6. Set an automatic reply (optional)
      7. Remove all licences (shared mailboxes under 50 GB need no licence)

    Use -WhatIf to preview every step without changing anything.

.EXAMPLE
    .\Start-M365Offboarding.ps1 -UserPrincipalName alex.tran@contoso.com -ManagerUpn jordan.lee@contoso.com -AdminUpn admin@contoso.com -WhatIf

.NOTES
    Required: Graph scopes User.ReadWrite.All, Group.ReadWrite.All, Directory.AccessAsUser.All
              Exchange Online Management module (Exchange Administrator role)
    Only run against an approved leaver request. Confirm the leaving date with HR first.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$UserPrincipalName,
    [Parameter(Mandatory)] [string]$ManagerUpn,
    [string]$AutoReplyMessage = "Thank you for your email. I am no longer with the organisation. Please contact {0} for assistance.",
    [switch]$SkipAutoReply,
    # Your admin account. Pre-selects it in the Exchange sign-in so the wrong account isn't picked.
    [string]$AdminUpn,
    [string]$LogPath = ".\offboarding-$(Get-Date -Format yyyyMMdd-HHmmss).log"
)

# Always keep a log, even in -WhatIf mode (-WhatIf:$false stops the preview skipping it)
Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null
$summary = [ordered]@{}

# Make every error stop the script, so a failed step is never reported as done
$ErrorActionPreference = 'Stop'

try {
    # Reuse existing connections instead of prompting again
    $needScopes = 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.AccessAsUser.All'
    $ctx = Get-MgContext
    if (-not $ctx -or ($needScopes | Where-Object { $_ -notin $ctx.Scopes })) {
        Connect-MgGraph -Scopes $needScopes -NoWelcome
    }
    if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object State -eq 'Connected')) {
        Write-Host 'Signing in to Exchange Online (the window may open behind this one)...' -ForegroundColor DarkGray
        if ($AdminUpn) { Connect-ExchangeOnline -UserPrincipalName $AdminUpn -ShowBanner:$false }
        else { Connect-ExchangeOnline -ShowBanner:$false }
    }
    Write-Host "Connected as $((Get-MgContext).Account)" -ForegroundColor DarkGray

    $user = Get-MgUser -UserId $UserPrincipalName -Property Id, DisplayName, AccountEnabled, AssignedLicenses -ErrorAction Stop
    Write-Host "Offboarding $($user.DisplayName) <$UserPrincipalName>" -ForegroundColor Cyan

    # 1. Block sign-in
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Block sign-in')) {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        $summary['Sign-in blocked'] = 'Yes'
    }

    # 2. Revoke sessions (blocking alone does not kill existing tokens)
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Revoke all sign-in sessions')) {
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        $summary['Sessions revoked'] = 'Yes'
    }

    # 3. Reset password to a random value nobody knows
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Reset password')) {
        $bytes = New-Object byte[] 24
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $randomPw = [Convert]::ToBase64String($bytes) + 'a1!'
        Update-MgUser -UserId $user.Id -PasswordProfile @{ Password = $randomPw; ForceChangePasswordNextSignIn = $true }
        $summary['Password reset'] = 'Yes'
    }

    # 4. Remove group memberships (record them first so access can be restored if HR reverses the decision)
    $groups = Get-MgUserMemberOf -UserId $user.Id -All |
        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }
    $groupNames = $groups | ForEach-Object { $_.AdditionalProperties['displayName'] }
    $summary['Groups (before removal)'] = ($groupNames -join '; ')

    foreach ($g in $groups) {
        $name = $g.AdditionalProperties['displayName']
        # Dynamic groups and mail-enabled security / distribution lists can't be changed through
        # this Graph call. Those need Exchange (Remove-DistributionGroupMember) or will
        # update automatically.
        if ($g.AdditionalProperties['groupTypes'] -contains 'DynamicMembership') {
            Write-Host "    Skipping dynamic group $name (membership is rule-based)"; continue
        }
        if ($PSCmdlet.ShouldProcess($name, "Remove $UserPrincipalName")) {
            try {
                Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                Write-Host "    Removed from $name"
            } catch {
                Write-Warning "Could not remove from $name via Graph (likely a distribution list). Trying Exchange..."
                Remove-DistributionGroupMember -Identity $g.Id -Member $UserPrincipalName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    # 5. Convert mailbox to shared + give the manager access
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Convert mailbox to shared and delegate to manager')) {
        Set-Mailbox -Identity $UserPrincipalName -Type Shared
        Add-MailboxPermission -Identity $UserPrincipalName -User $ManagerUpn -AccessRights FullAccess -AutoMapping $true | Out-Null
        Set-Mailbox -Identity $UserPrincipalName -HiddenFromAddressListsEnabled $true
        $summary['Mailbox'] = "Shared, FullAccess -> $ManagerUpn, hidden from GAL"
    }

    # 6. Auto-reply
    if (-not $SkipAutoReply -and $PSCmdlet.ShouldProcess($UserPrincipalName, 'Set automatic reply')) {
        $msg = $AutoReplyMessage -f $ManagerUpn
        Set-MailboxAutoReplyConfiguration -Identity $UserPrincipalName -AutoReplyState Enabled `
            -InternalMessage $msg -ExternalMessage $msg -ExternalAudience All
        $summary['Auto-reply'] = 'Enabled'
    }

    # 7. Reclaim licences. Wait for the shared mailbox conversion to finish first,
    #    otherwise the mailbox can be put at risk.
    if ($user.AssignedLicenses.Count -gt 0 -and $PSCmdlet.ShouldProcess($UserPrincipalName, 'Remove all licences')) {
        $mbx = Get-Mailbox -Identity $UserPrincipalName
        if ($mbx.RecipientTypeDetails -ne 'SharedMailbox') {
            Write-Warning "Mailbox not yet showing as Shared. Licences NOT removed - re-run step 7 later."
        } else {
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses ($user.AssignedLicenses.SkuId) | Out-Null
            $skuNames = Get-MgSubscribedSku -All | Where-Object SkuId -in $user.AssignedLicenses.SkuId
            $summary['Licences reclaimed'] = ($skuNames.SkuPartNumber -join '; ')
        }
    }

    Write-Host "`n=== Offboarding summary (paste into ticket) ===" -ForegroundColor Cyan
    $summary.GetEnumerator() | ForEach-Object { '{0,-26}: {1}' -f $_.Key, $_.Value }
    Write-Host "`nManual follow-ups: wipe/retire device in Intune, collect hardware, remove from MFA/SaaS apps outside Entra, transfer OneDrive files (retained per retention policy)." -ForegroundColor Yellow
}
finally {
    # Connections are left open so a -WhatIf preview can be followed by the real run
    # without signing in again. Close them when finished: Disconnect-ExchangeOnline; Disconnect-MgGraph
    Stop-Transcript -WhatIf:$false | Out-Null
}
