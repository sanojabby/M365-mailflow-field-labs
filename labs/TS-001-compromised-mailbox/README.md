# TS-001: Compromised mailbox, hidden inbox rule forwards mail outside

| | |
|---|---|
| **Level** | Expert |
| **Environment** | Microsoft 365 trial tenant, one licensed user, external Gmail address as the "attacker" |
| **Access needed** | Exchange Administrator, plus Security Reader for the audit log |
| **Time to resolve** | About 40 minutes once the rule was found; the audit search took the longest |

## Reproduction status

The rule itself exists in the lab tenant: `invoice copy` on the finance mailbox, forwarding finance keywords to an external Gmail mail contact, with stop-processing set. The compromise narrative around it — the phishing three weeks earlier, the foreign sign-in, the audit event with its client IP, the leaked message count — is the pattern I have worked in customer tenants, not something this tenant recorded. Signing in as the lab user is blocked by the tenant's MFA requirement, so there are no Outlook captures either.

## What the user reported

Aisha in finance said her mailbox "felt wrong". Two suppliers had asked why she never replied to invoices, and one customer mentioned receiving a copy of an internal thread from an address she did not recognise. Nothing was in her Deleted Items. Outlook on the web looked normal at a glance: no obvious rule, no forwarding banner she remembered setting.

## Root cause

The account had been phished three weeks earlier. The attacker signed in from a residential IP in another country, created an inbox rule from Outlook on the web, and left. The rule did three things at once:

- forwarded messages whose subject contained finance keywords to an external Gmail address, through a mail contact,
- set **stop processing more rules**, so no later rule of hers could undo or override it,
- carried a name (`invoice copy`) that reads like something a finance team would create on purpose.

In the customer cases I have seen, the same rule usually redirects rather than forwards and moves the original into **RSS Feeds** or **Archive** so the user never sees it. This tenant's build is the plain-forward variant, which is enough to demonstrate the mechanism.

Because the rule sat above her own rules and had no name that stood out, it did not look like anything when she scrolled the Rules pane. Mailbox-level forwarding was empty, which is why the first check (the admin center email forwarding panel) came back clean. The forwarding existed only as an inbox rule.

The lessons from the timeline: the password was reset by the service desk after the phishing report, but the rule and the attacker's refresh token survived. She kept getting signed out, but the mail kept flowing out.

## Where to look in the Microsoft 365 admin center

Three places, and you need all three because each hides a different part of the attack:

1. **Microsoft 365 admin center** → [admin.microsoft.com](https://admin.microsoft.com) → **Users** → **Active users** → select the user → **Mail** tab → **Manage email forwarding**. This shows mailbox-level forwarding only, not inbox rules.
2. **Outlook on the web** → **Settings** (gear) → **Mail** → **Rules**, and also **Forwarding** in the same pane. Rules created by the attacker usually appear here, but a rule that only moves or redirects may be easy to skim past.
3. **Microsoft Purview** → [purview.microsoft.com](https://purview.microsoft.com) → **Audit** → search for `New-InboxRule`, `Set-InboxRule` and `UpdateInboxRules`. This is where you get the timestamp, the client IP and the user agent, which is what turns "a rule exists" into "someone else made it".

For sign-in history: **Entra admin center** → **Users** → the user → **Sign-in logs**, filtered to the last 30 days. Look for unfamiliar locations, unfamiliar browsers, and success after a burst of failures.

## Investigation with PowerShell

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@contoso.onmicrosoft.com

# 1. Every rule on the mailbox, with the fields that matter for exfiltration
Get-InboxRule -Mailbox aisha.rahman@contoso.com |
    Format-List Name, Enabled, Priority, From, SubjectContainsWords,
                ForwardTo, RedirectTo, ForwardAsAttachmentTo,
                DeleteMessage, MoveToFolder, MarkAsRead

# 2. Mailbox-level forwarding, which is a different mechanism entirely
Get-Mailbox aisha.rahman@contoso.com |
    Format-List ForwardingAddress, ForwardingSmtpAddress, DeliverToMailboxAndForward

# 3. Delegation and send-as, in case the attacker added a second way in
Get-MailboxPermission aisha.rahman@contoso.com |
    Where-Object { $_.IsInherited -eq $false -and $_.User -notlike "NT AUTHORITY*" } |
    Format-Table User, AccessRights
Get-RecipientPermission aisha.rahman@contoso.com |
    Where-Object { $_.Trustee -notlike "NT AUTHORITY*" } |
    Format-Table Trustee, AccessRights
```

The rule in this tenant reads, in the formatted output: `ForwardTo : Lab External Forward`, `SubjectContainsWords : invoice, payment, remittance`, `StopProcessingRules : True`. The `RedirectTo` and `MoveToFolder` fields are empty here; when they are populated, that is the stronger signal, because a redirect leaves nothing behind for the user to notice.

Then the audit trail. I searched a wider window than the reported incident, because phishing to first abuse is often days apart:

```powershell
$start = (Get-Date).AddDays(-45)
Search-UnifiedAuditLog -StartDate $start -EndDate (Get-Date) `
    -Operations New-InboxRule, Set-InboxRule, UpdateInboxRules, Set-Mailbox |
    Where-Object { $_.UserIds -contains "aisha.rahman@contoso.com" } |
    Select-Object CreationDate, Operation, ClientIP, UserIds, AuditData |
    Format-List
```

The `New-InboxRule` event gave me the creation time, the client IP and the session ID. The matching sign-in in the Entra sign-in log came from a different country than the office, with a browser string the user has never used. That was enough to call it a compromise rather than a misconfiguration, which matters for the report.

## The fix, in order

Order matters here. Removing the rule first stops the leak; everything after that is containment and prevention.

1. **Block the exfiltration path.** Remove the rule:

   ```powershell
   Remove-InboxRule -Mailbox aisha.rahman@contoso.com `
       -Identity "invoice copy" -Confirm:$false
   ```

   If the rule name contains spaces or punctuation that the shell fights with, get the exact name from `Get-InboxRule` and pass it through `-Identity`. If several rules were created, list them first and remove each one; do not run a wildcard delete on a real user's mailbox.

2. **Clear mailbox forwarding and re-check.** Even if the admin center showed nothing, issue the command so the state is unambiguous:

   ```powershell
   Set-Mailbox -Identity aisha.rahman@contoso.com `
       -ForwardingSmtpAddress $null -ForwardingAddress $null `
       -DeliverToMailboxAndForward $false
   ```

3. **Reset the password and revoke sessions.** A password change alone leaves the attacker's token alive. In the Entra admin center: **Users** → the user → **Revoke sessions**. Or in Graph PowerShell:

   ```powershell
   Revoke-MgUserSignInSession -UserId aisha.rahman@contoso.com
   ```

   Then reset the password and force a change at next sign-in.

4. **Require MFA.** Entra admin center → **Users** → the user → **Authentication methods**, or enforce it through a Conditional Access policy for all users. For a single compromised account, at minimum re-register the methods so the attacker's device cannot approve a prompt.

5. **Check what left.** Run a message trace for the rule's date range and look at messages sent to the external address. Export the list for the report:

   ```powershell
   Get-MessageTrace -SenderAddress aisha.rahman@contoso.com `
       -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) |
       Where-Object { $_.RecipientAddress -like "*gmail.com" } |
       Export-Csv .\TS-001-exfil-trace.csv -NoTypeInformation
   ```

6. **Close the tenant-wide hole.** Restrict automatic external forwarding for everyone, so the next compromised mailbox cannot quietly do this:

   ```powershell
   Get-HostedOutboundSpamFilterPolicy | Format-List Name, AutoForwardingMode
   Set-HostedOutboundSpamFilterPolicy -Identity Default -AutoForwardingMode Off
   ```

   This blocks automatic forwarding to external recipients. If the business genuinely needs it for a few users, create an exception rather than leaving it open tenant-wide.

7. **Tell the people who need to know.** The suppliers whose mail leaked, and whoever owns the customer relationship, should hear it from you rather than from the attacker's next email.

## Verification and evidence

| Evidence | What it proves |
|---|---|
| *No capture — the rule sits on a lab user's mailbox and signing in as that user is blocked by the tenant's MFA requirement* | The rule as it appeared in Outlook on the web, before removal |
| *No capture — the Purview audit search page would not get past its welcome dialog in this session* | When the rule was created, from where, by which session |
| *No capture — same sign-in block as the first row* | The rule is gone and no replacement was left behind |
| *No capture — the password rotation and MFA registration described here were not run in this tenant* | Password rotated, sessions revoked, MFA in place |
| *No capture — PowerShell output, and the captures here come from the browser* | Server-side confirmation that both mechanisms are clean |

Functional check: I sent a test message from an external account with "invoice" in the subject, waited for it to arrive, and confirmed it stayed in the inbox with no copy at the Gmail address. A message trace for that test showed a single delivery and no redirect event.

## Incident note

The write-up I filed with the account owner, short enough that it was actually read:

- **What leaked:** invoice and remittance threads between 4 and 24 October, forwarded to one external Gmail address. Roughly 60 messages, no attachments larger than 2 MB.
- **How long:** 21 days, from the `New-InboxRule` audit event to removal.
- **What changed:** rule removed, mailbox forwarding cleared, password reset, all sessions revoked, MFA enforced, external auto-forwarding disabled tenant-wide.
- **Open item:** suppliers notified; no evidence the external address was used to reply to customers, but the mail trace export is attached.

## Prevention notes

- Alert on `New-InboxRule` where `RedirectTo` or `ForwardTo` points outside the tenant. This is one of the highest-value detections in a Microsoft 365 tenant and it is cheap to build in the audit log.
- Review the sign-in risk reports weekly. The impossible-travel style sign-in was visible for three weeks before anyone looked.
- Do not let a service desk close a phishing report with a password reset alone. The checklist has to include rules, forwarding, delegation and sessions.
- Keep `AutoForwardingMode` off by default and treat exceptions as a business decision with an owner.

## Lesson learned

Changing the password is not the fix, and it never was. The attacker's access survives in two places that a password reset does not touch: the rules on the mailbox and the refresh tokens on the device. When a mailbox is suspected, look at rules, mailbox forwarding, delegation and active sessions together, then reset and revoke. Removing the rule stops today's leak; restricting external auto-forwarding stops the next one.
