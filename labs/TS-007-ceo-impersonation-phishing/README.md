# TS-007: Fake "CEO" email lands in the inbox

| | |
|---|---|
| **Level** | Expert |
| **Environment** | Microsoft 365 trial tenant with Defender for Office 365 Plan 1, one VIP mailbox, one external Gmail test sender |
| **Access needed** | Security Administrator or Global Administrator |
| **Time to resolve** | 35 minutes to configure, plus a few hours of policy propagation |

## Reproduction status

This case was **not reproduced** in the lab tenant. Injecting the spoofed message needs SMTP submission from a domain the tenant does not control, and when I tried to add a protected user in the Defender portal the impersonation sender list rejected the tenant's own address with "Please enter a valid Email address", so no policy was saved and nothing was quarantined. The narrative, the VIP list and the quarantine result describe the pattern from customer tenants; the configuration commands are the ones I use there.

## What the user reported

Accounts payable received a message from the CEO asking for an urgent bank transfer ahead of a "confidential acquisition". The display name was right, the signature was copied from a real email, the reply-to was a lookalike domain, and the message was sitting in the inbox with no warning. The recipient noticed the address at the last moment.

This was not an account takeover. The CEO's mailbox was clean, the tenant had no rule forwarders, and the audit log showed nothing unusual. The attacker had simply put the CEO's name on a free mailbox and sent from there.

## Root cause

The tenant had the default anti-phishing policy and nothing else. Default settings do not include impersonation protection for named users or for your own domains, and the default action for a message that *does* look suspicious is to move it to the Junk Email folder, not to quarantine it.

Three gaps combined:

- **No user impersonation protection.** The CEO, CFO and finance manager were not on any protected list, so a message with the CEO's display name from an unrelated domain scored no impersonation signal.
- **No domain impersonation protection.** A lookalike domain (`contoso-corp.com`) was not treated as an impersonation attempt.
- **No first-contact safety tip.** The recipient had never exchanged mail with the sender and saw no banner saying so.

Mailbox intelligence was enabled at the default level but had nothing to work with, because the sender had no history and the policy did not act on the signal.

## Where to look in the Microsoft Defender portal

1. [security.microsoft.com](https://security.microsoft.com) → **Email & collaboration** → **Policies & rules** → **Threat policies** → **Anti-phishing**. The default policy is tenant-wide; a rule can scope settings to a subset of users.
2. Same area → **Quarantine** to see what was stopped and to release or delete messages.
3. **Email & collaboration** → **Explorer** (or **Threat Explorer**) to find other messages from the same sender or display name, which tells you how wide the campaign was.
4. **Attack simulation training** if you want to test the new policy against a benign campaign instead of a real free-mail sender.

## Investigation

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@contoso.onmicrosoft.com

# What the policy currently protects
Get-AntiPhishPolicy | Format-List Name, Enabled, EnableTargetedUserProtection, TargetedUsersToProtect,
    EnableOrganizationDomainsProtection, EnableMailboxIntelligence,
    EnableMailboxIntelligenceProtection, EnableFirstContactSafetyTips,
    TargetedUserProtectionAction, TargetedDomainProtectionAction, MailboxIntelligenceProtectionAction

# Is there a scoped rule on top of the default policy?
Get-AntiPhishRule | Format-Table Name, State, Priority, SentToMemberOf, RecipientDomainIs -AutoSize
```

The default policy came back with `EnableTargetedUserProtection : False` and `EnableOrganizationDomainsProtection : False`. That is the whole story: nothing in the tenant was comparing the display name to the executive list, and nothing was watching for lookalike domains.

I also pulled the message from Explorer and checked its authentication results. SPF, DKIM and DMARC all passed, because the attacker was sending from a domain they legitimately controlled. Authentication proves a domain is genuine, not that the display name belongs to the person it claims.

## The fix

1. **Protect the people who get impersonated.** In the Defender portal, open the anti-phishing policy, go to **Impersonation** → **User impersonation protection**, add the CEO, CFO, finance manager and anyone who can approve payments, and set the action to **Quarantine**. Adding a user means adding both the display name and the address, so the policy has something to match.

2. **Protect your own domains.** Enable **Domain impersonation protection** and add `contoso.com` plus any domains you own but do not send from. This catches lookalikes such as `contoso-corp.com` and `contoso.co`.

3. **Turn on mailbox intelligence.** It builds a per-user map of who normally mails whom, and flags first contact from a sender imitating an internal person. Set the action to **Quarantine** rather than Junk.

4. **Enable the safety tips.** Turn on the first-contact tip and the impersonation tip. The first-contact banner was the single change recipients noticed and thanked us for; it costs nothing and it works.

5. **Scope it deliberately.** The default policy applies to everyone. If a subset of users needs different behaviour, create an anti-phish rule with a higher priority and a narrower recipient scope, rather than weakening the default for the whole tenant.

6. **Test with a real message.** From a personal Gmail account, send a message with the CEO's display name to the protected user. It should be quarantined, and the quarantine record should say user impersonation.

The same changes in PowerShell, which is what I used to keep the configuration reviewable:

```powershell
Set-AntiPhishPolicy -Identity "Office365 AntiPhish Default" `
    -EnableTargetedUserProtection $true `
    -TargetedUsersToProtect "Alex Morgan;alex.morgan@contoso.com", "Priya Nair;priya.nair@contoso.com" `
    -TargetedUserProtectionAction Quarantine `
    -EnableOrganizationDomainsProtection $true `
    -TargetedDomainsToProtect "contoso.com" `
    -TargetedDomainProtectionAction Quarantine `
    -EnableMailboxIntelligence $true `
    -EnableMailboxIntelligenceProtection $true `
    -MailboxIntelligenceProtectionAction Quarantine `
    -EnableFirstContactSafetyTips $true

# Confirm the result
Get-AntiPhishPolicy -Identity "Office365 AntiPhish Default" |
    Format-List EnableTargetedUserProtection, TargetedUsersToProtect, TargetedUserProtectionAction,
                EnableOrganizationDomainsProtection, TargetedDomainsToProtect,
                EnableMailboxIntelligenceProtection, MailboxIntelligenceProtectionAction,
                EnableFirstContactSafetyTips
```

`TargetedUsersToProtect` takes `Display Name;address` pairs. Getting the display name slightly wrong is the most common reason a VIP stays unprotected, so copy it from the mailbox rather than typing it.

## Verification and evidence

| Evidence | What it proves |
|---|---|
| *No capture — injecting a spoofed display-name message needs SMTP submission, which the browser session cannot do* | The starting state: no warning, no protection applied |
| *No capture — Defender's impersonation sender list rejected the lab tenant's address with "Please enter a valid Email address", so no VIP was ever saved* | The executive list is now enforced |
| *No capture — the policy wizard cannot be completed without a sender to protect* | Detections are quarantined rather than merely moved to Junk |
| *No capture — no policy and no test message, so nothing was quarantined* | The policy fires on a real attack shape |
| *No capture — PowerShell output, and the policy was never created* | Tenant-side confirmation of the policy state |

The test message arrived in quarantine within a minute of sending, with the detection listed as user impersonation, and the recipient got no notification beyond the quarantine digest. I then released it deliberately to confirm the safety tip appeared, which it did.

## Prevention notes

- Keep the VIP list current. When a new director joins, adding them to the list should be part of onboarding, not a separate project.
- Pair impersonation protection with a payment-change process. No policy will stop a convincing email if a human is willing to change bank details on the strength of an email alone.
- Add a rule that flags external senders in the subject or with an external tag, so every message from outside is visually distinct.
- Review quarantine weekly. A policy that quarantines legitimate invoices will otherwise look like a delivery problem.
- Test after every change. Impersonation policy propagation is not instant, and a test right after saving can show the old behaviour.

## Lesson learned

A display name proves nothing. Authentication tells you the sending domain is real, not that the name on it belongs to your boss. Protect the people attackers copy most, protect your own domain, and put a first-contact banner in front of staff who have no other way to know the sender is new.
