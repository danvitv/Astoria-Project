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
import 'package:glaze_flutter/core/credentials/image_openrouter_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_openrouter_destinations.dart';
import 'package:glaze_flutter/core/credentials/image_openrouter_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/image_novelai_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_novelai_destinations.dart';
import 'package:glaze_flutter/core/credentials/image_novelai_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/image_naistera_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_naistera_destinations.dart';
import 'package:glaze_flutter/core/credentials/image_naistera_legacy_source.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_connection_service.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_dispatcher.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_http.dart';
import 'package:glaze_flutter/features/image_gen/services/routmy_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/openrouter_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/novelai_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/naistera_image_provider.dart';
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
  _FailedImageSettingsBacking(
    Map<String, Object> initial, {
    this.throwAfterInvoke = false,
    this.persistAfterInvoke = false,
    this.acknowledgeWrite = false,
    this.afterInvoke,
  }) : values = {
         for (final entry in initial.entries)
           'flutter.${entry.key}': entry.value,
       };
  final Map<String, Object> values;
  final bool throwAfterInvoke;
  final bool persistAfterInvoke, acknowledgeWrite;
  final void Function()? afterInvoke;
  int writes = 0;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (persistAfterInvoke) values[key] = value;
    afterInvoke?.call();
    if (throwAfterInvoke) {
      throw StateError('SYNTHETIC_IMAGE_PLUGIN_WRITE_FAILURE');
    }
    return acknowledgeWrite;
  }

  @override
  Future<bool> remove(String key) async => false;
  @override
  Future<bool> clear() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('native Naistera IMAGE bounded custody (synthetic, UNRUN)', () {
    const key = ImageNaisteraLegacySource.settingsKey;
    const standalone = ImageNaisteraLegacySource.standaloneKey;
    const legacy = 'SYNTHETIC_NAISTERA_IMAGE_LEGACY:KEY/+%?';
    const native = 'SYNTHETIC_NAISTERA_IMAGE_NATIVE:KEY/+%?';
    const proxy = 'https://synthetic-naistera.invalid/client/v3';
    final slot = CredentialSlot(domain: 'image.naistera', id: 'native');
    late TrackedSharedPreferences prefs;
    late FakeCredentialStorage storage;
    late CredentialVault vault;
    late SecretRedactionCoordinator redaction;
    late Dio dio;
    late _RoutmyAdapter adapter;
    Map<String, dynamic> document() => {
      'enabled': true,
      'apiType': 'naistera',
      'naisteraApiKey': legacy,
      'naisteraModel': 'grok',
      'futurePrivateRoot': {'preserve': true},
      'novelai': {
        'apiKey': 'SYNTHETIC_OTHER_NAI',
        'futureLeaf': [1, 2],
      },
      'openrouter': {'apiKey': 'SYNTHETIC_OTHER_OR'},
    };
    ImageGenSettings settings([String model = 'grok']) => ImageGenSettings(
      enabled: true,
      apiType: ImageGenApiType.naistera,
      naisteraModel: model,
      naisteraApiKey: 'SYNTHETIC_UNTRUSTED_DTO',
    );
    ImageNaisteraCredentialOwner owner({
      Future<SharedPreferences>? original,
      String base = proxy,
    }) {
      final result = ImageNaisteraCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: original ?? Future.value(prefs),
        baseUrl: base,
      );
      addTearDown(result.dispose);
      return result;
    }

    Future<void> check(
      ImageNaisteraCredentialOwner credentials, [
      String model = 'grok',
    ]) => ImageGenConnectionService(dio: dio, naisteraCredentials: credentials)
        .checkConnection(
          settings: settings(model),
          llmEndpoint: 'https://untrusted-llm.invalid',
          llmApiKey: 'SYNTHETIC_LLM',
        );
    Future<Uint8List> generate(
      ImageNaisteraCredentialOwner credentials, [
      String model = 'grok',
    ]) =>
        ImageGenDispatcher(
          naisteraCredentials: credentials,
          naisteraClientFactory: (base, current, public) =>
              NaisteraImageProvider(
                baseUrl: base,
                http: ImageGenHttp(dio: dio),
                checkCurrent: current,
                isPublicValue: public,
                pollInterval: Duration.zero,
              ),
        ).generate(
          settings: settings(model),
          prompt: 'a cat',
          references: const [],
          llmEndpoint: 'https://untrusted-llm.invalid',
          llmApiKey: 'SYNTHETIC_LLM',
        );
    setUp(() async {
      SharedPreferences.setMockInitialValues({key: jsonEncode(document())});
      prefs =
          await TrackedSharedPreferences.getInstance()
              as TrackedSharedPreferences;
      storage = FakeCredentialStorage();
      vault = CredentialVault(storage: storage, buildChannel: 'dev');
      redaction = SecretRedactionCoordinator();
      adapter = _RoutmyAdapter(
        (_) => (status: 200, body: '{"data_url":"data:image/png;base64,AQI="}'),
      );
      dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close());
      addTearDown(redaction.dispose);
    });
    for (final base in [
      ImageNaisteraDestinations.defaultBase,
      '$proxy///',
      '$proxy/api/generate',
    ]) {
      test(
        'exact client generation/models/check recipients, no DTO/LLM/redirect ($base)',
        () async {
          final credentials = owner(base: base);
          final original = prefs.getString(key);
          await check(credentials);
          expect(await generate(credentials), [1, 2]);
          expect(adapter.requests.map((r) => r.uri.toString()), [
            credentials.destinations.check,
            credentials.destinations.generation,
          ]);
          expect(
            adapter.requests.every(
              (r) =>
                  !r.followRedirects &&
                  r.headers['Authorization'] == 'Bearer $legacy',
            ),
            isTrue,
          );
          final record = jsonDecode(storage.values.values.single) as Map;
          expect(record['generation'], credentials.destinations.generation);
          expect(record['models'], credentials.destinations.models);
          expect(record['check'], credentials.destinations.check);
          expect(prefs.getString(key), original);
        },
      );
    }
    for (final candidate in ['missing', 'null', 'wrong type']) {
      test(
        'present document $candidate never falls through to standalone',
        () async {
          final root = document()..remove('naisteraApiKey');
          if (candidate == 'null') root['naisteraApiKey'] = null;
          if (candidate == 'wrong type') root['naisteraApiKey'] = ['not a key'];
          await prefs.setString(key, jsonEncode(root));
          await prefs.setString(standalone, 'SYNTHETIC_STANDALONE');
          final summary = await owner().load();
          expect(summary.configured, isFalse);
          expect(summary.unavailable, candidate == 'wrong type');
          expect(
            storage.values.values,
            candidate == 'wrong type' ? isEmpty : [''],
          );
          expect(adapter.requests, isEmpty);
        },
      );
    }
    for (final selector in [false, true]) {
      test(
        'absent whole document standalone requires JS selector ($selector)',
        () async {
          await prefs.remove(key);
          await prefs.setString(standalone, legacy);
          if (selector)
            await prefs.setString(
              ImageNaisteraLegacySource.apiTypeKey,
              'naistera',
            );
          final credentials = owner();
          expect((await credentials.load()).configured, selector);
          expect(prefs.getString(standalone), legacy);
          if (selector)
            await check(credentials);
          else
            expect(storage.values, isEmpty);
        },
      );
    }
    test(
      'native Set/Clear preserves all raw legacy and stores an empty tombstone',
      () async {
        final credentials = owner();
        final raw = prefs.getString(key);
        expect((await credentials.setApiKey(native)).verifiedCommit, isTrue);
        await check(credentials);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
        final summary = await credentials.setApiKey('');
        expect(summary.verifiedCommit, isTrue);
        expect(summary.configured, isFalse);
        expect(await vault.hasStoredValue(slot), isTrue);
        expect(storage.values.values.single, isEmpty);
        await expectLater(check(credentials), throwsA(anything));
        expect(adapter.requests, hasLength(1));
        expect(prefs.getString(key), raw);
      },
    );
    for (final mode in ['read failure', 'corrupt', 'invoked unknown']) {
      test(
        '$mode is not absence; same-vault older record cannot revive consumption',
        () async {
          final credentials = owner();
          await credentials.setApiKey(native);
          if (mode == 'read failure') storage.readError = StateError(legacy);
          if (mode == 'corrupt') await vault.store(slot, '{corrupt');
          if (mode == 'invoked unknown') {
            storage.dropWrites = true;
            expect(
              (await owner().setApiKey(
                'SYNTHETIC_FAILED_REPLACEMENT',
              )).unknownCommit,
              isTrue,
            );
          }
          await expectLater(check(credentials), throwsA(anything));
          await expectLater(check(owner()), throwsA(anything));
          expect(adapter.requests, isEmpty);
        },
      );
    }
    for (final changedKey in [key, standalone]) {
      test(
        'first original producer captures $changedKey ABA before preferences await',
        () async {
          final gate = Completer<SharedPreferences>();
          final credentials = owner(original: gate.future);
          final pending = check(credentials);
          final denied = expectLater(
            pending,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          final old = prefs.get(changedKey);
          await prefs.setString(changedKey, 'SYNTHETIC_ABA');
          if (old == null)
            await prefs.remove(changedKey);
          else
            await prefs.setString(changedKey, old as String);
          gate.complete(prefs);
          await denied;
          expect(adapter.requests, isEmpty);
          expect(storage.operations.where((op) => op == 'write'), isEmpty);
        },
      );
    }
    test(
      'original pre-await producer cannot adopt replacement tracked store',
      () async {
        final gate = Completer<SharedPreferences>();
        final pending = check(owner(original: gate.future));
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        SharedPreferences.setMockInitialValues({key: jsonEncode(document())});
        final replacement = await TrackedSharedPreferences.getInstance();
        gate.complete(replacement);
        await denied;
        expect(adapter.requests, isEmpty);
      },
    );
    test(
      'same-vault latest Set wins; old verified invoked fact remains retired',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        var first = true;
        storage.beforeWrite = () async {
          if (first) {
            first = false;
            entered.complete();
            await release.future;
          }
        };
        final a = owner(), b = owner();
        final old = a.setApiKey(native);
        await entered.future;
        final latest = b.setApiKey('SYNTHETIC_LATEST_KEY');
        release.complete();
        final factual = await old;
        expect(factual.verifiedCommit, isTrue);
        expect(factual.retired, isTrue);
        expect(factual.unknownCommit, isFalse);
        expect((await latest).verifiedCommit, isTrue);
        await check(b);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer SYNTHETIC_LATEST_KEY',
        );
      },
    );
    test(
      'guarded absence import loses to latest same-vault native Set before invocation',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        var first = true;
        storage.beforeRead = () async {
          if (first) {
            first = false;
            entered.complete();
            await release.future;
          }
        };
        final importing = owner();
        final old = importing.load();
        await entered.future;
        final replacing = owner();
        final latest = replacing.setApiKey(native);
        release.complete();
        expect((await old).unavailable, isTrue);
        expect((await latest).verifiedCommit, isTrue);
        expect(storage.operations.where((op) => op == 'write'), hasLength(1));
        await check(replacing);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
      },
    );
    test(
      'invoked unverified import quarantines later consumption until verified native Set',
      () async {
        storage.dropWrites = true;
        expect((await owner().load()).unavailable, isTrue);
        storage.dropWrites = false;
        await expectLater(check(owner()), throwsA(anything));
        expect(storage.operations.where((op) => op == 'write'), hasLength(1));
        expect(adapter.requests, isEmpty);
        final replacement = owner();
        expect((await replacement.setApiKey(native)).verifiedCommit, isTrue);
        await check(replacement);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
      },
    );
    test(
      'first protected read failure never seeds retained native plaintext as absence',
      () async {
        storage.readError = StateError(legacy);
        expect((await owner().load()).unavailable, isTrue);
        expect(storage.operations.where((op) => op == 'write'), isEmpty);
        expect(prefs.getString(key), jsonEncode(document()));
        expect(adapter.requests, isEmpty);
      },
    );
    test(
      'plain native settings reject key patches and deep-detach queued input',
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
        expect(loaded.naisteraApiKey, isEmpty);
        await expectLater(
          container
              .read(imageGenSettingsProvider.notifier)
              .save(loaded.copyWith(naisteraApiKey: native)),
          throwsA(isA<StateError>()),
        );
        final credentials = container.read(
          imageNaisteraCredentialOwnerProvider,
        );
        final block = Completer<void>();
        final occupied = SavedPreferencesWrites.serializeImageRoutmy(
          () => block.future,
        );
        final patch = <String, dynamic>{
          'futureOrdinary': <String, dynamic>{'value': 7},
        };
        final pending = credentials.source.saveSettings(
          patch,
          isCurrent: () => true,
          hasNovelAiRecord: container
              .read(imageNovelAiCredentialOwnerProvider)
              .hasNativeRecord,
          hasOpenRouterRecord: container
              .read(imageOpenRouterCredentialOwnerProvider)
              .hasNativeRecord,
        );
        (patch['futureOrdinary'] as Map)['value'] = 9;
        patch['naisteraApiKey'] = native;
        block.complete();
        await occupied;
        await pending;
        final saved = jsonDecode(prefs.getString(key)!) as Map;
        expect(saved['futureOrdinary'], {'value': 7});
        expect(saved['naisteraApiKey'], legacy);
        expect(saved['futurePrivateRoot'], document()['futurePrivateRoot']);
        expect(saved['novelai'], document()['novelai']);
        expect(saved['openrouter'], document()['openrouter']);
        expect(
          () => container
              .read(imageRoutmyCredentialOwnerProvider)
              .source
              .saveSettings({'naisteraApiKey': native}, isCurrent: () => true),
          throwsA(anything),
        );
        expect(
          () => container
              .read(imageOpenRouterCredentialOwnerProvider)
              .source
              .saveSettings(
                {'naisteraApiKey': native},
                isCurrent: () => true,
                hasNativeRecord: (_) async => false,
              ),
          throwsA(anything),
        );
        expect(
          () => container
              .read(imageNovelAiCredentialOwnerProvider)
              .source
              .saveSettings(
                {'naisteraApiKey': native},
                isCurrent: () => true,
                hasNativeRecord: (_) async => false,
                hasOpenRouterRecord: (_) async => false,
              ),
          throwsA(anything),
        );
      },
    );
    for (final rawModel in ['nano banana', 'UnknownCaseModel', 'novelai']) {
      test(
        'native actual raw/normalized model $rawModel uses Naistera slot only',
        () async {
          final root = document()..['naisteraModel'] = rawModel;
          await prefs.setString(key, jsonEncode(root));
          expect(await generate(owner(), rawModel), [1, 2]);
          expect(
            (adapter.requests.single.data as Map)['model'],
            NaisteraConstants.normalizeModel(rawModel),
          );
          expect(
            adapter.requests.single.headers['Authorization'],
            'Bearer $legacy',
          );
        },
      );
    }
    test(
      'original full percent model guard survives policy replacement at first prefs await',
      () async {
        const alias = 'SYNTHETIC_PREAWAIT_MODEL/PRIVATE';
        final rawModel = 'model/${Uri.encodeComponent(alias)}';
        await prefs.setString(
          key,
          jsonEncode(document()..['naisteraModel'] = rawModel),
        );
        final previous = activeErrorRedactor;
        activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
        addTearDown(() => activeErrorRedactor = previous);
        final gate = Completer<SharedPreferences>();
        final pending = generate(owner(original: gate.future), rawModel);
        activeErrorRedactor = SecretRedactor();
        gate.complete(prefs);
        await expectLater(pending, throwsA(anything));
        expect(adapter.requests, isEmpty);
      },
    );
    test(
      'native catalog filters whole current aliases before return and queued persistence',
      () async {
        const alias = 'SYNTHETIC_CATALOG_PRIVATE';
        final entered = Completer<void>(),
            release = Completer<({int status, String body})>();
        adapter = _RoutmyAdapter((_) {
          entered.complete();
          return release.future;
        });
        dio.httpClientAdapter = adapter;
        final credentials = owner();
        final pending = ImageGenConnectionService(
          dio: dio,
          naisteraCredentials: credentials,
        ).fetchNaisteraModels(settings());
        await entered.future;
        redaction.registerSecret(alias);
        release.complete((
          status: 200,
          body: jsonEncode({
            'models': [
              {'id': 'safe', 'name': 'Public', 'references': false},
              {'id': 'image/$alias', 'name': 'Private'},
              {'id': 'other', 'name': 'Name $alias'},
            ],
          }),
        ));
        expect((await pending).map((m) => m.id), ['safe']);
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(container.dispose);
        final loaded = await container.read(imageGenSettingsProvider.future);
        final gate = Completer<void>();
        final occupied = SavedPreferencesWrites.serializeImageRoutmy(
          () => gate.future,
        );
        final save = container
            .read(imageGenSettingsProvider.notifier)
            .save(
              loaded.copyWith(
                naisteraModels: const [
                  NaisteraModelInfo(id: 'future', name: 'SYNTHETIC_LATE_LABEL'),
                ],
              ),
              ownsNaisteraCatalog: () => true,
            );
        final raw = prefs.getString(key);
        redaction.registerSecret('SYNTHETIC_LATE_LABEL');
        gate.complete();
        await occupied;
        await expectLater(save, throwsA(anything));
        expect(prefs.getString(key), raw);
        expect(
          container.read(imageGenSettingsProvider).value!.naisteraModels,
          isEmpty,
        );
      },
    );
    test(
      'native generation/poll current job alias refuses before a second authenticated request',
      () async {
        const alias = 'SYNTHETIC_JOB_PRIVATE';
        adapter = _RoutmyAdapter((_) {
          redaction.registerSecret(alias);
          return (
            status: 200,
            body: jsonEncode({'job_id': 'job/${Uri.encodeComponent(alias)}'}),
          );
        });
        dio.httpClientAdapter = adapter;
        await expectLater(generate(owner()), throwsA(anything));
        expect(adapter.requests, hasLength(1));
      },
    );
  });
  group('native NovelAI IMAGE original protected custody (synthetic)', () {
    const legacy = 'SYNTHETIC_NAI_IMAGE_LEGACY:KEY/+%?';
    const native = 'SYNTHETIC_NAI_IMAGE_NATIVE:KEY/+%?';
    const key = ImageNovelAiLegacySource.settingsKey;
    const proxy = 'https://synthetic-nai-image.invalid/custom/v7';
    const model = 'nai-diffusion-4-5-full';
    final slot = CredentialSlot(domain: 'image.novelai', id: 'native');
    late TrackedSharedPreferences prefs;
    late FakeCredentialStorage storage;
    late CredentialVault vault;
    late SecretRedactionCoordinator redaction;
    late Dio dio;
    late _RoutmyAdapter adapter;
    Map<String, dynamic> document([String endpoint = proxy]) => {
      'apiType': 'novelai',
      'novelai': {
        'endpoint': endpoint,
        'model': model,
        'apiKey': legacy,
        'futurePrivateLeaf': {'keep': true},
      },
      'futurePrivateRoot': {'keep': true},
      'openrouter': {'apiKey': 'SYNTHETIC_KEEP_OR', 'endpoint': ''},
    };
    ImageGenSettings settings([
      String endpoint = proxy,
      String selectedModel = model,
    ]) => ImageGenSettings(
      apiType: ImageGenApiType.novelai,
      novelai: NovelAIImageSettings(
        endpoint: endpoint,
        model: selectedModel,
        apiKey: 'SYNTHETIC_UNTRUSTED_DTO',
        seed: 7,
      ),
    );
    ImageNovelAiCredentialOwner owner([Future<SharedPreferences>? original]) {
      final result = ImageNovelAiCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: original ?? Future.value(prefs),
      );
      addTearDown(result.dispose);
      return result;
    }

    ImageGenConnectionService service(
      ImageNovelAiCredentialOwner credentials,
    ) => ImageGenConnectionService(dio: dio, novelaiCredentials: credentials);
    Future<void> check(
      ImageNovelAiCredentialOwner credentials, [
      ImageGenSettings? input,
    ]) => service(credentials).checkConnection(
      settings: input ?? settings(),
      llmEndpoint: 'https://untrusted-llm.invalid',
      llmApiKey: 'SYNTHETIC_LLM_KEY',
    );
    ImageGenDispatcher dispatcher(ImageNovelAiCredentialOwner credentials) =>
        ImageGenDispatcher(
          novelaiCredentials: credentials,
          novelaiClientFactory: (check) => NovelAIImageProvider(
            checkCurrent: check,
            http: ImageGenHttp(dio: dio),
          ),
        );
    Future<Uint8List> generate(ImageNovelAiCredentialOwner credentials) =>
        dispatcher(credentials).generate(
          settings: settings(),
          prompt: '1girl',
          references: const [],
          llmEndpoint: 'https://untrusted-llm.invalid',
          llmApiKey: 'SYNTHETIC_LLM_KEY',
        );
    setUp(() async {
      SharedPreferences.setMockInitialValues({key: jsonEncode(document())});
      prefs =
          await TrackedSharedPreferences.getInstance()
              as TrackedSharedPreferences;
      storage = FakeCredentialStorage();
      vault = CredentialVault(storage: storage, buildChannel: 'dev');
      redaction = SecretRedactionCoordinator();
      adapter = _RoutmyAdapter((_) => (status: 200, body: '{}'));
      dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close());
      addTearDown(redaction.dispose);
    });

    for (final endpoint in ['', '  $proxy///  ', '$proxy/ai/custom']) {
      test(
        'exact normalized generation/check recipients, no LLM/DTO or redirects: $endpoint',
        () async {
          await prefs.setString(key, jsonEncode(document(endpoint)));
          final credentials = owner();
          final original = prefs.getString(key);
          await check(credentials, settings(endpoint));
          final destinations = ImageNovelAiDestinations(endpoint, model);
          expect(
            ImageNovelAiDestinations.defaultEndpoint,
            NovelAIConstants.defaultEndpoint,
          );
          expect(
            ImageNovelAiDestinations.defaultModel,
            NovelAIConstants.defaultModel,
          );
          expect(adapter.requests.single.uri.toString(), destinations.check);
          expect(adapter.requests.single.method, 'GET');
          expect(
            adapter.requests.single.headers['Authorization'],
            'Bearer $legacy',
          );
          expect(adapter.requests.single.followRedirects, isFalse);
          expect(
            adapter.requests.single.receiveTimeout,
            const Duration(seconds: 10),
          );
          final record = jsonDecode(storage.values.values.single) as Map;
          expect(record['generation'], destinations.generation);
          expect(record['check'], destinations.check);
          expect(record['model'], model);
          expect(prefs.getString(key), original);
        },
      );
    }
    for (final status in [200, 204, 302, 401, 403, 500]) {
      test('check admits ONLY 2xx ($status)', () async {
        adapter = _RoutmyAdapter((_) => (status: status, body: '{}'));
        dio.httpClientAdapter = adapter;
        if (status >= 200 && status < 300) {
          await check(owner());
        } else {
          await expectLater(check(owner()), throwsA(isA<StateError>()));
        }
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.followRedirects, isFalse);
      });
    }
    test(
      'actual native dispatcher POST keeps settings/extraction without exposing the DTO key',
      () async {
        adapter = _RoutmyAdapter(
          (_) => (status: 200, body: '{"images":[{"image":"cG5n"}]}'),
        );
        dio.httpClientAdapter = adapter;
        expect(await generate(owner()), utf8.encode('png'));
        final request = adapter.requests.single;
        expect(request.uri.toString(), '$proxy/ai/generate-image');
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], 'Bearer $legacy');
        expect(request.followRedirects, isFalse);
        expect(request.data['model'], model);
        expect(request.data['parameters']['seed'], 7);
        expect(jsonEncode(request.data), isNot(contains(legacy)));
        expect(
          jsonEncode(request.data),
          isNot(contains('SYNTHETIC_UNTRUSTED_DTO')),
        );
      },
    );
    for (final response in [
      (302, '{"url":"https://never-follow.invalid/image"}'),
      (200, '{"url":"https://never-follow.invalid/image"}'),
    ]) {
      test(
        'generation has no redirect or returned-URL download hop (${response.$1})',
        () async {
          adapter = _RoutmyAdapter(
            (_) => (status: response.$1, body: response.$2),
          );
          dio.httpClientAdapter = adapter;
          await expectLater(generate(owner()), throwsA(isA<StateError>()));
          expect(adapter.requests, hasLength(1));
          expect(adapter.requests.single.followRedirects, isFalse);
        },
      );
    }
    test(
      'native model aliases are stripped before provider hydration/diagnostics or HTTP',
      () async {
        final root = document();
        (root['novelai'] as Map)['model'] = 'nai-diffusion-$legacy';
        await prefs.setString(key, jsonEncode(root));
        final c = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(c.dispose);
        expect(
          (await c.read(imageGenSettingsProvider.future)).novelai.model,
          isEmpty,
        );
        expect(c.read(imageGenSettingsProvider).value!.novelai.apiKey, isEmpty);
        await expectLater(
          dispatcher(c.read(imageNovelAiCredentialOwnerProvider)).generate(
            settings: settings(proxy, 'nai-diffusion-$legacy'),
            prompt: 'public',
            references: const [],
            llmEndpoint: '',
            llmApiKey: '',
          ),
          throwsStateError,
        );
        expect(adapter.requests, isEmpty);
      },
    );
    for (final candidate in [
      null,
      '',
      7,
      {'bad': true},
    ]) {
      test(
        'absent != empty != wrong type; no standalone or LLM fallback: $candidate',
        () async {
          final root = document();
          if (candidate == null) {
            (root['novelai'] as Map).remove('apiKey');
          } else {
            (root['novelai'] as Map)['apiKey'] = candidate;
          }
          await prefs.setString(key, jsonEncode(root));
          await prefs.setString(
            'gz_imggen_novelai_api_key',
            'SYNTHETIC_NOT_A_SOURCE',
          );
          final credentials = owner();
          final summary = await credentials.load();
          expect(summary.configured, isFalse);
          expect(
            summary.unavailable,
            candidate != null && candidate is! String,
          );
          expect(await vault.hasStoredValue(slot), candidate == '');
          await expectLater(
            check(credentials),
            throwsA(
              candidate != null && candidate is! String
                  ? isA<CredentialVaultAdmissionDenied>()
                  : isA<CredentialVaultException>(),
            ),
          );
          expect(adapter.requests, isEmpty);
        },
      );
    }
    test(
      'native Set/Clear wins retained legacy and remains a protected tombstone',
      () async {
        final credentials = owner();
        final original = prefs.getString(key);
        final set = await credentials.setApiKey(
          native,
          endpoint: proxy,
          model: model,
        );
        expect(set.verifiedCommit, isTrue);
        expect(set.configured, isTrue);
        await check(credentials);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
        final clear = await credentials.setApiKey(
          '',
          endpoint: proxy,
          model: model,
        );
        expect(clear.verifiedCommit, isTrue);
        expect(clear.configured, isFalse);
        expect((await owner().load()).configured, isFalse);
        await expectLater(
          check(owner()),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(storage.values.values.single, '');
        expect(prefs.getString(key), original);
      },
    );
    for (final mode in ['read failure', 'corrupt record', 'unverified Set']) {
      test(
        '$mode is not absence and cannot consume a same-vault older record',
        () async {
          final credentials = owner();
          await credentials.load();
          if (mode == 'read failure') {
            storage.readError = StateError('SYNTHETIC_READ');
          } else if (mode == 'corrupt record') {
            await vault.store(slot, 'SYNTHETIC_CORRUPT');
          } else {
            storage.dropWrites = true;
            expect(
              (await credentials.setApiKey(
                native,
                endpoint: proxy,
                model: model,
              )).unknownCommit,
              isTrue,
            );
            storage.dropWrites = false;
          }
          expect((await owner().load()).unavailable, isTrue);
          await expectLater(
            check(owner()),
            throwsA(
              mode == 'unverified Set'
                  ? isA<CredentialVaultAdmissionDenied>()
                  : isA<CredentialVaultException>(),
            ),
          );
          expect(adapter.requests, isEmpty);
          if (mode == 'unverified Set') {
            expect(
              (await credentials.setApiKey(
                native,
                endpoint: proxy,
                model: model,
              )).verifiedCommit,
              isTrue,
            );
            await check(credentials);
            expect(
              adapter.requests.single.headers['Authorization'],
              'Bearer $native',
            );
          }
        },
      );
    }
    for (final endpoint in [
      'https://u:p@synthetic.invalid',
      'https://synthetic.invalid/#f',
      'synthetic.invalid',
      'https://synthetic.invalid/%broken',
      'https://synthetic.invalid/?api_key=bad',
    ]) {
      test('malformed destination denied before HTTP: $endpoint', () async {
        await expectLater(
          check(owner(), settings(endpoint)),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(adapter.requests, isEmpty);
        expect(storage.operations, isEmpty);
      });
    }
    test(
      'model/query binding is exact and encoded with generation normalization',
      () async {
        const selected = ' model/with space+? ';
        final root = document();
        (root['novelai'] as Map)['model'] = selected;
        await prefs.setString(key, jsonEncode(root));
        final credentials = owner();
        await check(credentials, settings(proxy, selected));
        expect(
          adapter.requests.single.uri.toString(),
          '$proxy/ai/generate-image/suggest-tags?model=${Uri.encodeComponent(selected.trim())}&prompt=a',
        );
        await expectLater(
          check(credentials, settings(proxy, 'nai-diffusion-3')),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
    test(
      'original settings producer ABA during unresolved preferences cannot be adopted',
      () async {
        final gate = Completer<SharedPreferences>();
        final credentials = owner(gate.future);
        final pending = check(credentials);
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await prefs.setString(key, jsonEncode(document('$proxy/changed')));
        await prefs.setString(key, jsonEncode(document()));
        gate.complete(prefs);
        await denied;
        expect(adapter.requests, isEmpty);
        expect(storage.operations, isEmpty);
      },
    );
    test(
      'generation completion cannot publish after original endpoint ABA while HTTP is pending',
      () async {
        final entered = Completer<void>();
        final release = Completer<({int status, String body})>();
        adapter = _RoutmyAdapter((_) {
          entered.complete();
          return release.future;
        });
        dio.httpClientAdapter = adapter;
        final credentials = owner();
        final originalGuard = credentials.captureGuard();
        final pending = generate(credentials);
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        await prefs.setString(key, jsonEncode(document('$proxy/changed')));
        await prefs.setString(key, jsonEncode(document()));
        expect(originalGuard(), isFalse);
        release.complete((status: 200, body: '{"image":"cG5n"}'));
        await denied;
        expect(adapter.requests, hasLength(1));
      },
    );
    test(
      'newest native intent wins an import and a queued older Set',
      () async {
        final gate = Completer<SharedPreferences>();
        final credentials = owner(gate.future);
        final oldLoad = credentials.load();
        final oldSet = credentials.setApiKey(
          'SYNTHETIC_OLD_SET',
          endpoint: proxy,
          model: model,
        );
        final newSet = credentials.setApiKey(
          native,
          endpoint: proxy,
          model: model,
        );
        gate.complete(prefs);
        expect((await oldLoad).unavailable, isTrue);
        expect((await oldSet).retired, isTrue);
        expect((await newSet).verifiedCommit, isTrue);
        await check(credentials);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
      },
    );
    test(
      'ordinary queue input is cloned; native state strips keys and keeps unknown private leaves',
      () async {
        final c = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(c.dispose);
        final loaded = await c.read(imageGenSettingsProvider.future);
        expect(loaded.novelai.apiKey, isEmpty);
        await expectLater(
          c
              .read(imageGenSettingsProvider.notifier)
              .save(
                loaded.copyWith(
                  novelai: loaded.novelai.copyWith(apiKey: native),
                ),
              ),
          throwsStateError,
        );
        final credentials = c.read(imageNovelAiCredentialOwnerProvider);
        final gate = Completer<void>();
        final blocked = SavedPreferencesWrites.serializeImageRoutmy(
          () => gate.future,
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await blocked;
        });
        final patch = <String, dynamic>{
          'novelai': <String, dynamic>{'steps': 30},
          'futurePrivateRoot': <String, dynamic>{
            'list': <int>[1, 2],
          },
        };
        final pending = credentials.source.saveSettings(
          patch,
          isCurrent: () => true,
          hasNativeRecord: credentials.hasNativeRecord,
          hasOpenRouterRecord: c
              .read(imageOpenRouterCredentialOwnerProvider)
              .hasNativeRecord,
        );
        (patch['novelai'] as Map)['apiKey'] = 'SYNTHETIC_MUTABLE_KEY';
        (patch['novelai'] as Map)['endpoint'] = '$proxy/rebind';
        ((patch['futurePrivateRoot'] as Map)['list'] as List).add(3);
        gate.complete();
        await blocked;
        await pending;
        final saved = jsonDecode(prefs.getString(key)!) as Map;
        expect((saved['novelai'] as Map)['apiKey'], legacy);
        expect((saved['novelai'] as Map)['endpoint'], proxy);
        expect((saved['novelai'] as Map)['steps'], 30);
        expect((saved['novelai'] as Map)['futurePrivateLeaf'], {'keep': true});
        expect((saved['futurePrivateRoot'] as Map)['list'], [1, 2]);
        expect((saved['openrouter'] as Map)['apiKey'], 'SYNTHETIC_KEEP_OR');
      },
    );
    test(
      'older ordinary helpers deny NovelAI raw key and endpoint rebinding',
      () async {
        final routmy = ImageRoutmyLegacySource(Future.value(prefs));
        final openrouter = ImageOpenRouterLegacySource(Future.value(prefs));
        for (final leaf in [
          {'apiKey': native},
          {'endpoint': '$proxy/rebind'},
          {'model': 'nai-diffusion-3'},
        ]) {
          expect(
            () => routmy.saveSettings({'novelai': leaf}, isCurrent: () => true),
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          expect(
            () => openrouter.saveSettings(
              {'novelai': leaf},
              isCurrent: () => true,
              hasNativeRecord: (_) async => true,
            ),
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
        }
        expect(storage.operations, isEmpty);
      },
    );
    for (final latePolicy in [false, true]) {
      for (final operation in ['check', 'generate']) {
        test(
          'partly encoded ${latePolicy ? 'CURRENT' : 'original'} NovelAI model denies $operation before HTTP or diagnostics',
          () async {
            const alias = 'SYNTHETIC_CURRENT_NAI_ALIAS';
            const encoded = '%53YNTHETIC_CURRENT_NAI_ALIAS';
            final doc = document();
            (doc['novelai'] as Map)['model'] = encoded;
            await prefs.setString(key, jsonEncode(doc));
            final credentials = owner();
            await credentials.load();
            final previous = activeErrorRedactor;
            addTearDown(() => activeErrorRedactor = previous);
            if (latePolicy)
              activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
            else
              redaction.registerSecret(alias);
            final destinations = ImageNovelAiDestinations(proxy, encoded);
            final guard = credentials.capturePublicTextGuard(url: true);
            expect(
              guard(destinations.check),
              isTrue,
            ); // One URL decode is insufficient.
            expect(
              guard(encoded),
              isFalse,
            ); // Inspect the original model separately.
            final input = settings(proxy, encoded);
            final pending = operation == 'check'
                ? check(credentials, input)
                : dispatcher(credentials).generate(
                    settings: input,
                    prompt: 'public synthetic',
                    references: const [],
                    llmEndpoint: '',
                    llmApiKey: '',
                  );
            await expectLater(
              pending,
              throwsA(isA<CredentialVaultAdmissionDenied>()),
            );
            expect(adapter.requests, isEmpty);
            expect(
              (jsonDecode(prefs.getString(key)!) as Map)['novelai']['model'],
              encoded,
            );
          },
        );
      }
    }
    test(
      'original sink model coverage survives unresolved NovelAI preferences and clean CURRENT replacement',
      () async {
        const alias = 'SYNTHETIC_CURRENT_NAI_ALIAS';
        const encoded = '%53YNTHETIC_CURRENT_NAI_ALIAS';
        final doc = document();
        (doc['novelai'] as Map)['model'] = encoded;
        await prefs.setString(key, jsonEncode(doc));
        final originalPreferences = Completer<SharedPreferences>();
        final credentials = owner(originalPreferences.future);
        final previous = activeErrorRedactor;
        addTearDown(() => activeErrorRedactor = previous);
        activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
        expect(credentials.capturePublicTextGuard(url: true)(encoded), isFalse);
        final pending = check(credentials, settings(proxy, encoded));
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        // Keep the same original preferences producer, lease and native owner.
        // Only the process-wide sink is replaced during its first await.
        activeErrorRedactor = SecretRedactor();
        expect(credentials.capturePublicTextGuard(url: true)(encoded), isTrue);
        originalPreferences.complete(prefs);
        await denied;
        expect(adapter.requests, isEmpty);
        expect(redaction.redactor.isKnownSecretFree(alias), isTrue);
        expect(
          (jsonDecode(prefs.getString(key)!) as Map)['novelai']['model'],
          encoded,
        );
      },
    );
    test(
      'new endpoint keeps protected record bound to original endpoint; no silent transfer',
      () async {
        final credentials = owner();
        await credentials.load();
        final stored = Map<String, String>.from(storage.values);
        await credentials.source.saveSettings(
          {
            'novelai': {'endpoint': '$proxy/changed'},
          },
          isCurrent: () => true,
          hasNativeRecord: credentials.hasNativeRecord,
          hasOpenRouterRecord: (_) async => true,
        );
        await expectLater(
          check(credentials, settings('$proxy/changed')),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(storage.values, stored);
        expect(adapter.requests, isEmpty);
      },
    );
    for (final throwing in [false, true]) {
      test(
        'original ordinary ${throwing ? 'throw' : 'false'} is unverified, not a no-write claim',
        () async {
          final initial = {key: jsonEncode(document())};
          SharedPreferences.setMockInitialValues(initial);
          final previousBackend = SharedPreferencesStorePlatform.instance;
          final backing = _FailedImageSettingsBacking(
            initial,
            throwAfterInvoke: throwing,
            persistAfterInvoke: true,
          );
          SharedPreferencesStorePlatform.instance = backing;
          addTearDown(
            () => SharedPreferencesStorePlatform.instance = previousBackend,
          );
          prefs =
              await TrackedSharedPreferences.getInstance()
                  as TrackedSharedPreferences;
          final credentials = owner();
          await expectLater(
            credentials.source.saveSettings(
              {'enabled': true},
              isCurrent: () => true,
              hasNativeRecord: credentials.hasNativeRecord,
              hasOpenRouterRecord: (_) async => false,
            ),
            throwsA(isA<ImageOpenRouterSettingsWriteUnverified>()),
          );
          expect(backing.writes, 1);
          final saved =
              jsonDecode(backing.values['flutter.$key']! as String) as Map;
          expect(saved['enabled'], isTrue);
          expect((saved['novelai'] as Map)['apiKey'], legacy);
          expect(adapter.requests, isEmpty);
        },
      );
    }
    test(
      'generation error sees whole ORIGINAL and CURRENT encoded aliases',
      () async {
        const alias = 'SYNTHETIC_CURRENT_NAI_ALIAS';
        final previous = activeErrorRedactor;
        addTearDown(() => activeErrorRedactor = previous);
        adapter = _RoutmyAdapter((_) {
          activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
          return (
            status: 400,
            body: jsonEncode({
              'error': '${Uri.encodeComponent(legacy)} $alias',
            }),
          );
        });
        dio.httpClientAdapter = adapter;
        try {
          await generate(owner());
          fail('Expected synthetic failure');
        } catch (error) {
          expect(error.toString(), isNot(contains(legacy)));
          expect(
            error.toString(),
            isNot(contains(Uri.encodeComponent(legacy))),
          );
          expect(error.toString(), isNot(contains(alias)));
        }
      },
    );
  });
  group('native OpenRouter IMAGE exact-recipient custody', () {
    const legacy = 'SYNTHETIC_OR_IMAGE_LEGACY:KEY/+%?';
    const native = 'SYNTHETIC_OR_IMAGE_NATIVE:KEY/+%?';
    const key = ImageOpenRouterLegacySource.settingsKey;
    const proxy = 'https://synthetic-image-proxy.invalid/custom/v7';
    final slot = CredentialSlot(domain: 'image.openrouter', id: 'native');
    late TrackedSharedPreferences prefs;
    late FakeCredentialStorage storage;
    late CredentialVault vault;
    late SecretRedactionCoordinator redaction;
    late Dio dio;
    late _RoutmyAdapter adapter;

    ImageGenSettings settings([String endpoint = proxy]) => ImageGenSettings(
      apiType: ImageGenApiType.openrouter,
      openrouter: OpenRouterImageSettings(
        endpoint: endpoint,
        model: 'google/gemini-2.5-flash-image',
        apiKey: 'SYNTHETIC_UNTRUSTED_DTO_KEY',
      ),
    );
    Map<String, dynamic> document([String endpoint = proxy]) => {
      'apiType': 'openrouter',
      'openrouter': {
        'apiKey': legacy,
        'endpoint': endpoint,
        'model': 'google/gemini-2.5-flash-image',
        'futurePrivateLeaf': {'keep': true},
      },
      'routmyApiKey': 'SYNTHETIC_OTHER_IMAGE_KEY',
      'naisteraApiKey': 'SYNTHETIC_UNCHANGED_NAISTERA',
      'futurePrivateRoot': {'keep': true},
    };
    ImageOpenRouterCredentialOwner owner() {
      final result = ImageOpenRouterCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: Future.value(prefs),
      );
      addTearDown(result.dispose);
      return result;
    }

    ImageGenConnectionService service(
      ImageOpenRouterCredentialOwner credentials,
    ) =>
        ImageGenConnectionService(dio: dio, openrouterCredentials: credentials);
    ProviderContainer container() {
      final result = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          credentialVaultProvider.overrideWithValue(vault),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        ],
      );
      addTearDown(result.dispose);
      return result;
    }

    ImageGenDispatcher dispatcher(ImageOpenRouterCredentialOwner credentials) =>
        ImageGenDispatcher(
          openrouterCredentials: credentials,
          openrouterClientFactory: (check, publicUrl) =>
              OpenRouterImageProvider(
                checkCurrent: check,
                isPublicUrl: publicUrl,
                http: ImageGenHttp(dio: dio),
                downloadHttp: ImageGenHttp(dio: dio),
              ),
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({key: jsonEncode(document())});
      prefs =
          await TrackedSharedPreferences.getInstance()
              as TrackedSharedPreferences;
      storage = FakeCredentialStorage();
      vault = CredentialVault(storage: storage, buildChannel: 'dev');
      redaction = SecretRedactionCoordinator();
      adapter = _RoutmyAdapter(
        (_) => (
          status: 200,
          body: '{"data":[{"id":"public/image-model","name":"Public Image"}]}',
        ),
      );
      dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close());
      addTearDown(redaction.dispose);
    });

    for (final endpoint in ['', '  $proxy///  ', '$proxy/chat/completions/']) {
      test(
        'actual default/custom/complete recipients bind verbatim: $endpoint',
        () async {
          await prefs.setString(key, jsonEncode(document(endpoint)));
          final credentials = owner();
          final original = prefs.getString(key);
          final expected = ImageOpenRouterDestinations(endpoint);
          expect(
            ImageOpenRouterDestinations.defaultEndpoint,
            OpenRouterConstants.defaultEndpoint,
          );
          expect(
            await service(
              credentials,
            ).fetchOpenRouterModels(settings(endpoint)),
            ['public/image-model'],
          );
          await service(credentials).checkConnection(
            settings: settings(endpoint),
            llmEndpoint: 'https://untrusted-llm.invalid',
            llmApiKey: 'SYNTHETIC_LLM_KEY',
          );
          expect(adapter.requests.map((request) => request.uri.toString()), [
            expected.imageModels,
            expected.models,
          ]);
          expect(
            adapter.requests.every(
              (request) => request.headers['Authorization'] == 'Bearer $legacy',
            ),
            isTrue,
          );
          expect(
            adapter.requests.every((request) => !request.followRedirects),
            isTrue,
          );
          final record = jsonDecode(storage.values.values.single) as Map;
          expect(record['generation'], expected.generation);
          expect(record['models'], expected.models);
          expect(record['imageModels'], expected.imageModels);
          expect(record['protocol'], ImageOpenRouterDestinations.protocol);
          expect(prefs.getString(key), original);
        },
      );
    }

    for (final endpoint in [
      'https://user:pass@synthetic.invalid/v1',
      'https://synthetic.invalid/v1#fragment',
      'synthetic.invalid/v1',
      'https://synthetic.invalid/%broken',
      'https://synthetic.invalid:0/v1',
      'https://synthetic.invalid/v1?api_key=bad',
    ]) {
      test(
        'malformed/userinfo/fragment destination fails before HTTP: $endpoint',
        () async {
          await expectLater(
            service(owner()).fetchOpenRouterModels(settings(endpoint)),
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          expect(adapter.requests, isEmpty);
          expect(storage.operations, isEmpty);
        },
      );
    }

    test(
      'native Set/Clear is keyless metadata; tombstone never adopts legacy or LLM',
      () async {
        final credentials = owner();
        final original = prefs.getString(key);
        final set = await credentials.setApiKey(native, endpoint: proxy);
        expect(set.verifiedCommit, isTrue);
        expect(set.configured, isTrue);
        expect(adapter.requests, isEmpty);
        await service(credentials).fetchOpenRouterModels(settings());
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $native',
        );
        final clear = await credentials.setApiKey('', endpoint: proxy);
        expect(clear.verifiedCommit, isTrue);
        expect(clear.configured, isFalse);
        final restarted = owner();
        expect((await restarted.load()).configured, isFalse);
        await expectLater(
          service(restarted).fetchOpenRouterModels(settings()),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(adapter.requests, hasLength(1));
        expect(await vault.hasStoredValue(slot), isTrue);
        expect(storage.values.values.single, '');
        expect(prefs.getString(key), original);
      },
    );

    for (final corrupt in [false, true]) {
      test(
        'secure ${corrupt ? 'corrupt record' : 'read failure'} is not absence',
        () async {
          if (corrupt) {
            await vault.store(slot, 'SYNTHETIC_CORRUPT_ENVELOPE');
          } else {
            storage.readError = StateError('SYNTHETIC_SECURE_READ_FAILURE');
          }
          final writes = storage.operations.where((op) => op == 'write').length;
          final credentials = owner();
          expect((await credentials.load()).unavailable, isTrue);
          await expectLater(
            service(credentials).fetchOpenRouterModels(settings()),
            throwsA(isA<CredentialVaultException>()),
          );
          expect(
            storage.operations.where((op) => op == 'write').length,
            writes,
          );
          expect(adapter.requests, isEmpty);
        },
      );
    }

    for (final badValue in [
      7,
      {'wrong': 'type'},
    ]) {
      test(
        'wrong-type legacy candidate refuses protected import: $badValue',
        () async {
          final root = document();
          (root['openrouter'] as Map)['apiKey'] = badValue;
          await prefs.setString(key, jsonEncode(root));
          expect((await owner().load()).unavailable, isTrue);
          expect(storage.operations, isNot(contains('write')));
          expect(adapter.requests, isEmpty);
        },
      );
    }

    test(
      'ordinary settings are keyless and preserve every private/unknown leaf',
      () async {
        final c = container();
        final loaded = await c.read(imageGenSettingsProvider.future);
        expect(loaded.openrouter.apiKey, isEmpty);
        expect(loaded.routmyApiKey, isEmpty);
        expect(loaded.naisteraApiKey, 'SYNTHETIC_UNCHANGED_NAISTERA');
        await c
            .read(imageGenSettingsProvider.notifier)
            .save(
              loaded.copyWith(
                enabled: true,
                openrouter: loaded.openrouter.copyWith(aspectRatio: '16:9'),
              ),
            );
        final saved = jsonDecode(prefs.getString(key)!) as Map;
        expect((saved['openrouter'] as Map)['apiKey'], legacy);
        expect((saved['openrouter'] as Map)['futurePrivateLeaf'], {
          'keep': true,
        });
        expect(saved['futurePrivateRoot'], {'keep': true});
        expect(saved['routmyApiKey'], 'SYNTHETIC_OTHER_IMAGE_KEY');
        final original = prefs.getString(key);
        await expectLater(
          c
              .read(imageGenSettingsProvider.notifier)
              .save(
                loaded.copyWith(
                  openrouter: loaded.openrouter.copyWith(apiKey: native),
                ),
              ),
          throwsStateError,
        );
        expect(prefs.getString(key), original);
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'admitted OpenRouter ordinary patch is detached before image FIFO await',
      () async {
        final credentials = owner();
        await credentials.load();
        final stored = Map<String, String>.from(storage.values);
        final gate = Completer<void>();
        final blocked = SavedPreferencesWrites.serializeImageRoutmy(
          () => gate.future,
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await blocked;
        });
        final patch = <String, dynamic>{
          'enabled': true,
          'openrouter': <String, dynamic>{'aspectRatio': '16:9'},
          'futurePrivateRoot': <String, dynamic>{
            'list': <int>[1, 2],
          },
        };
        var checkedPresence = false;
        final pending = credentials.source.saveSettings(
          patch,
          isCurrent: () => true,
          hasNativeRecord: (_) async {
            checkedPresence = true;
            return true;
          },
        );
        (patch['openrouter'] as Map)['apiKey'] = 'SYNTHETIC_PATCH_NEW_KEY';
        (patch['openrouter'] as Map)['endpoint'] = '$proxy/UNADMITTED';
        ((patch['futurePrivateRoot'] as Map)['list'] as List).add(3);
        gate.complete();
        await blocked;
        await pending;
        final saved = jsonDecode(prefs.getString(key)!) as Map;
        expect(saved['enabled'], isTrue);
        expect(saved['openrouter']['apiKey'], legacy);
        expect(saved['openrouter']['endpoint'], proxy);
        expect(saved['openrouter']['aspectRatio'], '16:9');
        expect(saved['futurePrivateRoot']['list'], [1, 2]);
        expect(checkedPresence, isFalse);
        expect(storage.values, stored);
        expect(adapter.requests, isEmpty);
      },
    );

    for (final field in ['apiKey', 'endpoint']) {
      test(
        'older routmy helper rejects direct OpenRouter $field patch without binding authority',
        () async {
          final source = ImageRoutmyLegacySource(Future.value(prefs));
          final original = prefs.getString(key);
          expect(
            () => source.saveSettings({
              'openrouter': {field: 'SYNTHETIC_UNADMITTED'},
            }, isCurrent: () => true),
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          expect(prefs.getString(key), original);
          expect(storage.operations, isEmpty);
          expect(adapter.requests, isEmpty);
        },
      );
    }

    test(
      'older routmy helper also snapshots admitted patch before queued credential injection',
      () async {
        final source = ImageRoutmyLegacySource(Future.value(prefs));
        final gate = Completer<void>();
        final blocked = SavedPreferencesWrites.serializeImageRoutmy(
          () => gate.future,
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await blocked;
        });
        final patch = <String, dynamic>{'enabled': true};
        final pending = source.saveSettings(patch, isCurrent: () => true);
        patch['openrouter'] = {'apiKey': 'SYNTHETIC_PATCH_NEW_KEY'};
        patch['routmyApiKey'] = 'SYNTHETIC_PATCH_NEW_ROUTMY_KEY';
        gate.complete();
        await blocked;
        await pending;
        final saved = jsonDecode(prefs.getString(key)!) as Map;
        expect(saved['enabled'], isTrue);
        expect(saved['openrouter']['apiKey'], legacy);
        expect(saved['routmyApiKey'], document()['routmyApiKey']);
        expect(storage.operations, isEmpty);
        expect(adapter.requests, isEmpty);
      },
    );

    for (final presence in [false, true]) {
      test(
        'endpoint edit ${presence ? 'keeps old record, never rebinds after restart' : 'cannot mint binding from preserved legacy'}',
        () async {
          final credentials = owner();
          if (presence) await credentials.load();
          final original = prefs.getString(key);
          final pending = credentials.source.saveSettings(
            {
              'openrouter': {'endpoint': '$proxy/new'},
            },
            isCurrent: () => true,
            hasNativeRecord: credentials.hasNativeRecord,
          );
          if (!presence) {
            await expectLater(
              pending,
              throwsA(isA<CredentialVaultAdmissionDenied>()),
            );
            expect(prefs.getString(key), original);
          } else {
            await pending;
            final restarted = owner();
            expect((await restarted.load()).configured, isFalse);
            await expectLater(
              service(restarted).fetchOpenRouterModels(settings('$proxy/new')),
              throwsA(isA<CredentialVaultException>()),
            );
            expect(
              (jsonDecode(storage.values.values.single) as Map)['generation'],
              '$proxy/chat/completions',
            );
            expect(
              (jsonDecode(prefs.getString(key)!)
                  as Map)['openrouter']['apiKey'],
              legacy,
            );
          }
          expect(adapter.requests, isEmpty);
        },
      );
    }

    test(
      'failed presence read blocks endpoint edit without touching JSON',
      () async {
        final credentials = owner();
        final original = prefs.getString(key);
        storage.readError = StateError('SYNTHETIC_PRESENCE_FAILURE');
        await expectLater(
          credentials.source.saveSettings(
            {
              'openrouter': {'endpoint': '$proxy/new'},
            },
            isCurrent: () => true,
            hasNativeRecord: credentials.hasNativeRecord,
          ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(prefs.getString(key), original);
      },
    );

    test(
      'original pre-await producer never adopts changed legacy or ABA',
      () async {
        final original = Completer<SharedPreferences>();
        final credentials = ImageOpenRouterCredentialOwner(
          vault: vault,
          redaction: redaction,
          originalPreferences: original.future,
        );
        addTearDown(credentials.dispose);
        final pending = credentials.load();
        final raw = prefs.getString(key)!;
        await prefs.setString(key, raw);
        original.complete(prefs);
        expect((await pending).unavailable, isTrue);
        expect(storage.operations, isNot(contains('write')));
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'old producer cannot revive when the plugin producer changes and returns',
      () async {
        final credentials = owner();
        await credentials.load();
        final guard = credentials.captureGuard();
        SharedPreferences.setMockInitialValues({key: jsonEncode(document())});
        await TrackedSharedPreferences.getInstance();
        expect(guard(), isFalse);
        expect((await credentials.load()).unavailable, isTrue);
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'latest same-vault owner wins even same-value slot ABA; committed old fact is retired',
      () async {
        final first = owner();
        final second = owner();
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        storage.beforeWrite = () async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final old = first.setApiKey(native, endpoint: proxy);
        await entered.future;
        final newest = second.setApiKey(native, endpoint: proxy);
        release.complete();
        final retired = await old;
        expect(retired.verifiedCommit, isTrue);
        expect(retired.retired, isTrue);
        expect(first.isCurrentSummary(retired), isFalse);
        expect((await newest).configured, isTrue);
        expect(
          (jsonDecode(storage.values.values.single) as Map)['key'],
          native,
        );
      },
    );

    test('vault FIFO rechecks original admission before overwrite', () async {
      final credentials = owner();
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      storage.beforeWrite = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final blocked = vault.store(slot, '');
      await entered.future;
      final old = credentials.setApiKey(legacy, endpoint: proxy);
      await Future<void>.delayed(Duration.zero);
      final newest = credentials.setApiKey(native, endpoint: proxy);
      release.complete();
      await blocked;
      expect((await old).verifiedCommit, isFalse);
      expect((await newest).configured, isTrue);
      expect(storage.operations.where((op) => op == 'write'), hasLength(2));
    });

    for (final throwing in [false, true]) {
      test(
        'invoked secure ${throwing ? 'throw' : 'dropped write'} reports unknown, never fallback',
        () async {
          if (throwing)
            storage.writeError = StateError('SYNTHETIC_WRITE_FAILURE');
          else
            storage.dropWrites = true;
          final summary = await owner().setApiKey(native, endpoint: proxy);
          expect(summary.verifiedCommit, isFalse);
          expect(summary.unknownCommit, isTrue);
          expect(summary.unavailable, isTrue);
          expect(adapter.requests, isEmpty);
          storage.dropWrites = false;
          storage.writeError = null;
          final restartedOwnerSameVault = owner();
          expect((await restartedOwnerSameVault.load()).unavailable, isTrue);
          await expectLater(
            service(restartedOwnerSameVault).fetchOpenRouterModels(settings()),
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          expect(adapter.requests, isEmpty);
          expect(storage.values, isEmpty);
        },
      );
    }

    test(
      'import and tracked backup share existing image physical FIFO',
      () async {
        final credentials = owner();
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        storage.beforeWrite = () async {
          entered.complete();
          await release.future;
        };
        final importing = credentials.load();
        await entered.future;
        var backupDone = false;
        final replacement = jsonEncode(document('$proxy/new'));
        final backup = prefs.setString(key, replacement).then((value) {
          backupDone = true;
          return value;
        });
        await Future<void>.value();
        expect(backupDone, isFalse);
        release.complete();
        expect((await importing).unavailable, isTrue);
        expect(await backup, isTrue);
        expect(prefs.getString(key), replacement);
        expect(
          (jsonDecode(storage.values.values.single) as Map)['key'],
          legacy,
        );
      },
    );

    test(
      'model IDs and names reject whole raw/encoded echoes, including CURRENT aliases',
      () async {
        const later = 'SYNTHETIC_OR_LATE:ALIAS/+%?';
        final credentials = owner();
        await credentials.setApiKey(native, endpoint: proxy);
        final current = SecretRedactionCoordinator()..registerSecret(later);
        final previousSink = activeErrorRedactor;
        activeErrorRedactor = current.redactor;
        addTearDown(() {
          activeErrorRedactor = previousSink;
          current.dispose();
        });
        dio.httpClientAdapter = _RoutmyAdapter(
          (_) => (
            status: 200,
            body: jsonEncode({
              'data': [
                {'id': 'image/$native'},
                {'id': 'image/${Uri.encodeComponent(native)}'},
                {'id': 'image/bad-name', 'name': native},
                {
                  'id': 'image/current-name',
                  'name': Uri.encodeComponent(later),
                },
                {'id': 'image/${Uri.encodeComponent(later)}'},
                {'id': 'public/image-model', 'name': 'Public Image'},
              ],
            }),
          ),
        );
        expect(await service(credentials).fetchOpenRouterModels(settings()), [
          'public/image-model',
        ]);
        final c = container();
        final loaded = await c.read(imageGenSettingsProvider.future);
        final original = prefs.getString(key);
        await expectLater(
          c
              .read(imageGenSettingsProvider.notifier)
              .save(
                loaded.copyWith(
                  openrouter: loaded.openrouter.copyWith(
                    model: 'image/${Uri.encodeComponent(later)}',
                  ),
                ),
              ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(prefs.getString(key), original);
      },
    );

    test(
      'catalog publication and errors cannot outlive native rotation',
      () async {
        final credentials = owner();
        await credentials.load();
        final entered = Completer<void>(),
            release = Completer<({int status, String body})>();
        dio.httpClientAdapter = _RoutmyAdapter((_) {
          entered.complete();
          return release.future;
        });
        final pending = service(credentials).fetchOpenRouterModels(settings());
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        await credentials.setApiKey(native, endpoint: proxy);
        release.complete((status: 200, body: '{"data":[{"id":"late/image"}]}'));
        await denied;
      },
    );

    for (final throwing in [false, true]) {
      test(
        'verified secure commit stays retired, not unknown, across invoked ordinary ${throwing ? 'throw' : 'false'}',
        () async {
          final initial = {key: jsonEncode(document())};
          SharedPreferences.setMockInitialValues(initial);
          final previousBackend = SharedPreferencesStorePlatform.instance;
          SharedPreferencesStorePlatform.instance = _FailedImageSettingsBacking(
            initial,
            throwAfterInvoke: throwing,
          );
          addTearDown(
            () => SharedPreferencesStorePlatform.instance = previousBackend,
          );
          prefs =
              await TrackedSharedPreferences.getInstance()
                  as TrackedSharedPreferences;
          final credentials = owner();
          final entered = Completer<void>(), release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          storage.beforeWrite = () async {
            entered.complete();
            await release.future;
          };
          final pending = credentials.setApiKey(native, endpoint: proxy);
          await entered.future;
          await expectLater(
            credentials.source.saveSettings(
              {'enabled': true},
              isCurrent: () => true,
              hasNativeRecord: credentials.hasNativeRecord,
            ),
            throwsA(
              isA<ImageOpenRouterSettingsWriteUnverified>().having(
                (error) => error.acknowledged,
                'original plugin ack',
                isFalse,
              ),
            ),
          );
          release.complete();
          final summary = await pending;
          expect(summary.verifiedCommit, isTrue);
          expect(summary.retired, isTrue);
          expect(summary.unknownCommit, isFalse);
          expect(summary.unavailable, isFalse);
          expect(summary.configured, isTrue);
          expect(
            (jsonDecode(storage.values.values.single) as Map)['key'],
            native,
          );
        },
      );
    }

    for (final throwing in [false, true]) {
      test(
        'ordinary ${throwing ? 'throw' : 'false'} after physical persistence and retirement stays unverified',
        () async {
          final initial = {key: jsonEncode(document())};
          SharedPreferences.setMockInitialValues(initial);
          final previousBackend = SharedPreferencesStorePlatform.instance;
          var current = true;
          final backing = _FailedImageSettingsBacking(
            initial,
            throwAfterInvoke: throwing,
            persistAfterInvoke: true,
            afterInvoke: () => current = false,
          );
          SharedPreferencesStorePlatform.instance = backing;
          addTearDown(
            () => SharedPreferencesStorePlatform.instance = previousBackend,
          );
          prefs =
              await TrackedSharedPreferences.getInstance()
                  as TrackedSharedPreferences;
          final source = ImageOpenRouterLegacySource(Future.value(prefs));
          await expectLater(
            source.saveSettings(
              {'enabled': true},
              isCurrent: () => current,
              hasNativeRecord: (_) async => false,
            ),
            throwsA(
              isA<ImageOpenRouterSettingsWriteUnverified>().having(
                (error) => error.acknowledged,
                'original plugin ack',
                isFalse,
              ),
            ),
          );
          expect(backing.writes, 1);
          final saved =
              jsonDecode(backing.values['flutter.$key']! as String)
                  as Map<String, dynamic>;
          expect(saved['enabled'], isTrue);
          expect((saved['openrouter'] as Map)['apiKey'], legacy);
          expect(adapter.requests, isEmpty);
          expect(storage.values, isEmpty);
        },
      );
    }

    test(
      'acknowledged ordinary write survives original publication retirement without issuing a receipt',
      () async {
        final initial = {key: jsonEncode(document())};
        SharedPreferences.setMockInitialValues(initial);
        final previousBackend = SharedPreferencesStorePlatform.instance;
        var current = true;
        final backing = _FailedImageSettingsBacking(
          initial,
          persistAfterInvoke: true,
          acknowledgeWrite: true,
          afterInvoke: () => current = false,
        );
        SharedPreferencesStorePlatform.instance = backing;
        addTearDown(
          () => SharedPreferencesStorePlatform.instance = previousBackend,
        );
        prefs =
            await TrackedSharedPreferences.getInstance()
                as TrackedSharedPreferences;
        final source = ImageOpenRouterLegacySource(Future.value(prefs));
        await expectLater(
          source.saveSettings(
            {'enabled': true},
            isCurrent: () => current,
            hasNativeRecord: (_) async => false,
          ),
          throwsA(isA<ImageOpenRouterSettingsRetiredCommit>()),
        );
        expect(backing.writes, 1);
        final saved =
            jsonDecode(backing.values['flutter.$key']! as String)
                as Map<String, dynamic>;
        expect(saved['enabled'], isTrue);
        expect((saved['openrouter'] as Map)['apiKey'], legacy);
        expect(adapter.requests, isEmpty);
        expect(storage.values, isEmpty);
      },
    );

    test(
      'late CURRENT model alias is denied inside the already-queued ordinary write',
      () async {
        const alias = 'SYNTHETIC_QUEUED_OR_MODEL:ALIAS/+%?';
        final c = container();
        final loaded = await c.read(imageGenSettingsProvider.future);
        final original = prefs.getString(key);
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final blocked = SavedPreferencesWrites.serializeImageRoutmy(
          () => gate.future,
        );
        final pending = c
            .read(imageGenSettingsProvider.notifier)
            .save(
              loaded.copyWith(
                openrouter: loaded.openrouter.copyWith(
                  model: 'image/${Uri.encodeComponent(alias)}',
                ),
              ),
            );
        final denied = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        final current = SecretRedactionCoordinator()..registerSecret(alias);
        final previousSink = activeErrorRedactor;
        activeErrorRedactor = current.redactor;
        addTearDown(() {
          activeErrorRedactor = previousSink;
          current.dispose();
        });
        gate.complete();
        await blocked;
        await denied;
        expect(prefs.getString(key), original);
        expect(
          c.read(imageGenSettingsProvider).value!.openrouter.model,
          loaded.openrouter.model,
        );
      },
    );

    test(
      'native key equal to an old public model alias immediately leaves keyless provider state',
      () async {
        final c = container();
        final loaded = await c.read(imageGenSettingsProvider.future);
        final original = prefs.getString(key);
        final pending = c
            .read(imageOpenRouterAuthProvider.notifier)
            .setApiKey(loaded.openrouter.model, endpoint: proxy);
        expect(
          c.read(imageGenSettingsProvider).value!.openrouter.model,
          isEmpty,
        );
        await pending;
        expect(
          c.read(imageGenSettingsProvider).value!.openrouter.apiKey,
          isEmpty,
        );
        expect(
          c.read(imageGenSettingsProvider).value!.openrouter.model,
          isEmpty,
        );
        expect(prefs.getString(key), original);
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'actual dispatcher keeps Gemini/ref/image_config behavior and exact proxy POST',
      () async {
        final credentials = owner();
        dio.httpClientAdapter = _RoutmyAdapter(
          (_) => (
            status: 200,
            body: '{"choices":[{"message":{"images":[{"b64_json":"cG5n"}]}}]}',
          ),
        );
        final bytes = await dispatcher(credentials).generate(
          settings: settings(),
          prompt: 'synthetic prompt',
          references: [
            {'image': 'cG5n', 'description': 'synthetic reference'},
          ],
          llmEndpoint: 'https://untrusted-llm.invalid',
          llmApiKey: 'SYNTHETIC_LLM_KEY',
          instructionAspectRatio: '16:9',
          instructionImageSize: '1K',
        );
        final request =
            (dio.httpClientAdapter as _RoutmyAdapter).requests.single;
        expect(bytes, utf8.encode('png'));
        expect(request.uri.toString(), '$proxy/chat/completions');
        expect(request.headers['Authorization'], 'Bearer $legacy');
        expect(request.followRedirects, isFalse);
        final body = request.data as Map;
        expect(body['modalities'], ['image', 'text']);
        expect(body['enable_base64_output'], isTrue);
        expect((body['image_config'] as Map)['aspect_ratio'], '16:9');
        expect(
          ((body['messages'] as List).single as Map)['content'],
          isA<List<Object?>>(),
        );
      },
    );

    for (final echo in [true, false]) {
      test(
        'CDN ${echo ? 'key-echo URL rejected whole before download' : 'uses checked URL without Authorization'}',
        () async {
          final credentials = owner();
          await credentials.setApiKey(native, endpoint: proxy);
          final url = echo
              ? 'https://synthetic-cdn.invalid/${Uri.encodeComponent(native)}.png'
              : 'https://synthetic-cdn.invalid/public.png?size=large';
          dio.httpClientAdapter = _RoutmyAdapter(
            (request) => request.method == 'POST'
                ? (
                    status: 200,
                    body: jsonEncode({
                      'choices': [
                        {
                          'message': {
                            'images': [
                              {'url': url},
                            ],
                          },
                        },
                      ],
                    }),
                  )
                : (status: 200, body: 'png'),
          );
          final pending = dispatcher(credentials).generate(
            settings: settings(),
            prompt: 'synthetic',
            references: [],
            llmEndpoint: '',
            llmApiKey: 'SYNTHETIC_LLM_KEY',
          );
          if (echo)
            await expectLater(pending, throwsStateError);
          else
            expect(await pending, utf8.encode('png'));
          final requests = (dio.httpClientAdapter as _RoutmyAdapter).requests;
          expect(requests, hasLength(echo ? 1 : 2));
          if (!echo) {
            expect(requests.last.uri.toString(), url);
            expect(requests.last.headers.containsKey('Authorization'), isFalse);
            expect(requests.last.followRedirects, isFalse);
          }
        },
      );
    }

    for (final duringDownload in [false, true]) {
      test(
        'original custody stops ${duringDownload ? 'late CDN completion' : 'download after late POST'} on rotation',
        () async {
          final credentials = owner();
          await credentials.load();
          final entered = Completer<void>(),
              release = Completer<({int status, String body})>();
          final json = jsonEncode({
            'choices': [
              {
                'message': {
                  'images': [
                    {'url': 'https://synthetic-cdn.invalid/public.png'},
                  ],
                },
              },
            ],
          });
          dio.httpClientAdapter = _RoutmyAdapter((request) {
            if ((request.method == 'GET') == duringDownload) {
              entered.complete();
              return release.future;
            }
            return (status: 200, body: json);
          });
          final pending = dispatcher(credentials).generate(
            settings: settings(),
            prompt: 'synthetic',
            references: [],
            llmEndpoint: '',
            llmApiKey: 'SYNTHETIC_LLM_KEY',
          );
          final denied = expectLater(
            pending,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          await entered.future;
          await credentials.setApiKey(native, endpoint: proxy);
          release.complete((status: 200, body: duringDownload ? 'png' : json));
          await denied;
          expect(
            (dio.httpClientAdapter as _RoutmyAdapter).requests,
            hasLength(duringDownload ? 2 : 1),
          );
        },
      );
    }

    test(
      'public signed CDN query is sent verbatim without API bearer or redirects',
      () async {
        const url =
            'https://synthetic-cdn.invalid/public.png?token=PUBLIC%2BVALUE%3D&credential=PUBLIC_SIG&size=large';
        final credentials = owner();
        await credentials.setApiKey(native, endpoint: proxy);
        dio.httpClientAdapter = _RoutmyAdapter(
          (request) => request.method == 'POST'
              ? (
                  status: 200,
                  body: jsonEncode({
                    'choices': [
                      {
                        'message': {
                          'images': [
                            {'url': url},
                          ],
                        },
                      },
                    ],
                  }),
                )
              : (status: 200, body: 'png'),
        );
        expect(
          await dispatcher(credentials).generate(
            settings: settings(),
            prompt: 'synthetic',
            references: [],
            llmEndpoint: '',
            llmApiKey: 'SYNTHETIC_LLM_KEY',
          ),
          utf8.encode('png'),
        );
        final requests = (dio.httpClientAdapter as _RoutmyAdapter).requests;
        expect(requests, hasLength(2));
        expect(requests.last.uri.toString(), url);
        expect(requests.last.headers.containsKey('Authorization'), isFalse);
        expect(requests.last.followRedirects, isFalse);
      },
    );

    for (final current in [false, true]) {
      test(
        '${current ? 'CURRENT' : 'original'} partly percent-encoded known CDN secret refuses download',
        () async {
          const alias = 'SYNTHETIC_IMAGE_NATIVE';
          const url =
              'https://synthetic-cdn.invalid/SYNTHETIC%5fIMAGE_NATIVE.png?token=PUBLIC';
          final credentials = owner();
          await credentials.setApiKey(
            current ? native : alias,
            endpoint: proxy,
          );
          final policy = SecretRedactionCoordinator()..registerSecret(alias);
          final previous = activeErrorRedactor;
          if (current) activeErrorRedactor = policy.redactor;
          addTearDown(() {
            activeErrorRedactor = previous;
            policy.dispose();
          });
          dio.httpClientAdapter = _RoutmyAdapter(
            (_) => (
              status: 200,
              body: jsonEncode({
                'choices': [
                  {
                    'message': {
                      'images': [
                        {'url': url},
                      ],
                    },
                  },
                ],
              }),
            ),
          );
          await expectLater(
            dispatcher(credentials).generate(
              settings: settings(),
              prompt: 'synthetic',
              references: [],
              llmEndpoint: '',
              llmApiKey: 'SYNTHETIC_LLM_KEY',
            ),
            throwsStateError,
          );
          expect(
            (dio.httpClientAdapter as _RoutmyAdapter).requests,
            hasLength(1),
          );
        },
      );
    }

    test(
      'CURRENT signed CDN alias during download refuses completion without a second request',
      () async {
        const url =
            'https://synthetic-cdn.invalid/public.png?token=PUBLIC%2BVALUE%3D&credential=PUBLIC_SIG';
        final credentials = owner();
        await credentials.setApiKey(native, endpoint: proxy);
        final entered = Completer<void>(),
            release = Completer<({int status, String body})>();
        final policy = SecretRedactionCoordinator();
        final previous = activeErrorRedactor;
        addTearDown(() {
          activeErrorRedactor = previous;
          policy.dispose();
          if (!release.isCompleted)
            release.complete((status: 200, body: 'png'));
        });
        dio.httpClientAdapter = _RoutmyAdapter((request) {
          if (request.method == 'GET') {
            entered.complete();
            return release.future;
          }
          return (
            status: 200,
            body: jsonEncode({
              'choices': [
                {
                  'message': {
                    'images': [
                      {'url': url},
                    ],
                  },
                },
              ],
            }),
          );
        });
        final pending = dispatcher(credentials).generate(
          settings: settings(),
          prompt: 'synthetic',
          references: [],
          llmEndpoint: '',
          llmApiKey: 'SYNTHETIC_LLM_KEY',
        );
        final refused = expectLater(pending, throwsStateError);
        await entered.future;
        policy.registerSecret('PUBLIC+VALUE=');
        activeErrorRedactor = policy.redactor;
        release.complete((status: 200, body: 'png'));
        await refused;
        final requests = (dio.httpClientAdapter as _RoutmyAdapter).requests;
        expect(requests, hasLength(2));
        expect(requests.last.uri.toString(), url);
        expect(requests.last.headers.containsKey('Authorization'), isFalse);
      },
    );

    test(
      'late CURRENT public URL alias is refused before download without rotating native key',
      () async {
        const alias = 'SYNTHETIC_LATE_CDN:ALIAS/+%?';
        final credentials = owner();
        await credentials.load();
        final entered = Completer<void>(),
            release = Completer<({int status, String body})>();
        dio.httpClientAdapter = _RoutmyAdapter((_) {
          entered.complete();
          return release.future;
        });
        final pending = dispatcher(credentials).generate(
          settings: settings(),
          prompt: 'synthetic',
          references: [],
          llmEndpoint: '',
          llmApiKey: 'SYNTHETIC_LLM_KEY',
        );
        final denied = expectLater(pending, throwsStateError);
        await entered.future;
        final current = SecretRedactionCoordinator()..registerSecret(alias);
        final previousSink = activeErrorRedactor;
        activeErrorRedactor = current.redactor;
        addTearDown(() {
          activeErrorRedactor = previousSink;
          current.dispose();
        });
        release.complete((
          status: 200,
          body: jsonEncode({
            'choices': [
              {
                'message': {
                  'images': [
                    {
                      'url':
                          'https://synthetic-cdn.invalid/${Uri.encodeComponent(alias)}.png',
                    },
                  ],
                },
              },
            ],
          }),
        ));
        await denied;
        expect(
          (dio.httpClientAdapter as _RoutmyAdapter).requests,
          hasLength(1),
        );
      },
    );

    for (final disposed in [false, true]) {
      test(
        'ephemeral native error retains ORIGINAL coverage and CURRENT late aliases after await (disposed=$disposed)',
        () async {
          const later = 'SYNTHETIC_OR_ERROR_LATE:ALIAS/+%?';
          final credentials = owner();
          await credentials.setApiKey(native, endpoint: proxy);
          final current = SecretRedactionCoordinator();
          final previousSink = activeErrorRedactor;
          addTearDown(() {
            activeErrorRedactor = previousSink;
            current.dispose();
          });
          await expectLater(
            credentials.withApiKey<void>(
              destinations: ImageOpenRouterDestinations(proxy),
              consume: (key, check) async {
                if (disposed) redaction.dispose();
                current.registerSecret(later);
                activeErrorRedactor = current.redactor;
                throw StateError(
                  'HTTP 400 $key ${Uri.encodeComponent(key)} $later ${Uri.encodeComponent(later)}',
                );
              },
            ),
            throwsA(
              predicate((error) {
                final text = error.toString();
                return (disposed
                        ? text == 'Bad state: [REDACTION_LIMIT]'
                        : text.contains('HTTP 400')) &&
                    [native, later].every(
                      (value) =>
                          !text.contains(value) &&
                          !text.contains(Uri.encodeComponent(value)),
                    );
              }),
            ),
          );
        },
      );
    }
  });
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
