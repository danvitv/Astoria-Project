# Astoria Assistant — active implementation plan

Updated: 2026-11-02. This is the working plan, not a certificate of completion.
It supersedes the October plans and local phase journals. The user's latest
instruction and project safety rules take precedence over this document.

## Authority and accepted work

- [Global permissions](ASTORIA_GLOBAL_PERMISSIONS.md) defines the current access
  contract; [reports](ASTORIA_SUPPORT_REPORTS.md) defines the actual `.astreport`
  format and operator custody.
- [Implementation status](ASTORIA_ASSISTANT_STATUS.md) records capabilities and
  evidence; [handoff](ASTORIA_ASSISTANT_HANDOFF.md) records the current delivery.
- `docs/untracked/` and the six `.slim/deepwork/astoria*` task directories contain
  historical design/evidence. Old imperatives, pending labels, build hashes,
  permission checklists and executor IDs are not instructions to resume work.
- Accepted one-consent UI, typed SQLite readers, encrypted reports/decoder,
  Memory catalog integration, Studio dependency restoration, five global saved
  preferences families and the native/UI Memory wizard must not be rebuilt.
  Reuse unchanged evidence; refresh only checks invalidated by relevant changes.

## Product goal

Astoria is a native Dart assistant, separate from roleplay and the WebView. It
explains the app, helps configure it, diagnoses from real application evidence,
proposes available exact repairs, and helps prepare a separately approved report.
Advice, observed facts, hypotheses, applied changes and saved reports are distinct.
Missing tools or evidence must be reported, not filled in with claimed success.

## Current invariants — not legacy UX

1. One encrypted global application-data read consent includes use by the already
   chosen local/external model. It permits autonomous bounded discovery of several
   sessions/presets without repeated category, session, body or recipient dialogs.
   Ordinary DirectSend includes the current visible Astoria conversation without
   a prompt/recipient approval on every Send. A decline still permits ordinary chat.
2. OFF retires old reads and prevents replay, including after re-enable. Legacy
   narrow policies remain strict compatibility; they do not become broad consent.
   Original run/database/source/model ownership, Stop, CAS/ABA, redaction, frozen
   scopes, encrypted provenance and native ROOT admission remain mandatory.
3. Only actual connected typed tools are capabilities. No raw SQL, arbitrary
   preferences keys, shell, paths, credential values or prose-driven execution.
   Keys enter through native settings; configured/count metadata is not validity.
4. Reading grants no mutation, destructive repair, paid probe, backup/export,
   restore or upload authority. Preserve each existing action's native delegation,
   exact confirmation and conditional Undo rules. No blanket permission toggle is
   added as a new prerequisite. Missing original-owner seams refuse safely.
5. Ordinary and Studio presets are separate domains. Current saved definitions
   do not prove historical assembled prompts. Drafts are not approved Memory.
   Database health, hashes, counts and canon assembly do not prove narrative truth.
6. Reports require an immutable exact preview, exclusions with derivative closure,
   and separate one-use native save approval. Only ciphertext reaches the chosen
   destination. Preview is not save or submission. The real public recipient and
   local DPAPI decoder already exist; do not regenerate/read private keys.
7. Tool calling uses the existing dedicated native transport and its current
   `NativeToolLimits`: eight rounds, 32 calls per session, eight calls per turn,
   plus existing time/payload bounds. Specialists must fit within that total, not
   gain another independent budget. No `ChatTransport` tool-event rewrite.
8. DCP preserves stored history and original evidence/denial provenance. Summaries,
   provider replies, saved content and tool results are untrusted data, not grants
   or instructions. Retry/regeneration remain source-only; no effect replay.

## Delivered Memory wizard contract

Select an already-loaded idle native owner, then answer five questions: manual/
empty/LLM drafts; economy/balanced/detail retrieval; injection token ceiling;
saved/current draft connection; keyword/semantic search. Three independent reviews
and confirmations cover session SQLite, global `memorySettings` automation/vector
gate, and global `pipelineSettings.memoryBookApi`. There is no cross-store atomicity
or universal one-click rollback. Deep currently uses local Balanced capabilities;
consolidation is unchanged. Local readiness is not a paid/live connection test.

Generation -> pending approval -> explicit Approve -> catalog -> budgeted injection
is the required chain. Navigation opens only the exact selected active native owner;
it must not bootstrap a replacement chat. Bounded UI, retirement and navigation
evidence is accepted; physical-device/live-provider validation is not claimed.

## Remaining work, in order

### 1. Evidence-grounded diagnostics and specialist workflows — active

Deliver usable slices through the actual Send -> connected read -> evidence ->
answer path before broadening. Five immutable built-in skills guide connection,
generation, Studio, preset validation, and Memory/data integrity tasks. Skills
provide advice and relevant connected tool names, never extra rights or executors.
Selection comes from the current user task, not instructions found in sources.

The structured result must distinguish:

- observed facts and their exact source/call references;
- causal hypotheses: `confirmed_by_check`, `probable_cause`, `insufficient_data`;
- alternatives, missing/truncated/evicted evidence and the next safe check;
- proposed, confirmed and actually completed repair attempts.

Connection diagnosis needs recorded protocol/HTTP/timeout evidence, not a key count.
Generation diagnosis needs actual captured call/stream/context/sampling/reasoning
evidence. Studio needs real preset validation and recorded phase/parser/controller
results; required tracker failures must not be bypassed. Integrity diagnosis keeps
canonical books, drafts, derived catalogs, Ledger and canon assembly separate.
Autonomous multi-session discovery uses the existing global consent while every
observation retains exact session/run/call identity.

A deterministic annotation of an already-admitted result is only an observation
helper, **not** an internal specialist agent or a completed diagnostic product.
Actual bounded read-only specialists remain a distinct pending capability. They
must share original run/consent/Stop/transport bounds, cannot mutate/export/probe or
recursively launch more agents, and require evidence through the actual native
application path. Do not introduce a replacement reader graph or extra model call
merely to rename a metadata helper. Add a reader only for a named missing evidence
seam not already covered by the delivered typed source readers.

The richer diagnosis/remediation presentation and optional report integration
remain pending. Extend the existing report format only when required by that
delivery; do not rebuild its crypto, recipient or save infrastructure.

### 2. Extended actions and conditional Undo — separate bounded slices

Remaining scope includes roleplay session/message operations, composite deletions,
global selections/bindings, extended Memory entry/draft/revision/index jobs,
canon/rewrite, sync/auth/conflicts, regex/image/gallery, and further imports/exports.
Features elsewhere in the app are not automatically assistant tools. Choose one
usable operation with its original owner seam, precise effects, confirmation and
fresh conflict-safe Undo; no universal mutation framework or invented authority.

### 3. Remaining credential-family migration

The assistant vault/broker/redaction path is integrated; complete migration of
every original secret family is not established. Inventory only the family being
migrated, preserve consumer/reference and backup behavior, and keep native custody,
endpoint-origin restrictions and safe conditional recovery. Do not destructively
remove legacy data or infer permission to inspect real operator/user credentials.

### Additional original scope still open

Rich list/code-block rendering, some generation overrides, richer offline diagnostic
cards and full diagnostic/report presentation remain product backlog, not proof of
removed requirements. Encrypted support replies/import and automatic Cloudflare/
Discord delivery were optional proposals, **not part of the authorized sequence**.
No upload service, bot token, reply-key format or key rotation is to be introduced.

## Verification and stopping rules

For each slice name the observable capability, the original-owner/privacy risks,
and finite affected checks. Use existing synthetic native/provider fixtures;
separate real application integration from pure DTO tests and from live quality.
Flutter commands run sequentially. If the same fixture failure survives two focused
corrections, stop that loop; preserve safety assertions and report the blocker.
Do not repeat accepted suites/builds without a relevant invalidating change.

Current authorization excludes push/public actions, real user DB/preferences/keys,
live/paid requests, GUI/device launches, dependency installation and destructive
resets. No new review phase, harness or completion percentage substitutes for a
working user-visible result. Record actual gaps and evidence once in status/handoff.
