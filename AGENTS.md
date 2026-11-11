See [`CLAUDE.md`](./CLAUDE.md) for the project conventions, and
[`docs/WORKFLOW.md`](./docs/WORKFLOW.md) for branching and PR rules.

Subagents, delegation, and parallel agent work are explicitly authorized for
this project without separate approval. Keep delegated work within the user's
request and project rules; delegation does not expand permissions or authorize
otherwise restricted actions. See the delegation guidance in `CLAUDE.md`.

## Local planning context

At the start of new project work, read
[`docs/untracked/MEMORY_CONSOLIDATION_PLAN.md`](./docs/untracked/MEMORY_CONSOLIDATION_PLAN.md)
when it exists. The user wants the next agent to see this pending memory
consolidation plan. It is intentionally untracked and may be absent in another
checkout. Reading it does not authorize implementation or override the current
request, accepted work, or project safety rules.

## Current delivery checkpoint (2026-11-11)

Work is currently on `feat/astoria-assistant`. The immediate goal is a usable
private dev preview, not completion of every planned subsystem. Do not restart
accepted work or expand the remaining backlog unless the maintainer asks for a
specific slice.

### Memory consolidation

- The ordinary Memory + Links path is implemented through review-ready drafts:
  durable jobs, app-scoped automatic execution and startup/resume recovery,
  shared model-budget planning, initial-scan backup, compact status/review UI,
  explicit acceptance, source-currentness fences and temporal safeguards.
- The completed automatic-flow checkpoint is `80148c05`; current follow-up HEAD
  also includes honest queue cancellation/status handling and scene-time / Ledger
  anti-transfer safeguards. Focused tests, scoped analysis and race review passed.
- This is locally delivery-ready, not device/provider quality proof. A live scan
  confirmed the worker and safety fences and exposed a v2 prompt/allocation bug:
  the response schema was underspecified and event IDs were not bound to their
  allocated sources. Both are now corrected, including collision-safe retry packs,
  but live provider re-validation remains pending. Failed v2 parser calls now keep
  a local-only diagnostic envelope with the exact request, raw response and parser
  error; the queue can copy it explicitly and warns that it contains private Memory
  Book text. AVD and a complete real-device scenario remain unrun; do not restart
  AVD implicitly.
- Event-registry cloud sync, cross-branch lineage, structured witness/language
  semantics and richer revision history remain later work. See the local
  `docs/untracked/MEMORY_CONSOLIDATION_PLAN.md` for the exact evidence and limits.

### Astoria Assistant

- The assistant is integrated, enabled and usable for a dev preview. Its native
  workspace, provider/model flow, guarded tool loop, one-switch application-data
  read consent, source navigation, Memory Books wizard, selected diagnostics,
  bounded app-control actions and encrypted support-report flow are implemented.
- The complete original product plan is not finished. Remaining scope includes
  broader application control, richer causal diagnostics, unfinished credential
  migration/legacy plaintext cleanup, and live provider/device validation.
- `docs/ASTORIA_ASSISTANT_STATUS.md` and
  `docs/ASTORIA_ASSISTANT_HANDOFF.md` contain capability boundaries and accepted
  evidence, but their dated reviewed-HEAD fields are historical snapshots. The
  branch history and this checkpoint take precedence for current repository state.

### Preview and distribution boundary

- Windows and Android may be built locally, and the private `Build (Branch)`
  workflow may build an unsigned iOS artifact. These are dev-channel builds.
- Do not distribute binaries to testers or enable Drive/Discord/Telegram delivery
  until `docs/ASTORIA_LICENSE_AUDIT.md` is cleared. Private build artifacts are not
  evidence of release rights, signing, installation or runtime acceptance.
