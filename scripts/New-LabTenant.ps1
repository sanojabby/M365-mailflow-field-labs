<#
.SYNOPSIS
    Builds the Microsoft 365 objects the ten troubleshooting cases need.

.DESCRIPTION
    This script is a plan printer first and a change engine second. Run it with no
    switches and it only reads the tenant: it lists every change it would make, the
    target object, and whether that object is already present. Nothing is created
    until you re-run it with -Apply.

    What it creates:
      TS-001  a lab user, an external mail contact, and an inbox rule that forwards
              matching mail to that contact
      TS-002  two lab users with mailbox forwarding pointing at each other
      TS-007  the CEO mailbox used as the impersonation target (policy is separate)
      TS-008  a lab user with an archive and a litigation hold, plus a small
              Recoverable Items quota so the "dumpster full" state is reachable
      TS-009  an IMAP migration endpoint for the Google batch
      TS-010  a VIP bypass rule at priority 0 with stop-processing, and the external
              disclaimer at priority 5

    What it deliberately does not touch:
      TS-003, TS-004  paper designs, no tenant objects
      TS-005, TS-006  DNS records at your registrar, outside the tenant
      TS-007          the tenant-wide anti-phishing default, which needs its own
                      reviewed change rather than being bundled into a lab build

.PARAMETER Apply
    Actually make the changes. Without it the script is read-only.

.PARAMETER MailDomain
    Domain for the lab UPNs. Defaults to the tenant's default accepted domain.

.PARAMETER ExfilAddress
    External address the TS-001 rule forwards to. If omitted, the contact and rule
    steps are left out of the plan.

.PARAMETER DemoRecoverableQuotaGB
    Recoverable Items quota for the TS-008 mailbox. The default of 1 GB is a lab
    value, chosen so the quota can be reached without moving 30 GB of mail.

.PARAMETER PasswordFile
    Where generated initial passwords are written. Contains credentials, so it is
    excluded from git and should be deleted when the lab is torn down.

.EXAMPLE
    ./New-LabTenant.ps1
    Prints the full change plan and exits without touching anything.

.EXAMPLE
    ./New-LabTenant.ps1 -ExfilAddress lab.forward@gmail.com
    Prints the plan including the TS-001 contact and rule.

.EXAMPLE
    ./New-LabTenant.ps1 -ExfilAddress lab.forward@gmail.com -Apply
    Connects must already exist; creates the objects and prints verification output.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$MailDomain,
    [string]$ExfilAddress,
    [string]$UsageLocation = 'US',
    [int]$DemoRecoverableQuotaGB = 1,
    [string]$MigrationEndpointName = 'Gmail-IMAP',
    [string]$PasswordFile = '.lab-secrets/lab-passwords.csv',
    [int]$MailboxWaitSeconds = 600
)

$ErrorActionPreference = 'Stop'

Import-Module ExchangeOnlineManagement -ErrorAction Stop
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop

$disclaimerText = '<p style="font-size:8pt;color:#666666;">This message and any attachments are confidential and intended only for the named recipient. If you received it in error, delete it and notify the sender.</p>'

# ---------------------------------------------------------------- session state

$exoSession = if (Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue) {
    Get-ConnectionInformation -ErrorAction SilentlyContinue
} else {
    $null
}
$graphSession = if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
    Get-MgContext
} else {
    $null
}

$script:HasExo = [bool]$exoSession
$script:HasGraph = [bool]$graphSession
$script:LabSku = $null

$domainAssumed = $false
if (-not $MailDomain) {
    if ($script:HasExo) {
        $MailDomain = (Get-AcceptedDomain | Where-Object { $_.Default -eq $true } | Select-Object -First 1).DomainName
    }
    if (-not $MailDomain) {
        $MailDomain = 'contoso.onmicrosoft.com'
        $domainAssumed = $true
    }
}

# ---------------------------------------------------------------- helpers

function New-LabPassword {
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(18)
    $body = [Convert]::ToBase64String($bytes) -replace '[^a-zA-Z0-9]', ''
    return ('Lb{0}!9' -f $body.Substring(0, 14))
}

function Save-LabPassword {
    param([string]$Upn, [string]$Password)

    $dir = Split-Path -Parent $PasswordFile
    if ($dir -and -not (Test-Path -Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path -Path $PasswordFile)) {
        'UserPrincipalName,Password' | Set-Content -Path $PasswordFile -Encoding utf8
    }
    '{0},{1}' -f $Upn, $Password | Add-Content -Path $PasswordFile -Encoding utf8
}

function Get-LabSku {
    if ($script:LabSku) { return $script:LabSku }

    $response = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus'
    $sku = $response.value | Where-Object {
        $_.capabilityStatus -eq 'Enabled' -and
        $_.consumedUnits -lt $_.prepaidUnits.enabled -and
        ($_.servicePlans.servicePlanName -match 'EXCHANGE')
    } | Select-Object -First 1

    if (-not $sku) {
        throw 'No licence with free seats and an Exchange Online plan was found. Add seats to the trial subscription before applying.'
    }
    $script:LabSku = $sku
    return $sku
}

function Wait-LabMailbox {
    param([string]$Identity, [int]$TimeoutSeconds = $MailboxWaitSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-Mailbox -Identity $Identity -ErrorAction SilentlyContinue) { return }
        Start-Sleep -Seconds 20
    }
    throw "Mailbox $Identity did not appear within $TimeoutSeconds seconds. Licence assignment may still be provisioning."
}

function Get-LabStepState {
    param([pscustomobject]$Step)

    $graphKinds = @('CreateUser', 'AssignLicense')
    $exoKinds = @('MailContact', 'InboxRule', 'MailboxForward', 'Archive', 'LitigationHold', 'MigrationEndpoint', 'TransportRule')

    if (($graphKinds -contains $Step.Kind) -and -not $script:HasGraph) { return 'unknown (no Graph session)' }
    if (($exoKinds -contains $Step.Kind) -and -not $script:HasExo) { return 'unknown (no Exchange session)' }

    try {
        switch ($Step.Kind) {
            'CreateUser' {
                if (Get-MgUser -UserId $Step.Target -ErrorAction SilentlyContinue) { return 'exists' }
                return 'missing'
            }
            'AssignLicense' {
                $user = Get-MgUser -UserId $Step.Target -Property AssignedLicenses -ErrorAction SilentlyContinue
                if (-not $user) { return 'user missing' }
                if (@($user.AssignedLicenses).Count -gt 0) { return 'licensed' }
                return 'missing'
            }
            'MailContact' {
                if (Get-MailContact -Identity $Step.Params.Name -ErrorAction SilentlyContinue) { return 'exists' }
                return 'missing'
            }
            'InboxRule' {
                if (-not (Get-Mailbox -Identity $Step.Target -ErrorAction SilentlyContinue)) { return 'mailbox missing' }
                $rule = Get-InboxRule -Mailbox $Step.Target -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $Step.Params.Name }
                if ($rule) { return 'exists' }
                return 'missing'
            }
            'MailboxForward' {
                $mailbox = Get-Mailbox -Identity $Step.Target -ErrorAction SilentlyContinue
                if (-not $mailbox) { return 'mailbox missing' }
                if ($mailbox.ForwardingAddress -or $mailbox.ForwardingSmtpAddress) { return 'exists' }
                return 'missing'
            }
            'Archive' {
                $mailbox = Get-Mailbox -Identity $Step.Target -ErrorAction SilentlyContinue
                if (-not $mailbox) { return 'mailbox missing' }
                if ($mailbox.ArchiveStatus -eq 'Active') { return 'exists' }
                return 'missing'
            }
            'LitigationHold' {
                $mailbox = Get-Mailbox -Identity $Step.Target -ErrorAction SilentlyContinue
                if (-not $mailbox) { return 'mailbox missing' }
                if ($mailbox.LitigationHoldEnabled) { return 'exists' }
                return 'missing'
            }
            'TransportRule' {
                if (Get-TransportRule -Identity $Step.Params.Name -ErrorAction SilentlyContinue) { return 'exists' }
                return 'missing'
            }
            'MigrationEndpoint' {
                if (Get-MigrationEndpoint -Identity $Step.Params.Name -ErrorAction SilentlyContinue) { return 'exists' }
                return 'missing'
            }
            default { return 'unknown' }
        }
    } catch {
        return "check failed: $($_.Exception.Message)"
    }
}

function Invoke-LabStep {
    param([pscustomobject]$Step)

    switch ($Step.Kind) {
        'CreateUser' {
            $password = New-LabPassword
            New-MgUser -DisplayName $Step.Params.Display `
                -UserPrincipalName $Step.Target `
                -MailNickname ($Step.Target.Split('@')[0]) `
                -AccountEnabled:$true `
                -UsageLocation $UsageLocation `
                -PasswordProfile @{ Password = $password; ForceChangePasswordNextSignIn = $false } | Out-Null
            Save-LabPassword -Upn $Step.Target -Password $password
            return "created, password written to $PasswordFile"
        }
        'AssignLicense' {
            $sku = Get-LabSku
            $body = @{ addLicenses = @(@{ skuId = $sku.skuId }); removeLicenses = @() }
            $uri = 'https://graph.microsoft.com/v1.0/users/{0}/assignLicense' -f $Step.Target
            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body | Out-Null
            return "licensed from $($sku.skuPartNumber)"
        }
        'MailContact' {
            New-MailContact -Name $Step.Params.Name -ExternalEmailAddress $Step.Target -Alias 'lab-external-forward' | Out-Null
            return "contact created for $($Step.Target)"
        }
        'InboxRule' {
            Wait-LabMailbox -Identity $Step.Target
            New-InboxRule -Mailbox $Step.Target `
                -Name $Step.Params.Name `
                -SubjectContainsWords 'invoice', 'payment', 'remittance' `
                -ForwardTo $Step.Params.ForwardTo `
                -MarkAsRead $true `
                -StopProcessingRules $true | Out-Null
            return 'forwarding rule created'
        }
        'MailboxForward' {
            Wait-LabMailbox -Identity $Step.Target
            Set-Mailbox -Identity $Step.Target `
                -ForwardingAddress $Step.Params.ForwardTo `
                -DeliverToMailboxAndForward $true | Out-Null
            return "forwarding set to $($Step.Params.ForwardTo)"
        }
        'Archive' {
            Wait-LabMailbox -Identity $Step.Target
            Enable-Mailbox -Identity $Step.Target -Archive | Out-Null
            return 'archive mailbox enabled'
        }
        'LitigationHold' {
            Wait-LabMailbox -Identity $Step.Target
            Set-Mailbox -Identity $Step.Target `
                -LitigationHoldEnabled $true `
                -LitigationHoldOwner 'lab-owner' | Out-Null

            $quotaSet = $false
            try {
                $warningMb = [int]($DemoRecoverableQuotaGB * 1024 * 0.8)
                Set-Mailbox -Identity $Step.Target `
                    -RecoverableItemsQuota "$($DemoRecoverableQuotaGB)GB" `
                    -RecoverableItemsWarningQuota "$($warningMb)MB" | Out-Null
                $quotaSet = $true
            } catch {
                $quotaError = $_.Exception.Message
            }

            if ($quotaSet) {
                return "hold enabled, Recoverable Items quota $($DemoRecoverableQuotaGB)GB"
            }
            return "hold enabled, dumpster quota left at tenant default ($quotaError)"
        }
        'TransportRule' {
            if ($Step.Params.Rule -eq 'bypass') {
                New-TransportRule -Name $Step.Params.Name -Priority 0 `
                    -From $Step.Params.Vip `
                    -SetHeaderName 'X-Lab-VIP-Bypass' -SetHeaderValue 'true' `
                    -StopRuleProcessing $true | Out-Null
                return "created at priority 0 for $($Step.Params.Vip)"
            }
            New-TransportRule -Name $Step.Params.Name `
                -FromScope InOrganization `
                -SentToScope NotInOrganization `
                -ApplyHtmlDisclaimerLocation Append `
                -ApplyHtmlDisclaimerText $disclaimerText `
                -ApplyHtmlDisclaimerFallbackAction Wrap | Out-Null
            $created = Get-TransportRule -Identity $Step.Params.Name -ErrorAction SilentlyContinue
            return "created at priority $($created.Priority)"
        }
        'MigrationEndpoint' {
            New-MigrationEndpoint -Name $Step.Params.Name -IMAP `
                -RemoteServer 'imap.gmail.com' -Port 993 -Security Ssl | Out-Null
            return 'IMAP endpoint created'
        }
        default {
            throw "No handler for step type $($Step.Kind)."
        }
    }
}

# ---------------------------------------------------------------- plan

$script:plan = [System.Collections.Generic.List[object]]::new()

function Add-LabPlanStep {
    param(
        [string]$Case,
        [string]$Kind,
        [string]$Action,
        [string]$Target,
        [hashtable]$Params = @{}
    )
    $script:plan.Add([pscustomobject]@{
        Case   = $Case
        Kind   = $Kind
        Action = $Action
        Target = $Target
        Params = $Params
    })
}

$labUsers = @(
    [pscustomobject]@{ Local = 'aisha.rahman';   Display = 'Aisha Rahman';   Case = 'TS-001' }
    [pscustomobject]@{ Local = 'priya.nair';     Display = 'Priya Nair';     Case = 'TS-002' }
    [pscustomobject]@{ Local = 'marco.silva';    Display = 'Marco Silva';    Case = 'TS-002' }
    [pscustomobject]@{ Local = 'alex.morgan';    Display = 'Alex Morgan';    Case = 'TS-007 / 010' } # VIP target for TS-007 and TS-010
    [pscustomobject]@{ Local = 'dana.whitfield'; Display = 'Dana Whitfield'; Case = 'TS-008' }
    [pscustomobject]@{ Local = 'daniel.okafor';  Display = 'Daniel Okafor';  Case = 'TS-009' }
)

foreach ($user in $labUsers) {
    $upn = '{0}@{1}' -f $user.Local, $MailDomain
    Add-LabPlanStep -Case $user.Case -Kind 'CreateUser' -Action 'create user and mailbox' -Target $upn -Params @{ Display = $user.Display }
    Add-LabPlanStep -Case $user.Case -Kind 'AssignLicense' -Action 'assign a licence so the mailbox provisions' -Target $upn
}

if ($ExfilAddress) {
    Add-LabPlanStep -Case 'TS-001' -Kind 'MailContact' -Action 'create external mail contact for the lookalike destination' -Target $ExfilAddress -Params @{ Name = 'Lab External Forward' }
    Add-LabPlanStep -Case 'TS-001' -Kind 'InboxRule' -Action 'create rule "invoice copy", forward matching mail, stop processing' -Target ('aisha.rahman@{0}' -f $MailDomain) -Params @{ Name = 'invoice copy'; ForwardTo = 'Lab External Forward' }
}

Add-LabPlanStep -Case 'TS-002' -Kind 'MailboxForward' -Action 'forward with a copy kept (forwarding side A)' -Target ('priya.nair@{0}' -f $MailDomain) -Params @{ ForwardTo = ('marco.silva@{0}' -f $MailDomain) }
Add-LabPlanStep -Case 'TS-002' -Kind 'MailboxForward' -Action 'forward with a copy kept (forwarding side B)' -Target ('marco.silva@{0}' -f $MailDomain) -Params @{ ForwardTo = ('priya.nair@{0}' -f $MailDomain) }

Add-LabPlanStep -Case 'TS-008' -Kind 'Archive' -Action 'enable archive mailbox (destination for held items)' -Target ('dana.whitfield@{0}' -f $MailDomain)
Add-LabPlanStep -Case 'TS-008' -Kind 'LitigationHold' -Action ("enable litigation hold and set Recoverable Items quota to {0}GB" -f $DemoRecoverableQuotaGB) -Target ('dana.whitfield@{0}' -f $MailDomain)

Add-LabPlanStep -Case 'TS-009' -Kind 'MigrationEndpoint' -Action "create IMAP endpoint $MigrationEndpointName (imap.gmail.com:993)" -Target $MigrationEndpointName -Params @{ Name = $MigrationEndpointName }

Add-LabPlanStep -Case 'TS-010' -Kind 'TransportRule' -Action 'create "VIP bypass - no disclaimer" at priority 0 with stop-processing' -Target 'VIP bypass - no disclaimer' -Params @{ Name = 'VIP bypass - no disclaimer'; Rule = 'bypass'; Vip = ('alex.morgan@{0}' -f $MailDomain) }
Add-LabPlanStep -Case 'TS-010' -Kind 'TransportRule' -Action 'create "External disclaimer" at priority 5' -Target 'External disclaimer' -Params @{ Name = 'External disclaimer'; Rule = 'disclaimer' }

# ---------------------------------------------------------------- report

Write-Host ''
Write-Host '=== LAB TENANT CHANGE PLAN ===' -ForegroundColor Cyan
Write-Host ("Domain     : {0}{1}" -f $MailDomain, $(if ($domainAssumed) { '  (assumed, no session to read accepted domains)' } else { '' }))
Write-Host ("Exchange   : {0}" -f $(if ($script:HasExo) { 'connected' } else { 'not connected' }))
Write-Host ("Graph      : {0}" -f $(if ($script:HasGraph) { 'connected' } else { 'not connected' }))
Write-Host ("Mode       : {0}" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN (read-only)' }))
Write-Host ''

$index = 0
$rows = foreach ($step in $script:plan) {
    $index++
    [pscustomobject]@{
        '#'    = $index
        Case   = $step.Case
        Change = $step.Action
        Target = $step.Target
        State  = (Get-LabStepState -Step $step)
    }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host

$actionableStates = @('missing', 'user missing', 'mailbox missing')
$presentStates = @('exists', 'licensed')

$pending = @($rows | Where-Object { $actionableStates -contains $_.State }).Count
$present = @($rows | Where-Object { $presentStates -contains $_.State }).Count
$unknown = @($rows | Where-Object { $actionableStates -notcontains $_.State -and $presentStates -notcontains $_.State }).Count

Write-Host ("{0} step(s) would run, {1} already present, {2} not checked." -f $pending, $present, $unknown)
if ($unknown -gt 0) {
    Write-Host 'Unchecked steps are unknown, not changes: no session could confirm their current state.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Not included in this script:' -ForegroundColor DarkGray
Write-Host '  TS-003, TS-004  paper designs, nothing to create' -ForegroundColor DarkGray
Write-Host '  TS-005, TS-006  SPF and DMARC records live at your DNS provider' -ForegroundColor DarkGray
Write-Host '  TS-007          anti-phishing default policy, a tenant-wide change to review separately' -ForegroundColor DarkGray
Write-Host ''

if (-not $Apply) {
    Write-Host 'DRY RUN: nothing was changed.' -ForegroundColor Yellow
    Write-Host 'Connect to Exchange Online and Graph, then re-run with -Apply to execute.' -ForegroundColor Yellow
    return
}

if (-not $script:HasExo) { throw 'Apply needs an Exchange Online session. Run Connect-ExchangeOnline, then try again.' }
if (-not $script:HasGraph) { throw 'Apply needs a Graph session. Run Connect-MgGraph -Scopes User.ReadWrite.All, Organization.Read.All, then try again.' }

# ---------------------------------------------------------------- apply

Write-Host '=== APPLYING ===' -ForegroundColor Cyan
foreach ($step in $script:plan) {
    $state = Get-LabStepState -Step $step
    if ($state -in @('exists', 'licensed')) {
        Write-Host ("skip  {0}  ({1})" -f $step.Target, $state) -ForegroundColor DarkGray
        continue
    }
    try {
        $result = Invoke-LabStep -Step $step
        Write-Host ("ok    {0}  {1}" -f $step.Target, $result) -ForegroundColor Green
    } catch {
        Write-Host ("FAIL  {0}  {1}" -f $step.Target, $_.Exception.Message) -ForegroundColor Red
    }
}

# ---------------------------------------------------------------- verification

Write-Host ''
Write-Host '=== VERIFICATION (read-only) ===' -ForegroundColor Cyan

Write-Host ''
Write-Host '-- TS-001: inbox rule and external contact --'
Get-InboxRule -Mailbox ('aisha.rahman@{0}' -f $MailDomain) -ErrorAction SilentlyContinue |
    Format-List Name, Enabled, ForwardTo, RedirectTo, SubjectContainsWords, StopProcessingRules

Write-Host '-- TS-002: forwarding pair --'
foreach ($loopUser in @(('priya.nair@{0}' -f $MailDomain), ('marco.silva@{0}' -f $MailDomain))) {
    Get-Mailbox -Identity $loopUser -ErrorAction SilentlyContinue |
        Format-List Name, ForwardingAddress, ForwardingSmtpAddress, DeliverToMailboxAndForward
}

Write-Host '-- TS-008: hold, archive and quota --'
Get-Mailbox -Identity ('dana.whitfield@{0}' -f $MailDomain) -ErrorAction SilentlyContinue |
    Format-List LitigationHoldEnabled, ArchiveStatus, RecoverableItemsQuota, RecoverableItemsWarningQuota

Write-Host '-- TS-009: migration endpoint --'
Get-MigrationEndpoint -ErrorAction SilentlyContinue |
    Format-Table Identity, EndpointType, RemoteServer, Status -AutoSize
try {
    Test-MigrationServerAvailability -Endpoint $MigrationEndpointName -ErrorAction Stop |
        Format-List Result, Message
} catch {
    Write-Host ("endpoint test not run: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host '-- TS-010: rule order --'
Get-TransportRule -ErrorAction SilentlyContinue |
    Sort-Object Priority |
    Format-Table Name, Priority, State, StopRuleProcessing -AutoSize

Write-Host ''
Write-Host ("Done. Generated passwords are in {0}; delete that file when the lab is torn down." -f $PasswordFile) -ForegroundColor Yellow
