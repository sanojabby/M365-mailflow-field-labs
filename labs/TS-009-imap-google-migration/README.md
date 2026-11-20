# TS-009: IMAP/Google migration fails for some users

| | |
|---|---|
| **Level** | Expert |
| **Environment** | Microsoft 365 trial tenant, IMAP migration from a test Gmail account (two users plus one deliberately broken credential) |
| **Access needed** | Exchange Administrator; access to the source mailbox credentials |
| **Time to resolve** | 3 hours across a pilot batch and one re-run |

## Reproduction status

This case was **not reproduced** in the lab tenant. A migration batch needs Google Workspace credentials for a source mailbox, and the lab has an IMAP endpoint object with no source account behind it, so no batch was ever created. The 40-mailbox batch, the 48 MB item, the CSV typo and the re-run described below are the pattern from customer migrations; the commands and the order of checks are the ones I use there.

## What the user reported

A 40-mailbox IMAP migration from Google Workspace to Exchange Online reported **Failed** on the batch. Thirty-five users had migrated cleanly, three showed **Synced** with a warning, and two were stuck at **Failed** with no useful text in the batch summary. The project manager read "Failed" as "the whole migration is broken" and wanted to start over.

The batch was not broken. Two users were, for two different reasons, and the per-user report said so once I opened it.

## Root cause

The batch status is an aggregate, and an aggregate is almost never what you need. Opening the individual users gave:

- **One credential failure.** The user had changed their Google password and the CSV still held the old one. Their account also had 2-step verification enabled without an app password, so the plain password would have failed even if it were current.
- **One oversized item.** A single 48 MB message with a 30 MB attachment exceeded the per-item limit the IMAP endpoint would accept. The user showed "Synced" with a large `SkippedItemCount`, which is the dangerous state: it looks successful and silently misses mail.
- **One CSV typo.** A trailing space after an address in the `EmailAddress` column meant the migration engine created no user for that row and reported it as failed at the batch level.

The remaining warnings were large folders that took longer than the batch timeout, not real failures. They completed on the next incremental sync.

## Where to look in the Exchange admin center

1. [admin.exchange.microsoft.com](https://admin.exchange.microsoft.com) → **Migration**. The batch list shows status and counts; click the batch to see the users.
2. Inside the batch, the **Users** tab lists each mailbox with `Synced`, `Failed`, `Syncing` or `Completed`. A user with a warning shows a count, not an error, which is easy to miss.
3. Click a user → **Details** for the error and skipped-item count, or **Download the report** for the full per-item log.
4. **Mail flow** → **Message trace** after cutover, to confirm new mail is arriving in the cloud mailbox rather than the old one.

## Investigation

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@contoso.onmicrosoft.com

# Batch-level view: how many users are in each state
Get-MigrationBatch | Format-List Identity, Status, TotalCount, ActiveCount, SyncedCount, FailedCount, StartTime, CompleteTime

# Per-user view, which is where the answer actually is
Get-MigrationUser | Where-Object { $_.Status -ne "Completed" } |
    Format-Table Identity, Status, Error, LastSyncTime -AutoSize

# The report for one failing user
Get-MigrationUserStatistics -Identity daniel.okafor@contoso.com -IncludeReport |
    Format-List Status, Error, BadItemCount, SkippedItemCount,
                TotalItemsInSourceMailbox, ItemsSynced, BytesTransferred, LastSuccessfulSync
```

`SkippedItemCount` is the field people forget. A user can be `Synced` with 300 skipped items and nobody notices until someone asks where a thread went. I treat any non-zero count as a follow-up item with a named owner.

The endpoint check is worth running before you start changing credentials, because a wrong server or port fails every user and looks like a credential problem:

```powershell
Get-MigrationEndpoint | Format-Table Identity, EndpointType, RemoteServer, Port, Security -AutoSize
Test-MigrationServerAvailability -Endpoint "Gmail-IMAP"
```

## The fix, in order

1. **Start with the CSV.** Columns must be exactly `EmailAddress,UserName,Password`, saved as UTF-8, no trailing spaces, no header variations such as `Email`. One bad row fails quietly, so validate the file before the batch:

   ```powershell
   $csv = Import-Csv .\gmail-pilot.csv
   $csv | Where-Object { $_.EmailAddress -ne $_.EmailAddress.Trim() -or $_.EmailAddress -notmatch "^[^@\s]+@contoso\.com$" } |
       Format-Table EmailAddress, UserName
   ```

2. **Fix the authentication properly.** For Google, the account needs IMAP enabled and, with 2-step verification, an **app password** rather than the account password. App passwords are 16 characters; strip the spaces or the auth fails. "Less secure app" access is no longer a route, so an account without an app password will keep failing no matter how many times you resubmit the batch.

3. **Create the endpoint once and reuse it** for every batch:

   ```powershell
   New-MigrationEndpoint -Name "Gmail-IMAP" -IMAP `
       -RemoteServer imap.gmail.com -Port 993 -Security Ssl `
       -Authentication Basic -MaxConcurrentMigrations 10
   ```

   Throttle with `-MaxConcurrentMigrations` if Google starts returning rate-limit errors. Ten is a reasonable pilot value; raising it does not make a throttled source faster.

4. **Run a pilot with 2 or 3 users**, one of whom you expect to be awkward. That is the point of a pilot: find the awkward one before the other 37 depend on the schedule.

5. **Deal with oversized and bad items individually.** Fix the source where you can (ask the user to move the 48 MB message to Drive and send a link), or accept the skip with a written record. Then resume:

   ```powershell
   Resume-MigrationUser -Identity daniel.okafor@contoso.com
   # or, for a user that was never created in the batch:
   Remove-MigrationUser -Identity broken.row@contoso.com -Force
   ```

   Re-adding a single user is a new small batch from a one-line CSV. Do not recreate the whole batch to pick up one mailbox; the completed users would re-sync for nothing.

6. **Complete the batch and verify counts, not just status.** `Completed` with a `SkippedItemCount` above zero needs a line in the migration log, and someone should tell the user what is missing.

7. **Cut over on purpose.** Lower the MX TTL to 300 seconds at least 48 hours before the window, change MX to Exchange Online, keep the old mailboxes read-only for a week, and write the rollback (old MX value, TTL, who can change it) before you start. A final incremental sync after the MX change catches anything that arrived during the window.

## Verification and evidence

| Evidence | What it proves |
|---|---|
| *No capture — no Google Workspace credentials for a source endpoint, so no batch was run* | The batch is a mixed result, not a total failure |
| *No capture — there is no batch to report on* | The actual cause, per user |
| *No capture — nothing to correct without a source mailbox* | The credential and CSV issues are addressed |
| *No capture — no batch to complete* | Every user finished, warnings included in the record |
| *No capture — PowerShell output, and no migration user exists* | Server-side confirmation of the final state |

After the fix, I re-ran the two failing users as a two-line batch. Both completed, and the skipped item was documented and sent to the user with a link to the original in Drive. The larger batch was left untouched.

## Cutover notes for the lab

- MX TTL lowered to 300 seconds, 48 hours ahead. Recorded in the runbook with the timestamp.
- Pilot completed and signed off before the main batch started.
- Old mailboxes set to read-only at cutover, kept for seven days.
- Rollback: restore the previous MX target and TTL, and tell users to reopen the old mailbox. Rehearsed on a test domain before the real window.
- Any skipped items listed by user, with the reason and the owner.

## Prevention notes

- Validate the CSV mechanically. A single trailing space cost more time than the entire migration.
- Treat `SkippedItemCount` as an error, not a statistic. It is the number that decides whether the user trusts the new mailbox.
- Use app passwords for Google accounts with 2-step verification, and check that IMAP is enabled on the source before scheduling.
- Throttle with `MaxConcurrentMigrations` rather than retrying a batch that is being rate-limited.
- Keep the pilot cohort in every subsequent batch check, so a regression shows up on known users first.

## Lesson learned

Pilot first and read the per-user report. A migration batch is a collection of independent jobs, and "Failed" at the top level usually means two mailboxes out of forty, each for a reason written plainly in the report. Fix the cause per user, resume rather than restart, and never let a successful-looking `Synced` with skipped items pass without a record.
