# Astoria global permissions

For delivered capabilities, remaining scope and verification limits, see
[Astoria Assistant implementation status](ASTORIA_ASSISTANT_STATUS.md).

Astoria's native workspace uses one encrypted permission profile, shared across
all Astoria conversations. Opening another chat, restarting, or deleting chats
does not reset the profile. The fixed inactive `workspace-permissions-global-v1`
context has no conversation parent, no message range, and no support-session row.
Real conversation deletion cascades therefore leave it intact.

## Initialization and compatibility

The production native runtime explicitly initializes the profile when the normal
workspace admits its current conversation. It copies that conversation's existing
legacy policy if present; otherwise it chooses the newest existing legacy policy
by conversation update time, creation time, then ID. Existing legacy rows are not
changed. Only an actually missing source initializes deny. An unreadable, locked,
malformed, or unknown-version selected source fails closed, rather than searching
for a healthier policy or creating defaults. A locked current conversation cannot
admit initialization. Initialization is deferred until there is a current chat.

Standalone legacy fixture/store composition remains per-conversation until this
explicit initialization. Once the fixed global row exists, both native reads and
the model's original ROOT reader prefer it. Corruption or locking never falls back
to old conversation policies. Every native global write uses the latest row in
the repository transaction, with ownership checked after encryption and SQL.

## One application-data consent — November 1 redesign

This is the implemented product contract for the current access slice. Native
source/permission checks passed; UI evidence has explicit remaining gaps in the
status document. Do not interpret this contract as full device acceptance.

- The normal UI exposes one **application-data access** control, not independent
  local/model/category/session/recipient/report switches. Enabling requires one
  native consent; subsequent reads and conversations do not repeat that dialog.
- Consent allows Astoria to independently discover and read needed supported
  application sources, including several sessions and saved presets in one run.
  Session titles and other useful catalog labels may be returned to the selected
  model after bounded secret redaction. A catalog is not a complete history read.
- This is application-wide read consent, not a grant for one chosen session or
  provider. The user already chooses Astoria's local/external model connection.
  No extra per-provider approval is added. Ordinary DirectSend of the current
  Astoria conversation continues without a prompt/recipient review on every Send.
- Credentials remain excluded regardless of consent: API keys, authentication
  tokens, secret headers, vault material and other credential-bearing fields are
  not application content the assistant may reveal. Bounded typed projections
  and redaction remain required; consent does not expose SQL, shell or file paths.
- Revocation is available through the same single control. It must retire ongoing
  reads and prevent previously obtained source results from being posted again.
  Declining access does not prevent ordinary conversation, but source analysis
  must honestly report unavailable access rather than ask for repeated fragments.
- Legacy narrow grants do not automatically become this new broad consent.
  Missing/corrupt/locked state is not approval, and revocation must not fall back
  to old hidden per-category grants in production.

The first-Send invitation is suppressed after a decline for the current app
lifetime; accepted consent is durable. Missing consent after a later process
restart is still denial, not implicit authorization.

## User consent versus technical source custody

Removing repeated dialogs does not remove source fences. Each actual read still
belongs to the original native operation, database, selected connection/model and
immutable source snapshot. Native code establishes bounded frozen scopes from the
global read consent; models cannot mint grants or broaden an old snapshot with raw
IDs, invented selectors, appended messages or another run's handles.

Stop, source mutation, database/model/route changes and revocation remain terminal
for the affected operation. Writer exclusion, original ROOT validation before
actual POSTs and encrypted body-disclosure provenance remain mandatory. Source-only
retry/regeneration must not replay configuration, repair or backup effects.

Old exact-selection policies remain a compatibility format, not the normal UI.
Their selected message IDs and private handles retain their originating owner;
they must not silently be rebound while introducing application-wide consent.
Existing scope/recipient-bound legacy rights retain their stricter checks.

Native OFF first latches a shared denial/revision on the actual database owner,
then attempts encrypted persistence. This retires already-issued runs even if a
different bridge/runtime admitted OFF or the save fails. Refresh, conversation
switches and another repository on that same owner cannot clear it; only a fresh
successfully saved native enable review can. A later enable never revives old runs.
Failed persistence exposes an explicit save retry and stays locally OFF. It cannot
guarantee denial after process restart/new database owner until the denial is saved.

## Developer reports and changes are separate

Reading data for an answer is not permission to send a report to the developer.
Before export/sharing, the user must see the actual proposed contents, including
any necessary session titles/history, diagnosis and content-derived quotations.
They may exclude material or cancel. Cancellation means no export/upload/transfer;
the UI must not promise that a bug will necessarily be fixed after submission.

The detached recipient-encrypted `.astoria-report` exporter and local decoder are
not implemented. Do not present history encryption or reading consent as a working
report product, invent a support key, or silently downgrade its encryption design.

Read consent does not authorize edits, destructive repairs, connection tests,
backup export, restore, uploads or other public actions. Existing action-specific
native confirmations/authentication/file pickers, route validation and exact ROOT
admission remain intact. Models cannot edit the permission profile. Locked bytes
cannot be recovered by resetting them; readable corruption of an initialized
global profile can only be explicitly recovered to deny with a fresh identity.
