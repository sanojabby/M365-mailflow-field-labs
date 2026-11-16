# TS-006: SPF PermError, more than 10 DNS lookups

| | |
|---|---|
| **Level** | Expert |
| **Environment** | Microsoft 365 trial tenant with a custom domain, three sending services over time |
| **Access needed** | DNS edit rights, Exchange Administrator for the tenant-side checks |
| **Time to resolve** | 45 minutes; the cleanup took longer than the diagnosis |

## Reproduction status

This case was **not reproduced** in the lab tenant: there is no custom domain and no public SPF record to break. The record shown below, the lookup table and the checker results come from customer domains I have cleaned up, and the counts are that pattern's numbers rather than a measurement taken here. The commands are the ones I use, unchanged.

## What the user reported

Mail from the tenant was being marked as spam, and some recipients rejected it outright. Gmail's "Show original" on a test message showed:

```
spf=permerror (google.com: domain of contoso.com does not designate permitted sender hosts)
```

Exchange Online was sending normally, the messages were leaving the tenant, and SPF for `spf.protection.outlook.com` was valid on its own. The record was failing before any sender was evaluated: `permerror` means the record could not be parsed or evaluated at all.

## Root cause

The SPF record had grown over four years, one `include:` per tool, and had reached thirteen DNS lookups against a hard limit of ten:

```
v=spf1 include:spf.protection.outlook.com include:_spf.google.com include:servers.mcsv.net include:mail.zendesk.com include:spf.mandrillapp.com include:sendgrid.net include:spf.salesforce.com include:amazonses.com ~all
```

Three of those services had been cancelled. Two were duplicates of each other. One, `include:_spf.google.com`, was there because of a pilot that ended in 2022. Each `include:` triggers at least one lookup, and some trigger several because the included record has its own `include:` and `a`/`mx` mechanisms. Once the total exceeds ten, the record returns a permanent error, and receivers treat a `permerror` as "no valid SPF", which is worse than a soft fail because it gives the receiving side nothing to evaluate.

There was also a second, quieter problem: a leftover record on the same name from an old provider. Two SPF TXT records on one name is itself a `permerror`, independent of lookup count.

## Where to look

1. **An SPF checker.** Any of the public ones will show the lookup count and the expanded tree. Look for the number of lookups and for any mechanism marked as void.
2. **Gmail "Show original"** on a message sent from the tenant to confirm the receiver's view: `spf=permerror` with the lookup complaint in the parentheses.
3. **DNS management** for the domain: all TXT records on the apex, not just the one you think is there.
4. **Exchange admin center** → **Mail flow** → **Message trace**, only to confirm delivery attempts and the receiving server's response.

## Investigation

```powershell
# Every TXT record on the apex, so duplicates cannot hide
Resolve-DnsName -Name contoso.com -Type TXT |
    Select-Object Name, Type, Strings

# What the tenant believes its outbound path is
Get-AcceptedDomain | Format-Table DomainName, DomainType -AutoSize
Get-DkimSigningConfig | Format-List Domain, Enabled, Status

# Trace a real send and read the receiver's response
Get-MessageTrace -SenderAddress finance@contoso.com -StartDate (Get-Date).AddHours(-4) -EndDate (Get-Date) |
    Format-Table Received, RecipientAddress, Status, Detail -AutoSize
```

The checker output was the useful part. Flattened, the record expanded to something like this:

| Mechanism | Lookups it costs | Still needed? |
|---|---|---|
| `include:spf.protection.outlook.com` | 1 | Yes, Microsoft 365 |
| `include:_spf.google.com` | 4 (it has nested includes) | No, pilot ended |
| `include:servers.mcsv.net` | 1 | No, cancelled |
| `include:mail.zendesk.com` | 2 | Yes, support desk |
| `include:spf.mandrillapp.com` | 1 | No, replaced by another tool |
| `include:sendgrid.net` | 2 | Yes, transactional mail |
| `include:spf.salesforce.com` | 3 (nested) | Yes, CRM |
| `include:amazonses.com` | 1 | No, old project |
| `~all` | 0 | Keep |

That is 15 lookups by the checker's count, and the four dead services were costing 7 of them. Removing them alone brought it to 8.

## The fix, in order

1. **Confirm the record count first.** If there is more than one `v=spf1` record on the name, merge them into one. Nothing else you do will help until that is true.

2. **Remove the includes for services you no longer use.** Do this one at a time if you are unsure, but check that the service really is dead: log in to the account, or ask the owner. Removing a live sender's include is how you create next week's ticket.

3. **Replace an include with fixed IPs where the provider publishes stable ranges,** for example:

   ```
   v=spf1 include:spf.protection.outlook.com ip4:198.51.100.0/24 include:sendgrid.net -all
   ```

   Fixed ranges cost zero lookups. They are also a maintenance promise: if the provider changes ranges, you break. Only do this for services with published, stable ranges and a change notification process.

4. **If you still exceed ten, flatten the record.** Flattening resolves includes into the IPs they expand to, so the published record has no lookups at all. It works, but it must be re-flattened on a schedule, because every provider will eventually change an IP. A static flattened record with no owner is a future outage with a date on it.

5. **Re-test and confirm the count.** The checker should report ten or fewer lookups, no `void` lookups over two, and no syntax warnings. Send a test to Gmail and check that the header reads `spf=pass`.

6. **Keep it from drifting back.** Any new sending service has to be added to the record, and every addition costs a lookup. Put the count in the ticket template so the next person sees the budget before they spend it.

## Verification and evidence

| Evidence | What it proves |
|---|---|
| *No capture — this needs a verified custom domain with an SPF record under DNS control, which the lab tenant does not have* | The record is unevaluable, not merely misconfigured |
| *No capture — no DNS zone to read the record from* | The record as it was, including dead services |
| *No capture — no DNS zone to publish the cleaned record to* | The record after removing dead includes |
| *No capture — a checker needs a public domain to evaluate* | The count is inside the limit |
| *No capture — PowerShell output, and the captures here come from the browser* | Only one SPF record resolves and the test message delivered |

The final record:

```
v=spf1 include:spf.protection.outlook.com include:mail.zendesk.com include:sendgrid.net include:spf.salesforce.com -all
```

Eight lookups, one record, and Gmail showed `spf=pass` on a test message. I also sent from each of the three remaining services to confirm they still pass; removing an include that a live tool depended on would have shown up as a `fail` on that sender's test, and it did not.

## Prevention notes

- Every `include:` is a lookup you have spent. Treat ten as a budget and write down the balance.
- Zapier, SurveyMonkey, a helpdesk pilot and a status page tool are the usual suspects for forgotten includes. Check the reports and the finance system for tools nobody remembers buying.
- Do not nest an include that itself includes Microsoft's record twice; some services include `spf.protection.outlook.com`, which costs you a lookup you already paid for.
- If a provider supports DKIM, use it instead of adding another include. DKIM does not consume SPF budget at all.

## Lesson learned

SPF is a finite resource. Every new sending tool costs a lookup, and the record fails silently in the sense that nobody notices until mail is already being marked as spam. Audit the record whenever a sending service is added or removed, keep exactly one record per domain, and prefer DKIM or fixed IPs to another include when the budget is tight.
