<#
.SYNOPSIS
    Onboards one or more new starters into Microsoft 365 / Entra ID.

.DESCRIPTION
    Creates the user account, sets usage location, assigns a licence and adds the
    user to security groups. It supports a single user (parameters) or bulk input
    from a CSV file. Each user gets a random temporary password and must change it
    at first sign-in.

.EXAMPLE
    .\New-M365User.ps1 -FirstName Alex -LastName Tran -Department Finance -JobTitle "Accounts Officer" `
        -Domain contoso.onmicrosoft.com -LicenceSku SPB -Groups SG-Finance,SG-AllStaff

.EXAMPLE
    .\New-M365User.ps1 -CsvPath .\samples\new-starters.csv -Domain contoso.onmicrosoft.com

.NOTES
    Required Graph scopes: User.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')] [string]$FirstName,
    [Parameter(Mandatory, ParameterSetName = 'Single')] [string]$LastName,
    [Parameter(ParameterSetName = 'Single')] [string]$Department,
    [Parameter(ParameterSetName = 'Single')] [string]$JobTitle,
    [Parameter(ParameterSetName = 'Single')] [string]$LicenceSku,
    [Parameter(ParameterSetName = 'Single')] [string[]]$Groups = @(),

    [Parameter(Mandatory, ParameterSetName = 'Csv')] [ValidateScript({ Test-Path $_ })] [string]$CsvPath,

    [Parameter(Mandatory)] [string]$Domain,
    [string]$UsageLocation = 'AU',
    [string]$LogPath = ".\onboarding-$(Get-Date -Format yyyyMMdd-HHmmss).log"
)

function New-TempPassword {
    # 16 characters from upper, lower, digits and symbols, with at least one of each
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*?')
    $chars = foreach ($s in $sets) { $s[(Get-Random -Maximum $s.Length)] }
    $all = -join $sets
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

Start-Transcript -Path $LogPath -Append | Out-Null

try {
    Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Organization.Read.All' -NoWelcome

    $starters = if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        Import-Csv $CsvPath | ForEach-Object {
            [pscustomobject]@{
                FirstName  = $_.FirstName
                LastName   = $_.LastName
                Department = $_.Department
                JobTitle   = $_.JobTitle
                LicenceSku = $_.LicenceSku
                Groups     = if ($_.Groups) { $_.Groups -split ';' } else { @() }
            }
        }
    } else {
        [pscustomobject]@{
            FirstName = $FirstName; LastName = $LastName; Department = $Department
            JobTitle = $JobTitle; LicenceSku = $LicenceSku; Groups = $Groups
        }
    }

    # Cache SKUs once so each user doesn't trigger another lookup
    $skus = Get-MgSubscribedSku -All

    $results = foreach ($s in $starters) {
        $upn = ('{0}.{1}@{2}' -f $s.FirstName, $s.LastName, $Domain).ToLower() -replace '\s', ''
        $mailNick = ($upn -split '@')[0] -replace '[^a-z0-9.]', ''

        if (Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue) {
            Write-Warning "$upn already exists - skipping. Check for a duplicate request."
            [pscustomobject]@{ UPN = $upn; Status = 'Skipped - exists'; TempPassword = $null }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($upn, 'Create user, assign licence and groups')) { continue }

        $tempPw = New-TempPassword
        $body = @{
            displayName       = "$($s.FirstName) $($s.LastName)"
            givenName         = $s.FirstName
            surname           = $s.LastName
            userPrincipalName = $upn
            mailNickname      = $mailNick
            usageLocation     = $UsageLocation
            accountEnabled    = $true
            passwordProfile   = @{ password = $tempPw; forceChangePasswordNextSignIn = $true }
        }
        # Graph rejects empty strings, so only send optional fields that have a value
        if ($s.Department) { $body.department = $s.Department }
        if ($s.JobTitle)   { $body.jobTitle   = $s.JobTitle }
        $user = New-MgUser -BodyParameter $body
        Write-Host "[+] Created $upn" -ForegroundColor Green

        # Licence (usage location must be set first, which we did above)
        if ($s.LicenceSku) {
            $sku = $skus | Where-Object SkuPartNumber -eq $s.LicenceSku
            if (-not $sku) {
                Write-Warning "SKU '$($s.LicenceSku)' not found in tenant."
            } elseif (($sku.PrepaidUnits.Enabled - $sku.ConsumedUnits) -lt 1) {
                Write-Warning "No free $($s.LicenceSku) licences. Raise with the account owner before the start date."
            } else {
                # A brand-new user may not have finished replicating yet, which gives a
                # 409 "Directory_ConcurrencyViolation". Wait and retry instead of failing.
                $assigned = $false
                for ($attempt = 1; $attempt -le 5 -and -not $assigned; $attempt++) {
                    try {
                        Set-MgUserLicense -UserId $user.Id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
                        $assigned = $true
                    } catch {
                        if ($attempt -lt 5) {
                            Write-Host "    Licence not assigned yet (attempt $attempt): retrying in $($attempt * 5)s..." -ForegroundColor DarkYellow
                            Start-Sleep -Seconds ($attempt * 5)
                        } else {
                            Write-Warning "Licence NOT assigned to $upn after 5 attempts: $($_.Exception.Message). Assign it manually."
                        }
                    }
                }
                if ($assigned) { Write-Host "    Licence assigned: $($s.LicenceSku)" }
            }
        }

        foreach ($g in $s.Groups) {
            $grp = Get-MgGroup -Filter "displayName eq '$g'" -ErrorAction SilentlyContinue
            if ($grp) {
                try {
                    New-MgGroupMember -GroupId $grp.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                    Write-Host "    Added to group: $g"
                } catch {
                    Write-Warning "Could not add $upn to '$g': $($_.Exception.Message)"
                }
            } else {
                Write-Warning "Group '$g' not found."
            }
        }

        [pscustomobject]@{ UPN = $upn; Status = 'Created'; TempPassword = $tempPw }
    }

    # The temporary password goes to the console only. Share it with the manager by phone or
    # a secure channel, never in the ticket or in plain-text email.
    $results | Format-Table -AutoSize
    Write-Host "`nNext: confirm the mailbox has provisioned (can take ~15 min), Teams access works, and the user registers MFA on first sign-in." -ForegroundColor Cyan
}
finally {
    Stop-Transcript | Out-Null
}
