# TS-003: Hybrid mail flow breaks after cutover (design exercise)

| | |
|---|---|
| **Level** | Expert |
| **Format** | Paper design. No on-premises Exchange server was available, so nothing here is a lab capture |
| **Applies to** | Exchange 2016/2019 hybrid with Exchange Online, mailbox migration in either direction |
| **Audience** | Whoever owns the cutover window and the person on call the morning after |

## Why this is a paper exercise

I have run this investigation on customer tenants, but I did not have an on-premises Exchange server to break for this repository. So this document is the design and the diagnostic order, not a walkthrough with screenshots. There are no fabricated captures here: the diagram, checklist and decision table are what I actually use, and the commands are the ones I run, but the "evidence" section is a list of what to collect rather than a set of images. If you build this lab for real, the same structure holds.

## The scenario

A mid-sized company runs Exchange 2019 on two servers and has been in hybrid mode for a year. Mailboxes are being moved to Exchange Online in batches. The MX record still points at the on-premises server, which relays to the cloud; the plan is to flip the MX at the end of the project. After batch three, three things start happening at once:

- one migrated user stops receiving external mail but can still send,
- an on-premises user gets an NDR mentioning the tenant's `mail.onmicrosoft.com` address,
- a distribution group that was converted to cloud-only during the batch stops delivering to two of its members.

Nobody changed the mailbox configuration. What changed was where the mailbox lives.

## Mail flow, before and after cutover

```
                            DNS: MX 10 mail.contoso.com
 Internet sender ─────────────────────────────┐
                                              v
                                   ┌──────────────────────┐
                                   │ On-premises Exchange │
                                   │  2019 (two servers)  │
                                   └──────────┬───────────┘
                                              │  Hybrid send connector
                        ┌─────────────────────┴────────────────────┐
                        │                                          │
             on-prem mailbox                            mail user for cloud mailbox
             (still on-prem)                            RemoteRoutingAddress =
                        ▲                                user@contoso.mail.onmicrosoft.com
                        │                                          │
                        │                                          v
                        │                            ┌───────────────────────────┐
                        └──── inbound connector ──── │ Exchange Online           │
                                 (TLS, certificate)  │ contoso.mail.onmicrosoft  │
                                                     └───────────────────────────┘
```

Two details in that picture cause most post-cutover incidents:

1. The on-premises object for a migrated mailbox is no longer a mailbox. It is a **mail user** whose `RemoteRoutingAddress` is the only thing telling on-premises where the mail should go. If that attribute is stale, mail is routed to an address that does not exist.
2. While MX points on-premises, every inbound message passes through the hybrid connectors and the certificate. A connector or TLS problem looks exactly like "external mail is broken" for cloud users, even though their mailboxes are healthy.

After the MX cutover the picture inverts: inbound mail goes straight to Exchange Online, and on-premises becomes the place that only receives mail for the mailboxes still there. Connectors still matter, but for outbound and for cross-premises routing rather than for all inbound traffic.

## What actually breaks, and how it looks

| Failure | What the user sees | What is really wrong |
|---|---|---|
| Stale `RemoteRoutingAddress` | External mail to a migrated user bounces with 5.1.10 or 5.4.4 | The on-premises mail user points at an old or misspelled tenant address |
| Connector misconfiguration | Mail queues on-premises, or NDRs mention "unable to relay" | Send/receive connector TLS name, certificate or smart host is wrong |
| Certificate expired | Intermittent TLS failures, often only on one server | The hybrid certificate expired or was replaced without updating the send connector |
| Accepted domain wrong | Internal mail loops back out, or NDR 5.1.1 for a valid user | Domain set to authoritative when it should be internal relay, or the reverse |
| DNS still pointing at the old target | Some senders fail, others work | MX or Autodiscover cache, or a split-horizon record |
| Distribution group membership | Group delivers to some members only | Group was converted to cloud-only but still has on-premises members, or the reverse |

## Verification checklist for every migrated mailbox

Run this after each batch, not only when something breaks. It takes a couple of minutes per batch and catches most of these before a user does.

| # | Check | Command or location | Expected |
|---|---|---|---|
| 1 | Routing address on the on-premises object | `Get-RemoteMailbox user@contoso.com \| fl RemoteRoutingAddress` | `user@contoso.mail.onmicrosoft.com`, matching the cloud mailbox's primary SMTP |
| 2 | Cloud mailbox exists and is enabled | `Get-Mailbox user@contoso.com \| fl Name,RecipientTypeDetails,PrimarySmtpAddress` | `UserMailbox`, correct primary address |
| 3 | Proxy addresses match | `Get-Mailbox user@contoso.com \| fl EmailAddresses` | The on-premises address is present as a proxy, not as a second primary |
| 4 | Hybrid configuration is intact | `Get-HybridConfiguration` | The expected domains and the current certificate thumbprint |
| 5 | Outbound connector | `Get-OutboundConnector \| fl Name,Enabled,SmartHosts,TlsSettings,RecipientDomains` | Enabled, expected smart host, TLS set |
| 6 | Inbound connector | `Get-InboundConnector \| fl Name,Enabled,SenderDomains,RequireTls` | Enabled, expected sender domains |
| 7 | Accepted domains | `Get-AcceptedDomain` | Contoso.com authoritative or internal relay as designed; tenant domain authoritative |
| 8 | Certificate | On-premises Exchange: `Get-ExchangeCertificate \| fl Thumbprint,NotAfter,Services` | Valid, not expiring, SMTP service assigned |
| 9 | End-to-end delivery | Message trace in both portals | Inbound arrives once, no queued copies |

### The commands, with the check they answer

```powershell
# On-premises Exchange Management Shell, or Exchange Online PowerShell for cloud objects
Get-HybridConfiguration | Format-List Name, Domains, ClientAccessServers, ReceivingTransportServers, SendingTransportServers, TlsCertificateName, OnPremisesSmartHost

Get-OutboundConnector | Format-List Name, Enabled, ConnectorType, RecipientDomains, SmartHosts, TlsSettings, TlsDomain
Get-InboundConnector  | Format-List Name, Enabled, ConnectorType, SenderDomains, RequireTls, RestrictDomainsToCertificate

Get-AcceptedDomain | Format-Table DomainName, DomainType, Default -AutoSize
Get-RemoteDomain    | Format-Table Name, DomainName, AllowedOOFType, AutoReplyEnabled -AutoSize

# The on-premises half of a migrated user
Get-RemoteMailbox -Identity user@contoso.com | Format-List DisplayName, RemoteRoutingAddress, EmailAddresses

# Cloud half
Get-Mailbox -Identity user@contoso.com | Format-List DisplayName, RecipientTypeDetails, PrimarySmtpAddress, EmailAddresses
```

`Get-HybridConfiguration` on its own is not proof that mail works. It reports what the Hybrid Configuration Wizard last wrote, and that can be months old. Treat it as a map, then confirm each line with the connector and trace checks.

## Troubleshooting order

The order below is deliberately boring: cheap checks first, and nothing that changes a setting until the failing leg is identified.

1. **Message trace in both places.** In Exchange Online, `Get-MessageTrace` for the sender or recipient. On-premises, the equivalent trace in the Exchange admin center (on-prem) or `Get-MessageTrackingLog`. Find the last hop where the message existed and the first where it did not. That boundary is the broken leg.
2. **Read the NDR properly.** 5.1.10 means the recipient does not exist at the target (classic stale routing address). 5.4.4 means no route was found. 5.7.x is usually TLS or policy. 5.1.1 with a hybrid address points at directory sync, not transport.
3. **Check the routing address** on the on-premises object for the affected user. This is the single most common post-cutover cause and it is a one-line fix.
4. **Check connectors and TLS**, both directions, including which certificate is bound to SMTP on the server that actually sends. In a two-server deployment, verify both.
5. **Check accepted domains and remote domains.** A domain that is authoritative in both places will cause mail to be rejected as unknown rather than relayed. A domain that is internal relay in the cloud when it should be authoritative can send mail in circles.
6. **Check DNS last**, MX and Autodiscover, including TTL and any cached negative answers. If the cutover happened in the last hour, wait out the TTL before concluding the record is wrong.
7. **Check directory sync** if the object exists in one place and not the other. A failed delta sync after a batch looks like a transport problem and is not.

## Decision table

| Symptom | First test | Likely cause | Fix |
|---|---|---|---|
| External mail to one migrated user bounces, internal mail fine | `Get-RemoteMailbox user \| fl RemoteRoutingAddress` | Stale or missing routing address | Set the correct `-RemoteRoutingAddress` and wait for sync |
| All external mail to cloud users fails, internal fine | Trace from an external test account; check inbound connector and certificate | Connector TLS or certificate | Renew or rebind the certificate, update the connector |
| Mail queues on-premises with "unable to relay" | `Get-OutboundConnector` and the queue viewer | Outbound connector disabled or smart host wrong | Correct the connector, restart transport |
| Migrated user can send but receives nothing from anywhere | Trace plus accepted domains | Cloud mailbox has the on-premises address as primary, or domain type wrong | Fix primary SMTP, set domain type correctly |
| Distribution group delivers to some members | Expand the group in both directories | Mixed on-prem and cloud membership after conversion | Recreate membership in the authoritative location |
| NDR mentions `mail.onmicrosoft.com` | Check the address in the NDR against `Get-RemoteMailbox` | Wrong tenant address, often a typo or an old tenant name | Correct the routing address |
| Autodiscover fails for on-prem users after MX change | `Resolve-DnsName autodiscover.contoso.com` | DNS record changed or split-horizon mismatch | Restore the record, flush cache |

## What I would put in the cutover runbook

- Lower the TTL on MX and Autodiscover to 300 seconds at least 24 hours before the window, and say so in the runbook with the timestamp.
- After each batch, run checks 1, 3 and 9 above and record the result per user in a table. One line per mailbox beats a verbal "looks good".
- Keep the old MX target available and configured for at least a week after the flip, with the connector still accepting mail from it.
- Write the rollback step before the cutover step. For MX, that means knowing the exact previous record, its TTL, and who can change it at 2 a.m.
- Never change connectors and the MX record in the same window. If something breaks, you will not know which change did it.

## Lesson learned

In hybrid, the mailbox is almost never the problem: the routing around it is. When a migrated user's mail disappears, the answer is usually one attribute (`RemoteRoutingAddress`) or one connector, and message trace in both environments finds it faster than any amount of staring at mailbox settings. Keep the checklist short enough that people actually run it after every batch, and treat the Hybrid Configuration Wizard output as a map rather than as evidence.
