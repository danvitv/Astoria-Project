import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_read_port.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/support_automatic_sources_fixture.dart';

export 'helpers/support_automatic_sources_fixture.dart';
export 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
export 'package:glaze_flutter/core/preferences/saved_preferences_read_port.dart';
export 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';

const preferencesCanaries = [
  'PREF_LEGACY_MEMORY_SECRET',
  'PREF_PIPELINE_SECRET',
  'PREF_HEADER_SECRET',
  'PREF_PARAMETER_SECRET',
  'PREF_DISABLED_SECRET',
  'PREF_NESTED_SECRET',
  'PREF_VARIABLE_SECRET',
  'PREF_PRIVATE_SELECTION_ID',
];
const preferenceNeedles = {
  'savedMemoryPreferences': 'memory preference needle',
  'savedPipelinePreferences': 'pipeline preference needle',
  'savedRegexPreferences': 'regex preference needle',
  'savedSelectionPreferences': 'reference',
  'savedGlobalVariables': 'global variable needle',
};

Map<String, Object> syntheticSavedPreferences() => {
  'memorySettings': jsonEncode({
    'enabled': false,
    'memoryMode': 'deep',
    'generationApiKey': preferencesCanaries[0],
    'generationEndpoint':
        'https://user:PREF_ENDPOINT_SECRET@example.invalid?key=PRIVATE',
    'customPrompts': [
      {
        'key': 'custom_memory',
        'label': 'Saved prompt',
        'prompt': 'memory preference needle',
        'headers': {'Authorization': preferencesCanaries[2]},
      },
    ],
  }),
  'pipelineSettings': jsonEncode({
    'studioAgent': {
      'studioFinalExtraRequestParameters': [
        {'key': 'temperature', 'value': '0.42', 'enabled': true},
        {
          'key': 'authorization',
          'value': preferencesCanaries[3],
          'enabled': true,
        },
        {'key': 'headers', 'value': preferencesCanaries[4], 'enabled': false},
      ],
    },
    'cleaner': {
      'postCleanerStyleInstructions': 'pipeline preference needle',
      'postCleanerAvoidInstructions': jsonEncode({
        'prompt': 'inert text',
        'headers': {'X-Custom': preferencesCanaries[5]},
      }),
    },
    'memoryBookApi': {
      'generationApiKey': preferencesCanaries[1],
      'generationEndpoint':
          'https://user:PREF_ENDPOINT_SECRET@example.invalid?token=PRIVATE',
    },
  }),
  'gz_global_regex_scripts': jsonEncode([
    {
      'id': 'private-regex-id',
      'name': 'Saved disabled regex',
      'regex': 'regex preference needle',
      'replacement': '<script>inert()</script>',
      'disabled': true,
      'headers': {'X-Custom': preferencesCanaries[2]},
    },
  ]),
  'gz_studio_regex_scripts': jsonEncode([
    {
      'stages': ['cleaner', 'final'],
      'script': {
        'id': 'private-studio-regex-id',
        'name': 'Studio inert',
        'regex': 'studio regex saved',
        'replacement': '<script>noRun()</script>',
      },
    },
  ]),
  'activeApiConfigId': preferencesCanaries[7],
  'activeEmbeddingConfigId': preferencesCanaries[7],
  'activePresetId': 'private-ordinary-selection',
  'activeStudioPresetId': 'private-studio-selection',
  'activePersonaId': 'private-persona-selection',
  'active_preset_id': 'private-legacy-selection',
  'feature_studio_enabled': false,
  'presetConnections': jsonEncode({
    'character': {'private-character': 'private-ordinary-selection'},
  }),
  'personaConnections': jsonEncode({
    'chat': {'private-chat': 'private-persona-selection'},
  }),
  'globalVars': jsonEncode({
    'authored dotted variable': 'global variable needle',
    'apiKey': preferencesCanaries[6],
  }),
  'glaze.global_variables': jsonEncode({
    'scene': {'name': 'extension global saved'},
    'headers': {'X-Custom': preferencesCanaries[6]},
  }),
};

/// Reuses the existing genuine FILE/native ROOT/AEAD/scripted POST fixture.
/// Only the preferences injection is new; no grant, ROOT or DB is fabricated.
Future<void> savedPreferencesModelTest(
  Future<void> Function(AutomaticSourcesFixture, SharedPreferences) body, {
  Map<String, Object>? saved,
  bool grant = true,
  bool Function()? producerCurrent,
  void Function()? onPreferencesStoreInitialized,
}) async {
  final f = AutomaticSourcesFixture();
  late SharedPreferences prefs;
  await HttpOverrides.runZoned(
    () => IOOverrides.runWithIOOverrides(() async {
      try {
        await f.initialize(
          grant: grant,
          preferencesFactory: () async {
            SharedPreferences.setMockInitialValues(
              saved ?? syntheticSavedPreferences(),
            );
            onPreferencesStoreInitialized?.call();
            prefs = await TrackedSharedPreferences.getInstance();
            final original = Future<SharedPreferences>.value(prefs);
            return SavedPreferencesReadPort(
              original: original,
              loaded: prefs,
              producerCurrent: () =>
                  f.native.rootCurrent && (producerCurrent?.call() ?? true),
            );
          },
        );
        await body(f, prefs);
      } finally {
        await f.close();
      }
    }, f.io),
    createHttpClient: (_) => f.io.block('HTTP/socket'),
  );
}

Future<void> preferencesEncryptedBeforePost(
  AutomaticSourcesFixture f,
  int count,
) async {
  final rows = await f.native.repo.getMessagesForSession(f.native.session);
  final reply = rows.lastWhere((m) => m.role == 'assistant');
  final block = await f.native.repo.getContextBlockById(
    'support.reply_provenance:${reply.id}',
  );
  expect(block, isNotNull);
  final recipe = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
    block!.protectedFactsJson,
  ).recipe!;
  expect(recipe.toolDisclosures, hasLength(count));
  final outward = jsonEncode(f.wire);
  for (final disclosure in recipe.toolDisclosures!) {
    expect(disclosure.snapshotDigest, isNotEmpty);
    expect(outward, isNot(contains(disclosure.snapshotDigest)));
  }
}

void noPreferencesSecrets(AutomaticSourcesFixture f) {
  final wire = jsonEncode(f.wire);
  for (final secret in [
    ...preferencesCanaries,
    'PREF_ENDPOINT_SECRET',
    'private-regex-id',
    'private-studio-regex-id',
    'private-ordinary-selection',
    'private-studio-selection',
    'private-persona-selection',
    'private-legacy-selection',
    'private-character',
    'private-chat',
  ]) {
    expect(wire, isNot(contains(secret)));
  }
}
