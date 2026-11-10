import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_mobile_metadata.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_preferences.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_record.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_transport.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart' as lorebooks;
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_auth.dart';
import 'package:glaze_flutter/features/cloud_sync/services/gdrive/gdrive_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/gdrive/gdrive_auth.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_service.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'cloud_oauth_fixture.dart';
import '../sync_lifecycle_test.dart' as sync;

const _access = 'SYNTHETIC_CLOUD_ACCESS_CANARY';
const _refresh = 'SYNTHETIC_CLOUD_REFRESH_CANARY';
const _next = 'SYNTHETIC_CLOUD_NEXT_ACCESS_CANARY';
const _nextRefresh = 'SYNTHETIC_CLOUD_NEXT_REFRESH_CANARY';
const _late = 'SYNTHETIC_CLOUD_STALE_ACCESS_CANARY';
const _code = 'SYNTHETIC_CLOUD_CODE_CANARY';
const _key = CloudOAuthPreferences.tokens;

bool Function() _captureCurrentAdmission() =>
    () => true;

Map<String, dynamic> _legacyPair({int? expiry, bool google = false}) => {
  'access_token': _access,
  'refresh_token': _refresh,
  'expires_at': expiry,
  if (!google) 'account_id': 'SYNTHETIC_ACCOUNT',
  if (!google) 'uid': 'SYNTHETIC_UID',
  if (google) 'folderId': 'SYNTHETIC_BOUND_FOLDER',
  'unknown_provider_metadata': {'preserved': true},
};

Map<String, dynamic> _reply({String access = _next}) => {
  'access_token': access,
  'refresh_token': _nextRefresh,
  'expires_in': 3600,
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

final class _FailingAdapter implements HttpClientAdapter {
  _FailingAdapter(this.type);
  final DioExceptionType type;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw DioException(
    requestOptions: options,
    type: type,
    error: StateError(_access),
    message: 'transport failed with $_refresh',
  );

  @override
  void close({bool force = false}) {}
}

Dio _dio(_Adapter adapter) => Dio()..httpClientAdapter = adapter;

SyncService _service(
  CloudOAuthFixture fixture,
  DropboxAuth dropbox,
  GDriveAuth google,
  sync.FakeCloudAdapter cloud, {
  sync.FakeCharacterStore? characters,
  sync.FakeChatStore? chats,
  sync.FakeLorebookStore? lorebookStore,
  Future<void> Function(LorebookActivations)? saveLorebookActivations,
  Future<void> Function(Set<String>)? reconcilePulledSessions,
}) {
  final chars = characters ?? sync.FakeCharacterStore();
  final ownedChats = chats ?? sync.FakeChatStore();
  return SyncService(
    characterRepo: chars,
    chatRepo: ownedChats,
    personaRepo: sync.FakePersonaStore(),
    presetRepo: sync.FakePresetStore(),
    apiRepo: sync.FakeApiConfigStore(),
    memoryBookRepo: sync.FakeMemoryBookStore(),
    lorebookRepo: lorebookStore ?? sync.FakeLorebookStore(),
    embeddingRepo: sync.FakeEmbeddingStore(),
    imageStorage: sync.FakeImageStore(),
    themePresetRepo: sync.FakeThemePresetStore(),
    extensionPresetRepo: sync.FakeExtensionPresetStore(),
    extensionsSettingsStore: sync.FakeExtensionsSettingsStore(),
    infoBlockStore: sync.FakeInfoBlockStore(),
    trackerSnapshotStore: sync.FakeTrackerSnapshotStore(),
    trackerValueStore: sync.FakeTrackerValueStore(),
    studioConfigStore: sync.FakeStudioConfigStore(),
    sessionDeletionStore: sync.FakeSessionDeletionStore(ownedChats),
    characterDeletionStore: sync.FakeCharacterDeletionStore(chars),
    saveLorebookActivations: saveLorebookActivations ?? ((_) async {}),
    reconcilePulledSessions: reconcilePulledSessions,
    selectAdapter: (_) => cloud,
    dropboxAuth: dropbox,
    gdriveAuth: google,
    originalPreferences: Future.value(fixture.prefs),
    redaction: fixture.redaction,
  );
}

final class _GatedCharacters extends sync.FakeCharacterStore {
  final entered = Completer<void>(), release = Completer<void>();
  int puts = 0;
  bool gate = false;
  @override
  Future<Character?> getById(String id) async {
    if (gate) {
      entered.complete();
      await release.future;
    }
    return super.getById(id);
  }

  @override
  Future<void> put(Character character) async {
    puts++;
    await super.put(character);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CloudOAuthFixture fixture;
  late String original;
  setUp(() async {
    final expiry = DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    original = jsonEncode({
      'dropbox': _legacyPair(expiry: expiry),
      'gdrive': _legacyPair(expiry: expiry, google: true),
      'unknown_sibling': {'backup_metadata': 42},
    });
    fixture = await CloudOAuthFixture.create(
      values: {_key: original, 'unrelated': 9},
    );
    addTearDown(fixture.redaction.dispose);
  });

  DropboxAuth dropbox(
    _Adapter http, {
    CloudOAuthCredentialOwner? owner,
    Future<({String code, String redirectUri})> Function(String)? authorize,
  }) => DropboxAuth(
    credentials: owner ?? fixture.owner(CloudOAuthProvider.dropbox),
    dio: _dio(http),
    appKey: 'SYNTHETIC_APP',
    authorize:
        authorize ??
        ((_) async => (code: _code, redirectUri: 'http://localhost:32123')),
  );

  GDriveAuth google(_Adapter http, {CloudOAuthCredentialOwner? owner}) =>
      GDriveAuth(
        credentials: owner ?? fixture.owner(CloudOAuthProvider.gdrive),
        dio: _dio(http),
        clientId: 'SYNTHETIC_CLIENT',
        clientSecret: 'SYNTHETIC_CLIENT_SECRET',
        authorize: (_) async =>
            (code: _code, redirectUri: 'http://localhost:32123'),
      );

  test(
    'actual auth owners import separate atomic provider envelopes without JSON writes',
    () async {
      final http = _Adapter((_) => (status: 200, body: _reply()));
      final db = dropbox(http), gd = google(http);
      expect(await db.getValidToken(), _access);
      expect(await gd.getValidToken(), _access);
      expect(gd.folderId, 'SYNTHETIC_BOUND_FOLDER');
      expect(db.saveTokens(), isNull);
      expect(gd.saveTokens(), isNull);
      expect(http.requests, isEmpty);
      expect(fixture.storage.values, hasLength(2));
      final protected = fixture.storage.values.values
          .map((raw) => jsonDecode(raw) as Map)
          .toList();
      expect(
        protected.map((m) => m['provider']),
        containsAll(['dropbox', 'gdrive']),
      );
      for (final pair in protected) {
        expect(pair['access_token'], _access);
        expect(pair['refresh_token'], _refresh);
        expect(pair['version'], 1);
      }
      expect(fixture.prefs.getString(_key), original);
      expect(fixture.storage.operations, isNot(contains('delete')));
      expect(PrivatePreferenceKeys.tracked, contains(_key));
      expect(SavedPreferencesKeys.all, isNot(contains(_key)));
      expect(SavedPreferencesKeys.families.length, 5);
      expect(
        fixture.redaction.redactor.redactText('$_access $_refresh'),
        '[REDACTED] [REDACTED]',
      );
    },
  );

  for (final tombstone in [false, true]) {
    test(
      'protected ${tombstone ? 'tombstone' : 'pair'} wins conflicting backup restore',
      () async {
        final slot = CredentialSlot(domain: 'cloud.oauth', id: 'dropbox');
        await fixture.vault.store(
          slot,
          tombstone
              ? ''
              : const CloudOAuthPair(
                  accessToken: _next,
                  refreshToken: _nextRefresh,
                ).encode(CloudOAuthProvider.dropbox),
        );
        final http = _Adapter((_) => (status: 200, body: _reply()));
        final auth = dropbox(http);
        await fixture.prefs.setString(
          _key,
          jsonEncode({'dropbox': _legacyPair(expiry: 0)}),
        );
        auth.loadTokens({
          'dropbox': _legacyPair(expiry: 0),
        }); // Cannot grant custody.
        if (tombstone) {
          await expectLater(
            auth.getValidToken(),
            throwsA(isA<CredentialVaultException>()),
          );
        } else {
          expect(await auth.getValidToken(), _next);
        }
        expect(http.requests, isEmpty);
        expect(
          fixture.storage.values.values.single,
          tombstone
              ? ''
              : const CloudOAuthPair(
                  accessToken: _next,
                  refreshToken: _nextRefresh,
                ).encode(CloudOAuthProvider.dropbox),
        );
      },
    );
  }

  for (final failure in ['read', 'write', 'readback']) {
    test(
      'secure $failure failure is not absence or plaintext HTTP fallback',
      () async {
        if (failure == 'read') fixture.storage.readError = StateError(_access);
        if (failure == 'write')
          fixture.storage.writeError = StateError(_access);
        if (failure == 'readback') fixture.storage.dropWrites = true;
        final http = _Adapter((_) => (status: 200, body: _reply()));
        await expectLater(
          dropbox(http).getValidToken(),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(http.requests, isEmpty);
        expect(fixture.prefs.getString(_key), original);
        expect(fixture.storage.operations, isNot(contains('delete')));
      },
    );
  }

  test(
    'later secure read failure clears cache and refuses diagnostic reuse',
    () async {
      final http = _Adapter((_) => (status: 200, body: _reply()));
      final auth = dropbox(http);
      await auth.restoreTokens();
      expect(auth.requireExistingTokenForReadOnlyDownload(), _access);
      fixture.storage.readError = StateError(_access);
      await expectLater(
        auth.getValidToken(),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(auth.isConnected, isFalse);
      expect(auth.requireExistingTokenForReadOnlyDownload, throwsException);
      expect(http.requests, isEmpty);
    },
  );

  test(
    'late original preferences cannot bind a replacement producer',
    () async {
      final originalProducer = Completer<SharedPreferences>();
      final owner = fixture.owner(
        CloudOAuthProvider.dropbox,
        original: originalProducer.future,
      );
      final replacement = await CloudOAuthFixture.create(
        values: {_key: original},
      );
      addTearDown(replacement.redaction.dispose);
      originalProducer.complete(replacement.prefs);
      final http = _Adapter((_) => (status: 200, body: _reply()));
      await expectLater(
        dropbox(http, owner: owner).getValidToken(),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(fixture.storage.values, isEmpty);
      expect(http.requests, isEmpty);
    },
  );

  test(
    'same-value ABA before import permanently refuses original document lease',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      fixture.storage.beforeRead = () async {
        if (fixture.storage.reads == 1) {
          entered.complete();
          await release.future;
        }
      };
      final http = _Adapter((_) => (status: 200, body: _reply()));
      final auth = dropbox(http);
      final pending = auth.getValidToken();
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await fixture.prefs.setString(_key, original);
      release.complete();
      await refused;
      expect(fixture.storage.values, isEmpty);
      expect(http.requests, isEmpty);
    },
  );

  test(
    'sixth physical FIFO holds original import readback before tracked backup',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      fixture.storage.beforeWrite = () async {
        entered.complete();
        await release.future;
      };
      final source = CloudOAuthLegacySource(Future.value(fixture.prefs));
      final pending = source.importIfAbsent(
        vault: fixture.vault,
        slot: CredentialSlot(domain: 'cloud.oauth', id: 'dropbox'),
        provider: CloudOAuthProvider.dropbox,
        redaction: fixture.redaction,
        isCurrent: () => true,
      );
      final refused = expectLater(
        pending,
        throwsA(
          isA<CloudOAuthImportSettledButRetired>()
              .having(
                (error) => error.receipt.nativeResultVerified,
                'native result',
                isTrue,
              )
              .having(
                (error) => error.receipt.writeCommitted,
                'vault API uncertainty',
                isNull,
              ),
        ),
      );
      await entered.future;
      final backup = fixture.prefs.setString(
        _key,
        '{"backup":"SYNTHETIC_NEW_DOC"}',
      );
      await pumpEventQueue();
      expect(fixture.prefs.getString(_key), original);
      release.complete();
      await refused;
      expect(await backup, isTrue);
      expect(
        (jsonDecode(fixture.storage.values.values.single)
            as Map)['access_token'],
        _access,
      );
      expect(fixture.storage.operations, isNot(contains('delete')));
    },
  );

  for (final reload in [false, true]) {
    test(
      'whole-store ${reload ? 'reload' : 'clear'} reserves sixth tail before later cloud write',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final first = SavedPreferencesWrites.serializeChub(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final whole = reload ? fixture.prefs.reload() : fixture.prefs.clear();
        final later = fixture.prefs.setString(_key, 'SYNTHETIC_LATER');
        try {
          await pumpEventQueue();
          expect(fixture.prefs.getString(_key), original);
        } finally {
          release.complete();
          await first;
          await whole;
          expect(await later, isTrue);
        }
        expect(fixture.prefs.getString(_key), 'SYNTHETIC_LATER');
      },
    );
  }

  test(
    'generic saved JSON CAS refuses the private document before wrong-type read',
    () async {
      await fixture.prefs.setInt(_key, 7);
      final lease = SavedPreferencesOwner.process.capture([
        _key,
      ], store: fixture.prefs.store);
      final result = await fixture.prefs.compareAndSetString(
        key: _key,
        expectedRaw: null,
        value: 'SYNTHETIC_REPLACEMENT',
        expected: lease,
        isCurrent: () => true,
      );
      expect(result.started, isFalse);
      expect(result.accepted, isFalse);
      expect(result.receipt, isNull);
      expect(fixture.prefs.get(_key), 7);
      expect(fixture.storage.values, isEmpty);
    },
  );

  test(
    'new disconnect denies older native commit waiting in the actual vault slot',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      fixture.storage.beforeRead = () async {
        if (fixture.storage.reads == 1) {
          entered.complete();
          await release.future;
        }
      };
      final slot = CredentialSlot(domain: 'cloud.oauth', id: 'dropbox');
      final held = fixture.vault.metadata(slot);
      await entered.future;
      final owner = fixture.owner(CloudOAuthProvider.dropbox);
      final old = owner.store(
        const CloudOAuthPair(accessToken: _next, refreshToken: _nextRefresh),
        owner.beginOperation(),
      );
      final refused = expectLater(
        old,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await pumpEventQueue();
      final logout = owner.disconnect(
        (_, _) async => fail('No cached pair to revoke'),
      );
      release.complete();
      await held;
      await refused;
      await logout;
      expect(fixture.storage.values.values.single, '');
      expect(
        fixture.storage.operations.where((op) => op == 'write'),
        hasLength(1),
      );
      expect(fixture.prefs.getString(_key), original);
    },
  );

  for (final desktopGoogle in [false, true]) {
    test(
      'native ${desktopGoogle ? 'Google' : 'Dropbox'} connect commits secure pair only',
      () async {
        final http = _Adapter((request) {
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          // Dio's RequestOptions retains the submitted map; its transformer emits
          // the form-encoded stream separately. Do not cast the original map to text.
          expect(request.data, isA<Map<String, String>>());
          final data = request.data as Map<String, String>;
          expect(data['code'], _code);
          expect(data['grant_type'], 'authorization_code');
          expect(
            request.uri.toString(),
            desktopGoogle
                ? 'https://oauth2.googleapis.com/token'
                : 'https://api.dropboxapi.com/oauth2/token',
          );
          return (status: 200, body: _reply());
        });
        if (desktopGoogle) {
          final auth = google(http);
          await auth.connect();
          expect(await auth.getValidToken(), _next);
          expect(auth.saveTokens(), isNull);
        } else {
          final auth = dropbox(http);
          await auth.connect();
          expect(await auth.getValidToken(), _next);
          expect(auth.saveTokens(), isNull);
        }
        final pair = jsonDecode(fixture.storage.values.values.single) as Map;
        expect(pair['access_token'], _next);
        expect(pair['refresh_token'], _nextRefresh);
        expect(fixture.prefs.getString(_key), original);
        expect(
          fixture.redaction.redactor.redactText('$_code $_next $_nextRefresh'),
          '[REDACTED] [REDACTED] [REDACTED]',
        );
      },
    );
  }

  test('late browser code cannot undo newer explicit disconnect', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final http = _Adapter((_) => (status: 200, body: _reply()));
    final auth = dropbox(
      http,
      authorize: (_) async {
        entered.complete();
        await release.future;
        return (code: _code, redirectUri: 'http://localhost:32123');
      },
    );
    final pending = auth.connect();
    final refused = expectLater(
      pending,
      throwsA(isA<CredentialVaultAdmissionDenied>()),
    );
    await entered.future;
    await auth.disconnect();
    release.complete();
    await refused;
    expect(http.requests, isEmpty);
    expect(fixture.storage.values.values.single, '');
    expect(fixture.redaction.redactor.redactText(_code), '[REDACTED]');
    expect(fixture.prefs.getString(_key), original);
  });

  for (final desktopGoogle in [false, true]) {
    test(
      'late ${desktopGoogle ? 'Google' : 'Dropbox'} refresh cannot resurrect logout',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final provider = desktopGoogle
            ? CloudOAuthProvider.gdrive
            : CloudOAuthProvider.dropbox;
        final owner = fixture.owner(provider);
        await owner.store(
          const CloudOAuthPair(
            accessToken: _access,
            refreshToken: _refresh,
            expiresAt: 0,
          ),
          owner.beginOperation(),
        );
        final http = _Adapter((request) async {
          if (request.uri.path.endsWith('/token')) {
            entered.complete();
            await release.future;
            return (status: 200, body: _reply(access: _late));
          }
          return (status: 200, body: <String, Object?>{});
        });
        final db = desktopGoogle ? null : dropbox(http, owner: owner);
        final gd = desktopGoogle ? google(http, owner: owner) : null;
        final pending = desktopGoogle
            ? gd!.getValidToken()
            : db!.getValidToken();
        final refused = expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        if (desktopGoogle) {
          await gd!.disconnect();
        } else {
          await db!.disconnect();
        }
        expect(fixture.storage.values.values.single, '');
        release.complete();
        await refused;
        expect(fixture.storage.values.values.single, '');
        expect(fixture.redaction.redactor.redactText(_late), '[REDACTED]');
        expect(fixture.prefs.getString(_key), original);
        expect(fixture.storage.operations, isNot(contains('delete')));
      },
    );
  }

  test(
    'new stable-vault graph native connect owns commit before old refresh response',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final owner = fixture.owner(CloudOAuthProvider.dropbox);
      await owner.store(
        const CloudOAuthPair(
          accessToken: _access,
          refreshToken: _refresh,
          expiresAt: 0,
        ),
        owner.beginOperation(),
      );
      var calls = 0;
      final http = _Adapter((_) async {
        if (++calls == 1) {
          entered.complete();
          await release.future;
          return (status: 200, body: _reply(access: _late));
        }
        return (status: 200, body: _reply());
      });
      final old = dropbox(http, owner: owner);
      final pending = old.getValidToken();
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      final newer = dropbox(http);
      await newer.connect();
      release.complete();
      await refused;
      expect(await newer.getValidToken(), _next);
      expect(old.isConnected, isFalse);
      expect(
        (jsonDecode(fixture.storage.values.values.single)
            as Map)['access_token'],
        _next,
      );
    },
  );

  test('disposed connect cannot publish late returned aliases', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final http = _Adapter((_) async {
      entered.complete();
      await release.future;
      return (status: 200, body: _reply(access: _late));
    });
    final auth = dropbox(http);
    final pending = auth.connect();
    final refused = expectLater(
      pending,
      throwsA(isA<CredentialVaultAdmissionDenied>()),
    );
    await entered.future;
    auth.dispose();
    release.complete();
    await refused;
    expect(fixture.storage.values, isEmpty);
    expect(fixture.redaction.redactor.redactText(_late), '[REDACTED]');
  });

  test(
    'diagnostic remains synchronous-cache-only, no vault read or refresh',
    () async {
      final http = _Adapter((_) => (status: 200, body: '{"synthetic":true}'));
      final auth = dropbox(http);
      await auth.restoreTokens();
      final before = List.of(fixture.storage.operations);
      final adapter = DropboxAdapter(auth, dio: _dio(http));
      expect(
        await adapter.downloadReadOnly(cloudPath('character', 'synthetic')),
        '{"synthetic":true}',
      );
      expect(fixture.storage.operations, before);
      expect(
        http.requests.single.uri.toString(),
        'https://content.dropboxapi.com/2/files/download',
      );
      expect(http.requests.single.followRedirects, isFalse);
      expect(fixture.prefs.getString(_key), original);
    },
  );

  test(
    'Drive folder lookup completing after disconnect cannot start next original HTTP',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final http = _Adapter((request) async {
        if (request.uri.path == '/drive/v3/files') {
          entered.complete();
          await release.future;
          return (
            status: 200,
            body: {
              'files': [
                {'id': 'SYNTHETIC_FOLDER'},
              ],
            },
          );
        }
        return (status: 200, body: <String, Object?>{});
      });
      final auth = google(http);
      await auth.restoreTokens();
      final adapter = GDriveAdapter(auth, createDio: () => _dio(http));
      final pending = adapter.listFolder('$cloudBase/characters');
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await auth.disconnect();
      release.complete();
      await refused;
      expect(
        http.requests.where((r) => r.uri.path == '/drive/v3/files'),
        hasLength(1),
      );
      expect(fixture.storage.values.values.single, '');
    },
  );

  for (final status in [302, 401, 500]) {
    test(
      'HTTP $status aliases register but no redirect/reflection/cause escapes',
      () async {
        final http = _Adapter(
          (_) => (
            status: status,
            body: {
              'access_token': _late,
              'refresh_token': _nextRefresh,
              'echo': _access,
            },
          ),
        );
        final auth = dropbox(http);
        await expectLater(
          auth.connect(),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              'fixed',
              isNot(contains(_late)),
            ),
          ),
        );
        expect(http.requests, hasLength(1));
        expect(http.requests.single.followRedirects, isFalse);
        expect(fixture.redaction.redactor.redactText(_late), '[REDACTED]');
        expect(fixture.storage.values, isEmpty);
        expect(fixture.prefs.getString(_key), original);
      },
    );
  }

  for (final type in [
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
    DioExceptionType.badCertificate,
    DioExceptionType.cancel,
  ]) {
    test('response-less cloud failure preserves safe $type category', () async {
      final requests = CloudOAuthRequestScope(
        _captureCurrentAdmission,
        fixture.redaction,
      );
      final dio = Dio()..httpClientAdapter = _FailingAdapter(type);
      requests.protect(dio, CloudOAuthProvider.gdrive);

      DioException? captured;
      try {
        await dio.post<void>(
          'https://www.googleapis.com/drive/v3/files?token=$_next',
          data: {'secret': _refresh},
          options: Options(headers: {'Authorization': 'Bearer $_access'}),
        );
      } on DioException catch (error) {
        captured = error;
      }

      expect(captured, isNotNull);
      expect(captured!.type, type);
      expect(captured.response, isNull);
      expect(captured.error, isNull);
      expect(captured.requestOptions.path, 'cloud-sync');
      final text = captured.toString();
      expect(text, isNot(contains(_access)));
      expect(text, isNot(contains(_refresh)));
      expect(text, isNot(contains(_next)));
      expect(text, isNot(contains('HTTP 0')));
    });
  }

  test(
    'genuine cloud HTTP failure keeps status with sanitized request',
    () async {
      final requests = CloudOAuthRequestScope(
        _captureCurrentAdmission,
        fixture.redaction,
      );
      final dio = _dio(_Adapter((_) => (status: 503, body: {'echo': _access})));
      requests.protect(dio, CloudOAuthProvider.gdrive);

      DioException? captured;
      try {
        await dio.get<void>(
          'https://www.googleapis.com/drive/v3/files?token=$_next',
          options: Options(headers: {'Authorization': 'Bearer $_access'}),
        );
      } on DioException catch (error) {
        captured = error;
      }

      expect(captured, isNotNull);
      expect(captured!.type, DioExceptionType.badResponse);
      expect(captured.response?.statusCode, 503);
      expect(captured.response?.data, isNull);
      expect(captured.requestOptions.path, 'cloud-sync');
      expect(captured.toString(), isNot(contains(_access)));
      expect(captured.toString(), isNot(contains(_next)));
    },
  );

  test(
    'native mobile metadata refuses token-bearing legacy rather than copying or cleaning',
    () async {
      await expectLater(
        saveCloudOAuthMobileMetadata(
          originalPreferences: Future.value(fixture.prefs),
          connected: true,
          folderId: 'SYNTHETIC_FOLDER',
          redaction: fixture.redaction,
          isCurrent: () => true,
        ),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(fixture.prefs.getString(_key), original);
      expect(fixture.storage.values, isEmpty);
    },
  );

  test(
    'native-connected metadata preserves unknown siblings without any Google vault custody',
    () async {
      final metadataFixture = await CloudOAuthFixture.create(
        values: {
          _key: jsonEncode({
            'gdrive': {
              'native_connected': true,
              'folderId': 'OLD',
              'unknown': 7,
            },
            'unknown_sibling': {'preserved': true},
          }),
        },
      );
      addTearDown(metadataFixture.redaction.dispose);
      await saveCloudOAuthMobileMetadata(
        originalPreferences: Future.value(metadataFixture.prefs),
        connected: false,
        folderId: null,
        redaction: metadataFixture.redaction,
        isCurrent: () => true,
      );
      expect(jsonDecode(metadataFixture.prefs.getString(_key)!), {
        'gdrive': {'native_connected': false, 'folderId': null, 'unknown': 7},
        'unknown_sibling': {'preserved': true},
      });
      expect(metadataFixture.storage.values, isEmpty);
    },
  );

  test(
    'valid Drive admission cannot reuse old token after another refresh commits',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final owner = fixture.owner(CloudOAuthProvider.gdrive);
      final http = _Adapter((request) async {
        entered.complete();
        await release.future;
        return (
          status: 200,
          body: {
            'files': [
              {'id': 'SYNTHETIC_FOLDER'},
            ],
          },
        );
      });
      final auth = google(http, owner: owner);
      await auth.restoreTokens();
      final adapter = GDriveAdapter(auth, createDio: () => _dio(http));
      final pending = adapter.listFolder('$cloudBase/characters');
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      final refresh = owner.beginRefresh(owner.captureGuard());
      await owner.store(
        const CloudOAuthPair(
          accessToken: _next,
          refreshToken: _nextRefresh,
          folderId: 'SYNTHETIC_BOUND_FOLDER',
        ),
        refresh,
      );
      release.complete();
      await refused;
      expect(http.requests, hasLength(1));
      expect(http.requests.single.headers['Authorization'], 'Bearer $_access');
      expect(owner.cached?.accessToken, _next);
    },
  );

  test(
    'own refreshing Drive workflow retains genuinely issued credential admission',
    () async {
      final owner = fixture.owner(CloudOAuthProvider.gdrive);
      await owner.store(
        const CloudOAuthPair(
          accessToken: _access,
          refreshToken: _refresh,
          expiresAt: 0,
        ),
        owner.beginOperation(),
      );
      final http = _Adapter(
        (request) => request.uri.path == '/token'
            ? (status: 200, body: _reply())
            : (
                status: 200,
                body: {
                  'files': [
                    {'id': 'SYNTHETIC_FOLDER', 'name': 'synthetic'},
                  ],
                },
              ),
      );
      final auth = google(http, owner: owner);
      final adapter = GDriveAdapter(auth, createDio: () => _dio(http));
      expect(await adapter.listFolder('$cloudBase/characters'), isNotEmpty);
      expect(http.requests.where((r) => r.uri.path == '/token'), hasLength(1));
      for (final request in http.requests.where(
        (r) => r.uri.path != '/token',
      )) {
        expect(request.headers['Authorization'], 'Bearer $_next');
      }
    },
  );

  test(
    'nested Drive creation refreshes after local capture without using old bearer for next lookup or listing',
    () async {
      final owner = fixture.owner(CloudOAuthProvider.gdrive);
      await owner.load();
      var lookups = 0;
      final http = _Adapter((request) {
        if (request.uri.path == '/token') return (status: 200, body: _reply());
        if (request.method == 'POST') {
          expect(request.headers['Authorization'], 'Bearer $_next');
          return (status: 200, body: {'id': 'SYNTHETIC_ROOT'});
        }
        final query = request.queryParameters['q'] as String;
        if (query.startsWith('name=')) {
          if (++lookups == 1) {
            expect(request.headers['Authorization'], 'Bearer $_access');
            // Deterministic clock boundary for this SAME native pair/generation:
            // creation must perform the workflow's ordinary expired-token refresh.
            final key = fixture.storage.values.keys.single;
            final pair =
                jsonDecode(fixture.storage.values[key]!)
                    as Map<String, dynamic>;
            fixture.storage.values[key] = jsonEncode({
              ...pair,
              'expires_at': 0,
            });
            return (status: 200, body: {'files': <Object?>[]});
          }
          expect(request.headers['Authorization'], 'Bearer $_next');
          return (
            status: 200,
            body: {
              'files': [
                {'id': 'SYNTHETIC_CHILD'},
              ],
            },
          );
        }
        expect(request.headers['Authorization'], 'Bearer $_next');
        return (
          status: 200,
          body: {
            'files': [
              {'id': 'SYNTHETIC_FILE', 'name': 'synthetic'},
            ],
          },
        );
      });
      final auth = google(http, owner: owner);
      final adapter = GDriveAdapter(auth, createDio: () => _dio(http));
      expect(await adapter.listFolder('$cloudBase/characters'), hasLength(1));
      expect(lookups, 2);
      expect(
        http.requests.where((request) => request.uri.path == '/token'),
        hasLength(1),
      );
      expect(http.requests, hasLength(5));
      expect(owner.cached?.accessToken, _next);
      expect(fixture.prefs.getString(_key), original);
    },
  );

  test(
    'exact captured Drive token receipt cannot adopt a subsequent own refresh at HTTP invocation',
    () async {
      final owner = fixture.owner(CloudOAuthProvider.gdrive);
      final http = _Adapter((_) => (status: 200, body: {'files': <Object?>[]}));
      final auth = google(http, owner: owner);
      final dio = _dio(http);
      auth.requests.protect(dio, CloudOAuthProvider.gdrive);
      await auth.requests.run(() async {
        final oldToken = await auth.getRequestToken();
        expect(oldToken.value, _access);
        final refresh = owner.beginRefresh(
          auth.requests.captureOperationGuard(),
        );
        const next = CloudOAuthPair(
          accessToken: _next,
          refreshToken: _nextRefresh,
          folderId: 'SYNTHETIC_BOUND_FOLDER',
        );
        await auth.requests.run(
          () => owner.store(next, refresh),
          original: refresh,
        );
        auth.requests.retainRefreshedCredentialGuard(
          owner.credentialGuard(next),
          refresh,
        );
        auth.requests.check();
        expect(oldToken.isCurrent(), isFalse);
        expect(oldToken.toString(), isNot(contains(_access)));
        await expectLater(
          dio.get<Map<String, dynamic>>(
            'https://www.googleapis.com/drive/v3/files',
            options: Options(
              headers: {'Authorization': 'Bearer ${oldToken.value}'},
              extra: CloudOAuthRequestScope.tokenAdmission(oldToken),
            ),
          ),
          throwsA(
            isA<DioException>().having(
              (error) => error.error,
              'retired exact token',
              isA<CredentialVaultAdmissionDenied>(),
            ),
          ),
        );
        expect(http.requests, isEmpty);
        final issued = await auth.getRequestToken();
        await dio.get<Map<String, dynamic>>(
          'https://www.googleapis.com/drive/v3/files',
          options: Options(
            headers: {'Authorization': 'Bearer ${issued.value}'},
            extra: CloudOAuthRequestScope.tokenAdmission(issued),
          ),
        );
        expect(http.requests.single.headers['Authorization'], 'Bearer $_next');
      });
      expect(fixture.prefs.getString(_key), original);
    },
  );

  test(
    'late alias reaches original and distinct current stable-vault redactors',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final originalOwner = fixture.owner(CloudOAuthProvider.dropbox);
      await originalOwner.store(
        const CloudOAuthPair(
          accessToken: _access,
          refreshToken: _refresh,
          expiresAt: 0,
        ),
        originalOwner.beginOperation(),
      );
      var calls = 0;
      final http = _Adapter((_) async {
        if (++calls == 1) {
          entered.complete();
          await release.future;
          return (status: 200, body: _reply(access: _late));
        }
        return (status: 200, body: _reply());
      });
      final old = dropbox(http, owner: originalOwner);
      final pending = old.getValidToken();
      final refused = expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      final currentRedaction = SecretRedactionCoordinator();
      addTearDown(currentRedaction.dispose);
      final currentOwner = CloudOAuthCredentialOwner(
        vault: fixture.vault,
        provider: CloudOAuthProvider.dropbox,
        redaction: currentRedaction,
        originalPreferences: Future.value(fixture.prefs),
      );
      final newer = dropbox(http, owner: currentOwner);
      await newer.connect();
      release.complete();
      await refused;
      expect(fixture.redaction.redactor.redactText(_late), '[REDACTED]');
      expect(currentRedaction.redactor.redactText(_late), '[REDACTED]');
      expect(await newer.getValidToken(), _next);
      expect(old.isConnected, isFalse);
      expect(fixture.prefs.getString(_key), original);
    },
  );

  test(
    'already admitted workflow replaces only its own verified refresh clause',
    () async {
      final owner = fixture.owner(CloudOAuthProvider.gdrive);
      final http = _Adapter(
        (_) => fail('No HTTP expected in this native admission fixture'),
      );
      final auth = google(http, owner: owner);
      await auth.requests.run(() async {
        expect(await auth.getValidToken(), _access);
        final originalHttp = auth.requests.captureGuard();
        final refresh = owner.beginRefresh(
          auth.requests.captureOperationGuard(),
        );
        const next = CloudOAuthPair(
          accessToken: _next,
          refreshToken: _nextRefresh,
          folderId: 'SYNTHETIC_BOUND_FOLDER',
        );
        await auth.requests.run(
          () => owner.store(next, refresh),
          original: refresh,
        );
        auth.requests.retainRefreshedCredentialGuard(
          owner.credentialGuard(next),
          refresh,
        );
        auth.requests.check();
        expect(originalHttp(), isFalse);
        expect(await auth.getValidToken(), _next);
        final copied = CloudOAuthPair(
          accessToken: _next,
          refreshToken: _nextRefresh,
          folderId: next.folderId,
        );
        expect(
          copied.encode(CloudOAuthProvider.gdrive),
          next.encode(CloudOAuthProvider.gdrive),
        );
        expect(
          owner.credentialGuard(copied)(),
          isFalse,
        ); // Same JSON is not a receipt.
      });
      expect(http.requests, isEmpty);
      expect(fixture.prefs.getString(_key), original);
    },
  );

  test(
    'verified invoked write retired during readback exposes actual commit receipt',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      fixture.storage.beforeRead = () async {
        entered.complete();
        await release.future;
      };
      final owner = fixture.owner(CloudOAuthProvider.dropbox);
      final pending = owner.store(
        const CloudOAuthPair(accessToken: _next, refreshToken: _nextRefresh),
        owner.beginOperation(),
      );
      CloudOAuthCommitReceipt? receipt;
      final observed = pending.catchError((Object error) {
        expect(error, isA<CloudOAuthCommittedButRetired>());
        receipt = (error as CloudOAuthCommittedButRetired).receipt;
      });
      await entered.future;
      expect(
        (jsonDecode(fixture.storage.values.values.single)
            as Map)['access_token'],
        _next,
      );
      owner.dispose();
      release.complete();
      await observed;
      expect(receipt?.committed, isTrue);
      expect(receipt?.disconnected, isFalse);
      expect(owner.cached, isNull);
      expect(fixture.prefs.getString(_key), original);
    },
  );

  for (final desktopGoogle in [false, true]) {
    for (final failure in [
      'write throws',
      'readback throws',
      'unequal readback',
    ]) {
      test(
        'retired invoked ${desktopGoogle ? 'Google' : 'Dropbox'} $failure stays commit unknown through auth',
        () async {
          final entered = Completer<void>(), release = Completer<void>();
          final owner = fixture.owner(
            desktopGoogle
                ? CloudOAuthProvider.gdrive
                : CloudOAuthProvider.dropbox,
          );
          if (failure == 'write throws') {
            fixture.storage.beforeWrite = () async {
              entered.complete();
              await release.future;
            };
          } else {
            fixture.storage.beforeRead = () async {
              entered.complete();
              await release.future;
            };
            fixture.storage.dropWrites = failure == 'unequal readback';
          }
          final http = _Adapter((_) => (status: 200, body: _reply()));
          final pending = desktopGoogle
              ? google(http, owner: owner).connect()
              : dropbox(http, owner: owner).connect();
          final observed = expectLater(
            pending,
            throwsA(
              isA<CloudOAuthCommitUnknown>()
                  .having(
                    (error) => error.writeInvoked,
                    'actual write invocation',
                    isTrue,
                  )
                  .having(
                    (error) => error.committed,
                    'not success or rollback',
                    isNull,
                  )
                  .having(
                    (error) => error.failure,
                    'original sanitized failure',
                    failure == 'unequal readback'
                        ? CredentialVaultFailure.verificationFailed
                        : CredentialVaultFailure.storageUnavailable,
                  )
                  .having(
                    (error) => error.toString(),
                    'no reflected secret',
                    isNot(contains(_next)),
                  ),
            ),
          );
          await entered.future;
          expect(
            fixture.storage.operations.where(
              (operation) => operation == 'write',
            ),
            hasLength(1),
          );
          if (failure == 'write throws')
            fixture.storage.writeError = StateError(_next);
          if (failure == 'readback throws')
            fixture.storage.readError = StateError(_next);
          owner.dispose();
          release.complete();
          await observed;
          expect(owner.cached, isNull);
          expect(http.requests, hasLength(1));
          expect(fixture.storage.operations, isNot(contains('delete')));
          if (failure == 'readback throws') {
            expect(
              (jsonDecode(fixture.storage.values.values.single)
                  as Map)['access_token'],
              _next,
            );
          } else {
            expect(fixture.storage.values, isEmpty);
          }
          expect(fixture.prefs.getString(_key), original);
        },
      );
    }
  }

  for (final desktopGoogle in [false, true]) {
    test(
      'retired invoked refresh readback failure is not swallowed by ${desktopGoogle ? 'Google' : 'Dropbox'} account lookup',
      () async {
        final owner = fixture.owner(
          desktopGoogle
              ? CloudOAuthProvider.gdrive
              : CloudOAuthProvider.dropbox,
        );
        await owner.store(
          const CloudOAuthPair(
            accessToken: _access,
            refreshToken: _refresh,
            expiresAt: 0,
          ),
          owner.beginOperation(),
        );
        final entered = Completer<void>(), release = Completer<void>();
        fixture.storage.beforeWrite = () async {
          fixture.storage.beforeRead = () async {
            entered.complete();
            await release.future;
          };
        };
        final http = _Adapter((_) => (status: 200, body: _reply()));
        final pending = desktopGoogle
            ? google(http, owner: owner).getAccountInfo()
            : DropboxAdapter(
                dropbox(http, owner: owner),
                dio: _dio(http),
              ).getAccountInfo();
        final observed = expectLater(
          pending,
          throwsA(
            isA<CloudOAuthCommitUnknown>().having(
              (error) => error.committed,
              'commit remains unknown',
              isNull,
            ),
          ),
        );
        await entered.future;
        fixture.storage.readError = StateError(_next);
        owner.dispose();
        release.complete();
        await observed;
        expect(
          http.requests,
          hasLength(1),
        ); // No account HTTP after the failed refresh.
        expect(owner.cached, isNull);
        expect(fixture.prefs.getString(_key), original);
      },
    );
  }

  test(
    'original mobile true metadata ack is not discarded after retirement',
    () async {
      final previous = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      final initial = {
        _key: jsonEncode({
          'gdrive': {'native_connected': false},
          'unknown_sibling': {'preserved': true},
        }),
      };
      final backing = CloudOAuthPreferencesBacking(initial);
      final mobile = await CloudOAuthFixture.create(
        values: initial,
        backing: backing,
      );
      addTearDown(mobile.redaction.dispose);
      final entered = Completer<void>(), release = Completer<void>();
      backing.beforeSet = () async {
        entered.complete();
        await release.future;
      };
      var current = true;
      final pending = saveCloudOAuthMobileMetadata(
        originalPreferences: Future.value(mobile.prefs),
        connected: true,
        folderId: 'SYNTHETIC_FOLDER',
        redaction: mobile.redaction,
        isCurrent: () => current,
      );
      await entered.future;
      current = false;
      release.complete();
      final result = await pending;
      expect(result.acknowledged, isTrue);
      expect(result.committedButRetired, isTrue);
      expect(
        () => result.requireCurrent(() => current),
        throwsA(
          isA<CloudOAuthMobileMetadataCommittedButRetired>().having(
            (error) => error.receipt.acknowledged,
            'original ack',
            isTrue,
          ),
        ),
      );
      expect(
        (jsonDecode(backing.values['flutter.$_key'] as String)
            as Map)['gdrive'],
        {'native_connected': true, 'folderId': 'SYNTHETIC_FOLDER'},
      );
      expect(mobile.storage.values, isEmpty);
      expect(backing.writes, ['flutter.$_key']);
    },
  );

  for (final throwsAck in [false, true]) {
    test(
      'retired invoked mobile ${throwsAck ? 'throwing' : 'false'} ack is commit unknown even when plugin stored metadata',
      () async {
        final previous = SharedPreferencesStorePlatform.instance;
        addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
        final initial = {
          _key: jsonEncode({
            'gdrive': {'native_connected': false},
            'unknown_sibling': {'preserved': true},
          }),
        };
        final backing = CloudOAuthPreferencesBacking(initial)
          ..acknowledgement = false
          ..setError = throwsAck ? StateError(_next) : null;
        final mobile = await CloudOAuthFixture.create(
          values: initial,
          backing: backing,
        );
        addTearDown(mobile.redaction.dispose);
        final entered = Completer<void>(), release = Completer<void>();
        backing.beforeSet = () async {
          entered.complete();
          await release.future;
        };
        var current = true;
        final pending = saveCloudOAuthMobileMetadata(
          originalPreferences: Future.value(mobile.prefs),
          connected: true,
          folderId: 'SYNTHETIC_FOLDER',
          redaction: mobile.redaction,
          isCurrent: () => current,
        );
        final observed = expectLater(
          pending,
          throwsA(
            isA<CloudOAuthMobileMetadataCommitUnknown>()
                .having(
                  (error) => error.writeInvoked,
                  'original setter invocation',
                  isTrue,
                )
                .having(
                  (error) => error.committed,
                  'unknown durable outcome',
                  isNull,
                )
                .having(
                  (error) => error.acknowledged,
                  'actual acknowledgement',
                  throwsAck ? isNull : isFalse,
                )
                .having(
                  (error) => error.toString(),
                  'no arbitrary cause',
                  isNot(contains(_next)),
                ),
          ),
        );
        await entered.future;
        current = false;
        release.complete();
        await observed;
        expect(
          (jsonDecode(backing.values['flutter.$_key'] as String)
              as Map)['gdrive'],
          {'native_connected': true, 'folderId': 'SYNTHETIC_FOLDER'},
        );
        expect(backing.writes, ['flutter.$_key']);
        expect(mobile.storage.values, isEmpty);
      },
    );
  }

  for (final desktopGoogle in [false, true]) {
    test(
      'local ${desktopGoogle ? 'Google' : 'Dropbox'} disconnect distinguishes remote 500',
      () async {
        final http = _Adapter(
          (_) => (status: 500, body: {'access_token': _late}),
        );
        final db = desktopGoogle ? null : dropbox(http);
        final gd = desktopGoogle ? google(http) : null;
        if (desktopGoogle) {
          await gd!.restoreTokens();
        } else {
          await db!.restoreTokens();
        }
        final result = desktopGoogle
            ? await gd!.disconnect()
            : await db!.disconnect();
        expect(result.localDisconnected, isTrue);
        expect(result.remoteComplete, isFalse);
        expect(result.warning, isNotNull);
        expect(http.requests, hasLength(1));
        expect(fixture.storage.values.values.single, '');
        expect(fixture.prefs.getString(_key), original);
        expect(desktopGoogle ? gd!.isConnected : db!.isConnected, isFalse);
      },
    );
  }

  for (final broken in CloudOAuthProvider.values) {
    test(
      'original service survives corrupt ${broken.name} and explicit reconnect remains reachable',
      () async {
        final values = jsonDecode(original) as Map<String, dynamic>;
        values[broken.name] = {'access_token': _access};
        final healthy = broken == CloudOAuthProvider.dropbox
            ? CloudOAuthProvider.gdrive
            : CloudOAuthProvider.dropbox;
        final repair = await CloudOAuthFixture.create(
          values: {_key: jsonEncode(values), 'gz_sync_provider': healthy.name},
        );
        addTearDown(repair.redaction.dispose);
        var callbacks = 0;
        final http = _Adapter((_) => (status: 200, body: _reply()));
        final db = DropboxAuth(
          credentials: repair.owner(CloudOAuthProvider.dropbox),
          dio: _dio(http),
          appKey: 'SYNTHETIC_APP',
          authorize: (_) async {
            callbacks++;
            return (code: _code, redirectUri: 'http://localhost:32123');
          },
        );
        final gd = GDriveAuth(
          credentials: repair.owner(CloudOAuthProvider.gdrive),
          dio: _dio(http),
          clientId: 'SYNTHETIC_CLIENT',
          authorize: (_) async {
            callbacks++;
            return (code: _code, redirectUri: 'http://localhost:32123');
          },
        );
        final service = _service(repair, db, gd, sync.FakeCloudAdapter());
        await service.init();
        expect(service.isConnected(), isTrue);
        expect(service.storageWarnings.keys.map((p) => p.name), [broken.name]);
        expect(http.requests, isEmpty);
        await service.setProvider(
          broken == CloudOAuthProvider.dropbox
              ? SyncProvider.dropbox
              : SyncProvider.gdrive,
        );
        if (broken == CloudOAuthProvider.dropbox) {
          await service.connectDropbox();
        } else {
          await service.connectGDrive();
        }
        expect(callbacks, 1);
        expect(service.isConnected(), isTrue);
        expect(service.storageWarnings, isEmpty);
        expect(repair.prefs.getString(_key), jsonEncode(values));
      },
    );
  }

  test(
    'native SDK success stays connected when legacy token document refuses metadata save',
    () async {
      final document = jsonDecode(original) as Map<String, dynamic>;
      document['dropbox'] = {'access_token': _access};
      final raw = jsonEncode(document);
      final mobile = await CloudOAuthFixture.create(
        values: {_key: raw, 'gz_sync_provider': 'gdrive'},
      );
      addTearDown(mobile.redaction.dispose);
      var callbacks = 0;
      final native = GDriveAuth(
        redaction: mobile.redaction,
        nativeConnect: () async {
          callbacks++;
        },
      );
      final db = DropboxAuth(
        credentials: mobile.owner(CloudOAuthProvider.dropbox),
      );
      final service = _service(mobile, db, native, sync.FakeCloudAdapter());
      await service.init();
      expect(service.storageWarnings.keys, [SyncProvider.dropbox]);
      await service.connectGDrive();
      expect(callbacks, 1);
      expect(service.isConnected(), isTrue);
      expect(
        native.hasWorkflowOwner,
        isTrue,
      ); // SDK lifecycle, not a vault owner.
      expect(service.warning, contains('metadata'));
      expect(mobile.storage.values, isEmpty);
      expect(mobile.prefs.getString(_key), raw);
    },
  );

  test(
    'reconciliation retirement between sessions settles first transaction but never starts second',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final http = _Adapter((_) => (status: 200, body: _reply()));
      final db = dropbox(http);
      await db.restoreTokens();
      final chats = sync.FakeChatStore();
      final cloud = sync.FakeCloudAdapter();
      final entries = <String, SyncManifestEntry>{};
      for (final id in ['SYNTHETIC_SESSION_A', 'SYNTHETIC_SESSION_B']) {
        final chat = ChatSession(
          id: id,
          characterId: 'SYNTHETIC_CARD',
          sessionIndex: 0,
          updatedAt: 1,
        );
        final entry = SyncManifestEntry(
          type: 'chat',
          id: id,
          path: cloudPath('chat', id),
          updatedAt: 1,
          hash: 'SYNTHETIC_HASH_$id',
        );
        entries[entry.key] = entry;
        cloud.files[entry.path] = jsonEncode(chat.toJson());
      }
      cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        SyncManifest(
          deviceId: 'SYNTHETIC_DEVICE',
          createdAt: 1,
          entries: entries,
        ).toJson(),
      );
      final started = <String>[], settled = <String>[];
      final service = _service(
        fixture,
        db,
        GDriveAuth(),
        cloud,
        chats: chats,
        reconcilePulledSessions: (ids) async {
          // Models the production repository's per-session transaction loop. A
          // callback given both ids would continue into B after A's retirement.
          for (final id in ids) {
            started.add(id);
            if (started.length == 1) {
              entered.complete();
              await release.future;
            }
            settled.add(id);
          }
        },
      );
      final progress = <SyncProgress>[];
      final pending = service.fullPull(onProgress: progress.add);
      final observed = expectLater(
        pending,
        throwsA(
          isA<SyncWorkflowRetired>().having(
            (error) => error.committedLocalWrites,
            'already settled effects retained',
            greaterThan(0),
          ),
        ),
      );
      await entered.future;
      expect(
        chats.data.keys,
        containsAll(['SYNTHETIC_SESSION_A', 'SYNTHETIC_SESSION_B']),
      );
      final beforeProgress = progress.length;
      final beforeDownloads = List.of(cloud.downloadCalls);
      service.dispose();
      release.complete();
      await observed;
      expect(started, hasLength(1));
      expect(settled, started);
      expect(
        chats.data,
        hasLength(2),
      ); // No claim of rolling prior imports back.
      expect(progress.length, beforeProgress);
      expect(cloud.downloadCalls, beforeDownloads);
      expect(service.lastSyncTime, isNull);
      expect(service.lastError, isNull);
      expect(fixture.prefs.getInt('gz_sync_last'), isNull);
    },
  );

  test(
    'production lorebook callback retires during original prefs acquisition before invoking setter',
    () async {
      final previous = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      final initial = {_key: original};
      final backing = CloudOAuthPreferencesBacking(initial);
      final loreFixture = await CloudOAuthFixture.create(
        values: initial,
        backing: backing,
      );
      addTearDown(loreFixture.redaction.dispose);
      final owner = loreFixture.owner(CloudOAuthProvider.dropbox);
      final http = _Adapter((_) => (status: 200, body: _reply()));
      final db = dropbox(http, owner: owner);
      await db.restoreTokens();
      final originalPreferences = Completer<SharedPreferences>();
      final entered = Completer<void>();
      final store = sync.FakeLorebookStore();
      const book = Lorebook(
        id: 'SYNTHETIC_LOREBOOK',
        name: 'synthetic',
        activationScope: 'character',
        activationTargetId: 'SYNTHETIC_CARD',
      );
      final entry = SyncManifestEntry(
        type: 'lorebooks',
        id: 'lorebooks',
        path: cloudPath('lorebooks', 'lorebooks'),
        updatedAt: 1,
        hash: 'SYNTHETIC_HASH',
      );
      final cloud = sync.FakeCloudAdapter();
      cloud.files[entry.path] = jsonEncode({
        '__singleton': true,
        'items': [book.toJson()],
      });
      cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        SyncManifest(
          deviceId: 'SYNTHETIC_DEVICE',
          createdAt: 1,
          entries: {entry.key: entry},
        ).toJson(),
      );
      late final SyncService service;
      service = _service(
        loreFixture,
        db,
        GDriveAuth(),
        cloud,
        lorebookStore: store,
        saveLorebookActivations: (activations) {
          final issued = service.capturePublicationGuard();
          entered.complete();
          return lorebooks.saveLorebookActivations(activations, null, () {
            if (!issued()) throw const CredentialVaultAdmissionDenied();
          }, originalPreferences.future);
        },
      );
      final pending = service.fullPull();
      final observed = expectLater(
        pending,
        throwsA(isA<SyncWorkflowRetired>()),
      );
      await entered.future;
      expect(store.data, contains(book.id));
      service.dispose();
      originalPreferences.complete(loreFixture.prefs);
      await observed;
      expect(backing.writes, isNot(contains('flutter.lorebookActivations')));
      expect(loreFixture.prefs.getString('lorebookActivations'), isNull);
      expect(
        store.data,
        contains(book.id),
      ); // Earlier durable import may settle.
      expect(service.lastSyncTime, isNull);
      expect(service.lastError, isNull);
    },
  );

  for (final supersede in [false, true]) {
    test(
      'download then original character read gate ${supersede ? 'supersedes' : 'disposes'} workflow before put',
      () async {
        final owner = fixture.owner(CloudOAuthProvider.dropbox);
        final http = _Adapter((_) => (status: 200, body: _reply()));
        final db = dropbox(http, owner: owner);
        await db.restoreTokens();
        final chars = _GatedCharacters();
        final cloud = sync.FakeCloudAdapter();
        const character = Character(
          id: 'SYNTHETIC_CARD',
          name: 'synthetic imported card',
        );
        final entry = SyncManifestEntry(
          type: 'character',
          id: character.id,
          path: cloudPath('character', character.id),
          updatedAt: 1,
          hash: 'SYNTHETIC_HASH',
        );
        cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
          SyncManifest(
            deviceId: 'SYNTHETIC_DEVICE',
            createdAt: 1,
            entries: {entry.key: entry},
          ).toJson(),
        );
        cloud.files[entry.path] = jsonEncode(character.toJson());
        chars.gate = true;
        final service = _service(
          fixture,
          db,
          GDriveAuth(),
          cloud,
          characters: chars,
        );
        final progress = <SyncProgress>[];
        final pending = service.fullPull(onProgress: progress.add);
        final refused = expectLater(
          pending,
          throwsA(isA<SyncWorkflowRetired>()),
        );
        await chars.entered.future;
        expect(cloud.downloadCalls, contains(entry.path));
        final beforeProgress = progress.length;
        final beforeHttp = List.of(cloud.downloadCalls);
        if (supersede) {
          final newer = fixture.owner(CloudOAuthProvider.dropbox);
          await newer.store(
            const CloudOAuthPair(
              accessToken: _next,
              refreshToken: _nextRefresh,
            ),
            newer.beginOperation(),
          );
        } else {
          service.dispose();
        }
        chars.release.complete();
        await refused;
        expect(chars.puts, 0);
        expect(chars.data, isEmpty);
        expect(progress.length, beforeProgress);
        expect(cloud.downloadCalls, beforeHttp);
        expect(service.lastSyncTime, isNull);
        expect(service.lastError, isNull);
        expect(service.capturePublicationGuard()(), isFalse);
      },
    );
  }
}
