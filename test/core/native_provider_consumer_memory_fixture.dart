import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/persona_repo.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_regex.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/state/studio_regex_provider.dart';
import 'package:glaze_flutter/features/chat/memory_draft_generator.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

import 'native_provider_consumer_roleplay_isolation.dart';
import 'native_provider_source_fixture.dart';

export 'native_provider_consumer_roleplay_isolation.dart';
export 'native_provider_source_fixture.dart';

/// Real typed provider reads over a finite, pre-overridden synthetic graph.
/// No default DB, preferences, plugin, app initialization or real adapter.
final class NativeMemoryConsumerFixture {
  NativeMemoryConsumerFixture(this.isolation) {
    character = NativeMemorySyntheticCharacterRepo();
    isolation.allowed.addAll({
      apiConfigRepoProvider,
      apiListProvider,
      activeApiConfigProvider,
      characterRepoProvider,
      presetRepoProvider,
      personaRepoProvider,
      activePresetIdProvider,
      activePersonaIdProvider,
      presetConnectionsProvider,
      personaConnectionsProvider,
      globalRegexProvider,
      studioRegexProvider,
      globalVarsProvider,
      memoryGlobalSettingsProvider,
    });
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        appDbProvider.overrideWith((_) => isolation.block('default DB')),
        sharedPreferencesProvider.overrideWith(
          (_) => isolation.block('preferences'),
        ),
        apiConfigRepoProvider.overrideWithValue(_SyntheticApiRepo(source.repo)),
        apiListProvider.overrideWith(_SyntheticApiList.new),
        activeApiConfigProvider.overrideWith(
          (ref) => ref.read(apiListProvider).value?.single,
        ),
        characterRepoProvider.overrideWithValue(character),
        presetRepoProvider.overrideWithValue(_SyntheticPresetRepo()),
        personaRepoProvider.overrideWithValue(_SyntheticPersonaRepo()),
        activePresetIdProvider.overrideWith((_) => null),
        activePersonaIdProvider.overrideWith((_) => null),
        presetConnectionsProvider.overrideWith(
          (_) => const PresetConnections(),
        ),
        personaConnectionsProvider.overrideWith(
          (_) => const PersonaConnections(),
        ),
        globalRegexProvider.overrideWith(_SyntheticGlobalRegex.new),
        studioRegexProvider.overrideWith(_SyntheticStudioRegex.new),
        globalVarsProvider.overrideWith((_) => <String, String>{}),
        memoryGlobalSettingsProvider.overrideWith(
          MemoryGlobalSettingsNotifier.new,
        ),
      ],
    );
    llm = AuxLlmClient(
      sources: source.sources,
      purpose: NativeProviderPurpose.memoryBooks,
      transportPicker: source.wire.factory.pick,
    );
  }

  final NativeRoleplayIsolation isolation;
  final source = NativeSourceConsumerFixture();
  late final NativeMemorySyntheticCharacterRepo character;
  late final ProviderContainer container;
  late final AuxLlmClient llm;
  final _gates = <NativeSourceHeldGate>[];
  final _pending = <Future<void>>[];

  set beforeApiRead(Future<void> Function()? callback) {
    source.repo.beforeRead = callback;
  }

  NativeSourceHeldGate newGate() {
    final gate = NativeSourceHeldGate();
    _gates.add(gate);
    return gate;
  }

  Future<void> waitUntilGateEntered<T>(
    NativeSourceHeldGate gate,
    Future<T> job,
  ) => Future.any<void>([
    gate.entered.future,
    job.then<void>(
      (_) => throw StateError('Memory job completed before entering its gate'),
    ),
  ]);

  Future<T> own<T>(Future<T> future) {
    _pending.add(
      future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return future;
  }

  Future<void> close() async {
    source.runCurrent = false;
    for (final gate in _gates) {
      gate.release();
    }
    try {
      await Future.wait(_pending);
      expect(source.wire.adapters.every((adapter) => adapter.closed), isTrue);
    } finally {
      try {
        container.dispose();
      } finally {
        source.wire.core.mutations.dispose();
        source.wire.core.redaction.dispose();
      }
    }
  }

  MemoryDraftGenerator generator() => MemoryDraftGenerator.settings(
    read: container.read,
    llm: llm,
    sources: source.sources,
    isCurrent: () =>
        source.runCurrent && source.sessionId == 'original-session',
  );
}

final class _SyntheticApiRepo implements ApiConfigRepo {
  _SyntheticApiRepo(this.saved);
  final NativeSourceFakeApiRepo saved;
  @override
  Future<List<ApiConfig>> getAll() => saved.getAll();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Undeclared synthetic API operation');
}

final class _SyntheticApiList extends ApiListNotifier {
  @override
  Future<List<ApiConfig>> build() => ref.read(apiConfigRepoProvider).getAll();
}

final class _SyntheticGlobalRegex extends GlobalRegexNotifier {
  @override
  Future<List<PresetRegex>> build() async => [];
}

final class _SyntheticStudioRegex extends StudioRegexNotifier {
  @override
  Future<List<StudioRegex>> build() async => [];
}

final class NativeMemorySyntheticCharacterRepo implements CharacterRepo {
  int reads = 0;
  Future<void> Function()? beforeRead;
  @override
  Future<Character?> getById(String id) async {
    reads++;
    await beforeRead?.call();
    return Character(id: id, name: 'Synthetic character');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Undeclared synthetic character operation');
}

final class _SyntheticPresetRepo implements PresetRepo {
  @override
  Future<List<Preset>> getAll() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Undeclared synthetic preset operation');
}

final class _SyntheticPersonaRepo implements PersonaRepo {
  @override
  Future<List<Persona>> getAll() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Undeclared synthetic persona operation');
}
