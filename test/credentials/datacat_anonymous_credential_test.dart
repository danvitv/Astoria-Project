import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/datacat_account_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/datacat_anonymous_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/datacat_anonymous_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/datacat_anonymous_preferences.dart';
import 'package:glaze_flutter/core/credentials/datacat_anonymous_transport.dart';
import 'package:glaze_flutter/core/credentials/datacat_installation_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/catalog/services/datacat_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Only the existing synthetic legacy backing-store seam, never native storage.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fake_credential_storage.dart';

const _key = DatacatAnonymousPreferences.token;
const _deviceKey = DatacatAnonymousPreferences.device;
const _device = '11111111-2222-4333-8444-555555555555';
const _character = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _legacy = 'SYNTHETIC_DATACAT_ANONYMOUS_LEGACY_CANARY';
const _next = 'SYNTHETIC_DATACAT_ANONYMOUS_NEXT_CANARY';
const _oldReply = 'SYNTHETIC_DATACAT_ANONYMOUS_STALE_REPLY_CANARY';
const _linked = 'SYNTHETIC_DATACAT_LINKED_UNTOUCHED_CANARY';
const _url = 'https://janitorai.com/characters/$_character';
final _slot = CredentialSlot(domain: 'catalog.datacat', id: 'anonymous');

Map<String, dynamic> _card({
  String definition = 'SYNTHETIC_DEFINITION',
  String? avatar,
}) => {
  'character': {
    'name': 'SYNTHETIC_CHARACTER',
    'personality': definition,
    'description': 'SYNTHETIC_NOTES',
    'first_messages': ['FIRST', 'SECOND'],
    if (avatar != null) 'avatar': avatar,
  },
};

final class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final FutureOr<({int status, Object body})> Function(RequestOptions) reply;
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
      response.body is String
          ? response.body as String
          : jsonEncode(response.body),
      response.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _DeviceBacking extends SharedPreferencesStorePlatform {
  final values = <String, Object>{};
  final writes = <String>[];
  Future<void> Function(String key)? beforeWrite;
  bool reject = false, throwWrite = false, persistOnFailure = false;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    await beforeWrite?.call(key);
    if ((!reject && !throwWrite) || persistOnFailure) values[key] = value;
    if (throwWrite) throw StateError('SYNTHETIC_PRIVATE_WRITE_FAILURE');
    return !reject;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCredentialStorage storage;
  late CredentialVault vault;
  late SecretRedactionCoordinator redaction;
  late TrackedSharedPreferences prefs;

  Future<void> preferences(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    prefs =
        await TrackedSharedPreferences.getInstance()
            as TrackedSharedPreferences;
  }

  Future<void> deviceBacking(_DeviceBacking backing) async {
    SharedPreferences.setMockInitialValues({});
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = backing;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    prefs =
        await TrackedSharedPreferences.getInstance()
            as TrackedSharedPreferences;
  }

  setUp(() async {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    redaction = SecretRedactionCoordinator();
    addTearDown(redaction.dispose);
    await preferences({
      _key: _legacy,
      _deviceKey: _device,
      'gz_dc_user_token': _linked,
    });
  });

  DatacatAnonymousCredentialOwner owner({
    Future<SharedPreferences>? original,
  }) => DatacatAnonymousCredentialOwner(
    vault: vault,
    redaction: redaction,
    originalPreferences: original ?? Future.value(prefs),
  );
  DatacatAnonymousExtractor extractor(
    _Adapter adapter, {
    DatacatAnonymousCredentialOwner? credentials,
    Future<void> Function(Duration)? delay,
  }) => DatacatAnonymousExtractor(
    credentials: credentials ?? owner(),
    transport: DatacatAnonymousTransport(
      redaction: redaction,
      dio: Dio()..httpClientAdapter = adapter,
    ),
    delay: delay ?? ((_) async {}),
  );

  test(
    'actual character reader imports exact bytes into separate private slot',
    () async {
      final linkedSlot = CredentialSlot(
        domain: 'catalog.datacat',
        id: 'account',
      );
      await vault.store(linkedSlot, _linked);
      final adapter = _Adapter((request) {
        expect(request.uri.origin, 'https://datacat.run');
        expect(request.uri.path, '/api/characters/$_character');
        expect(request.uri.queryParameters['sourceKind'], 'janitor');
        expect(request.headers['X-Session-Token'], _legacy);
        expect(request.headers['Origin'], 'https://datacat.run');
        expect(request.headers['Referer'], 'https://datacat.run/');
        expect(request.headers['User-Agent'], contains('Chrome/136.0.0.0'));
        expect(request.followRedirects, false);
        expect(request.maxRedirects, 0);
        return (status: 200, body: _card(definition: 'BEFORE $_legacy AFTER'));
      });
      final result = await extractor(adapter).getCharacter(_character);
      expect(result.charData.description, 'BEFORE [REDACTED] AFTER');
      expect(result.charData.firstMes, 'FIRST');
      expect(result.charData.alternateGreetings, ['SECOND']);
      expect(storage.values.values, containsAll([_legacy, _linked]));
      expect(
        storage.values.keys.where((key) => key.endsWith(':anonymous')),
        hasLength(1),
      );
      expect(prefs.getString(_key), _legacy);
      expect(prefs.getString('gz_dc_user_token'), _linked);
      expect(prefs.getString(_deviceKey), _device);
      expect(storage.operations, isNot(contains('delete')));
      expect(PrivatePreferenceKeys.tracked, contains(_key));
      expect(SavedPreferencesKeys.all, isNot(contains(_key)));
      expect(SavedPreferencesKeys.families.length, 5);
    },
  );

  for (final protected in [_next, '']) {
    test(
      'existing protected ${protected.isEmpty ? 'empty' : 'token'} never adopts legacy',
      () async {
        await vault.store(_slot, protected);
        storage.operations.clear();
        final adapter = _Adapter((_) => (status: 200, body: _card()));
        final native = extractor(adapter);
        if (protected.isEmpty) {
          await expectLater(
            native.getCharacter(_character),
            throwsA(
              isA<CredentialVaultException>().having(
                (e) => e.failure,
                'failure',
                CredentialVaultFailure.missing,
              ),
            ),
          );
          await expectLater(
            native.initialize(),
            throwsA(isA<CredentialVaultException>()),
          );
          expect(adapter.requests, isEmpty);
        } else {
          await native.getCharacter(_character);
          expect(adapter.requests.single.headers['X-Session-Token'], _next);
        }
        expect(storage.operations, isNot(contains('write')));
        expect(storage.values.values, [protected]);
        expect(prefs.getString(_key), _legacy);
      },
    );
  }

  for (final failure in ['secure read', 'secure write', 'unequal readback']) {
    test(
      '$failure is not absence, plaintext fallback or identify permission',
      () async {
        if (failure == 'secure read')
          storage.readError = StateError('PRIVATE $_legacy');
        if (failure == 'secure write')
          storage.writeError = StateError('PRIVATE $_legacy');
        if (failure == 'unequal readback') storage.dropWrites = true;
        final adapter = _Adapter((_) => (status: 200, body: _card()));
        final result = await extractor(adapter).extractAndPoll(_url);
        expect(result.charData, isNull);
        expect(result.error, 'DataCat extraction is unavailable.');
        expect(adapter.requests, isEmpty);
        expect(prefs.getString(_key), _legacy);
        expect(storage.operations, isNot(contains('delete')));
      },
    );
  }

  test(
    'later secure failure cannot reuse a hydrated token or run recovery',
    () async {
      final adapter = _Adapter((_) => (status: 200, body: _card()));
      final native = extractor(adapter);
      await native.getCharacter(_character);
      storage.readError = StateError('PRIVATE $_legacy');
      final result = await native.extractAndPoll(_url);
      expect(result.error, 'DataCat extraction is unavailable.');
      expect(adapter.requests, hasLength(1));
    },
  );

  test('wrong-type legacy value refuses safely before native HTTP', () async {
    await preferences({_key: 123, _deviceKey: _device});
    final adapter = _Adapter((_) => (status: 200, body: _card()));
    await expectLater(
      extractor(adapter).getCharacter(_character),
      throwsA(isA<CredentialVaultException>()),
    );
    expect(adapter.requests, isEmpty);
    expect(storage.values, isEmpty);
    expect(prefs.get(_key), 123);
  });

  test(
    'verified absence uses original identify endpoint/device without plaintext persistence',
    () async {
      await preferences({_deviceKey: _device, 'gz_dc_user_token': _linked});
      final adapter = _Adapter((request) {
        if (request.uri.path == '/api/liberator/identify') {
          expect(request.method, 'POST');
          expect(jsonDecode(request.data as String), {'deviceToken': _device});
          expect(request.headers['X-Session-Token'], isNull);
          return (status: 200, body: {'sessionToken': _next});
        }
        expect(request.headers['X-Session-Token'], _next);
        if (request.method == 'POST') {
          expect(request.uri.path, '/api/character/smart-extract-v2');
          final body = jsonDecode(request.data as String) as Map;
          expect(body['url'], _url);
          expect(body['appearOnPublicFeed'], true);
          expect(body['useSeparateWorkerServer'], true);
          expect(body['inlinePostExtractCreatorProfile'], true);
          expect(body['idempotencyKey'], matches(r'^[a-f0-9-]{36}$'));
          return (status: 200, body: {'characterId': _character});
        }
        return (status: 200, body: _card());
      });
      final result = await extractor(adapter).extractAndPoll(_url);
      expect(result.charData?.name, 'SYNTHETIC_CHARACTER');
      expect(adapter.requests, hasLength(3));
      expect(storage.values.values, [_next]);
      expect(prefs.containsKey(_key), false);
      expect(prefs.getString(_deviceKey), _device);
      expect(prefs.getString('gz_dc_user_token'), _linked);
      expect(redaction.redactor.redactText(_next), '[REDACTED]');
    },
  );

  for (final device in <Object?>[null, '']) {
    test(
      'missing/empty original identity is never generated or rebound: $device',
      () async {
        await preferences({
          if (device != null) _deviceKey: device,
          'gz_dc_user_token': _linked,
        });
        final adapter = _Adapter(
          (_) => (status: 200, body: {'sessionToken': _next}),
        );
        final result = await extractor(adapter).extractAndPoll(_url);
        expect(result.error, 'DataCat extraction is unavailable.');
        expect(adapter.requests, isEmpty);
        expect(prefs.get(_deviceKey), device);
        expect(prefs.getString('gz_dc_user_token'), _linked);
        expect(storage.values, isEmpty);
      },
    );
  }

  test(
    'genuine first extraction births once and shares only its issued original custody',
    () async {
      await preferences({'SYNTHETIC_SIBLING': 'UNCHANGED'});
      final original = Future<SharedPreferences>.value(prefs);
      final anonymous = owner(original: original);
      final linked = DatacatAccountCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: original,
      );
      addTearDown(linked.dispose);
      expect(storage.operations, isEmpty);
      expect(prefs.containsKey(_deviceKey), false);
      String? born;
      final adapter = _Adapter((request) {
        if (request.uri.path == '/api/liberator/identify') {
          born =
              (jsonDecode(request.data as String) as Map)['deviceToken']
                  as String;
          expect(born, matches(r'^[a-f0-9-]{36}$'));
          expect(prefs.getString(_deviceKey), born);
          return (status: 200, body: {'sessionToken': _next});
        }
        expect(request.headers['X-Session-Token'], _next);
        return request.method == 'POST'
            ? (status: 200, body: {'characterId': _character})
            : (status: 200, body: _card());
      });
      final native = extractor(adapter, credentials: anonymous);
      expect(
        (await native.extractAndPoll(_url)).charData?.name,
        'SYNTHETIC_CHARACTER',
      );
      expect((await linked.load()).authenticated, false);
      await linked.link((device, current, commit) async {
        expect(device, born);
        expect(current(), true);
        await commit(_linked, 'SYNTHETIC_ACCOUNT', const []);
      });
      await native.getCharacter(_character);
      expect(prefs.getString(_deviceKey), born);
      expect(prefs.getKeys(), {_deviceKey, 'SYNTHETIC_SIBLING'});
      expect(prefs.getString('SYNTHETIC_SIBLING'), 'UNCHANGED');
      expect(storage.values.values, contains(_next));
      expect(storage.operations, isNot(contains('delete')));
    },
  );

  for (final inherited in [_key, 'gz_dc_user_token']) {
    test(
      'inherited $inherited without device never grants birth or extraction',
      () async {
        await preferences({inherited: _legacy});
        final adapter = _Adapter((_) => (status: 200, body: _card()));
        final result = await extractor(adapter).extractAndPoll(_url);
        expect(result.error, 'DataCat extraction is unavailable.');
        expect(adapter.requests, isEmpty);
        expect(storage.values, isEmpty);
        expect(prefs.getKeys(), {inherited});
      },
    );
  }

  for (final id in ['account', 'anonymous']) {
    for (final protected in [_next, '']) {
      test(
        'protected $id ${protected.isEmpty ? 'tombstone' : 'token'} without device refuses birth',
        () async {
          await preferences({});
          await vault.store(
            CredentialSlot(domain: 'catalog.datacat', id: id),
            protected,
          );
          storage.operations.clear();
          final adapter = _Adapter((_) => (status: 200, body: _card()));
          final result = await extractor(adapter).extractAndPoll(_url);
          expect(result.error, 'DataCat extraction is unavailable.');
          expect(adapter.requests, isEmpty);
          expect(prefs.getKeys(), isEmpty);
          expect(storage.values.values, [protected]);
          expect(storage.operations, isNot(contains('write')));
        },
      );
    }
  }

  for (final invalid in <Object>[
    '',
    'short',
    'invalid binding with spaces',
    123,
  ]) {
    test(
      'exact inherited invalid device is not regenerated: $invalid',
      () async {
        await preferences({_deviceKey: invalid});
        final adapter = _Adapter((_) => (status: 200, body: _card()));
        expect(
          (await extractor(adapter).extractAndPoll(_url)).error,
          'DataCat extraction is unavailable.',
        );
        expect(adapter.requests, isEmpty);
        expect(prefs.get(_deviceKey), invalid);
        expect(storage.values, isEmpty);
      },
    );
  }

  test('failed secure absence read cannot birth a missing device', () async {
    await preferences({});
    storage.readError = StateError('SYNTHETIC_PRIVATE_READ_FAILURE');
    final adapter = _Adapter((_) => (status: 200, body: _card()));
    expect(
      (await extractor(adapter).extractAndPoll(_url)).error,
      'DataCat extraction is unavailable.',
    );
    expect(prefs.getKeys(), isEmpty);
    expect(adapter.requests, isEmpty);
    expect(storage.values, isEmpty);
  });

  test(
    'same-vault account tombstone during second absence read fences first identify',
    () async {
      final backing = _DeviceBacking();
      await deviceBacking(backing);
      final original = Future<SharedPreferences>.value(prefs);
      final linked = DatacatAccountCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: original,
      );
      addTearDown(linked.dispose);
      final guard = linked.captureAuthGuard();
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeRead = () async {
        // Three anonymous presence reads, then the installation's account read
        // and its SECOND secure absence read. Different vault slots do not wait.
        if (storage.reads == 5) {
          entered.complete();
          await release.future;
        }
      };
      final adapter = _Adapter(
        (_) => (status: 200, body: {'sessionToken': _next}),
      );
      final anonymous = owner(original: original);
      final transport = DatacatAnonymousTransport(
        redaction: redaction,
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(transport.dispose);
      var identifies = 0;
      final refused = expectLater(
        anonymous.initialize(anonymous.captureOperation(), (
          device,
          current,
          commit,
        ) {
          identifies++;
          return transport.identify(device, current, commit);
        }),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      try {
        await entered.future;
        expect(guard(), true);
        await linked.forgetRevoked(isCurrent: guard);
        expect(storage.values.values, ['']);
        expect(storage.operations.where((op) => op == 'write'), hasLength(1));
        expect(backing.writes, isEmpty);
        expect(adapter.requests, isEmpty);
        expect(identifies, 0);
      } finally {
        release.complete();
        await refused;
      }
      expect(prefs.getKeys(), isEmpty);
      expect(backing.writes, isEmpty);
      expect(adapter.requests, isEmpty);
      expect(identifies, 0);
    },
  );

  test(
    'known deleted device cannot be regenerated by a fresh native producer',
    () async {
      await preferences({_deviceKey: _device});
      final linked = DatacatAccountCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: Future.value(prefs),
      );
      addTearDown(linked.dispose);
      expect((await linked.load()).authenticated, false);
      expect(await prefs.remove(_deviceKey), true);
      final adapter = _Adapter((_) => (status: 200, body: _card()));
      expect(
        (await extractor(adapter).extractAndPoll(_url)).error,
        'DataCat extraction is unavailable.',
      );
      expect(prefs.getKeys(), isEmpty);
      expect(adapter.requests, isEmpty);
      expect(storage.values, isEmpty);
    },
  );

  for (final throws in [false, true]) {
    test(
      'ambiguous device write ${throws ? 'throw' : 'false'} has no receipt, HTTP or regeneration',
      () async {
        final backing = _DeviceBacking()
          ..reject = !throws
          ..throwWrite = throws
          ..persistOnFailure = true;
        await deviceBacking(backing);
        final original = Future<SharedPreferences>.value(prefs);
        final adapter = _Adapter((_) => (status: 200, body: _card()));
        final native = extractor(
          adapter,
          credentials: owner(original: original),
        );
        await expectLater(
          native.initialize(),
          throwsA(isA<DatacatInstallationWriteUnverified>()),
        );
        await expectLater(
          Future<void>.sync(
            () => extractor(
              adapter,
              credentials: owner(original: original),
            ).initialize(),
          ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(backing.writes, ['flutter.$_deviceKey']);
        expect(adapter.requests, isEmpty);
        expect(storage.values, isEmpty);
      },
    );
  }

  for (final throws in [false, true]) {
    test(
      'invoked device ${throws ? 'throw' : 'false'} remains unknown after original anonymous retirement',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final backing = _DeviceBacking()
          ..reject = !throws
          ..throwWrite = throws
          ..persistOnFailure = true
          ..beforeWrite = (_) async {
            entered.complete();
            await release.future;
          };
        await deviceBacking(backing);
        final original = Future<SharedPreferences>.value(prefs);
        final credentials = owner(original: original);
        final adapter = _Adapter(
          (_) => (status: 200, body: {'sessionToken': _next}),
        );
        final native = extractor(adapter, credentials: credentials);
        final unknown = expectLater(
          native.initialize(),
          throwsA(isA<DatacatInstallationWriteUnverified>()),
        );
        await entered.future;
        credentials.dispose();
        release.complete();
        await unknown;
        await expectLater(
          Future<void>.sync(
            () => extractor(
              adapter,
              credentials: owner(original: original),
            ).initialize(),
          ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(backing.writes, ['flutter.$_deviceKey']);
        expect(backing.values.keys, ['flutter.$_deviceKey']);
        expect(adapter.requests, isEmpty);
        expect(storage.values, isEmpty);
      },
    );
  }

  test(
    'secure token write failure after birth cannot persist plaintext or regenerate device',
    () async {
      final backing = _DeviceBacking();
      await deviceBacking(backing);
      storage.writeError = StateError('SYNTHETIC_PRIVATE_TOKEN_WRITE_FAILURE');
      final adapter = _Adapter(
        (_) => (status: 200, body: {'sessionToken': _next}),
      );
      final native = extractor(adapter);
      await expectLater(
        native.initialize(),
        throwsA(isA<CredentialVaultException>()),
      );
      final born = prefs.getString(_deviceKey);
      await expectLater(
        native.initialize(),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(prefs.getString(_deviceKey), born);
      expect(prefs.containsKey(_key), false);
      expect(backing.writes, ['flutter.$_deviceKey']);
      expect(adapter.requests, hasLength(2));
      expect(storage.values, isEmpty);
    },
  );

  for (final separateGraph in [false, true]) {
    test(
      'competing first initialization keeps one acknowledged device and newest HTTP: $separateGraph',
      () async {
        final backing = _DeviceBacking();
        final entered = Completer<void>(), release = Completer<void>();
        backing.beforeWrite = (_) async {
          entered.complete();
          await release.future;
        };
        await deviceBacking(backing);
        final original = Future<SharedPreferences>.value(prefs);
        final adapter = _Adapter(
          (_) => (status: 200, body: {'sessionToken': _next}),
        );
        final first = extractor(
          adapter,
          credentials: owner(original: original),
        );
        final refused = expectLater(
          first.initialize(),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        expect(adapter.requests, isEmpty); // Optimistic cache is NOT a receipt.
        final second = separateGraph
            ? extractor(adapter, credentials: owner(original: original))
            : first;
        final newest = second.initialize();
        await pumpEventQueue();
        expect(adapter.requests, isEmpty);
        release.complete();
        await refused;
        await newest;
        expect(backing.writes, ['flutter.$_deviceKey']);
        expect(adapter.requests, hasLength(1));
        expect(storage.values.values, [_next]);
      },
    );
  }

  test(
    'device-write ABA retires birth receipt and never adopts conflicting backup',
    () async {
      final backing = _DeviceBacking();
      final entered = Completer<void>(), release = Completer<void>();
      backing.beforeWrite = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      await deviceBacking(backing);
      final original = Future<SharedPreferences>.value(prefs);
      final adapter = _Adapter(
        (_) => (status: 200, body: {'sessionToken': _next}),
      );
      final native = extractor(adapter, credentials: owner(original: original));
      final refused = expectLater(
        native.initialize(),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      final optimistic = prefs.getString(_deviceKey)!;
      final backup = prefs.setString(_deviceKey, optimistic);
      release.complete();
      await refused;
      expect(await backup, true);
      await expectLater(
        Future<void>.sync(native.initialize),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(adapter.requests, isEmpty);
      expect(storage.values, isEmpty);
      expect(prefs.getString(_deviceKey), optimistic);
      expect(backing.writes, ['flutter.$_deviceKey', 'flutter.$_deviceKey']);
    },
  );

  test(
    'anonymous backup admitted during device write cannot borrow its birth receipt',
    () async {
      final backing = _DeviceBacking();
      final entered = Completer<void>(), release = Completer<void>();
      backing.beforeWrite = (key) async {
        if (key == 'flutter.$_deviceKey') {
          entered.complete();
          await release.future;
        }
      };
      await deviceBacking(backing);
      final original = Future<SharedPreferences>.value(prefs);
      final adapter = _Adapter(
        (_) => (status: 200, body: {'sessionToken': _next}),
      );
      final native = extractor(adapter, credentials: owner(original: original));
      final refused = expectLater(
        native.initialize(),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      expect(await prefs.setString(_key, _legacy), true);
      release.complete();
      await refused;
      await expectLater(
        Future<void>.sync(native.initialize),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(prefs.getString(_key), _legacy);
      expect(adapter.requests, isEmpty);
      expect(storage.values, isEmpty);
      expect(
        backing.writes.where((key) => key == 'flutter.$_deviceKey'),
        hasLength(1),
      );
    },
  );

  test(
    'whole-store clear during birth retires its receipt before any native HTTP',
    () async {
      final backing = _DeviceBacking();
      final entered = Completer<void>(), release = Completer<void>();
      backing.beforeWrite = (_) async {
        entered.complete();
        await release.future;
      };
      await deviceBacking(backing);
      final adapter = _Adapter(
        (_) => (status: 200, body: {'sessionToken': _next}),
      );
      final native = extractor(adapter);
      final refused = expectLater(
        native.initialize(),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      final clearing = prefs.clear();
      release.complete();
      await refused;
      expect(await clearing, true);
      await expectLater(
        Future<void>.sync(native.initialize),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(prefs.getKeys(), isEmpty);
      expect(adapter.requests, isEmpty);
      expect(storage.values, isEmpty);
      expect(backing.writes, ['flutter.$_deviceKey']);
    },
  );

  test(
    'replacement original store during birth cannot inherit the pending device receipt',
    () async {
      final backing = _DeviceBacking();
      final entered = Completer<void>(), release = Completer<void>();
      backing.beforeWrite = (_) async {
        entered.complete();
        await release.future;
      };
      await deviceBacking(backing);
      final adapter = _Adapter(
        (_) => (status: 200, body: {'sessionToken': _next}),
      );
      final native = extractor(adapter);
      final refused = expectLater(
        native.initialize(),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await preferences({_deviceKey: _device});
      release.complete();
      await refused;
      await expectLater(
        Future<void>.sync(native.initialize),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(prefs.getString(_deviceKey), _device);
      expect(adapter.requests, isEmpty);
      expect(storage.values, isEmpty);
      expect(backing.writes, ['flutter.$_deviceKey']);
    },
  );

  for (final status in [401, 403]) {
    test(
      '$status recovery is bounded, native, and preserves legacy/device',
      () async {
        var calls = 0;
        final adapter = _Adapter((request) {
          if (request.uri.path == '/api/liberator/identify') {
            expect(jsonDecode(request.data as String), {
              'deviceToken': _device,
            });
            return (status: 200, body: {'sessionToken': _next});
          }
          if (++calls == 1)
            return (status: status, body: {'error': 'EXPIRED $_legacy'});
          expect(request.headers['X-Session-Token'], _next);
          return (status: 200, body: _card(definition: '$_legacy $_next'));
        });
        final result = await extractor(adapter).getCharacter(_character);
        expect(result.charData.description, '[REDACTED] [REDACTED]');
        expect(adapter.requests, hasLength(3));
        expect(adapter.requests.first.uri, adapter.requests.last.uri);
        expect(storage.values.values, [_next]);
        expect(prefs.getString(_key), _legacy);
        expect(prefs.getString(_deviceKey), _device);
        expect(prefs.getString('gz_dc_user_token'), _linked);
        expect(storage.operations, isNot(contains('delete')));
      },
    );
    test('second $status is terminal, never a third attempt', () async {
      final adapter = _Adapter(
        (request) => request.uri.path == '/api/liberator/identify'
            ? (status: 200, body: {'sessionToken': _next})
            : (status: status, body: {'error': 'EXPIRED $_legacy $_next'}),
      );
      await expectLater(
        extractor(adapter).getCharacter(_character),
        throwsA(
          isA<DatacatAnonymousHttpException>()
              .having((e) => e.status, 'status', status)
              .having((e) => e.toString(), 'safe', isNot(contains(_legacy))),
        ),
      );
      expect(adapter.requests, hasLength(3));
    });
  }

  test('401 text in a 500 body is not session recovery', () async {
    final adapter = _Adapter(
      (_) => (status: 500, body: {'error': '401 $_legacy'}),
    );
    await expectLater(
      extractor(adapter).getCharacter(_character),
      throwsA(
        isA<DatacatAnonymousHttpException>().having(
          (e) => e.status,
          'status',
          500,
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
    expect(storage.values.values, [_legacy]);
  });

  for (final separateGraph in [false, true]) {
    test(
      'newest identify owns commit before HTTP, old reply refuses: $separateGraph',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        var calls = 0;
        final adapter = _Adapter((request) async {
          expect(request.uri.path, '/api/liberator/identify');
          if (++calls == 1) {
            entered.complete();
            await release.future;
            return (status: 200, body: {'sessionToken': _oldReply});
          }
          return (status: 200, body: {'sessionToken': _next});
        });
        final first = extractor(adapter);
        final pending = first.initialize();
        final refused = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final second = separateGraph ? extractor(adapter) : first;
        await second.initialize();
        release.complete();
        await refused;
        expect(storage.values.values, [_next]);
        expect(redaction.redactor.redactText(_oldReply), '[REDACTED]');
        expect(prefs.getString(_key), _legacy);
      },
    );
  }

  test(
    'disposed native HTTP cannot publish late character or returned aliases',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final adapter = _Adapter((_) async {
        entered.complete();
        await release.future;
        return (status: 200, body: {..._card(), 'sessionToken': _oldReply});
      });
      final native = extractor(adapter);
      final pending = native.getCharacter(_character);
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      native.dispose();
      release.complete();
      await refused;
      expect(adapter.requests, hasLength(1));
      expect(redaction.redactor.redactText(_oldReply), '[REDACTED]');
    },
  );

  test(
    'same-value tracked ABA permanently retires pre-await owner before import',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeRead = () async {
        if (storage.reads == 1) {
          entered.complete();
          await release.future;
        }
      };
      final adapter = _Adapter((_) => (status: 200, body: _card()));
      final native = extractor(adapter);
      final pending = native.getCharacter(_character);
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await prefs.setString(_key, _legacy);
      release.complete();
      await refused;
      await expectLater(
        native.getCharacter(_character),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(storage.values, isEmpty);
      expect(storage.operations, isNot(contains('write')));
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'late preference resolution cannot adopt a replacement original store',
    () async {
      final original = Completer<SharedPreferences>();
      final credentials = owner(original: original.future);
      await preferences({_key: _next, _deviceKey: _device});
      original.complete(prefs);
      final adapter = _Adapter((_) => (status: 200, body: _card()));
      await expectLater(
        extractor(adapter, credentials: credentials).getCharacter(_character),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(storage.values, isEmpty);
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'central private FIFO holds import through readback before tracked backup write',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeWrite = () async {
        entered.complete();
        await release.future;
      };
      final source = DatacatAnonymousLegacySource(Future.value(prefs));
      final importing = source.importIfAbsent(
        vault: vault,
        slot: _slot,
        redaction: redaction,
        isCurrent: () => true,
      );
      final refused = expectLater(
        importing,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      final backup = prefs.setString(_key, _next);
      await pumpEventQueue();
      expect(prefs.getString(_key), _legacy);
      release.complete();
      await refused;
      expect(await backup, true);
      expect(storage.values.values, [_legacy]);
      expect(prefs.getString(_key), _next);
      expect(storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'whole-store admission reserves anonymous FIFO before a later family writer',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final order = <String>[];
      final first = DatacatAnonymousPreferences.serialize(() async {
        entered.complete();
        await release.future;
        order.add('first');
      });
      await entered.future;
      final whole = SavedPreferencesWrites.serializePrivateSources(() async {
        order.add('whole');
      });
      final later = DatacatAnonymousPreferences.serialize(() async {
        order.add('later');
      });
      await pumpEventQueue();
      expect(order, isEmpty);
      release.complete();
      await first;
      await whole;
      await later;
      expect(order, ['first', 'whole', 'later']);
    },
  );

  for (final reload in [false, true]) {
    test(
      'fourth private tail cannot overtake earlier whole-store ${reload ? 'reload' : 'clear'} blocked by Chub',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final first = SavedPreferencesWrites.serializeChub(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final whole = reload ? prefs.reload() : prefs.clear();
        final later = prefs.setString(_key, _next);
        try {
          await pumpEventQueue();
          expect(prefs.getString(_key), _legacy);
          expect(storage.operations, isEmpty);
        } finally {
          if (!release.isCompleted) release.complete();
          await first;
          await whole;
          expect(await later, isTrue);
        }
        expect(prefs.getString(_key), _next);
      },
    );
  }

  test(
    'generic saved JSON CAS refuses anonymous private key before wrong-type read',
    () async {
      await preferences({_key: 7, _deviceKey: _device});
      final lease = SavedPreferencesOwner.process.capture([
        _key,
      ], store: prefs.store);
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      final result = await prefs.compareAndSetString(
        key: _key,
        expectedRaw: null,
        value: _next,
        expected: lease,
        isCurrent: () => true,
      );
      expect(result.started, isFalse);
      expect(result.accepted, isFalse);
      expect(result.receipt, isNull);
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
      expect(SavedPreferencesKeys.all.contains(_key), isFalse);
      expect(storage.operations, isEmpty);
    },
  );

  test(
    'original/current aliases are removed without rewriting public avatar queries',
    () async {
      const avatar =
          'https://ella.janitorai.com/public/image.png?size=large&v=2';
      final adapter = _Adapter((_) {
        redaction.registerSecret(_next);
        return (
          status: 200,
          body: {
            ..._card(definition: '$_legacy $_next', avatar: avatar),
            'sessionToken': _oldReply,
            'echo': _oldReply,
          },
        );
      });
      final result = await extractor(adapter).getCharacter(_character);
      expect(result.charData.description, '[REDACTED] [REDACTED]');
      expect(result.avatarUrl, avatar);
      expect(redaction.redactor.redactText(_oldReply), '[REDACTED]');
    },
  );

  for (final sensitiveAvatar in [false, true]) {
    test(
      'common percent-encoded original/current secrets cannot escape native card projection: $sensitiveAvatar',
      () async {
        const token = 'SYNTHETIC_ORIGINAL/ENCODED+VALUE=';
        const late = 'SYNTHETIC_LATE/ENCODED+VALUE=';
        final encodedToken = Uri.encodeComponent(token);
        final encodedLate = Uri.encodeComponent(late);
        const publicAvatar =
            'https://ella.janitorai.com/public/image.png?sig=PUBLIC%2BVALUE%3D&size=large';
        await preferences({_key: token, _deviceKey: _device});
        final adapter = _Adapter((_) {
          redaction.registerSecret(late);
          return (
            status: 200,
            body: _card(
              definition: '$token $encodedToken $late $encodedLate',
              avatar: sensitiveAvatar
                  ? 'https://ella.janitorai.com/public/image.png?size=large&sig=$encodedToken&extra=$encodedLate'
                  : publicAvatar,
            ),
          );
        });
        final result = await extractor(adapter).getCharacter(_character);
        final text = '${result.charData.description} ${result.avatarUrl}';
        for (final secret in [token, encodedToken, late, encodedLate]) {
          expect(text, isNot(contains(secret)));
        }
        expect(result.charData.description, contains(SecretRedactor.removed));
        if (!sensitiveAvatar) expect(result.avatarUrl, publicAvatar);
        expect(adapter.requests, hasLength(1));
        expect(prefs.getString(_key), token);
      },
    );
  }

  for (final rejection in [401, 403]) {
    test(
      'polling terminal second $rejection cannot start another poll or identify',
      () async {
        var polls = 0, identifies = 0, delays = 0;
        final adapter = _Adapter((request) {
          switch (request.uri.path) {
            case '/api/character/smart-extract-v2':
              return (status: 200, body: {'requestId': 'synthetic-poll'});
            case '/api/extraction/status':
              polls++;
              return polls == 1
                  ? (
                      status: 200,
                      body: {
                        'run': {'requestId': 'previous-poll'},
                      },
                    )
                  : (status: rejection, body: {'error': 'Rejected'});
            case '/api/liberator/identify':
              identifies++;
              return (status: 200, body: {'sessionToken': _next});
            default:
              fail('Unexpected native request after terminal auth refusal.');
          }
        });
        final phases = <String>[];
        final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
        final result = await extractor(
          adapter,
          delay: (_) async {
            delays++;
          },
        ).extractAndPoll(_url, onPhaseChange: phases.add);
        expect(
          result.error,
          'DataCat extraction request failed (HTTP $rejection)',
        );
        expect(result.charData, isNull);
        expect(polls, 3); // Initial observation, first rejection, one retry.
        expect(identifies, 1);
        expect(delays, 1);
        expect(phases, isEmpty);
        expect(adapter.requests, hasLength(5));
        expect({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }, before);
        expect(storage.values.values, [_next]);
      },
    );
  }

  test(
    'redirects refuse before a second request and register error aliases',
    () async {
      final adapter = _Adapter(
        (_) => (
          status: 302,
          body: {
            'sessionToken': _oldReply,
            'location': 'https://untrusted.invalid/$_legacy',
          },
        ),
      );
      await expectLater(
        extractor(adapter).getCharacter(_character),
        throwsA(
          isA<DatacatAnonymousHttpException>().having(
            (e) => e.status,
            'status',
            302,
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.followRedirects, false);
      expect(adapter.requests.single.maxRedirects, 0);
      expect(redaction.redactor.redactText(_oldReply), '[REDACTED]');
    },
  );

  test(
    'arbitrary adapter exception never exposes its message or request',
    () async {
      final adapter = _Adapter(
        (_) => throw StateError('PRIVATE $_legacy $_linked'),
      );
      await expectLater(
        extractor(adapter).getCharacter(_character),
        throwsA(
          isA<DatacatAnonymousHttpException>().having(
            (e) => e.toString(),
            'fixed',
            'DataCat extraction request failed (HTTP 0)',
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'actual Saucepan extraction/poll/avatar consumer preserves native body and owner',
    () async {
      const url = 'https://saucepan.ai/companion/$_character';
      var polls = 0, cards = 0;
      final adapter = _Adapter((request) {
        expect(request.headers['X-Session-Token'], _legacy);
        if (request.method == 'POST') {
          expect(request.uri.path, '/api/saucepan-extract/run');
          final body = jsonDecode(request.data as String) as Map;
          expect(body['companion'], url);
          expect(body['extractHidden'], false);
          expect(body['includeSearch'], true);
          expect(body['alwaysReextract'], false);
          expect(body['netnsRole'], 'general_scraper');
          expect(body['sourceKind'], 'one_off');
          expect(body['vpnNamespace'], 'general_scraper');
          expect(body['sourceRef'], body['idempotencyKey']);
          return (status: 200, body: {'requestId': 'MY_REQUEST'});
        }
        if (request.uri.path == '/api/extraction/status') {
          return ++polls == 1
              ? (
                  status: 200,
                  body: {
                    'run': {'requestId': 'PREVIOUS'},
                  },
                )
              : (
                  status: 200,
                  body: {
                    'run': {
                      'requestId': 'MY_REQUEST',
                      'lifecycle': 'terminal',
                      'characterId': _character,
                      'phase': 'DONE',
                    },
                  },
                );
        }
        if (++cards == 1) {
          expect(request.uri.queryParameters['sourceKind'], 'janitor');
          return (
            status: 200,
            body: {
              'character': {
                'name': 'SYNTHETIC_SAUCEPAN',
                'primary_content_source_kind': 'saucepan',
                'description': 'SYNTHETIC_DEFINITION',
              },
            },
          );
        }
        expect(request.uri.queryParameters.containsKey('sourceKind'), false);
        return (
          status: 200,
          body: {
            'character': <String, Object?>{},
            'metadata': {'image': '/images/public/highres'},
          },
        );
      });
      final phases = <String>[];
      final result = await extractor(
        adapter,
      ).extractAndPoll(url, onPhaseChange: phases.add);
      expect(result.charData?.name, 'SYNTHETIC_SAUCEPAN');
      expect(result.charData?.description, 'SYNTHETIC_DEFINITION');
      expect(result.avatarUrl, 'https://cdn.saucepan.ai/images/public/highres');
      expect(result.characterId, _character);
      expect(phases, ['DONE']);
      expect(adapter.requests, hasLength(5));
    },
  );

  test(
    'new identify during poll delay retires original request instead of token adoption',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final adapter = _Adapter((request) {
        if (request.uri.path == '/api/liberator/identify') {
          return (status: 200, body: {'sessionToken': _next});
        }
        if (request.method == 'POST')
          return (status: 200, body: {'requestId': 'MY_REQUEST'});
        return (
          status: 200,
          body: {
            'run': {'requestId': 'PREVIOUS'},
          },
        );
      });
      final native = extractor(
        adapter,
        delay: (_) async {
          entered.complete();
          await release.future;
        },
      );
      final phases = <String>[];
      final pending = native.extractAndPoll(_url, onPhaseChange: phases.add);
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await native.initialize();
      release.complete();
      await refused;
      expect(adapter.requests, hasLength(3));
      expect(phases, isEmpty);
      expect(storage.values.values, [_next]);
    },
  );

  test(
    'phase callback retirement fences the following character publication',
    () async {
      final adapter = _Adapter(
        (request) => request.method == 'POST'
            ? (status: 200, body: {'requestId': 'MY_REQUEST'})
            : (
                status: 200,
                body: {
                  'run': {
                    'requestId': 'MY_REQUEST',
                    'lifecycle': 'terminal',
                    'characterId': _character,
                    'phase': 'DONE',
                  },
                },
              ),
      );
      final native = extractor(adapter);
      await expectLater(
        native.extractAndPoll(_url, onPhaseChange: (_) => native.dispose()),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(adapter.requests, hasLength(3));
      expect(
        adapter.requests.every(
          (request) => !request.uri.path.startsWith('/api/characters/'),
        ),
        true,
      );
    },
  );

  test(
    'real native composition connects public extraction wrapper without returning a token',
    () async {
      final adapter = _Adapter(
        (request) => request.method == 'POST'
            ? (status: 200, body: {'characterId': _character})
            : (status: 200, body: _card()),
      );
      final container = ProviderContainer(
        overrides: [
          credentialVaultProvider.overrideWithValue(vault),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          datacatAnonymousTransportFactoryProvider.overrideWithValue(
            () => DatacatAnonymousTransport(
              redaction: redaction,
              dio: Dio()..httpClientAdapter = adapter,
            ),
          ),
        ],
      );
      try {
        container.read(datacatAnonymousExtractorProvider);
        final result = await datacatExtractAndPoll(_url);
        expect(result.charData?.name, 'SYNTHETIC_CHARACTER');
        expect(adapter.requests, hasLength(2));
        expect(prefs.getString(_key), _legacy);
        expect(storage.values.values, [_legacy]);
      } finally {
        container.dispose();
      }
      final unavailable = await datacatExtractAndPoll(_url);
      expect(unavailable.error, 'DataCat extraction is unavailable.');
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'older native graph disposal never clears current wrapper or revives its predecessor',
    () async {
      ProviderContainer compose(_Adapter adapter) => ProviderContainer(
        overrides: [
          credentialVaultProvider.overrideWithValue(vault),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          datacatAnonymousTransportFactoryProvider.overrideWithValue(
            () => DatacatAnonymousTransport(
              redaction: redaction,
              dio: Dio()..httpClientAdapter = adapter,
            ),
          ),
        ],
      );
      final firstAdapter = _Adapter((_) => (status: 200, body: _card()));
      final secondAdapter = _Adapter((_) => (status: 200, body: _card()));
      final first = compose(firstAdapter), second = compose(secondAdapter);
      final stale = first.read(datacatAnonymousExtractorProvider);
      second.read(datacatAnonymousExtractorProvider);
      try {
        await expectLater(
          stale.getCharacter(_character),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        first.dispose();
        final result = await datacatGetCharacter(_character);
        expect(result.charData.name, 'SYNTHETIC_CHARACTER');
        expect(firstAdapter.requests, isEmpty);
        expect(secondAdapter.requests, hasLength(1));
      } finally {
        second.dispose();
      }
      final unavailable = await datacatExtractAndPoll(_url);
      expect(unavailable.error, 'DataCat extraction is unavailable.');
      expect(firstAdapter.requests, isEmpty);
      expect(secondAdapter.requests, hasLength(1));
    },
  );
}
