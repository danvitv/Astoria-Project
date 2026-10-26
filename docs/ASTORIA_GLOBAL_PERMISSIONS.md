# Astoria global permissions

Astoria's native workspace uses one encrypted permission profile, shared across
all Astoria conversations. Opening another chat, restarting, or deleting chats
does not reset its switches. The fixed inactive `workspace-permissions-global-v1`
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

## Switches versus exact sources

- A displayed enabled switch means **configured**, not unconditional access.
  `allows` still requires that right's actual current scope and, where applicable,
  recipient. An enabled but ineffective switch can be revoked without selecting
  a new source first.
- Safe categories and exact game-history selections are shared. The game session
  ID and selected ordered message IDs are unchanged; a different game cannot
  inherit them. Source mutation/staleness checks remain required.
- Selected Astoria message IDs stay attached to the originating Astoria chat.
  Another chat's projection hides them without deleting or rebinding them. A
  grant-only edit there preserves the original selection. Only the fresh native
  support-history picker may replace it with that chat's own selection.
- Explicit **whole current Astoria chat** is a distinct rule. It may apply to the
  current chat after switching. A null selection alone never means all messages.
- Private data/file/snippet handles retain their originating owner and are hidden
  from another chat's effective scope. Selecting support history in a different
  chat does not transplant those handles. Their loaders remain unavailable where
  they were unavailable before this change.
- An explicit scope change still advances its selection revision and revokes
  scope-dependent grants. A recipient change still revokes recipient-dependent
  grants. Independent grant-only edits merge; original identity, scope/recipient
  revision, revocation, and ABA checks remain exact.

## Reading, model output, and actions

Reading and sending full selected source bodies are distinct rights. A
model-initiated tool read returns its bounded factual summary/projection to the
model; it is not a promise of zero data egress. A game-history read grant alone
does not add full selected history bodies to a model request.
Ordinary DirectSend of the current Astoria conversation is unchanged and does not
gain a per-request recipient confirmation.

Do not describe every tool read as "nothing is sent." Existing finite application
tools can return factual bounded metadata to the model: for example,
`astoria_preferences_read` returns safe UI scalar values, which the active tool
loop places in its next tool-result round. This is not arbitrary existing-body or
file access. Existing native discovery returns opaque/session IDs, indexes and
counts, with body access not granted. Selected history/body context still has its separate source/model
authorization. This change does not broaden tool results or add body loaders.

Switches are prerequisites, not persistent final approval. Fresh exact destructive
consent, native authentication, file pickers, recipient-route validation, original
ROOT admission before each wire/action, and action-specific refusal remain intact.
Models cannot edit this permission profile. Locked bytes cannot be recovered by
resetting them; readable corruption of an initialized global profile can only be
explicitly recovered to deny with a fresh identity.
