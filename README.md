# Microsoft 365 & Exchange Online Troubleshooting Labs

Ten cases, written the way I work them: what the user reported, what I found underneath, the admin center path I walked, the PowerShell I ran, and the evidence that the fix held. Each one is self-contained, so you can jump straight to the case that matches your problem.

They are not all the same kind of case, and the difference matters when you read the evidence tables.

**Four were built and checked hands-on** in a trial tenant: the forwarding rule and its alert in TS-001, the two-way forward and its message trace in TS-002, the litigation hold and archive in TS-008, and the two transport rules fighting over priority in TS-010. In each of those a setting exists in a tenant I can open and point at, and the capture or the trace is from that tenant.

**Four are written from the investigation pattern rather than a reproduction** — TS-005, TS-006, TS-007 and TS-009. Each needs something the trial tenant did not have: a custom domain with DNS control for the DMARC and SPF work, a spoofed sender and a policy Defender would accept for the impersonation case, and a Google Workspace source mailbox for the migration. The commands, the order of checks and the reasoning are the ones I use; the capture slots are empty, with the specific reason written beside each one rather than a picture borrowed from somewhere else.

**The last two, hybrid mail flow and hybrid free/busy, are design exercises**: I had no on-premises Exchange server to break, so they are the investigation I run on customer environments, with the diagrams, checklists and decision tables I keep in my notes.

I would rather label each case for what it is than let ten write-ups imply ten identical lab runs.

## Cases at a glance

| # | Case | What actually breaks | Setup |
|---|---|---|---|
| TS-001 | Compromised mailbox | Hidden inbox rule forwards mail to an outside address | Lab |
| TS-002 | Forwarding pair | Two mailboxes forward to each other; copies multiply but the hop limit never trips | Lab |
| TS-003 | Hybrid mail flow after cutover | Wrong routing address or connector, mail lands nowhere | Paper design |
| TS-004 | Hybrid free/busy | Broken trust chain, calendars show "no information available" | Paper design |
| TS-005 | DMARC reject | A legitimate third-party sender fails alignment | Written, no reproduction |
| TS-006 | SPF PermError | More than 10 DNS lookups in one SPF record | Written, no reproduction |
| TS-007 | CEO impersonation | Display-name spoof lands in the inbox | Written, no reproduction |
| TS-008 | Recoverable Items quota | A hold fills the dumpster while the mailbox looks nearly empty | Lab, configuration only |
| TS-009 | IMAP migration | Per-user migration failures in a Google batch | Written, no reproduction |
| TS-010 | Missing disclaimer | Mail flow rule priority conflict | Lab |

---

### TS-001: Compromised mailbox, hidden rule forwards mail outside

A thief gets a copy of your house key, then quietly asks the post office to send a photocopy of every letter to his address. You change nothing at home, and the lock still works, yet your private mail leaks every day. That is how a mailbox compromise usually looks from the inside. The attacker signs in with a phished password, creates an inbox rule that forwards or redirects mail to an address they control, and often adds "move to RSS Feeds" or "move to Archive" so the copies never appear where the user would notice them. The rule lives on the mailbox rather than in the session, so a password reset alone leaves the leak running.

**Where it shows up in Microsoft 365**

*No capture yet — the rule lives on a lab user's mailbox and signing in as that user is blocked by the tenant's MFA requirement.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-001-compromised-mailbox/README.md)**

---

### TS-002: Two mailboxes forwarding to each other

Two colleagues each set their phone to forward calls to the other, and both phones then ring for the same call. Email behaves the same way, with one important difference: Exchange notices the repeat and stops it. Mailbox A forwards to B, B forwards back to A, and the second copy is discarded as a duplicate rather than circling until the hop limit trips. What the team gets is a message stored twice and a setting nobody owns, not the `5.4.14` bounce everyone assumed. Telling those two outcomes apart is a matter of counting rows in the message trace instead of reading the configuration.

**Where it shows up in Microsoft 365**

*No capture yet — the forwarding trace goes in with the case.*

Four rows for two messages: the addressee and the forward, both delivered, with no repeat cycle and no bounce.

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-002-forwarding-pair-duplicate-copies/README.md)**

---

### TS-003: Hybrid mail flow breaks after cutover

A company moves offices but keeps two reception desks. After the move, packages go to the old desk, the new desk, or nowhere at all, because nobody agreed on which address is the correct one. In hybrid Exchange the same split exists: the mailbox has moved to Exchange Online, but on-premises still holds a mail user with a target address that no longer resolves, or the MX still points at the server while the connectors, certificate and accepted domains disagree about who is authoritative. The mailbox is fine. The routing around it is not.

**Where it shows up in Microsoft 365**

```
 Internet sender
       |
       v
 MX 10 mail.contoso.com  ──▶  On-premises Exchange 2019
                                   |
                    ┌──────────────┴───────────────┐
                    │                              │
             on-prem mailbox                 mail user (hybrid)
             stays on-prem                  RemoteRoutingAddress
                                                    │
                                                    ▼
                              Exchange Online  (contoso.mail.onmicrosoft.com)
```

👉 **[View the Hybrid Mail Flow Design, Checklist & Lesson Learned](./docs/TS-003-hybrid-mail-flow-design.md)**

---

### TS-004: Hybrid free/busy shows no calendar data

Two offices share one wall calendar, but one office's window is frosted, so nobody can see when the other side is busy. In a hybrid tenant the frost comes from a broken trust path: Outlook asks Exchange Online for availability, Exchange Online asks on-premises through the organization relationship, and if the OAuth trust, the Autodiscover record or a firewall rule is wrong, the answer never comes back. The user sees a blank calendar with "no information available" and assumes the other person is simply free.

**Where it shows up in Microsoft 365**

```
 Outlook  ──▶  Exchange Online  ──▶  Organization Relationship  ──▶  On-premises EWS
 (organizer)   free/busy proxy        OAuth / federation trust        Availability service
                (cloud mailbox)                                              │
                                                                             │
                     ◀──────────── free/busy response ───────────────────────┘
```

👉 **[View the Free/Busy Trust Map, Checklist & Lesson Learned](./docs/TS-004-hybrid-free-busy-design.md)**

---

### TS-005: DMARC reject blocks a legitimate third-party sender

You tell the bank to accept only cheques carrying your signature. Your accountant then writes cheques on your behalf without that signature, so the bank rejects them even though you asked for them. Moving a domain to `p=reject` works the same way: an invoicing or marketing service that sends "as" your domain but fails SPF and DKIM alignment gets refused at the door, and the bounce lands in a shared mailbox nobody watches. The reports were telling me which sender it was; I just had to read them.

**Where it shows up in Microsoft 365**

*No capture yet — this case needs a verified custom domain with DNS control, which the lab tenant does not have.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-005-dmarc-reject-third-party/README.md)**

---

### TS-006: SPF PermError, more than 10 DNS lookups

A bouncer is handed a guest list that says "also check list B", and list B says "also check list C". After ten lists he gives up and turns everyone away. SPF has the same ceiling: ten DNS lookups per record. Stack enough `include:` entries from old tools and the record returns a PermError, which receivers treat as no valid SPF at all. The mail isn't blocked because the record is wrong about a sender; it's blocked because the record cannot be evaluated in time.

**Where it shows up in Microsoft 365**

*No capture yet — an SPF failure needs a custom domain and a public record to break; the lab tenant has neither.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-006-spf-permerror-10-lookups/README.md)**

---

### TS-007: Fake "CEO" email lands in the inbox

A stranger puts on a suit, clips on a name tag that reads "Director", and walks through the office. Staff do what he asks because he looks the part. Email has exactly this weakness: the display name is free text, so an attacker can write the CEO's name on a free mailbox or a lookalike domain and reach staff who never check the address behind it. If impersonation protection has never been configured, nothing in the tenant is looking at that name at all.

**Where it shows up in Microsoft 365**

*No capture yet — Defender's impersonation sender list rejected the lab tenant's address, so no protected user could be saved.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-007-ceo-impersonation-phishing/README.md)**

---

### TS-008: Litigation hold, Recoverable Items and the quota nobody watches

A company keeps every deleted piece of paper in a locked room for the lawyers, and nobody writes down how full the room is getting. Litigation hold does this to a mailbox: deletions are preserved in Recoverable Items instead of purged, against a quota that no page of the admin center displays. Fill it and the user cannot delete while the mailbox itself looks nearly empty, and the obvious fix — removing the hold — destroys the evidence it exists to keep. This tenant has the healthy half built, hold on and archive enabled with the quota readable only from `Get-Mailbox`, and the case says plainly that the overflow itself was never reproduced.

**Where it shows up in Microsoft 365**

*No capture yet — the hold panel goes in with the case.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-008-recoverable-items-litigation-hold/README.md)**

---

### TS-009: IMAP/Google migration fails for some users

Moving house with thirty boxes: most arrive fine, two are too heavy for the truck, and one has somebody else's label on it. A migration batch fails the same way, per user rather than as a whole. One account has an old app password, another has a 40 GB item the IMAP endpoint refuses, a third has the wrong username in the CSV, and the batch reports "failed" in a way that makes it look like the project is broken. The per-user report says exactly which box is too heavy.

**Where it shows up in Microsoft 365**

*No capture yet — a migration batch needs Google Workspace credentials for the source endpoint, which the lab does not have.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-009-imap-google-migration/README.md)**

---

### TS-010: Disclaimer missing, mail flow rule order conflict

A security guard follows a list of rules from the top down. Rule 1 says "let VIPs through and stop checking", so nobody ever reaches rule 5, "hand out the visitor badge". Transport rules run by priority in exactly that way: an earlier rule carrying "stop processing more rules", or a broad exception, quietly prevents the disclaimer rule from ever executing. The disclaimer rule itself is correct, which is why people keep editing it and getting nowhere.

**Where it shows up in Microsoft 365**

*No capture yet — the rule list goes in with the case.*

👉 **[View Step-by-Step Fix, PowerShell Commands & Lesson Learned](./labs/TS-010-disclaimer-rule-conflict/README.md)**

---

## Repository layout

```
m365-exchange-troubleshooting-labs/
├── README.md                 this page: the ten cases and where to start
├── scripts/
│   └── New-LabTenant.ps1     builds the lab objects, prints a read-only plan by default
├── docs/
│   ├── TS-003-hybrid-mail-flow-design.md
│   └── TS-004-hybrid-free-busy-design.md
└── labs/
    ├── TS-001-compromised-mailbox/
    │   ├── README.md
    │   └── screenshots/
    ├── TS-002-forwarding-pair-duplicate-copies/
    ├── TS-005-dmarc-reject-third-party/
    ├── TS-006-spf-permerror-10-lookups/
    ├── TS-007-ceo-impersonation-phishing/
    ├── TS-008-recoverable-items-litigation-hold/
    ├── TS-009-imap-google-migration/
    └── TS-010-disclaimer-rule-conflict/
```

Each lab folder holds the full write-up: root cause, the admin center path, the commands, the fix in order, the verification, and the lesson. Screenshots are referenced by filename from `screenshots/`; drop the capture in with that exact name and it renders here and in the case doc. Captures are from the trial tenant, and the case text uses shortened `contoso.com` addresses; where a capture shows the tenant's own domain, that is the admin account the screenshots were taken from.

## Before you run any of this

The lab cases — TS-001, TS-002, TS-008 and TS-010 — were run with an Exchange Administrator account on that test tenant, with Global Administrator only where the case says so. The four walkthroughs (TS-005, TS-006, TS-007, TS-009) describe commands and checks I have run in customer tenants, not in this one, which is why they carry no captures. All of them assume a connected PowerShell session and a mailbox you can afford to break.

Two rules I follow in every environment, including these labs: never test a destructive change on a mailbox that holds something you cannot restore, and never remove a legal hold without written approval from whoever owns the matter.
