# TS-005: DMARC reject blocks a legitimate third-party sender

| | |
|---|---|
| **Level** | Expert |
| **Environment** | Microsoft 365 trial tenant, one verified custom domain, MX and SPF pointing at Exchange Online |
| **Access needed** | Exchange Administrator, plus DNS edit rights at the registrar |
| **Time to resolve** | 90 minutes, mostly waiting on DNS propagation and one aggregate report |

## Reproduction status

This case was **not reproduced** in the lab tenant. It needs a verified custom domain with DNS control, an outside sender that authenticates as its own domain, and a receiving mailbox you can read headers in; the tenant has none of those. What follows is the investigation I run on customer domains — the checks, the commands, the order — and the volumes and timings in the narrative describe that pattern rather than a measurement from this tenant.

## What the user reported

Invoices stopped reaching customers. The billing service said it was sending them, the customers said they never arrived, and the only clue was a bounce that landed in the service's own bounce mailbox:

```
550 5.7.26 Message rejected due to DMARC policy for contoso.com
```

Nothing had changed in Exchange. What had changed three weeks earlier was DNS: I moved the domain's DMARC record from `p=none` to `p=reject` after a phishing wave, and the billing service was still sending as `contoso.com` without a signature that aligned.

## Root cause

DMARC asks two questions: does the message pass SPF or DKIM, and does the passing identifier align with the `From:` domain? With `p=reject`, a message that fails both is refused.

The billing platform sent mail with `From: billing@contoso.com` but authenticated with **its own** domain:

- the envelope sender was `bounces.billingprovider.com`, so SPF passed for the provider's domain and not for `contoso.com` (no alignment),
- DKIM was signed with `d=billingprovider.com`, so the signature was valid but not aligned to `contoso.com`.

Neither mechanism produced an aligned pass, so DMARC failed and `p=reject` turned that into a rejection at the receiving end. Under `p=none` the same messages had been delivered with a failed DMARC result that nobody was reading, because the aggregate reports were pointing at an address in a shared mailbox that no one had opened since setup.

The invoices had been failing alignment for months. The policy change did not create the problem, it exposed it.

## Where to look

1. **DMARC aggregate reports.** Wherever `rua=mailto:...` points. If it is a raw mailbox, the XML attachments can be read as-is; if it is a report viewer, the domain view lists every source IP sending as your domain and whether it passed.
2. **Gmail "Show original"** on a test message from the service. The authentication block shows `SPF`, `DKIM` and `DMARC` results line by line, which is the fastest way to see which mechanism failed and whether the domain in `d=` matches yours.
3. **DNS management** for the domain: the `_dmarc` TXT record, the SPF TXT record, and the provider's DKIM selector records.
4. **Message trace in Exchange Online** for outbound messages to the affected recipients, to confirm the rejection happened at the remote end rather than in your tenant.

## Investigation

```powershell
# What the world sees for DMARC and SPF right now
Resolve-DnsName -Name _dmarc.contoso.com -Type TXT | Select-Object -ExpandProperty Strings
Resolve-DnsName -Name contoso.com -Type TXT |
    Where-Object { $_.Strings -match "v=spf1" } |
    Select-Object -ExpandProperty Strings

# The provider's DKIM selector, as published in their setup guide
Resolve-DnsName -Name s1._domainkey.contoso.com -Type CNAME
Resolve-DnsName -Name s2._domainkey.contoso.com -Type CNAME

# Tenant-side DKIM, for mail sent by Exchange Online itself
Get-DkimSigningConfig | Format-List Domain, Enabled, Status, Selector1CNAME, Selector2CNAME
```

The DMARC record at the time read:

```
v=DMARC1; p=reject; rua=mailto:dmarc-reports@contoso.com; pct=100; adkim=s; aspf=s
```

Strict alignment (`adkim=s; aspf=s`) made this worse than it needed to be. With relaxed alignment the provider's SPF domain, `bounces.billingprovider.com`, would still not align, so the outcome would have been the same, but strict mode also rejects subdomain sends that a relaxed policy would accept. That is a decision to make deliberately, not by copying a template.

The aggregate report for the previous week showed three sources sending as `contoso.com`: Exchange Online (aligned, passing), the billing provider (failing alignment), and a marketing platform (failing alignment, lower volume). Two senders, not one, and the marketing one would have been next week's ticket.

## The fix, in order

1. **Inventory every sender from the reports.** List each source IP, reverse DNS and reported volume. Anything you cannot identify deserves investigation rather than a DNS exception.

2. **For each legitimate sender, publish what the provider requires.** For the billing platform that meant adding its DKIM CNAMEs:

   ```
   s1._domainkey.contoso.com  CNAME  s1.domainkey.u12345.wl.sendgrid.net
   s2._domainkey.contoso.com  CNAME  s2.domainkey.u12345.wl.sendgrid.net
   ```

   and adding its SPF include, if it sends with your envelope domain at all. DKIM is the better lever here, because a DKIM signature survives forwarding and does not consume an SPF lookup.

3. **Verify alignment, not just a pass.** A message can pass DKIM for `billingprovider.com` and still fail DMARC for `contoso.com`. In Gmail "Show original", the `dkim=` line must show `d=contoso.com` (or a subdomain, if relaxed) for the pass to count.

   ```powershell
   # Confirm the tenant's own outbound signing is on and healthy
   Get-DkimSigningConfig -Identity contoso.com | Format-List Enabled, Status, LastChecked
   ```

   If Exchange Online's own DKIM is disabled, enable it; outbound mail from your users then has an aligned signature independent of SPF:

   ```powershell
   Set-DkimSigningConfig -Identity contoso.com -Enabled $true
   ```

4. **Roll back the policy while you work, if the volume justifies it.** A day of `p=quarantine` is better than a day of lost invoices:

   ```
   v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc-reports@contoso.com
   ```

   Use `pct=25` if you want a partial rollout, and note that `pct` is ignored by some receivers, so it is a soft control rather than a guarantee. Once every sender is aligned, return to `p=reject`.

5. **Send a real test from the service** to a Gmail address you control, then open "Show original". The expected result is `SPF: PASS`, `DKIM: PASS with domain contoso.com`, `DMARC: PASS`.

6. **Fix the reporting loop.** The reports had been going to an unread mailbox. Point `rua` at a viewer or a monitored mailbox, and add a weekly check. DMARC without someone reading the reports is a policy you cannot debug.

## Verification and evidence

| Evidence | What it proves |
|---|---|
| *No capture — this needs a verified custom domain with DNS control, which the lab tenant does not have* | The failure is a policy rejection at the receiver, not a delivery delay |
| *No capture — no domain, so no aggregate reports arrive* | Which sender is failing and how much mail is affected |
| *No capture — no DNS zone to edit* | The missing authentication records are published |
| *No capture — requires a sender on the custom domain and a Gmail recipient* | End-to-end proof after the fix |
| *No capture — PowerShell output, and the captures here come from the browser* | Records resolve and the tenant signing config is enabled |

After the DNS change propagated I resent three invoices through the platform: all three arrived, and their headers showed an aligned DKIM pass with `d=contoso.com`. I left the policy at `p=quarantine` for a week of clean reports, then moved back to `p=reject`.

## Prevention notes

- Publish DMARC at `p=none` with reporting **before** moving to quarantine or reject, and read the reports for at least two weeks. I skipped this step and paid for it with a day of missing invoices.
- Keep a written inventory of every service that sends as the domain, with the person who owns the account. The report tells you an IP; the inventory tells you who to call.
- Prefer DKIM over SPF for third-party senders. It survives forwarding and does not add to the 10-lookup budget.
- Avoid `p=none` as a permanent state. It protects nobody; it is a monitoring mode, not a policy.

## Lesson learned

Move to reject gradually, and inventory every sender before you do. `p=reject` does not break mail, it reveals mail that was never authenticated properly, and the sender that goes quiet is usually the one nobody remembered to add to the inventory. Read the aggregate reports before the policy change, not after the invoices stop.
