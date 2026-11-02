import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/models/database_maintenance.dart';
import '../../../core/state/chat_source_mutation_provider.dart';
import '../../../core/state/character_folder_provider.dart';
import '../../../core/state/preset_folder_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../chat/state/chat_native_owner_registry.dart';
import '../../memory/state/memory_native_entry_owner.dart';
import '../models/support_app_action.dart';
import '../services/app_control/native/support_native_domain_adapter.dart';
import '../services/app_control/native/support_native_domain_sources.dart';
import '../services/app_control/native/support_native_repair_discovery.dart';
import '../services/app_control/native/support_native_session_title_adapter.dart';
import '../services/app_control/native/support_native_memory_entry_adapter.dart';
import '../services/app_control/native/support_native_active_selection_adapter.dart';
import '../services/app_control/native/support_native_global_regex_adapter.dart';
import 'support_app_control_native_global_regex_owner.dart';
import 'support_app_control_native_selection_owner.dart';
import 'support_app_control_content_provider.dart';
import 'support_app_control_session_memory_provider.dart';
import 'support_app_control_secondary_provider.dart';
import 'support_app_control_repair_provider.dart';
import 'support_app_control_native_repair_provider.dart';

/// Actual original native graph, captured once by the existing model factory.
/// No default database, vault hydration, preference startup or replacement chat.
final supportAppNativeDomainAdaptersProvider =
    Provider<List<SupportAppActionAdapter>>((ref) {
      final native = ref.watch(nativeProviderRuntimeProvider);
      if (native == null) return const [];
      final chats = ref.watch(chatRepoProvider);
      final characters = ref.watch(characterRepoProvider);
      final presets = ref.watch(presetRepoProvider);
      final studio = ref.watch(studioPresetRepoProvider);
      final folders = ref.watch(characterFolderRepoProvider);
      final presetFolders = ref.watch(presetFolderRepoProvider);
      final refresh = ref.watch(supportAppNativeRepairPortProvider);
      final sources = SupportNativeDomainSources(
        mutations: ref.watch(chatSourceMutationRegistryProvider),
        owners: ref.watch(chatNativeOwnerRegistryProvider),
        isOriginalOwnerCurrent: () => ref.mounted && native.isCurrent,
        maintenance: refresh.maintenance,
      );
      final repair = ref.watch(supportAppControlRepairAdaptersProvider);
      final titles = SupportNativeSessionTitleAdapter(
        support: ref.watch(supportRepoProvider),
        sources: sources,
      );
      ref.onDispose(titles.dispose);
      final memoryEntries = SupportNativeMemoryEntryAdapter(
        originContainer: ref.container,
        support: ref.watch(supportRepoProvider),
        sources: sources,
        owners: ref.watch(memoryNativeEntryOwnerRegistryProvider),
      );
      ref.onDispose(memoryEntries.dispose);
      final selections = SupportNativeActiveSelectionAdapter(
        support: ref.watch(supportRepoProvider),
        personas: ref.watch(personaRepoProvider),
        presets: presets,
        chats: chats,
        sources: sources,
        ports: captureSupportNativeSelections(
          ref,
          () => ref.mounted && native.isCurrent,
        ),
      );
      ref.onDispose(selections.dispose);
      final regex = SupportNativeGlobalRegexAdapter(
        support: ref.watch(supportRepoProvider),
        chats: chats,
        sources: sources,
        port: captureSupportNativeGlobalRegex(
          ref,
          () => ref.mounted && native.isCurrent,
        ),
      );
      ref.onDispose(regex.dispose);
      SupportNativeRepairDiscovery? discovery;
      if (repair.length == 2 &&
          repair[0] is SupportAppIntegrityAdapter &&
          repair[1] is SupportAppSessionRepairAdapter) {
        discovery = SupportNativeRepairDiscovery(
          integrity: repair[0] as SupportAppIntegrityAdapter,
          sessions: repair[1] as SupportAppSessionRepairAdapter,
          chats: chats,
          databaseTargets: () async {
            bool current() => ref.mounted && native.isCurrent;
            final cards = await characters.getAll();
            if (!current()) return const [];
            final targets = <DatabaseMaintenanceTarget>[
              for (final card in cards)
                if (card.variantGroupId.isEmpty)
                  DatabaseMaintenanceTarget.characterGroup(card.id),
            ];
            final members = await folders.getAllMembers();
            if (!current()) return const [];
            final ids = cards.map((c) => c.id).toSet();
            for (final member in members) {
              if (!ids.contains(member.charId)) {
                targets.add(
                  DatabaseMaintenanceTarget.characterMembership(
                    characterId: member.charId,
                    folderId: member.folderId,
                  ),
                );
              }
            }
            final memberships = await presetFolders.watchMembers().first;
            if (!current()) return const [];
            for (final member in memberships) {
              if (member.kind != 'normal' && member.kind != 'agentic') continue;
              final missing = member.kind == 'normal'
                  ? await presets.getById(member.presetId) == null
                  : await studio.getById(member.presetId) == null;
              if (!current()) return const [];
              if (missing) {
                targets.add(
                  DatabaseMaintenanceTarget.presetMembership(
                    presetId: member.presetId,
                    folderId: member.folderId,
                    presetKind: member.kind == 'normal'
                        ? DatabaseMaintenancePresetKind.normal
                        : DatabaseMaintenancePresetKind.agentic,
                  ),
                );
              }
            }
            return targets;
          },
        );
      }
      return List.unmodifiable([
        for (final adapter in [
          titles,
          memoryEntries,
          selections,
          regex,
          ...ref.watch(supportAppControlContentAdaptersProvider),
          ...ref.watch(supportAppControlSessionMemoryProvider),
          ...ref.watch(supportAppControlSecondaryAdaptersProvider),
          if (discovery != null) discovery else ...repair,
        ])
          SupportNativeDomainAdapter(
            adapter: adapter,
            chats: chats,
            sources: sources,
            repairSession: discovery?.targetSession,
            refreshSession: refresh.refreshSession,
          ),
      ]);
    });
