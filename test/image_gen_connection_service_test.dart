import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/image_routmy_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_routmy_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_connection_service.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_dispatcher.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_http.dart';
import 'package:glaze_flutter/features/image_gen/services/routmy_image_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'credentials/fake_credential_storage.dart';

// Same synthetic Dio adapter pattern as the credential consumer fixtures. No
// listening socket, real preference backend, OS vault, probe or paid request.
final class _RoutmyAdapter implements HttpClientAdapter {
  _RoutmyAdapter(this.reply);
  final FutureOr<({int status, String body})> Function(RequestOptions) reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = await reply(options);
    return ResponseBody.fromString(
      response.body,
      response.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// Same synthetic plugin producer seam as the native credential owner tests.
// A failed ordinary write may still alter the plugin's in-memory cache.
final class _FailedImageSettingsBacking extends SharedPreferencesStorePlatform {
  _FailedImageSettingsBacking(Map<String, Object> initial)
    : values = {
        for (final entry in initial.entries)
          'flutter.${entry.key}': entry.value,
      };
  final Map<String, Object> values;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
  @override
  Future<bool> remove(String key) async => false;
  @override
  Future<bool> clear() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('native rout.my image credential integration', () {
    const legacy = 'SYNTHETIC_IMAGE_ROUTMY_LEGACY';
    const native = 'SYNTHETIC_IMAGE_ROUTMY_NATIVE';
    const standalone = 'SYNTHETIC_IMAGE_ROUTMY_STANDALONE';
    const settingsKey = ImageRoutmyLegacySource.settingsKey;
    const standaloneKey = ImageRoutmyLegacySource.standaloneKey;
    const settings = ImageGenSettings(apiType: ImageGenApiType.routmy);
    final slot = CredentialSlot(domain: 'image.routmy', id: 'native');
    late TrackedSharedPreferences prefs;
    late FakeCredentialStorage storage;
    late CredentialVault vault;
    late SecretRedactionCoordinator redaction;
    late Dio dio;
    late _RoutmyAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        settingsKey: jsonEncode({
          'apiType': 'routmy',
          'routmyApiKey': legacy,
          'ruRoutmyApiKey': 'SYNTHETIC_RETIRED_RU',
          'naisteraApiKey': 'SYNTHETIC_OTHER_PROVIDER',
          'futureSetting': {'keep': true},
          'routmyMirror': 'global',
        }),
        standaloneKey: standalone,
        'unrelatedPreference': 'keep',
      });
      prefs =
          (await TrackedSharedPreferences.getInstance())
              as TrackedSharedPreferences;
      storage = FakeCredentialStorage();
      vault = CredentialVault(storage: storage, buildChannel: 'dev');
      redaction = SecretRedactionCoordinator();
      adapter = _RoutmyAdapter(
        (_) => (
          status: 200,
          body: jsonEncode({
            'data': [
              {
                'id': 'gpt-image-fixture',
                'endpoints': ['/v1/images/edits'],
              },
            ],
          }),
        ),
      );
      dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close());
      addTearDown(redaction.dispose);
    });

    ImageRoutmyCredentialOwner owner() {
      final value = ImageRoutmyCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: Future.value(prefs),
      );
      addTearDown(value.dispose);
      return value;
    }

    test(
      'model list imports only image key and retains all plaintext',
      () async {
        final original = prefs.getString(settingsKey);
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: owner(),
        );
        final models = await service.fetchRoutmyModels(
          settings.copyWith(
            routmyApiKey: 'SYNTHETIC_STALE_SETTINGS_KEY',
            useSameEndpoint: true,
            customEndpoint: 'https://untrusted.invalid',
          ),
        );
        expect(models.single.id, 'gpt-image-fixture');
        expect(
          adapter.requests.single.uri.toString(),
          'https://api.rout.my/v1/models',
        );
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $legacy',
        );
        expect(adapter.requests.single.followRedirects, isFalse);
        expect(prefs.getString(settingsKey), original);
        expect(prefs.getString(standaloneKey), standalone);
        expect(storage.values.length, 1);
      },
    );

    test(
      'native replacement is verified metadata only and never auto-probes',
      () async {
        final credentials = owner();
        final original = prefs.getString(settingsKey);
        final summary = await credentials.setApiKey(native);
        expect(summary.configured, isTrue);
        expect(summary.unavailable, isFalse);
        expect(adapter.requests, isEmpty);
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: credentials,
        );
        await service.fetchRoutmyModels(settings);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
        expect(prefs.getString(settingsKey), original);
        expect(prefs.getString('unrelatedPreference'), 'keep');
      },
    );

    test(
      'successful model catalog omits raw and encoded echoed credentials before DTO/save',
      () async {
        const key = 'SYNTHETIC_IMAGE_MODEL:KEY/+%?';
        final credentials = owner();
        await credentials.setApiKey(key);
        dio.httpClientAdapter = _RoutmyAdapter(
          (_) => (
            status: 200,
            body: jsonEncode({
              'data': [
                {'id': 'gpt-image-$key', 'name': 'Bad raw ID'},
                {
                  'id': 'gpt-image-${Uri.encodeComponent(key)}',
                  'name': 'Bad encoded ID',
                },
                {'id': 'gpt-image-raw-name', 'name': key},
                {
                  'id': 'gpt-image-encoded-name',
                  'name': Uri.encodeComponent(key),
                },
                {
                  'id': 'openai/gpt-image-2',
                  'name': 'GPT Image 2',
                  'endpoints': ['/v1/images/edits'],
                },
                {
                  'id': 'google/gemini-3.1-flash-image-preview',
                  'name': 'Gemini Image',
                },
              ],
            }),
          ),
        );
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: credentials,
        );
        final models = await service.fetchRoutmyModels(settings);
        expect(models.map((model) => model.id), [
          'openai/gpt-image-2',
          'google/gemini-3.1-flash-image-preview',
        ]);
        expect(models.first.name, 'GPT Image 2');
        expect(models.first.supportsEdits, isTrue);
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(container.dispose);
        final loaded = await container.read(imageGenSettingsProvider.future);
        await container
            .read(imageGenSettingsProvider.notifier)
            .save(loaded.copyWith(routmyModels: models));
        final persisted =
            (jsonDecode(prefs.getString(settingsKey)!) as Map)['routmyModels'];
        expect(jsonEncode(persisted), isNot(contains(key)));
        expect(
          jsonEncode(persisted),
          isNot(contains(Uri.encodeComponent(key))),
        );
        expect((persisted as List), hasLength(2));
      },
    );

    test(
      'late current sink aliases cannot enter ordinary image model persistence',
      () async {
        const later = 'SYNTHETIC_LATE_MODEL:KEY/+%?';
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(container.dispose);
        final loaded = await container.read(imageGenSettingsProvider.future);
        final original = prefs.getString(settingsKey);
        final current = SecretRedactionCoordinator()..registerSecret(later);
        addTearDown(current.dispose);
        final previousSink = activeErrorRedactor;
        activeErrorRedactor = current.redactor;
        addTearDown(() => activeErrorRedactor = previousSink);
        await expectLater(
          container
              .read(imageGenSettingsProvider.notifier)
              .save(
                loaded.copyWith(
                  routmyModels: [
                    RoutmyModelInfo(
                      id: 'gpt-image-fixture',
                      name: Uri.encodeComponent(later),
                    ),
                  ],
                ),
              ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(prefs.getString(settingsKey), original);
        expect(
          container.read(imageGenSettingsProvider).value!.routmyModels,
          isEmpty,
        );
      },
    );

    test(
      'invoked secure replacement stays a verified commit when an overlapping ordinary save fails',
      () async {
        final initial = Map<String, Object>.fromEntries(
          prefs.getKeys().map((key) => MapEntry(key, prefs.get(key)!)),
        );
        SharedPreferences.setMockInitialValues(initial);
        final previousBackend = SharedPreferencesStorePlatform.instance;
        SharedPreferencesStorePlatform.instance = _FailedImageSettingsBacking(
          initial,
        );
        addTearDown(
          () => SharedPreferencesStorePlatform.instance = previousBackend,
        );
        prefs =
            (await TrackedSharedPreferences.getInstance())
                as TrackedSharedPreferences;
        final credentials = owner();
        final container = ProviderContainer(
          overrides: [
            imageRoutmyCredentialOwnerProvider.overrideWithValue(credentials),
          ],
        );
        addTearDown(container.dispose);
        await container.read(imageRoutmyAuthProvider.future);
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        storage.beforeWrite = () async {
          entered.complete();
          await release.future;
        };
        final pending = container
            .read(imageRoutmyAuthProvider.notifier)
            .setApiKey(native);
        await entered.future;
        final ordinary = credentials.source.saveSettings({
          'enabled': true,
        }, isCurrent: () => true);
        await expectLater(
          ordinary,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        release.complete();
        await pending;
        final summary = container.read(imageRoutmyAuthProvider).value!;
        expect(summary.configured, isTrue);
        expect(summary.unavailable, isFalse);
        expect(summary.preferencesChanged, isTrue);
        expect(credentials.isCurrentSummary(summary), isTrue);
        expect(storage.values.values.single, native);
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'verified native empty tombstone prevents every legacy fallback',
      () async {
        final credentials = owner();
        expect((await credentials.setApiKey('')).configured, isFalse);
        final reloaded = owner();
        expect((await reloaded.load()).configured, isFalse);
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: reloaded,
        );
        await expectLater(
          service.fetchRoutmyModels(settings),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(adapter.requests, isEmpty);
        expect(prefs.getString(standaloneKey), standalone);
        expect(await vault.hasStoredValue(slot), isTrue);
      },
    );

    test(
      'RU legacy codec fallback binds only the actual RU native mirror',
      () async {
        await prefs.setString(
          settingsKey,
          jsonEncode({
            'apiType': 'ruRoutmy',
            'routmyApiKey': '',
            'ruRoutmyApiKey': legacy,
          }),
        );
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: owner(),
        );
        await expectLater(
          service.fetchRoutmyModels(settings),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await service.fetchRoutmyModels(
          settings.copyWith(routmyMirror: RoutMyMirror.ru),
        );
        expect(adapter.requests.single.uri.host, 'ru-api.rout.my');
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $legacy',
        );
      },
    );

    test(
      'standalone imports only when no higher-priority JSON candidate exists',
      () async {
        await prefs.setString(settingsKey, jsonEncode({'apiType': 'routmy'}));
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: owner(),
        );
        await service.fetchRoutmyModels(settings);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $standalone',
        );
      },
    );

    test(
      'present empty JSON prevents historic standalone resurrection',
      () async {
        await prefs.setString(settingsKey, jsonEncode({'routmyApiKey': ''}));
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: owner(),
        );
        await expectLater(
          service.fetchRoutmyModels(settings),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(adapter.requests, isEmpty);
        expect(await vault.hasStoredValue(slot), isTrue);
      },
    );

    test(
      'failed secure read never sends plaintext or anonymous HTTP',
      () async {
        storage.readError = StateError('SYNTHETIC_SECURE_FAILURE');
        final credentials = owner();
        expect((await credentials.load()).unavailable, isTrue);
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: credentials,
        );
        await expectLater(
          service.fetchRoutmyModels(settings),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(adapter.requests, isEmpty);
        expect(storage.operations, isNot(contains('write')));
      },
    );

    test(
      'native dropped write cannot report the submitted key configured',
      () async {
        storage.dropWrites = true;
        final credentials = owner();
        await expectLater(
          credentials.setApiKey(native),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(storage.values, isEmpty);
        expect(adapter.requests, isEmpty);
      },
    );

    for (final gateImage in [false, true]) {
      for (final reload in [false, true]) {
        test(
          'fifth private tail reserves ${reload ? 'reload' : 'clear'} before later ${gateImage ? 'Chub' : 'image'} writer',
          () async {
            final gate = Completer<void>();
            final blocked = gateImage
                ? SavedPreferencesWrites.serializeImageRoutmy(() => gate.future)
                : SavedPreferencesWrites.serializeChub(() => gate.future);
            final Future<void> whole = reload
                ? prefs.reload()
                : prefs.clear().then<void>(
                    (accepted) => expect(accepted, isTrue),
                  );
            final key = gateImage
                ? PrivatePreferenceKeys.chubApiKey
                : settingsKey;
            final next = gateImage
                ? 'SYNTHETIC_NEWER_CHUB_BACKUP'
                : jsonEncode({
                    'routmyApiKey': 'SYNTHETIC_NEWER_IMAGE_BACKUP',
                    'futureSetting': 'newer settings must survive',
                  });
            final later = prefs.setString(key, next);
            try {
              await Future<void>.delayed(Duration.zero);
              expect(prefs.get(key), isNot(next));
              gate.complete();
              await blocked;
              await whole;
              expect(await later, isTrue);
              expect(prefs.get(key), next);
            } finally {
              if (!gate.isCompleted) gate.complete();
              await blocked;
              await whole;
              await later;
            }
          },
        );
      }
    }

    test(
      'generic saved JSON CAS cannot write either native image source',
      () async {
        for (final key in ImageRoutmyLegacySource.keys) {
          await prefs.setInt(
            key,
            7,
          ); // A denial must precede a typed string getter.
          final lease = prefs.store.owner.capture([key], store: prefs.store);
          final denied = await prefs.compareAndSetString(
            key: key,
            expectedRaw: 'not a credential snapshot',
            value: 'forbidden replacement',
            expected: lease,
            isCurrent: () => true,
          );
          expect(denied.started, isFalse);
          expect(denied.accepted, isFalse);
          expect(denied.receipt, isNull);
          expect(prefs.get(key), 7);
          expect(SavedPreferencesKeys.all, isNot(contains(key)));
        }
        expect(SavedPreferencesKeys.families, hasLength(5));
      },
    );

    test(
      'settings provider strips only rout.my and preserves JSON on ordinary save',
      () async {
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(container.dispose);
        final loaded = await container.read(imageGenSettingsProvider.future);
        expect(loaded.routmyApiKey, isEmpty);
        expect(loaded.naisteraApiKey, 'SYNTHETIC_OTHER_PROVIDER');
        await container
            .read(imageGenSettingsProvider.notifier)
            .save(loaded.copyWith(enabled: true));
        final saved = jsonDecode(prefs.getString(settingsKey)!) as Map;
        expect(saved['routmyApiKey'], legacy);
        expect(saved['ruRoutmyApiKey'], 'SYNTHETIC_RETIRED_RU');
        expect(saved['futureSetting'], {'keep': true});
        expect(saved['naisteraApiKey'], 'SYNTHETIC_OTHER_PROVIDER');
        expect(
          container.read(imageGenSettingsProvider).value!.routmyApiKey,
          isEmpty,
        );
        expect(adapter.requests, isEmpty);
        expect(await vault.hasStoredValue(slot), isTrue);
      },
    );

    test(
      'original pre-await source revision cannot adopt changed backing data',
      () async {
        final original = Completer<SharedPreferences>();
        final credentials = ImageRoutmyCredentialOwner(
          vault: vault,
          redaction: redaction,
          originalPreferences: original.future,
        );
        addTearDown(credentials.dispose);
        final pending = credentials.load();
        await prefs.setString(standaloneKey, 'SYNTHETIC_BACKUP_REPLACEMENT');
        original.complete(prefs);
        expect((await pending).unavailable, isTrue);
        expect(storage.operations, isNot(contains('write')));
      },
    );

    test(
      'in-flight old vault write settles but only newest native setter publishes',
      () async {
        final credentials = owner();
        final entered = Completer<void>();
        final release = Completer<void>();
        storage.beforeWrite = () async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final old = credentials.setApiKey(legacy);
        final oldDenied = expectLater(
          old,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final newest = credentials.setApiKey(native);
        release.complete();
        await oldDenied;
        expect((await newest).configured, isTrue);
        expect(storage.values.values.single, native);
      },
    );

    test(
      'same-vault native owners fence older admitted setter publication',
      () async {
        final first = owner();
        final second = owner();
        final entered = Completer<void>();
        final release = Completer<void>();
        storage.beforeWrite = () async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final old = first.setApiKey(legacy);
        final denied = expectLater(
          old,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final newest = second.setApiKey(native);
        release.complete();
        await denied;
        expect((await newest).configured, isTrue);
        expect(storage.values.values.single, native);
      },
    );

    test(
      'rotation during model HTTP rejects late catalog publication',
      () async {
        final credentials = owner();
        final response = Completer<({int status, String body})>();
        final entered = Completer<void>();
        dio.httpClientAdapter = _RoutmyAdapter((_) {
          entered.complete();
          return response.future;
        });
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: credentials,
        );
        final pending = service.fetchRoutmyModels(settings);
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        await credentials.setApiKey(native);
        response.complete((
          status: 200,
          body: '{"data":[{"id":"gpt-image-late"}]}',
        ));
        await denied;
      },
    );

    test(
      'consumer error loses raw and encoded secret even with retired redactor',
      () async {
        final credentials = owner();
        const encodedCanary = 'SYNTHETIC:KEY/+%?';
        await credentials.setApiKey(encodedCanary);
        Object? observed;
        try {
          await credentials.withApiKey<void>(
            origin: RoutMyConstants.baseUrl,
            consume: (key, check) async {
              redaction.dispose();
              throw StateError('$key ${Uri.encodeComponent(key)}');
            },
          );
        } catch (error) {
          observed = error;
        }
        expect(observed, isA<StateError>());
        expect(observed.toString(), isNot(contains(encodedCanary)));
        expect(
          observed.toString(),
          isNot(contains(Uri.encodeComponent(encodedCanary))),
        );
      },
    );

    test(
      'live coordinator A error uses original and actual B sink including late aliases',
      () async {
        const keyA = 'SYNTHETIC_ORIGINAL_A:KEY/+%?';
        const keyB = 'SYNTHETIC_CURRENT_B:KEY/+%?';
        const lateB = 'SYNTHETIC_LATE_B:KEY/+%?';
        final credentials = owner();
        await credentials.setApiKey(keyA);
        final current = SecretRedactionCoordinator()..registerSecret(keyB);
        addTearDown(current.dispose);
        final previousSink = activeErrorRedactor;
        activeErrorRedactor = redaction.redactor;
        addTearDown(() => activeErrorRedactor = previousSink);
        final entered = Completer<void>();
        final response = Completer<({int status, String body})>();
        dio.httpClientAdapter = _RoutmyAdapter((_) {
          entered.complete();
          return response.future;
        });
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: credentials,
        );
        final pending = service.checkConnection(
          settings: settings,
          llmEndpoint: '',
          llmApiKey: '',
        );
        final denied = expectLater(
          pending,
          throwsA(
            predicate((error) {
              final text = error.toString();
              return text.contains('HTTP 400') &&
                  [keyA, keyB, lateB].every(
                    (key) =>
                        !text.contains(key) &&
                        !text.contains(Uri.encodeComponent(key)),
                  );
            }),
          ),
        );
        await entered.future;
        current.registerSecret(lateB);
        activeErrorRedactor = current.redactor; // A deliberately remains alive.
        response.complete((
          status: 400,
          body: jsonEncode({
            'error': {
              'message': [
                keyA,
                keyB,
                lateB,
              ].map((key) => '$key ${Uri.encodeComponent(key)}').join(' '),
            },
          }),
        ));
        await denied;
        expect(redaction.redactor.redactText('public'), 'public');
      },
    );

    test(
      'actual dispatcher omits long punctuated and encoded task canaries without slicing',
      () async {
        final key = 'SYNTHETIC_TASK_/+%?${List.filled(160, 'X').join()}';
        final credentials = owner();
        await credentials.setApiKey(key);
        dio.httpClientAdapter = _RoutmyAdapter(
          (_) => (
            status: 200,
            body: jsonEncode({
              'status': Uri.encodeComponent(key),
              'task_id': key,
              'object': 'image.generation.task',
            }),
          ),
        );
        final dispatcher = ImageGenDispatcher(
          routmyCredentials: credentials,
          routmyClientFactory: (origin, check) => RoutmyImageProvider(
            baseUrl: origin,
            checkCurrent: check,
            http: ImageGenHttp(dio: dio),
          ),
        );
        await expectLater(
          dispatcher.generate(
            settings: settings,
            prompt: 'SYNTHETIC_PROMPT',
            references: [],
            llmEndpoint: '',
            llmApiKey: '',
          ),
          throwsA(
            predicate((error) {
              final text = error.toString();
              return text.contains('asynchronous image task') &&
                  !text.contains('status=') &&
                  !text.contains('id=') &&
                  !text.contains('SYNTHETIC_TASK_') &&
                  !text.contains(key) &&
                  !text.contains(Uri.encodeComponent(key));
            }),
          ),
        );
      },
    );

    test(
      'tracked backup cannot physically overtake an admitted secure import',
      () async {
        final credentials = owner();
        final entered = Completer<void>();
        final release = Completer<void>();
        storage.beforeWrite = () async {
          entered.complete();
          await release.future;
        };
        final importing = credentials.load();
        await entered.future;
        var backupCompleted = false;
        final replacement = jsonEncode({'routmyApiKey': native});
        final backup = prefs.setString(settingsKey, replacement).then((value) {
          backupCompleted = true;
          return value;
        });
        await Future<void>.value();
        expect(backupCompleted, isFalse);
        release.complete();
        expect((await importing).unavailable, isTrue);
        expect(await backup, isTrue);
        expect(storage.values.values.single, legacy);
        expect(prefs.getString(settingsKey), replacement);
      },
    );

    for (final references in [
      <Map<String, String>>[],
      [
        {'image': 'cG5n'},
      ],
    ]) {
      test(
        'dispatcher integrates native owner into ${references.isEmpty ? 'generate' : 'edit'} HTTP',
        () async {
          final credentials = owner();
          dio.httpClientAdapter = _RoutmyAdapter(
            (_) => (status: 200, body: '{"data":[{"b64_json":"cG5n"}]}'),
          );
          final dispatcher = ImageGenDispatcher(
            routmyCredentials: credentials,
            routmyClientFactory: (origin, check) => RoutmyImageProvider(
              baseUrl: origin,
              checkCurrent: check,
              http: ImageGenHttp(dio: dio),
            ),
          );
          final bytes = await dispatcher.generate(
            settings: settings.copyWith(routmyModel: 'openai/gpt-image-2'),
            prompt: 'SYNTHETIC_IMAGE_PROMPT',
            references: references,
            llmEndpoint: 'https://untrusted.invalid',
            llmApiKey: 'SYNTHETIC_LLM_KEY',
          );
          final requests = (dio.httpClientAdapter as _RoutmyAdapter).requests;
          expect(bytes, utf8.encode('png'));
          expect(
            requests.single.uri.path,
            references.isEmpty ? '/v1/images/generations' : '/v1/images/edits',
          );
          expect(requests.single.headers['Authorization'], 'Bearer $legacy');
        },
      );
    }

    test(
      'check consumer uses native image key on explicit authenticated route',
      () async {
        final service = ImageGenConnectionService(
          dio: dio,
          routmyCredentials: owner(),
        );
        await service.checkConnection(
          settings: settings,
          llmEndpoint: '',
          llmApiKey: 'SYNTHETIC_LLM_KEY',
        );
        expect(adapter.requests.single.uri.path, '/v1/chat/completions');
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $legacy',
        );
        expect(adapter.requests.single.followRedirects, isFalse);
      },
    );
  });

  ImageGenConnectionService serviceFor(_RoutmyAdapter adapter) {
    // Reuse the same no-egress adapter. Flutter's native test binding intercepts
    // real HttpClient requests, including the former loopback servers.
    final dio = Dio()..httpClientAdapter = adapter;
    final service = ImageGenConnectionService(dio: dio);
    addTearDown(service.dispose);
    addTearDown(() => dio.close());
    return service;
  }

  test('fetches and filters OpenAI-compatible image models', () async {
    final adapter = _RoutmyAdapter((request) {
      expect(request.uri.path, '/v1/models');
      expect(request.headers['Authorization'], 'Bearer key');
      return (
        status: 200,
        body: jsonEncode({
          'data': [
            {'id': 'dall-e-3'},
            {'id': 'gpt-image-1'},
            {'id': 'sora-2'},
            {'id': 'chat-model'},
          ],
        }),
      );
    });
    final service = serviceFor(adapter);

    final models = await service.fetchOpenAiModels(
      settings: ImageGenSettings(
        useSameEndpoint: false,
        customEndpoint: 'https://synthetic-image.invalid',
        customApiKey: 'key',
      ),
      llmEndpoint: '',
      llmApiKey: '',
    );

    expect(models, ['dall-e-3', 'gpt-image-1']);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'checks a Gemini generateContent endpoint through its models route',
    () async {
      final adapter = _RoutmyAdapter((request) {
        expect(request.uri.path, '/v1beta/models');
        expect(request.headers['Authorization'], 'Bearer key');
        return (status: 200, body: '{}');
      });
      final service = serviceFor(adapter);

      await service.checkConnection(
        settings: ImageGenSettings(
          apiType: ImageGenApiType.gemini,
          useSameEndpoint: false,
          customEndpoint: 'https://synthetic-image.invalid',
          customApiKey: 'key',
        ),
        llmEndpoint: '',
        llmApiKey: '',
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test('checks a ComfyUI server through /system_stats', () async {
    final adapter = _RoutmyAdapter((request) {
      expect(request.uri.path, '/system_stats');
      return (status: 200, body: '{}');
    });
    final service = serviceFor(adapter);

    await service.checkConnection(
      settings: ImageGenSettings(
        apiType: ImageGenApiType.comfyui,
        comfyui: ComfyUiImageSettings(
          endpoint: 'https://synthetic-comfy.invalid',
        ),
      ),
      llmEndpoint: '',
      llmApiKey: '',
    );
    expect(adapter.requests, hasLength(1));
  });

  // The existing non-injectable ComfyUI client keeps its original loopback
  // regression in comfyui_connection_models_test.dart, outside this binding.
}
