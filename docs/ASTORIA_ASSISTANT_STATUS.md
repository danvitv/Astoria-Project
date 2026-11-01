# Astoria Assistant — implementation status

Updated: 2026-10-31. Documentation audit baseline: `1546a53f` on
`feat/astoria-assistant`. The two commits after the initial `21426960` audit concern
Card Evolution/rewrite, not the assistant's tool composition.

**The assistant is integrated and enabled, but the complete original product plan
is not finished.** Implementation remains paused; this update changes documentation
only. It does not authorize more feature work, runtime access, installation or
release actions.

## Integrated capabilities

| Capability | Current implementation and boundary |
|---|---|
| Native workspace | Desktop/mobile UI, separate conversations, encrypted local history, Send/Stop, guarded edit/delete/retry/regeneration. These are Astoria conversations, not full roleplay-session CRUD. |
| Model connection | Independent Astoria provider/model profile shared across its conversations, model catalog, native key entry and finite typed tool rounds for the supported provider protocols. |
| Context | Manual and automatic compaction with an encrypted checkpoint and the remaining conversation suffix; compaction does not delete stored history. |
| Permissions | Global encrypted profile, source/recipient constraints, revocation and separate dangerous-action confirmation. See [global permissions](ASTORIA_GLOBAL_PERMISSIONS.md). |
| Setup and actions | Installed theme/mode, provider preparation, bounded UI/configuration and character/persona/lorebook/preset/Studio/Memory operations. This is not arbitrary application control or a universal mutation/Undo engine. |
| Integrity and recovery | Bounded database/session/Collector/Ledger checks and specific repairs, conditional repair Undo, native SQLite snapshots, separate cold-start restore on Windows/Android. Restore preparation in chat is informational; it does not perform restore or restart. |
| Source navigation | Four read-only tools across nine domains, local target selection/index preparation, contents/search/selected reading and encrypted disclosure provenance before the actual model POST. |

Ordinary DirectSend uses the current Astoria conversation without a separate
recipient/prompt approval on every request. Other conversations and private source
bodies do not inherit that permission. Tool reads can return bounded factual
projections to the model; they must not be described as zero data egress.

## Source navigation: current, not the old disabled checkpoint

`ASTORIA_SOURCE_NAVIGATION_EXPERIMENTAL` defaults to **true**. An explicit false
disables this composition; an enabled feature flag does not grant body access.

The exact tools are `astoria_sources_list`, `astoria_source_contents`,
`astoria_source_search` and `astoria_source_read`. Domains are game history,
ordinary presets, Studio presets, Memory, saved summaries, Ledger state, Ledger
snapshots, reconciliation and character knowledge. The model gets no SQL, paths,
regex, grant, mutation or index-maintenance tool.

Local native preparation and target labels are not body/model grants. Navigation
requires a fresh exact run/source/snapshot/scope/recipient/model authority; Stop,
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

Current tests cover genuine local preparation and native/model flows across all
nine domains. The old ordinary-preset `updated_at` SQL error, overwritten ABA
failure category and obsolete two-tool/offset protocol fixtures have been corrected.
This audit read their code and recorded validation; it did not rerun those suites.

## Remaining product scope

| Original stage | Disposition |
|---|---|
| Security foundation | Assistant credential/broker/redaction path is integrated. Compatibility deliberately retains legacy Drift fallback; full migration of every original secret family is not established as complete. |
| Workspace and history | Integrated. Rich list/code-block rendering and some originally proposed generation overrides remain outside the current narrower UI. |
| Guided setup | Theme and provider flows are integrated within their boundaries. The complete Memory Books wizard is not implemented. |
| Tools, skills, agents and DCP | Actual tool execution and compaction are integrated. Curated diagnostic skills, bounded specialist agents and the full structured diagnostic product remain open. Tool rounds use the dedicated native transport, not the originally proposed streaming tool-event extension to `ChatTransport`. |
| Support reports | Detached facts/diagnosis/remediation snapshot, immutable preview/exclusions, recipient encryption, `.astoria-report` export and the local HELGA decrypt CLI are not implemented. |

The Memory Books quick action currently reports that the assistant entry is
unavailable. Existing Memory settings tools do not replace the planned 4–6-question
wizard, global/session distinction, end-to-end readiness check and rollback.

The report UI explicitly says no diagnostic snapshot/file has been created.
Per-install history encryption is not report encryption for the support recipient.
Production public recipient key/keyId and trusted private-key provisioning for the
local decoder remain an unresolved trust seam; do not embed a demo production key.

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

- At the runnable `bcb40025` checkpoint, Windows release and Android release APK
  builds passed with the same unchanged SQLite configuration; 15 targeted
  startup/native-ABI tests passed. The analyzer had zero errors/warnings and 15
  deferred infos. Kotlin Gradle migration advisories were nonblocking. These are
  checkpoint results, not fresh results for the current HEAD or full assistant.
- Earlier native/model/UI validation uses synthetic fixtures and scripted
  providers. No new tests/builds, live providers, user databases, GUI/device launch,
  real OS-vault restart or full regression suite were exercised by this audit.
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
  documentation refresh does not reopen all old gates or create a new full-suite
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
