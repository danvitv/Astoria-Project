# Ledger instruction ownership

Ledger extraction policy belongs to the editable **Studio preset**, not to
runtime prompt suffixes. This includes NPC initialization, durability,
relationships, knowledge, clock reasoning, and condition lifecycle. Ordinary
and legacy turn paths use the same preset authority.

The runtime owns context assembly, wire schema, supported keys and enums,
validation, focal-user ownership, provenance, cancellation and safe persistence.
The schema is not an extraction policy or a source of invented facts.

## Editable phases

| Phase | Required instruction | Optional policy |
|---|---|---|
| Turn | `ledger_system` | `ledger_shared_policy`, `ledger_turn_policy` |
| Reconciliation | `ledger_reconciliation_prompt` | `ledger_shared_policy`, `ledger_reconciliation_policy` |
| Output format repair | `ledger_output_repair` | None |
| Cleanup format repair | `ledger_cleanup_repair` | None |

These are direct instruction blocks routed to `ledger`, without an agent
target, group-boundary behavior, or append-to-last-message behavior. Folder
enablement still applies. Missing, blank, disabled, duplicate or misrouted
required instructions fail rather than silently falling back to hidden policy.
Disabled optional policies are not injected or regenerated.

Repair instructions cannot relax deterministic repair validation. A format
repair must still preserve the supplied literal evidence. Reconciliation still
cannot create new knowledge facts or change the clock.

## Existing presets

There is **no automatic upgrade on ordinary preset reads or application start**.
Fresh presets contain editable defaults and instruction revision 1. Existing
presets require the explicit consolidation action in the Studio preset editor.

The action first saves pending edits, previews the added blocks and warnings,
then asks for confirmation. Existing authored blocks are preserved; missing
shared, transferred and repair policies are appended in a new enabled group.
Custom primary text is not semantically rewritten, so conflicting old text
needs manual review. Disabled or misrouted existing primaries remain so and are
reported, not silently repaired.

Apply checks the entire raw persisted row against the confirmed preview inside
a transaction. A concurrent change, including an unknown raw JSON field,
invalidates the preview. Only block additions, the instruction revision marker,
and the update timestamp change. Agents, API slots and unrelated settings do not.
After revision 1, deleting or disabling a policy is an authored edit, not a
reason to grow it back.

Seed text in `ledger_preset_instruction_defaults.dart` is used only to create
or explicitly upgrade preset data. Runtime prompt assembly never imports it as
a fallback. Live model compliance is separate from deterministic routing and
persistence checks.
