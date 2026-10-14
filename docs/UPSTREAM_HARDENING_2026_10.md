# Selective Glaze hardening — October 2026

Astoria adaptations, not a wholesale upstream merge. Source: the merged PR
diffs in [hydall/Glaze](https://github.com/hydall/Glaze).

## Included

| Area | Upstream PRs | Astoria adaptation |
| --- | --- | --- |
| Database | #602, #673 | Local schema 136; install declared indexes and integrity triggers after historical migrations; allow only one immutable-capture NULL-to-message binding. |
| Character cards | repository portion of #619 | V2 depth prompt/depth/role/world round-trip; extension-only imports survive, explicit editor clearing removes fallbacks. |
| Backups | #684 | Default keyless export, explicit remembered opt-in; audited credentials and URL authentication omitted; local refill requires identity and proven matching destinations. |
| Chat | #556, #627, #662, #507 | Stable scaffold body; prepend/first-measure anchoring; attachments survive editing; only terminal WebView failures end the editor; bounded loopback image retries. |
| API/context | #622, #645, #629, #649 | Output-budget cap and ordinary-generation fit checks before send/swipe mutations and again before transport; context boundary after newest when empty; protocol normalization and stale model-fetch guards; mobile IME Enter stays a newline. |
| Extension blocks | #607, #611, #672 | Ordered context items, persona-description macro, prompt/display regexes, image-path reduction, and observed timeout completion errors. Current swipe/agent-swipe and completed-block filtering retained. |
| Cloud sync | #667 | Read the existing key-sharing preference on automatic/conflict pushes; snapshot API upload bytes and hash; cloud inclusion flag changes only after an API upload; whitelist-based chat layout transfer. |
| Images | #537 | Tokenless ComfyUI conditioning injection without replacing Astoria's default graph or negative prompt. |
| Janitor | #676 | Conservative local saturation detection, at most 16 fresh-chat passes, splitting and deduplicated lore/field-diff recovery. |

## Preserved and deliberately excluded

- Existing Stop claims, durable write queue/publication ownership, drafts,
  suffix-only deletion, Ledger/canon audit history and sync convergence remain.
- Studio, Agent Ops and manual Rewrite remain available. Their independent
  budgets are not rejected against the ordinary chat preset.
- Already-adapted fixes are not reapplied. No NoAssistant, new tokenizer,
  desktop/window redesign, Linux WebView dependency upgrade, 120-second default
  or default-disabled streaming is introduced.
- The existing o200k tokenizer and saved Enter-to-send preference remain.

## Review boundaries and operational notes

- Required unique indexes fail closed if old duplicate keys prevent creation.
  Rows and the previous schema version survive; recovery must be explicit,
  never an automatic destructive deduplication.
- Keyless backups are **not anonymized**. Free text, immutable audit payloads
  and unknown custom credential formats are not searched. Missing or ambiguous
  routing/account identity requires reauthentication rather than guessing.
  Global credential overrides are not automatically refilled when their runtime
  destination cannot be established.
- Janitor's server tokenizer is not added. Saturation uses o200k plus a
  conservative character estimate and margin; this is not a guarantee that all
  possible lore was recovered. Failed extra passes retain previous captures;
  diagnostics record failures and the pass limit.
- Synthetic SQLite/archive/provider/transport and real Chromium tests cover
  automated behavior. They do not prove native Android IME behavior, native
  WebView recreation, or live Janitor/cloud account behavior.
- After changing WebView assets, perform a **hot restart**, not hot reload.
  Before release, smoke-test Android keyboard input, background/session changes,
  long-chat history loading, keyless restore and the intended cloud-key toggle.

## Verification

- Verified on October 14, 2026; full analyzer: no issues.
- Flutter corpus: 4,831 passed, 14 skipped, covered in two portions because
  the server restart interrupted the first run after 4,215 successful tests.
  The remaining portion passed 616 tests; affected final-review files were
  checked separately after their last edits.
- Migration corpus: 74 tests passed. One v113 fixture exceeded the 30-second
  timeout during the loaded run; its isolated retry passed without code changes.
- Chromium WebView regression corpus: 154 tests passed.
- Provider/transport regression checks include rejected send, regenerate and
  continue without transcript/draft changes, and Stop during budget preflight.
- Python bug-triage checks cannot start in the available environments because
  their dependencies are missing; no dependency installations were performed.
