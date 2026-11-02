import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/memory_custom_api_credential_owner.dart';
import 'package:glaze_flutter/core/db/repositories/summary_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_custom_api_credentials_provider.dart';
import 'package:glaze_flutter/core/state/pipeline_settings_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/services/summary_generation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../credentials/fake_credential_storage.dart';
import '../support/helpers/support_mutation_journal_fixture.dart'
    show JournalControlledSql;
import '../support/memory_setup/memory_setup_preferences_backing.dart';
import 'native_provider_consumer_memory_fixture.dart';
import 'provider_setup_repo_fixture.dart' show ProviderMemoryDatabase;

const _key = 'SYNTHETIC_NATIVE_SUMMARY_KEY';
const _lateAlias = 'SYNTHETIC_LATE_SUMMARY_ALIAS';
const _url = 'https://synthetic.example/custom/exact-summary?tenant=1';
const _template = 'Recap {{char}}. {{previous_summary}}\n{{history}}';
const _previous = 'Established synthetic fact';
const _session = ChatSession(
  id: 'original-session',
  characterId: 'character',
  sessionIndex: 0,
  messages: [
    ChatMessage(id: 'm1', role: 'user', content: 'Say {{char}} literally'),
    ChatMessage(id: 'm2', role: 'system', content: 'Excluded system text'),
    ChatMessage(id: 'm3', role: 'assistant', content: 'Synthetic answer'),
  ],
);

typedef _Harness = ({
  NativeMemoryConsumerFixture fixture,
  ProviderContainer container,
  MemoryCustomApiCredentialOwner owner,
  SummaryRepo repo,
  ProviderMemoryDatabase db,
  JournalControlledSql sql,
  SummaryService service,
});

// Reuse the existing synthetic HTTP/isolation, vault callback storage, tracked
// preferences and memory SQLite fixtures. No new native channel or HTTP driver.
Future<void> _withSummary(Future<void> Function(_Harness) body) async {
  final isolation = NativeRoleplayIsolation();
  await isolation.run(() async {
    final f = NativeMemoryConsumerFixture(isolation);
    final sql = JournalControlledSql();
    final db = ProviderMemoryDatabase(
      NativeDatabase.memory().interceptWith(sql),
    );
    final repo = SummaryRepo(db);
    final initial = <String, Object>{
      'pipelineSettings': jsonEncode({
        'studioAgent': <String, dynamic>{},
        'memoryBookApi': {
          'generationSource': 'custom',
          'generationEndpoint': _url,
          'generationModel': 'synthetic-summary-model',
          'generationApiKey': '',
          'generationMaxTokens': 512,
          'generationTemperature': 0.2,
        },
      }),
    };
    SharedPreferences.setMockInitialValues(initial);
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = MemorySetupPreferencesBacking(
      initial,
    );
    ProviderContainer? container;
    MemoryCustomApiCredentialOwner? owner;
    try {
      final prefs = await TrackedSharedPreferences.getInstance();
      owner = MemoryCustomApiCredentialOwner(
        vault: CredentialVault(
          storage: FakeCredentialStorage(),
          buildChannel: 'dev',
        ),
        redaction: f.source.wire.core.redaction,
        originalPreferences: Future.value(prefs),
      );
      final service = SummaryService(
        repo,
        sources: f.source.sources,
        llm: AuxLlmClient(
          sources: f.source.sources,
          memoryCustomAdapterFactory: f.source.wire.adapter,
        ),
      );
      final character = characterByIdProvider(_session.characterId);
      final persona = effectivePersonaForChatProvider((
        charId: _session.characterId,
        sessionId: _session.id,
      ));
      isolation.allowed.addAll({
        pipelineSettingsProvider,
        sharedPreferencesProvider,
        memoryCustomApiLegacySourceProvider,
        memoryCustomApiCredentialOwnerProvider,
        secretRedactionCoordinatorProvider,
        summaryServiceProvider,
        summaryGenerationServiceProvider,
        trackerRepoProvider,
        character,
        persona,
        globalVarsProvider,
      });
      container = ProviderContainer(
        observers: [isolation],
        overrides: [
          appDbProvider.overrideWith((_) => isolation.block('default DB')),
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          memoryCustomApiLegacySourceProvider.overrideWithValue(owner.source),
          memoryCustomApiCredentialOwnerProvider.overrideWithValue(owner),
          secretRedactionCoordinatorProvider.overrideWithValue(
            f.source.wire.core.redaction,
          ),
          summaryServiceProvider.overrideWithValue(service),
          trackerRepoProvider.overrideWithValue(TrackerRepo(db)),
          character.overrideWithValue(
            const Character(id: 'character', name: 'Synthetic character'),
          ),
          persona.overrideWithValue(null),
          globalVarsProvider.overrideWith((_) => <String, String>{}),
        ],
      );
      await container.read(pipelineSettingsProvider.notifier).load();
      final api = container.read(pipelineSettingsProvider).memoryBookApi;
      final stored = await owner.setApiKey(
        _key,
        settings: api,
        isCurrent: () => true,
      );
      expect(stored.verifiedCommit, true);
      await repo.put(
        sessionId: _session.id,
        content: _previous,
        messageCount: 7,
        enabled: false,
        prompt: _template,
      );
      f.source.wire.contentType = 'application/json';
      f.source.wire.response = nativeTransportJson(
        'custom_chat_completion',
        text: 'Visible $_key $_lateAlias',
      );
      await body((
        fixture: f,
        container: container,
        owner: owner,
        repo: repo,
        db: db,
        sql: sql,
        service: service,
      ));
    } finally {
      sql.event = null;
      db.beforeOuterCommit = null;
      db.afterOuterCommit = null;
      container?.dispose();
      owner?.dispose();
      try {
        await f.close();
      } finally {
        try {
          await db.close();
        } finally {
          SharedPreferencesStorePlatform.instance = previousPlatform;
        }
      }
    }
  });
}

Future<String> _generate(_Harness h, {CancelToken? cancelToken}) =>
    h.fixture.own(
      h.container
          .read(summaryGenerationServiceProvider)
          .generate(
            charId: _session.characterId,
            session: _session,
            cancelToken: cancelToken,
          ),
    );

Future<String> _generateCore(
  _Harness h, {
  CancelToken? cancelToken,
  ApiConfig Function(ApiConfig)? changeConfig,
}) {
  final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
  // Deliberately independent of cancellation: the core API must carry its own
  // original token into dependent persistence, not trust the feature wrapper.
  final original = h.owner.capture(api, isCurrent: () => true);
  final config = ApiConfig(
    id: 'memory-slot-custom',
    endpoint: api.generationEndpoint,
    apiKey: '',
    model: api.generationModel,
    protocol: 'custom_chat_completion',
    maxTokens: api.generationMaxTokens ?? 0,
  );
  return h.fixture.own(
    h.service.generateSummary(
      sessionId: _session.id,
      history: _session.messages,
      customPrompt: _template,
      apiConfig: changeConfig?.call(config) ?? config,
      temperature: api.generationTemperature,
      memoryCustomApi: original,
      originalCustomRedactor: original.captureRedactor(),
      cancelToken: cancelToken,
    ),
  );
}

void main() {
  test(
    'actual keyless settings -> summary -> custom vault POST -> durable return',
    () => _withSummary((h) async {
      h.fixture.source.wire.core.redaction.registerSecret(_lateAlias);
      final result = await _generate(h);
      expect(result, startsWith('Visible'));
      expect(result, isNot(contains(_key)));
      expect(result, isNot(contains(_lateAlias)));
      expect(
        h.container
            .read(pipelineSettingsProvider)
            .memoryBookApi
            .generationApiKey,
        '',
      );
      expect(
        jsonEncode(h.container.read(pipelineSettingsProvider).toJson()),
        isNot(contains(_key)),
      );
      final row = (await h.repo.get(_session.id))!;
      expect(row.content, result);
      expect(row.messageCount, _session.messages.length);
      expect(row.enabled, false);
      expect(row.prompt, _template);
      final wire = h.fixture.source.wire.wires.single;
      expect(wire.uri, Uri.parse(_url));
      expect(wire.method, 'POST');
      expect(
        wire.headers.entries
            .singleWhere((e) => e.key.toLowerCase() == 'authorization')
            .value,
        'Bearer $_key',
      );
      expect(wire.body.toString(), isNot(contains(_key)));
      expect(wire.body['max_tokens'], 512);
      expect(wire.body['temperature'], 0.2);
      expect(wire.body['stream'], false);
      expect(
        wire.body.toString(),
        contains('Recap Synthetic character. $_previous'),
      );
      expect(wire.body.toString(), contains('Say {{char}} literally'));
      expect(wire.body.toString(), isNot(contains('Excluded system text')));
      expect(h.fixture.source.wire.legacy.requests, isEmpty);
      expect(h.fixture.source.repo.reads, 0);
    }),
  );

  for (final change in ['rotation', 'settings', 'retired owner', 'cancel']) {
    test(
      'held actual completion cannot persist or return after $change',
      () => _withSummary((h) async {
        final gate = h.fixture.newGate();
        h.fixture.source.wire.beforeResponse = gate.hold;
        final token = CancelToken();
        final pending = _generate(h, cancelToken: token);
        await h.fixture.waitUntilGateEntered(gate, pending);
        final pipeline = h.container.read(pipelineSettingsProvider);
        switch (change) {
          case 'rotation':
            await h.owner.setApiKey(
              'SYNTHETIC_ROTATED_SUMMARY_KEY',
              settings: pipeline.memoryBookApi,
              isCurrent: () => true,
            );
          case 'settings':
            await h.container
                .read(pipelineSettingsProvider.notifier)
                .save(
                  pipeline.copyWith(
                    memoryBookApi: pipeline.memoryBookApi.copyWith(
                      generationTemperature: 0.7,
                    ),
                  ),
                );
          case 'retired owner':
            h.owner.dispose();
          case 'cancel':
            token.cancel();
        }
        gate.release();
        await expectLater(
          pending,
          throwsA(
            anyOf(isA<CredentialVaultAdmissionDenied>(), isA<DioException>()),
          ),
        );
        expect((await h.repo.get(_session.id))?.content, _previous);
        expect(h.fixture.source.wire.wires.length, 1);
        expect(h.fixture.source.wire.legacy.requests, isEmpty);
      }),
    );
  }

  for (final change in ['rotation', 'retired owner', 'CURRENT alias']) {
    test(
      'actual dependent row SELECT rechecks $change before the summary write',
      () => _withSummary((h) async {
        final gate = h.fixture.newGate();
        var reads = 0;
        h.sql.event = (event) async {
          // Template and previous-summary reads precede the guarded repo read.
          if (event.startsWith('select:') &&
              event.contains('chat_summaries') &&
              ++reads == 3) {
            await gate.hold();
          }
        };
        final pending = _generate(h);
        await h.fixture.waitUntilGateEntered(gate, pending);
        if (change == 'rotation') {
          await h.owner.setApiKey(
            'SYNTHETIC_ROTATED_SUMMARY_KEY',
            settings: h.container.read(pipelineSettingsProvider).memoryBookApi,
            isCurrent: () => true,
          );
        } else if (change == 'retired owner') {
          h.owner.dispose();
        } else {
          h.fixture.source.wire.core.redaction.registerSecret(_lateAlias);
        }
        gate.release();
        if (change == 'CURRENT alias') {
          final result = await pending;
          expect(result, isNot(contains(_lateAlias)));
          expect((await h.repo.get(_session.id))?.content, result);
        } else {
          await expectLater(
            pending,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          expect((await h.repo.get(_session.id))?.content, _previous);
        }
      }),
    );
  }

  for (final boundary in ['actual write', 'before commit']) {
    test(
      'new CURRENT alias after $boundary rolls back, without a corrective write',
      () => _withSummary((h) async {
        var writes = 0;
        h.sql.event = (event) async {
          if (event.startsWith('insert:') && event.contains('chat_summaries')) {
            writes++;
            if (boundary == 'actual write') {
              h.fixture.source.wire.core.redaction.registerSecret(_lateAlias);
            }
          }
        };
        if (boundary == 'before commit') {
          h.db.beforeOuterCommit = () async {
            h.fixture.source.wire.core.redaction.registerSecret(_lateAlias);
          };
        }
        await expectLater(
          _generate(h),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect((await h.repo.get(_session.id))?.content, _previous);
        expect(writes, 1);
      }),
    );
  }

  test(
    'retirement after actual commit suppresses return without claiming rollback',
    () => _withSummary((h) async {
      h.db.afterOuterCommit = () async => h.owner.dispose();
      await expectLater(
        _generate(h),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect((await h.repo.get(_session.id))?.content, startsWith('Visible'));
    }),
  );

  test(
    'custom invocation cannot authorize a changed config or an ordinary native summary',
    () => _withSummary((h) async {
      final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
      final original = h.owner.capture(api, isCurrent: () => true);
      await expectLater(
        h.service.generateSummary(
          sessionId: _session.id,
          history: _session.messages,
          memoryCustomApi: original,
          temperature: api.generationTemperature,
          apiConfig: ApiConfig(
            id: 'memory-slot-custom',
            endpoint: '$_url&changed=1',
            apiKey: '',
            model: api.generationModel,
            protocol: 'custom_chat_completion',
            maxTokens: 512,
          ),
        ),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(h.fixture.source.wire.wires, isEmpty);
      await h.fixture.source.wire.store();
      await expectLater(
        h.service.generateSummary(
          sessionId: _session.id,
          history: _session.messages,
          apiConfig: h.fixture.source.wire.core.row,
        ),
        throwsA(isA<NativeProviderException>()),
      );
      expect(h.fixture.source.wire.wires, isEmpty);
      expect((await h.repo.get(_session.id))?.content, _previous);
    }),
  );

  for (final change in ['timeout', 'omit temperature']) {
    test(
      'direct custom summary rejects changed $change before request or write',
      () => _withSummary((h) async {
        await expectLater(
          _generateCore(
            h,
            changeConfig: (config) => change == 'timeout'
                ? config.copyWith(firstChunkTimeoutMs: 17)
                : config.copyWith(omitTemperature: true),
          ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(h.fixture.source.wire.wires, isEmpty);
        expect((await h.repo.get(_session.id))?.content, _previous);
      }),
    );
  }

  for (final boundary in [
    'dependent SELECT',
    'actual write',
    'before commit',
    'after commit',
  ]) {
    test(
      'direct core cancellation at $boundary fences persistence and settled publication',
      () => _withSummary((h) async {
        final token = CancelToken();
        final gate = h.fixture.newGate();
        var reads = 0;
        var writes = 0;
        h.sql.event = (event) async {
          if (event.startsWith('select:') &&
              event.contains('chat_summaries') &&
              ++reads == 2 &&
              boundary == 'dependent SELECT') {
            await gate.hold();
          }
          if (event.startsWith('insert:') && event.contains('chat_summaries')) {
            writes++;
            if (boundary == 'actual write') token.cancel();
          }
        };
        if (boundary == 'before commit')
          h.db.beforeOuterCommit = () async => token.cancel();
        if (boundary == 'after commit')
          h.db.afterOuterCommit = () async => token.cancel();
        final pending = _generateCore(h, cancelToken: token);
        if (boundary == 'dependent SELECT') {
          await h.fixture.waitUntilGateEntered(gate, pending);
          token.cancel();
          gate.release();
        }
        await expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        final row = (await h.repo.get(_session.id))!;
        if (boundary == 'after commit') {
          expect(row.content, startsWith('Visible'));
        } else {
          expect(row.content, _previous);
        }
        expect(writes, boundary == 'dependent SELECT' ? 0 : 1);
        expect(row.enabled, false);
        expect(row.prompt, _template);
        expect(h.fixture.source.wire.wires, hasLength(1));
        expect(h.fixture.source.wire.legacy.requests, isEmpty);
      }),
    );
  }
}
