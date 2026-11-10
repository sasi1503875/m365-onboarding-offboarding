<#
.SYNOPSIS
    Exports every user's licences, sign-in status and last sign-in to CSV.

.DESCRIPTION
    Useful as a weekly check to spot:
      - disabled accounts that still hold a licence (wasted cost / missed offboarding step)
      - enabled accounts with no sign-in for 90+ days (possible stale account)
      - licence totals vs. consumed

.EXAMPLE
    .\Get-M365LicenceReport.ps1 -OutputPath .\licence-report.csv

.NOTES
    Scopes: User.Read.All, Organization.Read.All, AuditLog.Read.All
    signInActivity requires an Entra ID P1/P2 licence in the tenant.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".\licence-report-$(Get-Date -Format yyyyMMdd).csv",
    [int]$StaleDays = 90
)

Connect-MgGraph -Scopes 'User.Read.All', 'Organization.Read.All', 'AuditLog.Read.All' -NoWelcome

$skuMap = @{}
Get-MgSubscribedSku -All | ForEach-Object { $skuMap[$_.SkuId] = $_.SkuPartNumber }

$props = 'DisplayName', 'UserPrincipalName', 'AccountEnabled', 'AssignedLicenses', 'Department', 'SignInActivity', 'UserType'
$users = Get-MgUser -All -Property $props -Filter "userType eq 'Member'" -ConsistencyLevel eventual -CountVariable c

$report = foreach ($u in $users) {
    $last = $u.SignInActivity.LastSignInDateTime
    $licences = ($u.AssignedLicenses | Where-Object SkuId | ForEach-Object { $skuMap[$_.SkuId] }) -join '; '
    $flag = @()
    if (-not $u.AccountEnabled -and $licences) { $flag += 'Disabled but licensed' }
    if ($u.AccountEnabled -and $last -and $last -lt (Get-Date).AddDays(-$StaleDays)) { $flag += "No sign-in $StaleDays+ days" }

    [pscustomobject]@{
        DisplayName       = $u.DisplayName
        UserPrincipalName = $u.UserPrincipalName
        Department        = $u.Department
        Enabled           = $u.AccountEnabled
        Licences          = $licences
        LastSignIn        = $last
        Flags             = $flag -join '; '
    }
}

$report | Sort-Object Flags -Descending | Export-Csv $OutputPath -NoTypeInformation -ErrorAction Stop
Write-Host "Exported $($report.Count) users to $OutputPath"
Write-Host "Flagged: $(($report | Where-Object Flags).Count)" -ForegroundColor Yellow

Write-Host "`nLicence usage:"
Get-MgSubscribedSku -All | Select-Object SkuPartNumber,
    @{n = 'Purchased'; e = { $_.PrepaidUnits.Enabled } }, ConsumedUnits,
    @{n = 'Free'; e = { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } } | Format-Table -AutoSize
