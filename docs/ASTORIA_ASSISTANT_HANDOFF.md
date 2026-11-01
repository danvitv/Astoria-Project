# Astoria assistant — current handoff

Date: 2026-11-02. Branch: `feat/astoria-assistant`.
Checkpoint: `e5fd03d8`. The resumed root session completed the wizard's remaining
UI/readiness/navigation slice as local uncommitted changes. No push, live calls
or application/device launch was performed.

## Scope on resumption

The active plan is [ASTORIA_ASSISTANT_PLAN.md](ASTORIA_ASSISTANT_PLAN.md). The
November 2 audit found conflicting legacy requirements in the original design
and phase journals; those are now explicitly archived, not resume instructions.
Documentation cleanup does not reopen accepted deliveries or retire safety guards.
Diagnostic skill/observation changes exist locally as a partial first slice:
19 distinct relevant cases pass, but the four new diagnostic UI cases do not
reach their first POST. Observation helpers are not actual specialist agents or
full causal diagnosis. Do not declare this slice integrated or proceed to the
extended-action backlog on the strength of unit results.

Standing original-plan order: Memory/Studio integrations -> global preferences
-> Memory Books wizard -> diagnostics/specialist workflows -> bounded extended
actions, Undo and credential-family migration. The wizard's bounded native/UI
delivery is now verified; diagnostics is the next separate product slice.

Completed one-consent UI, SQLite readers, encrypted reports and local decoder
must not be rebuilt or reverified by habit. Keep credential access excluded and
developer-report sharing a separate explicit decision.

## Accepted deliveries in this checkpoint

- Normal assistant Send can rebuild the local Memory catalog after exact native
  confirmation. Original consumed custody, private source lease, CAS and source
  retirement guard the effect; canonical book/drafts/settings/other sessions/
  vectors/entities are unchanged. Retry/regeneration have no effect graph.
- Studio dependency restoration survives ordinary codec/export/editor saves,
  preserving both previously enabled and disabled dependents.
- Five saved-preferences families (Memory, pipeline, regex, bindings, variables)
  are readable through the existing four source tools. Fifteen fixed keys use
  an original store/producer owner, with retirement before direct, optimistic,
  queued, backup/import/sync writes. False/throw or overlapping stale reloads
  quarantine affected cache. No read-side migration, raw-key tool, secret
  disclosure or source-budget increase. External writers are not certified.

Evidence: Memory's relevant existing regressions 27 PASS; Studio 44 PASS; global
FILE/model paths for all five families, cold/import/retirement cases, four reload
orderings, one sync admission and 29 existing variable/settings/theme regressions
passed across bounded runs. Global scoped analysis had no errors/warnings but
informational lints remained. Windows release passed in 80.7s **before the wizard**.

## Memory Books wizard — native/UI delivery verified

The entry is wired to five native questions and three independently confirmed
plans: session SQLite retrieval, global `memorySettings` automation/vector gate,
and global `pipelineSettings.memoryBookApi` draft connection. Do not claim
cross-store atomicity or silently rewrite other books. Deep currently behaves
like local Balanced; consolidation has no active consumer and is unchanged.

Native service evidence covers session row/absence CAS, encrypted journal and
fresh conflict-safe Undo; unknown settings/content/credentials stay preserved.
Global failures, overlap or lost journal delivery report reconciliation rather
than falsely claiming nothing changed. Original source/store/controller bindings
must survive every await; no replacement-provider lookup or receipt revival.

The neighboring independent root finished with a partial handoff. Its fixes:
readiness local-name collision, numeric budget evidence redaction aliases limited
to owned top-level fields, and post-write source/lease recheck after journal await.
Service/fence run: 8/8 PASS; affected journal/evidence recheck: 4/4 PASS, not four
additional independent feature claims. Initial global cases and synthetic
generation -> pending approval -> explicit approval -> catalog -> budgeted
injection also passed; unapproved drafts were not injected. No live generation.

The previous current-root controller alternative passed 1/1 with real native fixtures:
all five transitions/back -> session review -> explicit Confirm -> local readiness
-> fresh Undo. No pre-Confirm write, duplicate review cannot apply, globals unchanged.
This unchanged controller evidence is reused, not counted as a new verification run.

### Closed UI blocker and new evidence

The first Next was tapped while disabled: saved-connection metadata/SQL was still
pending. The test waited for a mounted spinner, but that trailing lazy ListView
child was outside the viewport. It now checks the actual declared busy child,
drains the real event queue within a finite limit and asserts the native button
is enabled. No production question-transition defect was found. A separate
measured Confirm issue placed the button under SheetView's pinned header;
centering it preserves real hit-testing and taps. No controller callback bypass,
assertion weakening or shared-chrome change was used.

The extended original widget test passes five questions, exact session review,
native Confirm, readiness and fresh session Undo; both global scopes then pass
separate native Confirm/Undo with private unknown/credential fields preserved and
other stores unchanged. It also opens the real MemorySheet Books tab on the exact
selected, already-loaded session. Navigation binds the original owner identity
and registry revision before mounting; a rejected owner is checked before any
chatProvider watch, and a mismatched session cannot mount books operations.

New targeted readiness cases: source ABA, physical book same-value ABA, owner
selection revision, read OFF, database lifetime and connection ABA all refuse
held stale reads; a completed global change during SQL is read fresh afterward.
Two negative navigation cases reject owner ABA and another actual session.
The existing ordinary MemorySheet/search suite passes without a binding.

Evidence from this delivery: extended UI chain 1 PASS; navigation 2 PASS;
readiness 7 PASS; ordinary MemorySheet/search 4 PASS. These are 14 distinct cases,
not an additional count for repeated runs. Scoped analysis reported no errors or
warnings; baseline informational lints remain (new flow-control/Future hints were
corrected). Windows release passed in 91.9s at
`build/windows/x64/runner/Release/Astoria.exe`; distribute the full Release folder,
not the executable alone. No manual GUI, physical-device, live generation or
external-process/raw-writer certification is claimed.

## Diagnostics — partial, native UI evidence blocked

Five immutable built-in checklists are selected from the current user question,
not provider prose or historical summaries. They advertise only intersecting
connected read tools and add no rights. Deterministic observations over admitted
connection/capture-count/catalog/canon metadata retain original correlation,
current redaction and DCP duplicate references. They distinguish observed facts
from an unknown cause; no additional reader, model, repair, export or probe runs.

The model instructions now describe the connected global preferences owner and
the one-consent contract accurately. Reachable report welcome/settings copy and
local help describe the existing native preview/exclusion/encrypted-save flow,
not an unavailable export or a fabricated recent-session list. Legacy permission
compatibility and actual effect confirmations are unchanged.

Evidence: 17 pure checklist/metadata cases pass; the changed local diagnostic
start case and an existing native regeneration/no-tool-warmup case pass (19
distinct cases total). Scoped analysis of changed services/UI/tests has no errors
or warnings. Three new informational brace hints were corrected afterward; two
unchanged hints remain in the model-run service. No new Windows build was run.

The four new diagnostic UI cases remain failing and unskipped. They now reuse
the existing owned-file backup/native UI fixture, with only an optional input
text parameter added. That fixture times out before the first diagnostic POST;
the concrete cause is not yet established. Earlier memory-only fixture attempts
refused automatic history preparation because memory SQLite intentionally has no
native file-source identity; that is not a defect to bypass. An older flat fixture
also retained an emitter retired by preferences loading. Temporary diagnostics
and attempted edits to those shared fixtures were removed.

Stop the fixture-repair loop: do not add another harness, increase frame/source
budgets, forge native authority or weaken assertions. The next observable result
is a concrete explanation of the existing file fixture's pre-POST wait, followed
by the original Send -> native read -> correlated continuation -> durable answer
and Stop assertions. Reuse the accepted 19 cases unless their inputs/code change.
Full recorded HTTP/stream/Studio diagnosis and actual specialist-agent execution
remain pending, as do rich diagnosis/report integration and subsequent actions.

## Files to start with

- `lib/features/support_assistant/services/diagnostics/`
- `lib/features/support_assistant/services/support_model_tool_loop.dart`
- `test/support/diagnostics/support_diagnostic_loop_test.dart`
- `test/support/support_app_backup_loop_fixture.dart`
- `docs/ASTORIA_ASSISTANT_PLAN.md`

- `lib/features/support_assistant/widgets/support_memory_setup_sheet.dart`
- `lib/features/support_assistant/state/support_memory_setup_controller.dart`
- `lib/features/support_assistant/state/support_memory_setup_provider.dart`
- `lib/features/support_assistant/services/memory_setup/`
- `lib/core/db/repositories/memory_book_setup_fence.dart`
- `lib/core/db/repositories/memory_book_setup_store.dart`
- `test/support/memory_setup/memory_setup_ui_chain_test.dart`
- `test/support/memory_setup/memory_setup_readiness_test.dart`
- `test/support/memory_setup/memory_setup_navigation_test.dart`
- `lib/features/chat/widgets/memory_sheet.dart`
- `test/support/memory_setup/memory_setup_controller_test.dart`
- `test/support/memory_setup/memory_setup_native_fixture.dart`
- `docs/ASTORIA_ASSISTANT_STATUS.md`

Machine-local detailed contracts/evidence remain under
`.slim/deepwork/astoria-assistant-sequential/`: `memory-wizard-contract.md`,
`memory-wizard-implementation.md`, `memory-wizard-root-result.md`, `progress.md`.
They are ignored local artifacts, not additional committed source files. Older
partial labels there do not override this resumed root delivery.

## Execution constraints

Use `CLAUDE.md`, `docs/WORKFLOW.md` and applicable UI/race/database rules.
The stalled old subagent was canceled; the neighboring root finished. Do not
rerun its launcher or create a duplicate writer. The user requested root-session
continuation for normal DCP, not another wizard subagent.

SDK: `Z:\GlazeProject\flutter\bin\flutter.bat`. Native checks are serial with
`--no-pub --concurrency=1`; per-process PATH prepend:
`C:\Program Files\Git\bin;C:\Program Files\Git\usr\bin;Z:\Android\Sdk\ndk\28.2.13676358\prebuilt\windows-x86_64\bin`.
The passing controller command additionally used `--timeout=20s --reporter=expanded`.
No source budget increases, assertion weakening, cosmetic lint-zero project or
repeated full verification. No GUI/device/live provider/user DB/prefs/operator-key
access, dependency/toolchain installation, reset or publishing is implied.
The report recipient is already provisioned; do not regenerate/read private keys.
