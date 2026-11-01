import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/chat_source_mutation_provider.dart';
import '../../../core/state/connection_revision_provider.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../chat/state/chat_native_owner_registry.dart';
import '../../memory/state/memory_book_revision_provider.dart';
import '../services/memory_setup/memory_setup_service.dart';
import '../services/support_connection_metadata_service.dart';
import 'support_model_dependencies.dart';
import 'support_native_provider.dart';

/// Loaded on a native entry gesture only. Captures all producers synchronously;
/// the service never resolves a replacement provider after an async boundary.
final supportMemorySetupFactoryProvider = Provider((ref) {
  var alive = true;
  ref.onDispose(() => alive = false);
  final controller = ref.watch(supportNativeConsentControllerProvider);
  final books = ref.watch(memoryBookRepoProvider);
  final chats = ref.watch(chatRepoProvider);
  final catalog = ref.watch(memoryCatalogRepoProvider);
  final api = ref.watch(apiConfigRepoProvider);
  final sources = ref.watch(chatSourceMutationRegistryProvider);
  final owners = ref.watch(chatNativeOwnerRegistryProvider);
  final journal = ref.watch(supportRepoProvider);
  final redactor = ref.watch(secretRedactorProvider);
  final redaction = ref.watch(secretRedactionCoordinatorProvider);
  final native = ref.watch(nativeProviderRuntimeProvider);
  final revisions = ref.watch(connectionRevisionRegistryProvider);
  final custody = ref.watch(supportModelDatabaseCustodyProvider);
  final prefs = ref.watch(sharedPreferencesProvider).value;
  final memory = ref.watch(memoryGlobalSettingsProvider.notifier);
  final pipeline = ref.watch(pipelineSettingsProvider.notifier);
  final bookRevision = ref.watch(memoryBookRevisionProvider.notifier);
  final metadata = SupportConnectionMetadataService(
    api,
    () => redaction.redactor,
    nativeMetadata: native?.credentialReader,
    nativeMetadataIsCurrent: () => alive && native?.isCurrent == true,
  );
  return ({required bool Function() uiCurrent}) => MemorySetupService(
    controller: controller,
    books: books,
    chats: chats,
    catalog: catalog,
    api: api,
    sources: sources,
    owners: owners,
    journal: journal,
    redactor: redactor,
    connections: revisions,
    originalCurrent: () =>
        alive &&
        uiCurrent() &&
        identical(redactor, redaction.redactor) &&
        (native == null || native.isCurrent),
    dbCurrent: () => custody.alive,
    preferences: prefs is TrackedSharedPreferences ? prefs : null,
    publishMemory: memory.publishNativeSaved,
    publishPipeline: pipeline.publishNativeSaved,
    loadConnectionMetadata: (current) => metadata.load(isCurrent: current),
    onBookChanged: (id) {
      if (!alive || !ref.mounted) return;
      ref.invalidate(memoryBookProvider(id));
      bookRevision.state++;
    },
  );
});
