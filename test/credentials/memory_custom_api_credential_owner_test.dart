import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/memory_custom_api_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/memory_custom_api_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/memory_custom_api_credentials_provider.dart';
import 'package:glaze_flutter/core/state/pipeline_settings_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Existing mock backend seam, not real preferences or platform channels.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../core/native_provider_consumer_roleplay_isolation.dart';
import '../support/memory_setup/memory_setup_preferences_backing.dart';
import 'fake_credential_storage.dart';

const _legacy = 'SYNTHETIC_MEMORY_LEGACY_KEY';
const _native = 'SYNTHETIC_MEMORY_NATIVE_KEY';
final _slot = CredentialSlot(domain: 'memory.custom_api', id: 'native');
Map<String, dynamic> _document({String key = _legacy}) => {
  'studioAgent': <String, dynamic>{},
  'memoryBookApi': {
    'generationSource': 'custom',
    'generationEndpoint': 'https://synthetic.example/exact/operation?tenant=1',
    'generationModel': 'synthetic-model',
    'generationApiKey': key,
    'futurePrivate': {'opaque': 'SYNTHETIC_OPAQUE_VALUE'},
  },
  'futureRoot': {'enabled': true},
};

Future<void> _withPreferences(
  Future<void> Function(
    TrackedSharedPreferences prefs,
    MemorySetupPreferencesBacking backing,
    FakeCredentialStorage storage,
    CredentialVault vault,
    SecretRedactionCoordinator redaction,
    MemoryCustomApiCredentialOwner owner,
  )
  body, {
  Map<String, dynamic>? document,
}) async {
  final isolation = NativeRoleplayIsolation();
  await isolation.run(() async {
    final initial = <String, Object>{
      'pipelineSettings': jsonEncode(document ?? _document()),
      'memorySettings': jsonEncode({
        'generationApiKey': 'SYNTHETIC_HISTORY_NOT_A_SOURCE',
      }),
    };
    SharedPreferences.setMockInitialValues(initial);
    final previous = SharedPreferencesStorePlatform.instance;
    final backing = MemorySetupPreferencesBacking(initial);
    SharedPreferencesStorePlatform.instance = backing;
    final storage = FakeCredentialStorage();
    final vault = CredentialVault(storage: storage, buildChannel: 'dev');
    final redaction = SecretRedactionCoordinator();
    MemoryCustomApiCredentialOwner? owner;
    try {
      final prefs =
          await TrackedSharedPreferences.getInstance()
              as TrackedSharedPreferences;
      owner = MemoryCustomApiCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: Future.value(prefs),
      );
      await body(prefs, backing, storage, vault, redaction, owner);
    } finally {
      owner?.dispose();
      redaction.dispose();
      SharedPreferencesStorePlatform.instance = previous;
    }
  });
}

void main() {
  test(
    'original import binds exact route, leaves raw JSON/history untouched',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      final raw = prefs.getString('pipelineSettings');
      final summary = await owner.load();
      expect(summary.configured, true);
      final record = jsonDecode(storage.values.values.single) as Map;
      expect(
        record['endpoint'],
        _document()['memoryBookApi']['generationEndpoint'],
      );
      expect(record['protocol'], 'custom-chat-completion');
      expect(record['key'], _legacy);
      expect(prefs.getString('pipelineSettings'), raw);
      expect(backing.values['flutter.pipelineSettings'], raw);
      expect(redaction.redactor.redactText(_legacy), '[REDACTED]');
      expect(summary.toString(), isNot(contains(_legacy)));
    }),
  );

  test(
    'explicit entry covers raw/trimmed aliases; empty is verified tombstone',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      final settings = MemoryCustomApiLegacySource.settings(_document());
      final pending = owner.setApiKey(
        '  $_native  ',
        settings: settings,
        isCurrent: () => true,
      );
      expect(
        redaction.redactor.redactText('  $_native  '),
        isNot(contains(_native)),
      );
      expect(redaction.redactor.redactText(_native), '[REDACTED]');
      expect((await pending).verifiedCommit, true);
      final cleared = await owner.setApiKey(
        '',
        settings: settings,
        isCurrent: () => true,
      );
      expect(cleared.verifiedCommit, true);
      expect(cleared.configured, false);
      expect(storage.values.values.single, '');
      expect((await owner.load()).configured, false);
      expect(prefs.getString('pipelineSettings'), contains(_legacy));
      await expectLater(
        owner
            .capture(settings, isCurrent: () => true)
            .withApiKey<void>(
              (key, guard) async => fail('No tombstone fallback'),
            ),
        throwsA(isA<CredentialVaultException>()),
      );
    }),
  );

  for (final record in ['', 'SYNTHETIC_CORRUPT_RECORD']) {
    test(
      'native ${record.isEmpty ? 'empty' : 'corrupt'} is not absence',
      () => _withPreferences((
        prefs,
        backing,
        storage,
        vault,
        redaction,
        owner,
      ) async {
        await vault.store(_slot, record);
        final writes = storage.operations
            .where((value) => value == 'write')
            .length;
        final summary = await owner.load();
        expect(summary.configured, false);
        expect(summary.unavailable, record.isNotEmpty);
        expect(
          storage.operations.where((value) => value == 'write').length,
          writes,
        );
        expect(storage.values.values.single, record);
      }),
    );
  }

  test(
    'failed secure read never falls back to plaintext',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      storage.readError = StateError(_legacy);
      expect((await owner.load()).unavailable, true);
      expect(storage.operations, isNot(contains('write')));
      expect(storage.values, isEmpty);
    }),
  );

  test(
    'actual-slot absence read plus queued keyless backup refuses import',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeRead = () async {
        if (storage.reads == 2) {
          entered.complete();
          await release.future;
        }
      };
      final load = owner.load();
      await entered.future;
      final backup = prefs.setString(
        'pipelineSettings',
        jsonEncode(_document(key: '')),
      );
      release.complete();
      expect((await load).unavailable, true);
      await backup;
      expect(storage.operations, isNot(contains('write')));
      expect(storage.values, isEmpty);
      expect((await owner.load()).configured, false);
    }),
  );

  test(
    'ordinary leaf save preserves unknown and raw private fields',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      final isolation = NativeRoleplayIsolation();
      isolation.allowed.addAll({
        pipelineSettingsProvider,
        sharedPreferencesProvider,
        memoryCustomApiLegacySourceProvider,
        secretRedactionCoordinatorProvider,
      });
      final container = ProviderContainer(
        observers: [isolation],
        overrides: [
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          memoryCustomApiLegacySourceProvider.overrideWithValue(owner.source),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        ],
      );
      try {
        final notifier = container.read(pipelineSettingsProvider.notifier);
        await notifier.load();
        final before = container.read(pipelineSettingsProvider);
        expect(before.memoryBookApi.generationApiKey, '');
        expect(before.toJson().toString(), isNot(contains(_legacy)));
        await notifier.save(
          before.copyWith(
            memoryBookApi: before.memoryBookApi.copyWith(
              generationTemperature: 0.3,
            ),
          ),
        );
        final saved = jsonDecode(prefs.getString('pipelineSettings')!) as Map;
        expect(saved['futureRoot'], _document()['futureRoot']);
        expect(
          saved['memoryBookApi']['futurePrivate'],
          _document()['memoryBookApi']['futurePrivate'],
        );
        expect(saved['memoryBookApi']['generationApiKey'], _legacy);
        expect(saved['memoryBookApi']['generationTemperature'], 0.3);
        expect(
          container
              .read(pipelineSettingsProvider)
              .memoryBookApi
              .generationApiKey,
          '',
        );
        expect(storage.operations, isEmpty);
      } finally {
        container.dispose();
      }
    }),
  );

  test(
    'route edits cannot make preserved plaintext acquire a new binding',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      const patch = {
        'memoryBookApi': {
          'generationEndpoint': 'https://synthetic.example/other',
        },
      };
      final denied = await owner.source.savePipeline(
        patch,
        isCurrent: () => true,
        hasNativeRecord: owner.hasNativeRecord,
      );
      expect(denied.status, MemoryCustomApiWriteStatus.denied);
      expect(prefs.getString('pipelineSettings'), jsonEncode(_document()));
    }),
  );

  test(
    'verified native key remains bound when ordinary destination changes',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      expect((await owner.load()).configured, true);
      final saved = await owner.source.savePipeline(
        {
          'memoryBookApi': {
            'generationEndpoint': 'https://synthetic.example/other',
          },
        },
        isCurrent: () => true,
        hasNativeRecord: owner.hasNativeRecord,
      );
      expect(saved.status, MemoryCustomApiWriteStatus.verified);
      expect((await owner.load()).configured, false);
      final settings = MemoryCustomApiLegacySource.settings(
        jsonDecode(prefs.getString('pipelineSettings')!) as Map<String, dynamic>,
      );
      await expectLater(
        owner
            .capture(settings, isCurrent: () => true)
            .withApiKey<void>((key, check) async => fail('No route rebind')),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(
        jsonDecode(storage.values.values.single)['endpoint'],
        _document()['memoryBookApi']['generationEndpoint'],
      );
    }),
  );

  for (final outcome in ['false', 'throw']) {
    test(
      'invoked ordinary $outcome-after-persist reports unknown, not denied',
      () => _withPreferences((
        prefs,
        backing,
        storage,
        vault,
        redaction,
        owner,
      ) async {
        if (outcome == 'false') backing.rejected = 'flutter.pipelineSettings';
        if (outcome == 'throw') backing.thrown = 'flutter.pipelineSettings';
        final result = await owner.source.savePipeline({
          'memoryBookApi': {'generationTemperature': 0.4},
        }, isCurrent: () => true);
        expect(result.status, MemoryCustomApiWriteStatus.unknown);
        expect(result.receipt, isNull);
        expect(backing.values['flutter.pipelineSettings'], contains('0.4'));
        expect(backing.values['flutter.pipelineSettings'], contains(_legacy));
      }),
    );
  }

  test(
    'verified secure write survives retired owner as a fact, not a denial',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeWrite = () async {
        entered.complete();
        await release.future;
      };
      final pending = owner.setApiKey(
        _native,
        settings: MemoryCustomApiLegacySource.settings(_document()),
        isCurrent: () => true,
      );
      await entered.future;
      owner.dispose();
      release.complete();
      final summary = await pending;
      expect(summary.verifiedCommit, true);
      expect(summary.retired, true);
      expect(summary.unknownCommit, false);
      expect(jsonDecode(storage.values.values.single)['key'], _native);
    }),
  );

  test(
    'native readback failure after persistence reports unknown, not rollback',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      storage.beforeWrite = () async {
        storage.readError = StateError(_native);
      };
      final summary = await owner.setApiKey(
        _native,
        settings: MemoryCustomApiLegacySource.settings(_document()),
        isCurrent: () => true,
      );
      expect(summary.unknownCommit, true);
      expect(summary.verifiedCommit, false);
      expect(jsonDecode(storage.values.values.single)['key'], _native);
      expect(prefs.getString('pipelineSettings'), contains(_legacy));
    }),
  );

  test(
    'verified ordinary write with retired caller remains a verified fact',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      var current = true;
      backing.beforeWrite = (_) async {
        current = false;
      };
      final result = await owner.source.savePipeline({
        'memoryBookApi': {'generationTemperature': 0.6},
      }, isCurrent: () => current);
      expect(result.status, MemoryCustomApiWriteStatus.verifiedRetired);
      expect(result.ordinary, isNull);
      expect(backing.values['flutter.pipelineSettings'], contains('0.6'));
      expect(backing.values['flutter.pipelineSettings'], contains(_legacy));
    }),
  );

  test(
    'flat ordinary patches preserve original private and unknown leaves',
    () => _withPreferences(
      (prefs, backing, storage, vault, redaction, owner) async {
        final result = await owner.source.savePipeline({
          'memoryBookApi': {'generationTemperature': 0.2},
        }, isCurrent: () => true);
        expect(result.status, MemoryCustomApiWriteStatus.verified);
        final saved = jsonDecode(prefs.getString('pipelineSettings')!);
        expect(saved['generationApiKey'], _legacy);
        expect(saved['unknown'], {'private': 'SYNTHETIC_FLAT_PRIVATE'});
        expect(saved['memoryBookApi']['generationApiKey'], _legacy);
        expect(saved['memoryBookApi']['unknown'], {
          'private': 'SYNTHETIC_FLAT_PRIVATE',
        });
        expect(saved['memoryBookApi']['generationTemperature'], 0.2);
      },
      document: {
        'generationSource': 'custom',
        'generationEndpoint': 'https://synthetic.example/exact',
        'generationModel': 'synthetic-model',
        'generationApiKey': _legacy,
        'unknown': {'private': 'SYNTHETIC_FLAT_PRIVATE'},
      },
    ),
  );

  test(
    'retained producer never renews against an equal replacement store',
    () => _withPreferences((
      prefs,
      backing,
      storage,
      vault,
      redaction,
      owner,
    ) async {
      await owner.load();
      SharedPreferences.setMockInitialValues({
        'pipelineSettings': jsonEncode(_document()),
      });
      await TrackedSharedPreferences.getInstance();
      expect(owner.source.captureSettings().current, false);
      expect((await owner.load()).unavailable, true);
    }),
  );
}
