# Astoria Assistant — implementation status

Updated: 2026-11-01. Read-access redesign commit: `d73093fb` on
`feat/astoria-assistant` (original baseline `4f1f9d58`). Subsequent bounded UI
verification fixes are complete for the named Send/settings debts and recorded
in the follow-up repository history.
The earlier October 31 documentation audit used `1546a53f`.

## Remaining SQLite readers and reports — delivered bounded slice

The temporary Windows restart checkpoint was committed as `fead7a60`; the prior
UI-debt commit is `6f9b9476`. The user's subsequent «Продолжай» resumed the two
preserved tasks, not the complete original assistant backlog. Follow-up reader
scenario corrections and report-selection ownership changes are recorded in the
follow-up repository history.

- Eleven domains now cover the 64 registered SQLite tables through fixed logical
  readers or explicit private-infrastructure exclusions. The two added domains
  expose 15 application datasets and bounded exact-AAD reads of other encrypted
  Astoria conversations. Credentials, vectors, authority/CAS fields and source
  receipts are excluded; credential columns are not selected by API readers.
- All thirteen new-data cases passed across the bounded affected runs. Native
  source regression also passed all fourteen cases. The three formerly failing
  success flows are closed: actual retained validation is batched only inside the
  original native ROOT; long exhaustive privacy scenarios use separate runs rather
  than raising repository, capture or disclosure limits.
- Report snapshot, full exact preview, exclusions with derivative closure,
  real libsodium recipient encryption, native ciphertext save and the protected
  local CLI are integrated. Seventeen latest targeted native report checks passed,
  including the compiled standalone DPAPI/Sodium CLI and stock executor ROOT.
  Eight report-widget cases passed, including retirement during content selection
  without constructing/querying replacement provider graphs. Earlier unaffected
  crypto/ROOT and 33 save-port checks remain separate, reusable evidence.
- Current Android/Kotlin release build passed in 390.4 seconds (156.9 MB), the
  standalone CLI bundle compiled with native assets, and Windows release passed
  in 81.5 seconds. These first builds used the unconfigured recipient; following
   explicit user approval, the configured-recipient APK rebuild passed in 49.7
   seconds (156.9 MB) and Windows rebuild in 10.1 seconds. Both current clients
   contain the real public recipient; the native CLI bundle is unchanged.
  The prior checkpoint passed a Windows release build in 89.1 seconds
  and fifteen selected startup/native-ABI cases; it is historical evidence, not a
  substitute for the current distribution builds or a device launch.
- The user explicitly chose local production key creation. The compiled native
  CLI created recipient `astoria-support-20261101-62ba1e85`, keeping the private
  DPAPI file outside the repository and bundling only its public descriptor.
  No private bytes were read by the model or printed. With that recipient in the
  rebuilt clients, export is enabled; a null descriptor still refuses safely. See
  [native reports and operator CLI](ASTORIA_SUPPORT_REPORTS.md).
- Cancellation before ciphertext admission prevents report-byte transfer; Android
  selection may leave an empty document if best-effort deletion fails. Admitted
  OS I/O is not undoable. Non-SQLite global preferences still need their own
  original revision/ABA owner and are not part of the 64-table coverage claim.

Controlled native/UI evidence is not a GUI/device launch, live-model diagnosis,
private database inspection or full-project regression certification.
The two resumed SQLite/report tasks are closed within these stated boundaries;
follow-up source, test, public-descriptor and documentation changes are recorded
in the local repository history. No push was performed.

**The assistant is integrated and enabled, but the complete original product plan
is not finished.** The November 1 request delivered a bounded implementation slice:
one global data-read consent, autonomous multi-source reading and a simpler UI.
It does not resume the entire original backlog or authorize private runtime access,
installation or release actions. The read-access backend and simplified UI are
implemented. Native source/permission and the bounded Send/settings UI evidence
are accepted. This is not full product or device acceptance.

## November 1 product decision

Replace per-category, per-session and per-body reading approvals with one native
consent to use application data. After enabling it, Astoria independently discovers
and reads needed sources, including several sessions. One switch revokes access.
API keys, tokens and other credential material remain excluded. The selected model
connection may be external or local; no additional per-provider consent flow is
part of this redesign. Technical source ownership, bounded projections and Stop
checks remain mandatory, not user-facing permission puzzles.

Sending a support report to the developer is a separate decision. Its exact preview
must say whether session titles/history or other personal content are included and
allow exclusion or cancellation. Read consent never authorizes export or upload.
The recipient-encrypted report/export/decoder is implemented with controlled
native/UI evidence and an explicitly provisioned public production recipient.
No unavailable preview or unconfirmed save may be presented as already created
or sent.

### Delivered access slice and limits

- The single read grant is stored in the existing encrypted global profile. New
  grant-bearing policies use strict version 3; legacy policies never automatically
  consent to application-wide reading. Normal source/model/category/recipient
  switches and mandatory source pickers are removed from the UI.
- The first configured-model Send offers consent. Declining allows ordinary chat
  and suppresses further invitations for the current app lifetime; an accepted
  grant persists independently of the conversation. Later enabling is explicit.
- Authorized source catalogs return bounded redacted labels, dates, session
  numbers and all original opaque handles on a page, rather than one manually
  selected target. Native code establishes run-local frozen scopes automatically;
  catalog and body disclosures retain encrypted provenance before actual POSTs.
- Trusted history-index preparation runs before source snapshots, with a bounded
  newest-session window and time/step budgets. It does not rewrite canonical
  history. Large or older unprepared sources may remain incomplete; this is not
  an unlimited scan or a promise that every stored row is immediately readable.
  Advanced native index diagnostics remain available separately.
- OFF retires reads immediately, including across runtimes/repositories sharing
  the same actual database owner. A failed encrypted denial write stays locally
  blocked and exposes a save retry; fresh native consent cannot resurrect an old
  run. An unsaved denial is in-process protection, not a durable guarantee after
  restarting the process or replacing the database owner.
- Credentials and secret-bearing JSON/header containers remain excluded before
  searching, slicing and transmission. Read consent grants no mutation, repair,
  backup, export, report, connection-test or upload authority.
- Theme/provider entry cards now route global-profile users to ordinary native
  settings instead of asking for hidden legacy prerequisite toggles. Historical
  nonglobal wizard composition remains compatibility code, not the normal UI.
- This policy does not implement a new local-model transport. Existing native
  model routes still require HTTPS; local HTTP endpoints and live models were not
  exercised or newly enabled by this read-access change.

## Integrated capabilities

| Capability | Current implementation and boundary |
|---|---|
| Native workspace | Desktop/mobile UI, separate conversations, encrypted local history, Send/Stop, guarded edit/delete/retry/regeneration. These are Astoria conversations, not full roleplay-session CRUD. |
| Model connection | Independent Astoria provider/model profile shared across its conversations, model catalog, native key entry and finite typed tool rounds for the supported provider protocols. |
| Context | Manual and automatic compaction with an encrypted checkpoint and the remaining conversation suffix; compaction does not delete stored history. |
| Permissions | One global encrypted application-data read consent, frozen technical source ownership, revocation and separate dangerous-action authority. Legacy exact-source/recipient policies remain compatibility-only. See [global permissions](ASTORIA_GLOBAL_PERMISSIONS.md). |
| Setup and actions | Theme/provider entries open native settings. Existing bounded UI/configuration and character/persona/lorebook/preset/Studio/Memory tools retain their original action-specific restrictions; the read grant does not enable every action. This is not arbitrary application control or a universal mutation/Undo engine. |
| Integrity and recovery | Bounded database/session/Collector/Ledger checks and specific repairs, conditional repair Undo, native SQLite snapshots, separate cold-start restore on Windows/Android. Restore preparation in chat is informational; it does not perform restore or restart. |
| Source navigation | Four read-only tools across eleven domains, fixed typed coverage of the 64 SQLite tables, autonomous bounded catalog/search/read after one consent, trusted bounded index preparation and encrypted catalog/body disclosure provenance before the actual model POST. Private infrastructure and non-SQLite preferences are not arbitrary raw sources. |
| Support reports | Native safe facts and optional personal commentary, full immutable preview/exclusions, separate one-use native save approval, recipient-encrypted ciphertext and a Windows DPAPI-protected local decoder. A real public recipient is provisioned; private custody remains outside the client/Git. No upload/Discord automation. |

Ordinary DirectSend uses the current Astoria conversation without a separate
recipient/prompt approval on every request. Other conversations/private source
bodies require the separate application-data grant, not inherited DirectSend
authority. Existing finite metadata tools can return bounded factual
projections to the model; they must not be described as zero data egress.

## Source navigation: current, not the old disabled checkpoint

`ASTORIA_SOURCE_NAVIGATION_EXPERIMENTAL` defaults to **true**. An explicit false
disables this composition; an enabled feature flag does not grant body access.

The exact tools are `astoria_sources_list`, `astoria_source_contents`,
`astoria_source_search` and `astoria_source_read`. Domains are game history,
ordinary presets, Studio presets, Memory, saved summaries, Ledger state, Ledger
snapshots, reconciliation, character knowledge, fixed `applicationData` datasets
and `astoriaConversation` sources. The model gets no SQL, paths, regex, grant,
mutation, report-export or index-maintenance tool.

Index preparation is not a grant. Authorized redacted catalog labels can now reach
the selected model. Navigation still requires fresh exact technical
run/source/snapshot/scope/recipient/model custody derived from native consent; Stop,
route/model changes, source mutation and ABA retire it. Retry/regeneration expose
only source tools, not the action/backup graph, and cannot replay earlier effects.

Later commits supersede the October 27–28 incomplete checkpoints:

- `395372a9`: enabled production source navigation by default.
- `a0f104cc`: separated original source ownership from approval authority.
- `4195a0b9`: batched source fences only inside the original writer-excluding ROOT
  admission; recorded validation includes source flows, native safety, engine and
  legacy compatibility. Earlier long-flow budget failures are historical.
- `3ac87c62`: newest-first local target picker, dates and safe pagination.
- `bcb40025`: compiler-target-aware SQLite exports for Windows and Android;
  `tool/sqlite3_source.c` makes manual target switching/restoration unnecessary.

Earlier tests cover genuine local preparation and native/model flows across all
nine domains. The old ordinary-preset `updated_at` SQL error, overwritten ABA
failure category and obsolete two-tool/offset protocol fixtures have been corrected.
The October audit read their code and recorded validation. The November checks
below verify the new access slice, not a rerun of every nine-domain legacy case.

## Remaining product scope

| Original stage | Disposition |
|---|---|
| Security foundation | Assistant credential/broker/redaction path is integrated. Compatibility deliberately retains legacy Drift fallback; full migration of every original secret family is not established as complete. |
| Workspace and history | Integrated. Rich list/code-block rendering and some originally proposed generation overrides remain outside the current narrower UI. |
| Guided setup | Theme/provider entry uses ordinary native settings for global-profile users. The complete Memory Books wizard is not implemented. |
| Tools, skills, agents and DCP | Actual tool execution and compaction are integrated. Curated diagnostic skills, bounded specialist agents and the full structured diagnostic product remain open. Tool rounds use the dedicated native transport, not the originally proposed streaming tool-event extension to `ChatTransport`. |
| Support reports | The bounded native facts/commentary, immutable preview/exclusions, recipient encryption, `.astreport` save and DPAPI-protected decoder slice is integrated with targeted native/UI evidence and explicit public-recipient provisioning. Physical-device/provider I/O and the richer original diagnostic product are not claimed complete. |

The Memory Books quick action currently reports that the assistant entry is
unavailable. Existing Memory settings tools do not replace the planned 4–6-question
wizard, global/session distinction, end-to-end readiness check and rollback.

The report UI prepares an explicit preview. No file is implied before an
actual successful native save; a null/unconfigured recipient disables export.
Per-install history encryption is not report encryption for the support recipient.
The public production key/keyId was provisioned by explicit user approval through
the documented local CLI, not simulated with a demo key. Private key material
remains in the CurrentUser DPAPI file outside the repository and conversation.

The broader application-control backlog includes full roleplay session/message
operations, composite deletion and global selections/bindings, extended Memory
entry/draft/revision/index jobs, canon/rewrite actions, sync/auth/conflict actions,
regex/image/gallery operations, other imports/exports and general Undo. Some of
these features exist elsewhere in the app; that does not make them assistant tools.
Missing unsafe owner seams are deliberate refusals, not permission to bypass them.

### Concrete integration follow-ups

1. **Memory catalog rebuild is advertised but unreachable in normal model runs.**
   [Memory adapter](../lib/features/support_assistant/services/app_control/session_memory/support_app_memory_adapter.dart)
   requires `context.sourceAccess`; the production
   [model tool loop](../lib/features/support_assistant/services/support_model_tool_loop.dart)
   supplies only the separate `sourceToolAccess`
   for navigation. The new read-only navigation graph does not authorize rebuild.
2. **Studio dependency-restore bookkeeping does not round-trip through the ordinary
   editor path.** [Native control](../lib/core/db/repositories/studio_preset_app_control.dart)
   persists `agentEnabledBeforeDependencyOff`, but the general
   [codec](../lib/core/models/studio_preset_codec.dart)/[upsert](../lib/core/db/repositories/studio_preset_repo.dart) does not retain
   it. A later ordinary editor save can lose that restoration map. This is a
   statically identified follow-up, not a newly executed runtime reproduction.

## Evidence and supported limits

- November access-slice verification: five permission/codec cases and fourteen
  real native-file/scripted-provider source cases passed. The latter include two
  named sessions plus the current saved Studio preset in one run without picker
  or body-confirmation callbacks, eight encrypted disclosures before respective
  continuation POSTs, canonical-history preservation, credential exclusion,
  failed-OFF persistence, cross-runtime revoke/re-enable, Stop and mutation.
- Two existing native source-only retry/regeneration cases passed without adding
  the action/backup graph. These are compatibility regression cases, not live
  provider evidence or complete global-consent retry certification.
- The first-Send grant and decline UI cases now pass through repeated Sends and
  another conversation without extra read dialogs. Their former timeout was a
  test readiness error: selection publishes the new ID before the queued encrypted
  read completes. The existing real/Flutter turn driver now waits for the native
  snapshot and displayed composer to be ready; no production guard was changed.
  The earlier changed-draft-during-consent case remains passed and unchanged.
  All eight settings/access widget cases now pass: OFF during native work,
  configuration/source instability, failed persistence with explicit retry,
  one-consent grant/revoke at widths 236/360/1120 and cancellation without grants.
  The timeout was a test-zone deadlock: the cipher key FIFO retained a completed
  widget-zone Future, while a subsequent runAsync decrypt waited for a late callback
  in that unadvanced zone. The existing bounded real-turn/pump driver resolves it
  without changing the cipher, controller, production widgets or assertions.
  Narrow-panel tests scroll lazily built groups and advance layout before actual
  hit-tested gestures. Two existing desktop/mobile settings layout cases also pass,
  with current output-limit/DCP labels and the application-data control reachable.
- Scoped analysis of the assistant/source boundary reported no errors/warnings;
  remaining backend/test hints are informational. The final five UI/composer/test
  files reported no issues after explicit mounted guards and import cleanup.
  The three changed Send/settings test files also report no issues after the
  post-commit driver/readiness/scroll corrections.
  A whole-project analyzer attempt timed out and is not completed evidence.
- The earlier access-slice APK passed at 155.0 MB without manual SQLite target
   switching. Current configured reader/report/Kotlin/CLI/Windows distribution
   builds passed; their results belong to the delivered slice above, not this
  historical APK. No GUI/device launch, installation, live provider, actual user
  database or full regression suite is included. Production key creation was
  separately approved and performed through the standalone native CLI without
  reading private bytes into the model.
- At the runnable `bcb40025` checkpoint, Windows release and Android release APK
  builds passed with the same unchanged SQLite configuration; 15 targeted
  startup/native-ABI tests passed. The analyzer had zero errors/warnings and 15
  deferred infos. Kotlin Gradle migration advisories were nonblocking. These are
  checkpoint results, not fresh results for the current HEAD or full assistant.
- Native/model/UI validation uses declared synthetic fixtures and scripted
  providers. It establishes controlled integration behavior, not the quality of
  a live model's autonomous tool selection or exact diagnosis of the old screenshot.
- SQLite VM progress callbacks and chunk checks provide bounded best-effort work,
  not a hard deadline during overflow-page/OS I/O. Do not promise absolute Stop or
  physical-disk latency guarantees.
- Android snapshots are app-private, not a portable external backup export. Android
  restore/Keystore/VFS/launcher runtime evidence is still absent; iOS recovery is
  not implemented. The Windows close-result `busy` versus `unsupported`
  classification remains a recorded evidence question, not proof of lost exclusion.
- Accepted restore scope is logical committed SQLite state. Corrupt/unopenable
  target headers, exact main/WAL/SHM bytes, power-loss atomicity and missing vault
  key recovery are not supported guarantees.
- Reuse accepted unchanged evidence. Resume only a named delivery slice; this
  bounded redesign does not reopen all old gates or create a new full-suite
  certification project.

## Plan and history pointers

The original design and detailed journals are local ignored artifacts, not files
distributed with a normal clone:

- `docs/untracked/ASTORIA_ASSISTANT_PLAN.md`
- `.slim/deepwork/astoria-assistant/progress.md`
- `.slim/deepwork/astoria-app-control/progress.md`
- `.slim/deepwork/astoria-source-navigation-cleanroom/progress.md`

Their dated historical failures, disabled flags, pending executors and build
hashes are not current task state. This repository summary distinguishes remaining
implementation, changed design and missing runtime evidence; no completion
percentage or whole-product acceptance is claimed.
