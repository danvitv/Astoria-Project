import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_record.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_read_only_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_auth.dart';
import 'package:glaze_flutter/features/cloud_sync/services/gdrive/gdrive_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/gdrive/gdrive_auth.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_service.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only platform spy uses the already-resolved transitive interface.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'sync_conflict_diagnostics_download_test.dart' show CapabilitySpy;
import 'sync_conflict_diagnostics_test.dart' as fixtures;
import 'sync_lifecycle_test.dart' as fakes;
import 'credentials/fake_credential_storage.dart';

class _PreferencesSpy extends SharedPreferencesStorePlatform {
  final values = <String, Object>{'flutter.sentinel': fixtures.canary};
  int reads = 0;
  int writes = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    return Map.of(values);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    writes++;
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    writes++;
    values.clear();
    return true;
  }
}

class _Characters extends fakes.FakeCharacterStore {
  int reads = 0;
  @override
  Future<Character?> getById(String id) async {
    reads++;
    return super.getById(id);
  }
}

class _Auth extends DropboxAuth {
  _Auth(CloudOAuthCredentialOwner credentials) : super(credentials: credentials);
  int ordinaryTokenCalls = 0;
  @override
  Future<String> getValidToken() async {
    ordinaryTokenCalls++;
    throw StateError('Ordinary auth/refresh forbidden');
  }
}

class _Dropbox extends DropboxAdapter {
  int ordinaryDownloads = 0;
  _Dropbox(super.auth, {required super.dio});
  @override
  Future<String> download(String path) async {
    ordinaryDownloads++;
    throw StateError('Ordinary download forbidden');
  }
}

class _Http implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  String body = '';
  bool rawFailure = false;
  Completer<void>? entered;
  Completer<void>? gate;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    entered?.complete();
    await gate?.future;
    if (rawFailure) {
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, data: fixtures.canary),
        error: StateError(fixtures.canary),
        message: fixtures.canary,
      );
    }
    return ResponseBody.fromString(body, status);
  }

  @override
  void close({bool force = false}) {}
}

class _PendingAccount extends fakes.FakeCloudAdapter {
  final entered = Completer<void>();
  final gate = Completer<Map<String, dynamic>?>();
  @override
  Future<Map<String, dynamic>?> getAccountInfo() {
    entered.complete();
    return gate.future;
  }
}

SyncService _service(
  _Characters chars, {
  CloudAdapter Function(SyncProvider)? selectAdapter,
  Future<String> Function(String)? diagnosticDownload,
}) {
  final chats = fakes.FakeChatStore();
  return SyncService(
    characterRepo: chars,
    chatRepo: chats,
    personaRepo: fakes.FakePersonaStore(),
    presetRepo: fakes.FakePresetStore(),
    apiRepo: fakes.FakeApiConfigStore(),
    memoryBookRepo: fakes.FakeMemoryBookStore(),
    lorebookRepo: fakes.FakeLorebookStore(),
    embeddingRepo: fakes.FakeEmbeddingStore(),
    imageStorage: fakes.FakeImageStore(),
    themePresetRepo: fakes.FakeThemePresetStore(),
    extensionPresetRepo: fakes.FakeExtensionPresetStore(),
    extensionsSettingsStore: fakes.FakeExtensionsSettingsStore(),
    infoBlockStore: fakes.FakeInfoBlockStore(),
    trackerSnapshotStore: fakes.FakeTrackerSnapshotStore(),
    trackerValueStore: fakes.FakeTrackerValueStore(),
    studioConfigStore: fakes.FakeStudioConfigStore(),
    sessionDeletionStore: fakes.FakeSessionDeletionStore(chats),
    characterDeletionStore: fakes.FakeCharacterDeletionStore(chars),
    saveLorebookActivations: (_) async => fail('Unexpected write'),
    selectAdapter: selectAdapter,
    diagnosticDownload: diagnosticDownload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PreferencesSpy prefs;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    prefs = _PreferencesSpy();
    SharedPreferencesStorePlatform.instance = prefs;
  });

  Future<_Auth> protectedAuth() async {
    final original = await TrackedSharedPreferences.getInstance();
    final redaction = SecretRedactionCoordinator();
    addTearDown(redaction.dispose);
    final owner = CloudOAuthCredentialOwner(
      vault: CredentialVault(storage: FakeCredentialStorage(), buildChannel: 'dev'),
      redaction: redaction, originalPreferences: Future.value(original),
      provider: CloudOAuthProvider.dropbox);
    await owner.store(CloudOAuthPair(accessToken: fixtures.canary,
      refreshToken: 'SYNTHETIC_DIAGNOSTIC_REFRESH',
      expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch),
      owner.beginOperation());
    // Authentication fixture acquisition is not diagnostic I/O.
    prefs.reads = 0;
    return _Auth(owner);
  }

  test(
    'default selector uses real Dropbox capability with unavailable auth',
    () async {
      final chars = _Characters();
      final c = fixtures.conflict('character');
      chars.data[c.id] = Character(id: c.id, name: fixtures.canary);
      final service = _service(chars);
      final report = await service.diagnoseConflicts([c]);
      expect(service.provider, SyncProvider.dropbox);
      expect(report.items.single.status, SyncDiagnosticStatus.authUnavailable);
      expect(chars.reads, 1);
      expect(prefs.reads, 0);
      expect(prefs.writes, 0);
    },
  );

  test(
    'real selected Dropbox capability reaches safe report without writes',
    () async {
      final chars = _Characters();
      final c = fixtures.conflict('character');
      chars.data[c.id] = Character(id: c.id, name: fixtures.canary);
      final auth = await protectedAuth();
      final beforeTokens = jsonEncode(auth.saveTokens());
      final beforeCard = jsonEncode(chars.data[c.id]!.toJson());
      final http = _Http()..body = beforeCard;
      final adapter = _Dropbox(auth, dio: Dio()..httpClientAdapter = http);
      final service = _service(chars, selectAdapter: (_) => adapter);
      service.conflicts.add(c);
      for (final pair in [
        (200, false, SyncDiagnosticStatus.compared),
        (401, false, SyncDiagnosticStatus.authUnavailable),
        (409, false, SyncDiagnosticStatus.cloudMissing),
        (403, false, SyncDiagnosticStatus.cloudReadFailed),
        (500, false, SyncDiagnosticStatus.cloudReadFailed),
        (302, false, SyncDiagnosticStatus.cloudReadFailed),
        (200, true, SyncDiagnosticStatus.cloudReadFailed),
      ]) {
        http.status = pair.$1;
        http.rawFailure = pair.$2;
        http.body = pair.$1 == 200 && !pair.$2 ? beforeCard : fixtures.canary;
        final report = await service.diagnoseConflicts(service.conflicts);
        expect(report.items.single.status, pair.$3);
        expect(report.toSafeText(), isNot(contains(fixtures.canary)));
        expect(service.operationInProgress, isFalse);
        expect(service.isDiagnosingConflicts, isFalse);
        expect(service.status, SyncStatus.idle);
        expect(service.lastError, isNull);
        expect(service.lastSyncTime, isNull);
        expect(service.conflicts, [c]);
      }
      expect(http.requests.length, 7);
      for (final request in http.requests) {
        expect(request.path, 'https://content.dropboxapi.com/2/files/download');
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
      }
      expect(adapter.ordinaryDownloads, 0);
      expect(auth.ordinaryTokenCalls, 0);
      expect(jsonEncode(auth.saveTokens()), beforeTokens);
      expect(jsonEncode(chars.data[c.id]!.toJson()), beforeCard);
      expect(prefs.reads, 0);
      expect(prefs.writes, 0);
      expect(prefs.values, {'flutter.sentinel': fixtures.canary});
    },
  );

  test(
    'GDrive refuses every supported item before local or callback reads',
    () async {
      // Ordinary provider setup uses only a fake account endpoint and mock prefs.
      final chars = _Characters();
      final setupAdapter = fakes.FakeCloudAdapter();
      final gdrive = GDriveAdapter(GDriveAuth());
      CloudAdapter selected = setupAdapter;
      var callbacks = 0;
      final service = _service(
        chars,
        selectAdapter: (provider) {
          expect(provider, SyncProvider.gdrive);
          return selected;
        },
        diagnosticDownload: (_) async {
          callbacks++;
          fail('Unsupported adapter must not call injected downloader');
        },
      );
      await service.setProvider(SyncProvider.gdrive);
      selected = gdrive;
      final beforeReads = prefs.reads;
      final beforeWrites = prefs.writes;
      final report = await service.diagnoseConflicts([
        fixtures.conflict('character'),
        fixtures.conflict('character_knowledge'),
        fixtures.conflict('memory_graph'),
        fixtures.conflict('api_presets'),
      ]);
      expect(
        report.items.map((i) => i.status),
        everyElement(SyncDiagnosticStatus.unsupported),
      );
      expect(chars.reads, 0);
      expect(callbacks, 0);
      expect(prefs.reads, beforeReads);
      expect(prefs.writes, beforeWrites);
      expect(service.operationInProgress, isFalse);
    },
  );

  test(
    'invalidPath capability failure maps to invalidIdentity report',
    () async {
      final chars = _Characters();
      final c = fixtures.conflict('character');
      chars.data[c.id] = Character(id: c.id, name: fixtures.canary);
      final adapter = CapabilitySpy()
        ..failure = const CloudReadOnlyDownloadException(
          CloudReadOnlyDownloadStatus.invalidPath,
        );
      final report = await _service(
        chars,
        selectAdapter: (_) => adapter,
      ).diagnoseConflicts([c]);
      expect(report.items.single.status, SyncDiagnosticStatus.invalidIdentity);
      expect(report.toSafeText(), isNot(contains(fixtures.canary)));
      expect(prefs.writes, 0);
    },
  );

  for (final operation in ['init', 'provider']) {
    test(
      'pending $operation rejects diagnosis without releasing its owner',
      () async {
        final adapter = _PendingAccount();
        final chars = _Characters();
        final service = _service(chars, selectAdapter: (_) => adapter);
        final pending = operation == 'init'
            ? service.init()
            : service.setProvider(SyncProvider.gdrive);
        await adapter.entered.future;
        for (var i = 0; i < 2; i++) {
          await expectLater(
            service.diagnoseConflicts([fixtures.conflict('character')]),
            throwsStateError,
          );
          expect(service.operationInProgress, isTrue);
          expect(service.isDiagnosingConflicts, isFalse);
        }
        expect(chars.reads, 0);
        adapter.gate.complete({});
        await pending;
        expect(service.operationInProgress, isFalse);
        final report = await service.diagnoseConflicts([
          fixtures.conflict('character'),
        ]);
        expect(report.items.single.status, SyncDiagnosticStatus.unsupported);
      },
    );
  }

  test(
    'pending real capability blocks ordinary operations and releases after failure',
    () async {
      final chars = _Characters();
      final c = fixtures.conflict('character');
      chars.data[c.id] = Character(id: c.id, name: fixtures.canary);
      final auth = await protectedAuth();
      final http = _Http()
        ..entered = Completer<void>()
        ..gate = Completer<void>()
        ..rawFailure = true;
      final adapter = _Dropbox(auth, dio: Dio()..httpClientAdapter = http);
      final service = _service(chars, selectAdapter: (_) => adapter);
      service.conflicts.add(c);
      final pending = service.diagnoseConflicts([c]);
      await http.entered!.future;
      for (final operation in <Future<void> Function()>[
        () => service.fullPush(),
        () => service.fullPull(),
        () => service.wipeCloudData(),
        () => service.setProvider(SyncProvider.gdrive),
        () => service.disconnect(),
        () => service.resolveConflict(c, 'local'),
        () => service.resolveAllConflicts('cloud'),
        () => service.init(),
      ]) {
        await expectLater(operation(), throwsStateError);
        expect(service.operationInProgress, isTrue);
      }
      http.gate!.complete();
      final report = await pending;
      expect(report.items.single.status, SyncDiagnosticStatus.cloudReadFailed);
      expect(report.toSafeText(), isNot(contains(fixtures.canary)));
      expect(service.operationInProgress, isFalse);
      expect(service.isDiagnosingConflicts, isFalse);
      expect(service.conflicts, [c]);
      expect(service.lastError, isNull);
      expect(service.status, SyncStatus.idle);
      expect(adapter.ordinaryDownloads, 0);
      expect(auth.ordinaryTokenCalls, 0);
      expect(prefs.reads, 0);
      expect(prefs.writes, 0);
    },
  );
}
