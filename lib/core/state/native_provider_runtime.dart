import 'package:dio/dio.dart';

import '../credentials/connection_revision_registry.dart';
import '../credentials/credential_vault.dart';
import '../credentials/native_provider_credentials.dart';
import '../credentials/secret_redaction_coordinator.dart';
import '../llm/native_saved_connection_source.dart';
import '../llm/transport/native_provider_transport.dart';
import '../models/api_config.dart';
import 'native_provider_mutation_bridge.dart';

typedef NativeProviderAdapterFactory = HttpClientAdapter Function();

/// One constructor-owned runtime attached to the ACTUAL ApiConfigRepo lifetime.
/// No storage reads, key hydration, network probes or second DB at construction.
final class NativeProviderRuntime {
  NativeProviderRuntime({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required this._revisions,
    required Future<ApiConfig?> Function(String) readSavedConnection,
    required HttpClientAdapter Function() adapterFactory,
    required this._isOriginalRoot,
  }) {
    mutations = NativeConnectionMutationOwner(redaction: redaction);
    routes = NativeProviderRoutePolicy(redaction: redaction);
    credentials = NativeProviderCredentialVault(
      vault: vault,
      redaction: redaction,
      mutations: mutations,
      routePolicy: routes,
    );
    auth = NativeSavedConnectionAuthIssuer(mutations: mutations);
    credentialReader = NativeProviderCredentialMetadataReader(
      credentials: credentials,
    );
    secretEntry = NativeProviderSecretEntryIssuer(
      mutations: mutations,
      routePolicy: routes,
      readSavedConnection: readSavedConnection,
    );
    keylessMutations = NativeProviderKeylessMutationBridge(
      mutations: mutations,
      credentials: credentials,
      readSavedConnection: readSavedConnection,
      isRootCurrent: () => isCurrent,
    );
    ordinaryMutations = NativeProviderOrdinaryMutationGuard(
      mutations: mutations,
      credentials: credentials,
      isRootCurrent: () => isCurrent,
    );
    sources = NativeSavedConnectionSourceResolver(
      mutations: mutations,
      auth: auth,
      credentials: credentials,
      currentRedactor: () => redaction.redactor,
    );
    transports = NativeProviderTransportFactory(
      credentials: credentials,
      authIssuer: auth,
      mutations: mutations,
      routes: routes,
      currentRedactor: () => redaction.redactor,
      adapterFactory: adapterFactory,
    );
    mutations.addFenceListener(_onNativeFence);
  }

  final ConnectionRevisionRegistry _revisions;
  final bool Function() _isOriginalRoot;
  late final NativeConnectionMutationOwner mutations;
  late final NativeProviderRoutePolicy routes;
  late final NativeProviderCredentialVault credentials;
  late final NativeSavedConnectionAuthIssuer auth;
  late final NativeProviderCredentialMetadataReader credentialReader;
  late final NativeProviderSecretEntryIssuer secretEntry;
  late final NativeProviderKeylessMutationBridge keylessMutations;
  late final NativeProviderOrdinaryMutationGuard ordinaryMutations;
  late final NativeSavedConnectionSourceResolver sources;
  late final NativeProviderTransportFactory transports;
  void Function()? _finishNativeRevision;
  bool _openingNativeRevision = false;
  bool _disposed = false;

  bool get isCurrent {
    if (_disposed) {
      return false;
    }
    try {
      return _isOriginalRoot() && !_disposed;
    } catch (_) {
      return false;
    }
  }

  /// The existing global registry still revokes ALL accepted N1 recipients.
  /// Native owned zones identify only their own DB fence, never renew consent.
  void Function() onApiMutationStarted() {
    // The held native operation already owns the registry fence from admission
    // through its outer settlement. Its repository hook must not open a second.
    if (mutations.isInOwnedMutation) return mutations.onMutationStarted();
    final finishRegistry = _revisions.beginMutation();
    // Ordinary/import observers own their explicit registry fence. The native
    // listener must not independently mirror that same begin/settlement.
    final wasOpening = _openingNativeRevision;
    _openingNativeRevision = true;
    late final void Function() finishNative;
    try {
      finishNative = mutations.onMutationStarted();
    } finally {
      _openingNativeRevision = wasOpening;
    }
    var finished = false;
    return () {
      if (finished) {
        return;
      }
      finished = true;
      final wasOpening = _openingNativeRevision;
      _openingNativeRevision = true;
      try {
        finishNative();
      } finally {
        _openingNativeRevision = wasOpening;
        // A competing import can outlive an invalidated owned operation. Close
        // that older mirrored fence when this last observed mutation settles.
        if (_finishNativeRevision != null && mutations.isStable) {
          _onNativeFence();
        }
        finishRegistry();
      }
    };
  }

  void _onNativeFence() {
    if (_openingNativeRevision) {
      return;
    }
    if (!_disposed && !mutations.isStable) {
      if (_finishNativeRevision != null) {
        return;
      }
      _openingNativeRevision = true;
      final finish = _revisions.beginMutation();
      _openingNativeRevision = false;
      if (!_disposed && !mutations.isStable) {
        _finishNativeRevision = finish;
      } else {
        finish();
      }
      return;
    }
    final finish = _finishNativeRevision;
    _finishNativeRevision = null; // Before a reentrant registry listener.
    finish?.call();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    mutations.dispose();
    mutations.removeFenceListener(_onNativeFence);
    final finish = _finishNativeRevision;
    _finishNativeRevision = null;
    finish?.call();
  }

  @override
  String toString() => 'NativeProviderRuntime';
}
