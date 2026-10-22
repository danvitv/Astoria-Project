import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/dev_mode_provider.dart';
import 'package:glaze_flutter/features/catalog/catalog_provider.dart';
import 'package:glaze_flutter/features/catalog/chub_account_provider.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/features/personas/persona_list_provider.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

enum EntryDataState { data, loading, error }

class EntrySettings extends AppSettingsNotifier {
  EntrySettings(this.showPicks);
  final bool showPicks;
  @override
  Future<AppSettings> build() async =>
      AppSettings(showOurPicks: showPicks, batterySaver: true);
}

class EntryCharacters extends CharactersNotifier {
  EntryCharacters(this.fixtures, this.mode);
  final List<Character> fixtures;
  final EntryDataState mode;
  @override
  Future<List<Character>> build() => switch (mode) {
    EntryDataState.data => Future.value(fixtures),
    EntryDataState.loading => Completer<List<Character>>().future,
    EntryDataState.error => Future.error(StateError('Synthetic library error')),
  };
  @override
  Future<int> backfillMissingAvatarThumbnails() async => 0;

  void show(EntryDataState next) {
    state = switch (next) {
      EntryDataState.data => AsyncData(fixtures),
      EntryDataState.loading => const AsyncLoading(),
      EntryDataState.error => AsyncError(
        StateError('Synthetic filtered library error'),
        StackTrace.current,
      ),
    };
  }
}

class EntryInfinite extends InfiniteCharactersNotifier {
  EntryInfinite(super.arg, this.fixtures, this.mode);
  final List<Character> fixtures;
  final EntryDataState mode;
  @override
  Future<InfiniteCharactersState> build() => switch (mode) {
    EntryDataState.data => Future.value(
      InfiniteCharactersState(
        items: fixtures,
        totalCount: fixtures.length,
        loadedLimit: fixtures.length,
      ),
    ),
    EntryDataState.loading => Completer<InfiniteCharactersState>().future,
    EntryDataState.error => Future.error(StateError('Synthetic page error')),
  };
}

// Implement, never extend: production constructors restore/search immediately.
class EntryCatalog extends StateNotifier<CatalogState>
    implements CatalogNotifier {
  EntryCatalog(this.block) : super(const CatalogState(hasMore: false));
  final Never Function(String) block;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('catalog command ${invocation.memberName}');
}

class EntryTheme extends StateNotifier<ThemeSettings> implements ThemeNotifier {
  EntryTheme(this.block)
    : super(
        const ThemeSettings(
          activePreset: ThemePreset(
            id: 'synthetic-entry',
            name: 'Synthetic',
            elementBlur: 0,
            noiseOpacity: 0,
            bgNoiseOpacity: 0,
          ),
        ),
      );
  final Never Function(String) block;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('theme command ${invocation.memberName}');
}

class EntryCatalogDisabled extends CatalogEnabledNotifier {
  @override
  bool build() => false;
}

class EntryThirdPartiesDisabled extends ThirdPartyProvidersNotifier {
  @override
  Set<ThirdPartyProvider> build() => ThirdPartyProvider.values.toSet();
}

class EntryAnonymousChub extends ChubAccountNotifier {
  @override
  ChubAccount build() => const ChubAccount();
}

class EntryHistory extends ChatHistoryNotifier {
  @override
  Future<List<ChatSessionInfo>> build() async => const [];
}

class EntryPersonas extends PersonaListNotifier {
  @override
  Future<List<Persona>> build() async => const [];
}

class EntryPresets extends PresetListNotifier {
  @override
  Future<List<Preset>> build() async => const [];
}

class EntryDevDisabled extends DevModeNotifier {
  @override
  bool build() => false;
}

class EntryRedactor extends SecretRedactorNotifier {
  EntryRedactor(this.value);
  final SecretRedactor value;
  @override
  SecretRedactor build() => value;
}

/// Render-only state. Topic constructor forwarding, not state/permissions proof.
class EntryWorkspace extends SupportWorkspaceNotifier {
  EntryWorkspace(this.onBuild);
  final void Function() onBuild;
  final topics = <String>[];
  @override
  SupportWorkspaceState build() {
    onBuild();
    return SupportWorkspaceState(
      sessions: [
        SupportSessionSummary(
          id: 'synthetic-entry-session',
          title: 'Synthetic offline guide',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
      activeSessionId: 'synthetic-entry-session',
      messagesBySession: const {},
      settings: const SupportAssistantSettings(),
      isLoading: false,
    );
  }

  @override
  void applyInitialTopic(String? topic) {
    if (topic != null) topics.add(topic);
  }
}
