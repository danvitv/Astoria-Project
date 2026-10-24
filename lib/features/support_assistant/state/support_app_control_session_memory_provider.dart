import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/card_rewriter/effective_canon_read_repository.dart';
import '../../../core/state/chat_source_mutation_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../memory/state/memory_active_drafts_provider.dart';
import '../../memory/state/memory_book_revision_provider.dart';
import '../models/support_app_action.dart';
import '../services/app_control/session_memory/session_memory_guard.dart';
import '../services/app_control/session_memory/support_app_canon_adapter.dart';
import '../services/app_control/session_memory/support_app_memory_adapter.dart';
import '../services/app_control/session_memory/support_app_session_diagnostics_adapter.dart';
import '../services/app_control/session_memory/support_app_sessions_adapter.dart';

/// Dedicated additive composition. The shared registry/provider is deliberately
/// untouched. No ChatNotifier build, recovery, preferences, vault or LLM graph.
final supportAppControlSessionMemoryProvider =
    Provider<List<SupportAppActionAdapter>>((ref) {
      final chats = ref.watch(chatRepoProvider);
      final books = ref.watch(memoryBookRepoProvider);
      final catalog = ref.watch(memoryCatalogRepoProvider);
      final guard = SessionMemoryGuard(
        ref.watch(chatSourceMutationRegistryProvider),
      );
      final canon = EffectiveCanonReadRepository(
        db: ref.watch(appDbProvider),
        characterRepo: ref.watch(characterRepoProvider),
        revisionRepo: ref.watch(characterRevisionRepoProvider),
        baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
        factRepo: ref.watch(characterKnowledgeFactRepoProvider),
        transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
        transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
        rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
      );
      return List<SupportAppActionAdapter>.unmodifiable([
        SupportAppSessionsAdapter(repo: chats, guard: guard),
        SupportAppMemoryAdapter(
          books: books,
          chats: chats,
          catalog: catalog,
          guard: guard,
          isDraftBusy: (id) =>
              !ref.mounted || ref.read(memoryActiveDraftsProvider).contains(id),
          onBookChanged: (id) {
            if (!ref.mounted) return;
            ref.invalidate(memoryBookProvider(id));
            ref.read(memoryBookRevisionProvider.notifier).state++;
          },
        ),
        SupportAppCanonAdapter(chats: chats, canon: canon, guard: guard),
        SupportAppSessionDiagnosticsAdapter(
          chats: chats,
          captures: ref.watch(llmRequestCaptureRepoProvider),
          catalog: catalog,
          checkpoints: ref.watch(sessionCanonCheckpointRepoProvider),
          reconciliation: ref.watch(ledgerReconciliationCheckpointRepoProvider),
          guard: guard,
        ),
      ]);
    });
