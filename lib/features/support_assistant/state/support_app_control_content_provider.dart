import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/time_helpers.dart';
import '../../personas/persona_list_provider.dart';
import '../../presets/preset_list_provider.dart';
import '../models/support_app_action.dart';
import '../services/app_control/content/support_content_mutation.dart';
import '../services/app_control/content/support_content_catalog_adapter.dart';
import '../services/app_control/content/support_character_control_adapter.dart';
import '../services/app_control/content/support_persona_control_adapter.dart';
import '../services/app_control/content/support_lorebook_control_adapter.dart';
import '../services/app_control/content/support_preset_control_adapter.dart';
import '../services/app_control/content/support_studio_preset_control_adapter.dart';
import '../services/app_control/content/support_studio_runtime_control_adapter.dart';
import '../services/app_control/native/support_native_content_port.dart';

export '../services/app_control/content/support_content_mutation.dart';

/// Reserved native composition input, NOT a model-controlled permission grant.
/// Existing-source changes fail fixed/unavailable until the original native run
/// supplies exact source fences. Never synthesize sourceAccess/read authority.
final supportAppControlContentMutationPortProvider =
    Provider<SupportContentMutationPort?>(
      (ref) => const SupportNativeContentPort(),
    );

/// Additive DI list; the shared registry/loop integrator owns composition.
/// No widget Ref, filesystem, credential hydration or default LLM graph here.
final supportAppControlContentAdaptersProvider =
    Provider<List<SupportAppActionAdapter>>((ref) {
      final characters = ref.watch(characterRepoProvider);
      final personas = ref.watch(personaRepoProvider);
      final lorebooks = ref.watch(lorebookRepoProvider);
      final presets = ref.watch(presetRepoProvider);
      final studio = ref.watch(studioPresetRepoProvider);
      var alive = true;
      ref.onDispose(() => alive = false);
      bool current() => alive && ref.mounted;
      final mutations = SupportContentMutation(
        isOwnerCurrent: current,
        sources: ref.watch(supportAppControlContentMutationPortProvider),
      );
      void refreshCharacters() {
        if (current()) ref.invalidate(charactersProvider);
      }

      void refreshPersonas() {
        if (current()) ref.invalidate(personaListProvider);
      }

      void refreshLorebooks() {
        if (current()) ref.invalidate(lorebooksProvider);
      }

      void refreshPresets() {
        if (!current()) return;
        ref.invalidate(presetListProvider);
        ref.invalidate(presetsListProvider);
      }

      void refreshStudio() {
        if (!current()) return;
        ref.invalidate(studioPresetListProvider);
        ref.invalidate(studioPresetProvider);
      }

      return List<SupportAppActionAdapter>.unmodifiable([
        SupportContentCatalogAdapter(
          characters: characters,
          personas: personas,
          lorebooks: lorebooks,
          presets: presets,
          studioPresets: studio,
        ),
        SupportCharacterControlAdapter(
          repo: characters,
          mutations: mutations,
          newId: generateId,
          clock: currentTimestampSeconds,
          refresh: refreshCharacters,
        ),
        SupportPersonaControlAdapter(
          repo: personas,
          mutations: mutations,
          newId: generateId,
          clock: currentTimestampSeconds,
          refresh: refreshPersonas,
        ),
        SupportLorebookControlAdapter(
          repo: lorebooks,
          mutations: mutations,
          newId: generateId,
          refresh: refreshLorebooks,
        ),
        SupportPresetControlAdapter(
          repo: presets,
          mutations: mutations,
          newId: generateId,
          clock: currentTimestampSeconds,
          refresh: refreshPresets,
        ),
        SupportStudioPresetControlAdapter(
          repo: studio,
          mutations: mutations,
          newId: generateId,
          clock: currentTimestampSeconds,
          refresh: refreshStudio,
        ),
        SupportStudioRuntimeControlAdapter(
          repo: studio,
          mutations: mutations,
          clock: currentTimestampSeconds,
          refresh: refreshStudio,
        ),
      ]);
    });
