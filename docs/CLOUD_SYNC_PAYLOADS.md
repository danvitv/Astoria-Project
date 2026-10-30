# Cloud sync payload transport

Large reconciliation journals use transport pages, not a new repository schema.
Runs, effects, lorebook evidence, collector boundaries and writer claims retain
their exact data/hashes. Manifest fingerprints remain those of the virtual
uncompressed schema-2 JSON, encoded incrementally in the original key/row order.

## File and memory budgets

- Every ordinary JSON file retains the **30 MiB UTF-8** physical-file limit.
- Reconciliation journals below 512 KiB retain their plain JSON wire format.
- Larger journals use `__syncPayload` version 2 / `gzip+base64-pages`.
  Each independently compressed page decodes to at most **512 KiB**; its base64
  cloud file is below **1 MiB**. A record may span multiple physical pages.
- The root index is limited to **8 MiB**, with explicit section counts and
  ordered page hashes/sizes. Page names are derived only from validated SHA-256
  values under `<entry.path>.pages/<sha256>.b64`, never supplied cloud paths.
- Temporary staging has a separate **8 GiB** disk budget, at most 32,768 pages
  and 500,000 records. This never relaxes any physical-file limit.
- A single domain record has a **32 MiB** decoded budget; normalization metadata
  is bounded to **64 MiB**, with at most 10,000 rows per metadata section.
  Local preflight includes failed/claimed collector rows consumed by bulk reads,
  even though those rows are not exported. Memory is proportional to one page,
  one supported record, and bounded run metadata—not the whole provenance log.

The aim is reconciliation provenance for long chats (including 10k-message
histories), not a guarantee of unrestricted message/record size. Individual
effect validation still parses its full before/after snapshots. Chat rendering,
generation and ordinary chat transport retain their existing representations
and limits; those are not made universally 10k-capable by journal paging.

## Export and import

The production store exposes a replayable section source. Fingerprinting and
export read bounded DB pages, preserving current filters, normalizations and
ordering. A consistent DB snapshot is held only while fingerprinting or writing
private local staging, never during cloud requests. An export whose fingerprint
changed since manifest building cannot publish under the older manifest hash.

NDJSON section streams are divided into independent gzip pages. Existing
content-addressed pages are reused, so unchanged immutable history is not
re-uploaded on every sync. All pages are uploaded before the small root index;
the overall sync manifest follows successful tasks as before.

On pull, the reader validates all descriptors before any page request, downloads
and decompresses one bounded page at a time to private temporary files, then
checks section counts and the complete virtual JSON fingerprint. Only then may
the store begin a **single transaction** replaying the complete staged source.
Normalization/divergence, acceptance ordering, invalidation resets and collector
validation remain global decisions, never independent per-page imports.
The final merged state is checked against the same record/count/byte budgets
inside that transaction. Abort/reset ownership is checked through transfer and
before transaction completion; retries cannot adopt a later sync generation.

A missing/corrupt page cannot partially apply domain history. Failed page uploads
leave an old root readable. This is safety for one journal, **not** a transaction
spanning every file in the entire sync; other successful uploads can remain after
a different task fails. Temporary artifacts are disposed on success and error.

Old pages are retained during ordinary pushes because concurrent readers may
hold older indexes. An owning reconciliation tombstone or full cloud wipe removes
its pages. Safe garbage collection of superseded versions is not implemented.

## Compatibility and deployment

Updated readers accept existing plain JSON and the new staged page encoding.
The bounded-map transport also accepts version-1 gzip/chunk envelopes for
compatibility adapters. No database schema migration or history replay is needed.
**Update both phone and PC before syncing large paged journals**: old app builds
cannot decode them. Small journals retain their old wire format.

For a phone whose push stopped at the old payload limit, install updated builds,
push from the phone owning the latest history, then pull on PC. Do not overwrite
the newer phone cloud files by pushing an older PC session first.

## Snapshot history recovery (manifest version 17)

Post-pull consistency keeps historical snapshots from surviving older card
revisions, including inherited epochs predating a branch root, and snapshots of
existing inactive variations. Only deleted coordinates and explicitly discarded
canon epochs are pruned. The live Ledger still uses an exact active committed
snapshot compatible with current canon; historical retention is not promotion.

Older builds could accept a truncated `tracker_snapshot` aggregate as a local
normalization. Version 17 records a local-only pending repair for those old
accepted hashes. It survives push-first upgrades and prevents publishing the
known truncated aggregate over complete cloud history. A normal pull retries it
once, after any owning chat import. Authored snapshot edits or unsafe owner states
do not trigger automatic replacement. Successful repair clears the marker even
if harmless normalization remains; failures leave it pending.
If an unchanged local owner has advanced or been deleted in cloud while repair
is pending, push stops before publishing files and requires pull first. Protecting
only snapshots while publishing an older owning chat would truncate history again.

Production replacement validates rows before deletion and runs delete/inserts in
one transaction, with exact snapshot/chat compare-and-swap and ownership checks
for recovery. Update the affected app and pull normally; do not delete the local
chat merely to bypass its canon timeline or create a sync tombstone.
