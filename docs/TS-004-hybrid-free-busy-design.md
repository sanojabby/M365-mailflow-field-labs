# TS-004: Hybrid free/busy shows no calendar data (design exercise)

| | |
|---|---|
| **Level** | Expert |
| **Format** | Paper design. No on-premises Exchange server was available, so there are no lab screenshots here |
| **Applies to** | Exchange hybrid with Exchange Online, cross-premises calendar availability |
| **Audience** | Exchange admins and the service desk that takes the first call |

## Why this is a paper exercise

Free/busy in a hybrid tenant depends on an on-premises Exchange server, an OAuth trust and DNS that I did not have available for this repository. What follows is the path I trace on customer systems, written as a design document: the request flow, the checklist, a failure table that maps what the user sees to the first test, and the commands I run. There are no invented screenshots in this file. Anything marked as an expected output is an example of the shape of the answer, not a captured result.

## The scenario

An organisation has 400 mailboxes, 120 still on Exchange 2019 on-premises and the rest in Exchange Online. Users in the cloud cannot see on-premises colleagues' availability when they open the Scheduling Assistant. The on-premises side can see cloud users fine, which is the detail that makes this interesting: one direction works, so DNS and the basic mailbox configuration are probably not the whole story.

The user-facing message is the same in almost every case: the calendar shows a hatched "no information available" area, or a suggestion that the person is free all day. That message is generated on the client side, so it tells you nothing about which link in the chain broke.

## How a free/busy request travels

```
 Organizer's Outlook
        │  (1) availability request for a hybrid attendee
        ▼
 Exchange Online mailbox / EWS
        │  (2) looks up the organization relationship for the target domain
        ▼
 Organization relationship  ──── OAuth token ────▶  On-premises Exchange
 (FreeBusyAccessEnabled,                            (EWS / Availability service)
  FreeBusyAccessLevel)                                    │
        ▲                                                 │ (3) reads the
        │                                                 │     on-prem calendar
        └──────────── (4) free/busy response ◀────────────┘

 On-premises discovery for step 2 uses:
   autodiscover.contoso.com  →  on-premises Client Access
   OAuth metadata            →  https://autodiscover.contoso.com/autodiscover/metadata/json/1
```

Old-style (non-OAuth) hybrid setups use the federation trust and a sharing policy instead of the organization relationship. Both paths have the same property: every hop has to trust the one before it, and a single broken hop produces the same blank calendar.

The asymmetry in the scenario above points at the trust rather than at DNS. If cloud-to-on-prem were a pure DNS problem, on-prem-to-cloud would usually fail too, because both directions use the same Autodiscover publisher in most designs. A one-way failure more often means the on-premises side accepts the cloud token but the cloud side cannot get a valid one, or the organization relationship is scoped to the wrong domain.

## What to check, in order

| # | Check | Command or location | What "good" looks like |
|---|---|---|---|
| 1 | Organization relationship exists for the on-prem domain | `Get-OrganizationRelationship \| fl Name,DomainNames,Enabled,FreeBusyAccessEnabled,FreeBusyAccessLevel,TargetApplicationUri,TargetAutodiscoverEpr` | `FreeBusyAccessEnabled : True`, `FreeBusyAccessLevel : AvailabilityOnly` or `LimitedDetails`, correct domain |
| 2 | Intra-organization connector | `Get-IntraOrganizationConnector \| fl Name,Enabled,TargetAddresses,DiscoveryEndpoint` | Enabled, target addresses include the on-prem domain, discovery endpoint resolves |
| 3 | OAuth connectivity from cloud to on-prem | `Test-OAuthConnectivity -Service EWS -TargetUri https://mail.contoso.com/ews/exchange.asmx -Mailbox user@contoso.com -Verbose` | `Success` with a token issued for the right audience |
| 4 | Autodiscover record for the on-prem namespace | `Resolve-DnsName autodiscover.contoso.com` and, externally, the same query against a public resolver | Points at the on-prem Client Access service, internally and externally consistent |
| 5 | OAuth metadata endpoint reachable | `Invoke-WebRequest https://autodiscover.contoso.com/autodiscover/metadata/json/1` | HTTP 200 with a JSON metadata document |
| 6 | Firewall and published endpoints | Port 443 from Exchange Online to the on-prem EWS and Autodiscover endpoints | Reachable, valid certificate chain, no TLS interception |
| 7 | Certificate | `Get-ExchangeCertificate \| fl Subject,NotAfter,Services` | Valid, includes the Autodiscover and EWS names, not expired |
| 8 | Mailbox-side permissions | `Get-MailboxFolderPermission user:\Calendar` on-prem | `Default` has `AvailabilityOnly` or better |

### The commands

```powershell
# Run in Exchange Online PowerShell
Connect-ExchangeOnline -UserPrincipalName admin@contoso.onmicrosoft.com

Get-OrganizationRelationship | Format-List Name, DomainNames, Enabled, FreeBusyAccessEnabled, FreeBusyAccessLevel, TargetApplicationUri, TargetAutodiscoverEpr, MailTipsAccessEnabled

Get-IntraOrganizationConnector | Format-List Name, Enabled, TargetAddresses, DiscoveryEndpoint

Test-OAuthConnectivity -Service EWS `
    -TargetUri https://mail.contoso.com/ews/exchange.asmx `
    -Mailbox priya.nair@contoso.com -Verbose

# DNS from a machine that uses the same resolvers as the service
Resolve-DnsName autodiscover.contoso.com -Type CNAME
Resolve-DnsName autodiscover.contoso.com -Type A
Invoke-WebRequest https://autodiscover.contoso.com/autodiscover/metadata/json/1 -UseBasicParsing | Select-Object StatusCode
```

```powershell
# Run on-premises, in the Exchange Management Shell
Get-OrganizationRelationship | Format-List Name, DomainNames, FreeBusyAccessEnabled
Get-FederationTrust | Format-List Name, ApplicationUri, OrgCertificate
Get-ExchangeCertificate | Format-List Subject, NotAfter, Services, Thumbprint
Get-WebServicesVirtualDirectory | Format-List Name, InternalUrl, ExternalUrl, OAuthAuthentication
```

`Test-OAuthConnectivity` is the single most useful command in this whole document. If it succeeds, the trust is intact and you are looking at discovery or mailbox permissions. If it fails, read the error: an audience mismatch, a certificate problem and an unreachable endpoint each produce a different message, and each sends you to a different fix.

## What each failure looks like, and the first test

| User-visible symptom | What it usually means | First test |
|---|---|---|
| "No information available" for every on-prem attendee | Organization relationship disabled or missing for the domain | `Get-OrganizationRelationship` |
| Blank free/busy only for a few people | Calendar folder permissions, or the mailbox is on the wrong side of the move | `Get-MailboxFolderPermission` on the on-prem mailbox |
| Works internally, fails for external organizers | Autodiscover published incorrectly, or the metadata endpoint not reachable from outside | External DNS plus the metadata URL from outside the network |
| Works after a restart, fails again later | Token caching masking an expiring certificate or a flaky endpoint | Certificate expiry and `Test-OAuthConnectivity` repeated over time |
| Free/busy works, meeting requests do not | Mail flow is broken separately from availability | Message trace, not the availability path |
| Everyone appears free all day rather than hatched | Access level set to none, or the relationship returns an empty result | `FreeBusyAccessLevel` on the relationship |
| One direction works, the other does not | One side's trust or discovery is scoped wrong | Run the test from both directions |

The last row is worth repeating: free/busy is directional. Testing only the failing direction tells you where it stops, not which side is misconfigured. Run the check from each side and compare.

## Decision table

| Observation | Conclusion | Action |
|---|---|---|
| `Test-OAuthConnectivity` fails with an audience error | The on-prem side does not trust tokens for the Exchange Online audience | Re-run the Hybrid Configuration Wizard, or repair the `Test-OrganizationRelationship`/trust configuration |
| `Test-OAuthConnectivity` fails with a connection error | Endpoint unreachable from the service | Check publishing, firewall, and that the EWS virtual directory has OAuth enabled |
| OAuth succeeds, availability still blank | Discovery or permissions | Check the Autodiscover response and the calendar folder permission |
| Metadata URL returns 404 | Autodiscover virtual directory missing the metadata handler | Recreate or repair the Autodiscover virtual directory; re-run HCW |
| Certificate expired | Token requests fail at TLS | Renew and rebind, then retest both directions |
| Relationship correct, still failing | Intra-organization connector or stale DNS | Verify `Get-IntraOrganizationConnector`, flush DNS caches on both sides |
| Only new mailboxes affected | Mailbox moved but not yet reprovisioned on the target | Check the mailbox's `RecipientTypeDetails` on both sides and wait for sync |

## What I would put in the runbook

- Record the exact `TargetAutodiscoverEpr` and `TargetApplicationUri` values after each Hybrid Configuration Wizard run. When free/busy breaks months later, the difference between the recorded and current values is usually the whole story.
- Put the certificate expiry date in the calendar with a 60-day reminder. A surprising number of "free/busy stopped working" tickets land the week a certificate expires.
- Test both directions after every CU or cumulative update, not just the direction users complained about last time.
- Keep a known-good on-prem and a known-good cloud test mailbox. When availability breaks, a two-mailbox test tells you whether it is tenant-wide in under a minute.
- Do not "fix" this by turning off the organization relationship. That hides the symptom and breaks mail tips at the same time.

## Lesson learned

Free/busy is a chain of trust, not a single setting. The user sees one blank calendar, but the request crosses the cloud mailbox, the organization relationship, an OAuth token, on-premises Autodiscover, the Availability service and the target calendar's permissions. Test the chain end to end, in both directions, and fix the first link that fails rather than the one that is easiest to edit.
