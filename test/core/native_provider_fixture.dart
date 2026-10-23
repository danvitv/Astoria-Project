import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

export 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
export 'package:glaze_flutter/core/models/api_config.dart';

const nativeCanary = 'TEST_ONLY_NATIVE_🔐_кириллица_e\u0301';

/// No platform plugin, database, prefs, env, app graph, sockets or real secrets.
final class NativeProviderFakeStorage implements CredentialStorage {
  final values = <String, String>{};
  final operations = <String>[];
  final readKeys = <String>[];
  final writeKeys = <String>[];
  final deleteKeys = <String>[];
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeWrite;
  Object? readError;
  Object? writeError;
  bool writeThenThrow = false;
  bool dropWrite = false;

  @override
  Future<String?> read(String key) async {
    operations.add('read');
    readKeys.add(key);
    await beforeRead?.call();
    if (readError != null) throw readError!;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    operations.add('write');
    writeKeys.add(key);
    await beforeWrite?.call();
    if (writeError != null) throw writeError!;
    if (!dropWrite) values[key] = value;
    if (writeThenThrow) throw StateError(nativeCanary);
  }

  @override
  Future<void> delete(String key) async {
    operations.add('delete');
    deleteKeys.add(key);
    throw StateError('Native provider must not delete credentials');
  }
}

final class NativeProviderFixture {
  NativeProviderFixture({NativeProviderFakeStorage? storage, ApiConfig? row})
    : storage = storage ?? NativeProviderFakeStorage(),
      row =
          row ??
          const ApiConfig(
            id: 'native-test',
            model: 'test-model',
            endpoint: 'https://api.openai.com/v1/chat/completions',
          ) {
    genericVault = CredentialVault(storage: this.storage, buildChannel: 'dev');
    mutations = NativeConnectionMutationOwner(redaction: redaction);
    policy = NativeProviderRoutePolicy(redaction: redaction);
    credentials = NativeProviderCredentialVault(
      vault: genericVault,
      redaction: redaction,
      mutations: mutations,
      routePolicy: policy,
    );
    auth = NativeSavedConnectionAuthIssuer(mutations: mutations);
    entry = NativeProviderSecretEntryIssuer(
      mutations: mutations,
      routePolicy: policy,
      readSavedConnection: (id) async {
        savedReads++;
        await beforeSavedRead?.call();
        return this.row.id == id ? this.row : null;
      },
    );
    lifetime = NativeProviderViewLifetime(
      isCurrent: () => entryIsCurrent?.call() ?? uiCurrent,
    );
  }

  final NativeProviderFakeStorage storage;
  ApiConfig row;
  final redaction = SecretRedactionCoordinator();
  late final CredentialVault genericVault;
  late final NativeConnectionMutationOwner mutations;
  late final NativeProviderRoutePolicy policy;
  late final NativeProviderCredentialVault credentials;
  late final NativeSavedConnectionAuthIssuer auth;
  late final NativeProviderSecretEntryIssuer entry;
  late final NativeProviderViewLifetime lifetime;
  bool uiCurrent = true;
  bool Function()? entryIsCurrent;
  int savedReads = 0;
  Future<void> Function()? beforeSavedRead;

  SavedConnectionAuth reference([
    NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
  ]) => auth.referenceFor(row, purpose)!;

  Future<NativeProviderSecretEntryPermit> permit({
    Set<NativeProviderPurpose> purposes = const {
      NativeProviderPurpose.roleplay,
    },
    NativeProviderDestinationApproval? destinationApproval,
  }) async {
    final ref = reference(purposes.first);
    final review = await entry.review(
      connection: ref,
      purposes: purposes,
      lifetime: lifetime,
      destinationApproval: destinationApproval,
    );
    return entry.confirmNativeEntry(review);
  }

  Future<CredentialMetadata> store({
    String secret = nativeCanary,
    Set<NativeProviderPurpose> purposes = const {
      NativeProviderPurpose.roleplay,
    },
    NativeProviderDestinationApproval? destinationApproval,
  }) async => credentials.storeFromNativeEntry(
    permit: await permit(
      purposes: purposes,
      destinationApproval: destinationApproval,
    ),
    secret: secret,
  );

  Future<NativeProviderCredentialObservation> inspect([
    NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
  ]) => credentials.inspectSavedConnection(
    connection: reference(purpose),
    isCurrent: () => true,
  );

  String get nativeStorageKey => storageKey('api_config.native_llm');
  CredentialSlot get nativeSlot =>
      CredentialSlot(domain: 'api_config.native_llm', id: row.id);
  String get preparationStorageKey => storageKey('api_config.native_prepared');
  CredentialSlot get preparationSlot =>
      CredentialSlot(domain: 'api_config.native_prepared', id: row.id);
  String storageKey(String domain) =>
      'app.astoria.credentials.v1.dev.${CredentialSlot(domain: domain, id: row.id).storageSuffix}';

  CredentialRoute route([
    NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
  ]) => policy
      .routesFor(connection: reference(purpose).connection, purpose: purpose)
      .first;

  void ordinaryMutation() => mutations.onMutationStarted()();

  Future<T> owned<T>(
    Future<T> Function(NativeConnectionOperationLease lease) operation, {
    bool Function()? isOriginalOwner,
  }) {
    final stamp = mutations.observe();
    final admission = stamp == null
        ? null
        : mutations.admit(
            expected: stamp,
            isOriginalOwner: isOriginalOwner ?? () => true,
          );
    if (admission == null) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.stale),
      );
    }
    return mutations.runOwned(admission: admission, operation: operation);
  }

  Future<void> markPrepared({bool Function()? isOriginalOwner}) => owned(
    (lease) => credentials.markPreparedForNativeCreate(
      lease: lease,
      connectionId: row.id,
    ),
    isOriginalOwner: isOriginalOwner,
  );
}

Matcher throwsNative(NativeProviderFailure failure) => throwsA(
  isA<NativeProviderException>()
      .having((error) => error.failure, 'fixed failure', failure)
      .having(
        (error) => error.toString(),
        'safe error',
        isNot(contains(nativeCanary)),
      ),
);
