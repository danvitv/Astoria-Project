# Chat post-generation: background Card Evolution

## Foreground and background boundaries

The foreground chat pipeline still awaits canonical work: reconciliation (when
due), ordinary Ledger, and the existing required cleaner/extension/image stages.
Automatic Collector and Card/Lorebook Writer work no longer precedes ordinary
Ledger or holds the chat generation mutex. Unapproved rewrite proposals are not
canonical input required by the next turn.

A successful reconciliation reserves an Evolution job in the **same database
transaction** as its immutable reconciliation run. Only after commit does the
app-scoped worker wake. Jobs become eligible two seconds after reservation;
ordinary Ledger can run immediately. This stagger is not provider rate limiting.
The worker recovers pending and expired leased jobs on startup/resume. Automatic
execution is serialized; database ownership also prevents concurrent same-session
claims. The background card has its own exact-job Cancel, separate from Stop for
the current foreground turn.

Schema 144 adds the durable queue. Job identity binds the session, character,
exact reconciliation run and chain hash. Session deletion removes its jobs;
rebinding or invalidating a source makes unfinished work stale. Result writes
check source/lease/nonce and local cancellation inside their atomic transaction.
Cancellation during an awaited ownership check cannot commit a late proposal.

## Cadence and routing

- Collector cadence remains every three successful reconciliations.
- New automatic Writer batches consume five completed Collectors, starting after
  the delivered frontier. A historically delivered frontier of two advances to
  seven, not five. Existing two-Collector claims retain their saved recovery input.
- Collector, Card Writer and Lorebook Writer dependencies remain sequential.
  Parallelizing those calls requires a different proposal/checkpoint contract.
- Enqueued work captures the turn's model/settings. Credentials stay in memory;
  persisted routing uses fingerprints rather than keys or raw endpoints. Recovery
  after restart requires matching routing/settings; changed routing fails stale
  rather than silently executing old work with a new model. Credential rotation
  alone does not change the routing identity.
- Incompatible Collector journals fail closed and are preserved for explicit
  recovery; discovery never resets/deletes their observations.

## Ownership and review Apply

Apply is fenced at the command boundary against conflicting foreground work and
session selection, not merely disabled in the UI. Successful fork/rebind retires
only the loaded owner of the affected session. Explicit provider invalidation
cancels its captured transport owner without relying on a mounted Ref. User Stop
still performs durable transcript settlement before releasing foreground busy
state. Per-run status identity prevents older completion/watchdogs from clearing
a newer operation.

Collapsed Collector/Reconciler diagnostics are built lazily; job watches select
the current session. These changes are not evidence of device frame-time gains.

## Delivery limits

Evidence is synthetic: in-memory SQLite, fake model transports, lifecycle/race
regressions and migration tests. No live provider or device performance claim is
made. A production Apply deadlock has not been established. Shortening its pure
preparation work and moving large transformations to isolates remain separate
optimization work; this delivery does not complete the entire original plan.

Focused evidence includes `card_evolution_job_repo_test.dart` (including
143-to-144 migration), `card_evolution_worker_test.dart`,
`ledger_reconciliation_outbox_test.dart`, `card_rewrite_observation_pass_test.dart`,
`rewrite_apply_session_fence_test.dart`, `chat_provider_retirement_test.dart`,
and the ordinary migration entrypoint `flutter test test/db_migration_test.dart`.
The `db_migration_suite.dart` file is a shared registration helper, not an
independent test entrypoint. Existing send/Stop/regeneration, durable rewrite
Apply, timestamp, write-queue and historical writer-recovery regressions are
also part of the scoped verification; no full-suite or device acceptance is
implied by those checks.

`ledger_stage_background_evolution_test.dart` exercises actual automatic
`LedgerStage`, reconciliation commit/outbox, worker claim and ordinary Ledger.
It holds background execution admission after source validation and verifies
that foreground Ledger still finishes successfully. It does not simulate a
live Collector request or prove UI frame time/next-turn latency on a device.
