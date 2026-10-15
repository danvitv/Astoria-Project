import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/build_channel.dart';
import '../credentials/api_config_credential_adapter.dart';
import '../credentials/credential_storage.dart';
import '../credentials/credential_vault.dart';
import '../credentials/secret_redaction_coordinator.dart';
import '../credentials/secret_redactor.dart';
import '../llm/transport/llm_request_capture.dart';
import '../utils/error_format.dart';

/// Trusted injection point for base known values and diagnostic policy limits.
final baseSecretRedactorProvider = Provider<SecretRedactor>((ref) {
  return SecretRedactor();
});

final secretRedactionCoordinatorProvider = Provider<SecretRedactionCoordinator>(
  (ref) {
    final coordinator = SecretRedactionCoordinator(
      redactor: ref.watch(baseSecretRedactorProvider),
    );
    final captures = _RedactorSinkLease.capture(
      _captureSnapshot(coordinator.redactor),
    );
    final errors = _RedactorSinkLease.error(coordinator.redactor);
    coordinator.addListener((snapshot) {
      captures.update(_captureSnapshot(snapshot));
      errors.update(snapshot);
    });
    ref.onDispose(() {
      coordinator.dispose();
      captures.dispose();
      errors.dispose();
    });
    return coordinator;
  },
);

/// Reactive snapshots, separate from the stable vault/adapter owner. Publishing
/// a registered secret never rebuilds an adapter or loses its operation state.
final secretRedactorProvider =
    NotifierProvider<SecretRedactorNotifier, SecretRedactor>(
      SecretRedactorNotifier.new,
    );

class SecretRedactorNotifier extends Notifier<SecretRedactor> {
  @override
  SecretRedactor build() {
    final coordinator = ref.watch(secretRedactionCoordinatorProvider);
    void changed(SecretRedactor snapshot) => state = snapshot;
    coordinator.addListener(changed);
    ref.onDispose(() => coordinator.removeListener(changed));
    return coordinator.redactor;
  }
}

final credentialStorageProvider = Provider<CredentialStorage>((ref) {
  return FlutterSecureCredentialStorage(
    const FlutterSecureStorage(),
    buildChannel: buildChannel,
  );
});

final credentialVaultProvider = Provider<CredentialVault>((ref) {
  return CredentialVault(
    storage: ref.watch(credentialStorageProvider),
    buildChannel: buildChannel,
  );
});

final apiConfigCredentialAdapterProvider = Provider<ApiConfigCredentialAdapter>(
  (ref) {
    return ApiConfigCredentialAdapter(
      vault: ref.watch(credentialVaultProvider),
      redactionCoordinator: ref.watch(secretRedactionCoordinatorProvider),
    );
  },
);

SecretRedactor _captureSnapshot(SecretRedactor snapshot) =>
    snapshot.withKnownSecrets(
      const [],
      maxInputLength: 200000,
      maxOutputLength: 400000,
      maxDepth: 32,
      maxNodes: 4096,
    );

/// Composition-only ownership chain for legacy process-wide sinks. Each link
/// remembers an owner, not just its snapshot: disposing A while B is active
/// cannot make B later restore A's stale value. External replacements are never
/// overwritten by updates/disposal; capture and error ownership are independent.
final class _RedactorSinkLease {
  _RedactorSinkLease(this._owners, this._read, this._write, this._snapshot)
    : _previousValue = _read() {
    for (final owner in _owners.reversed) {
      if (identical(owner._snapshot, _previousValue)) {
        _previousOwner = owner;
        _previousValue = null;
        break;
      }
    }
    _owners.add(this);
    _write(_snapshot);
  }

  factory _RedactorSinkLease.capture(SecretRedactor snapshot) =>
      _RedactorSinkLease(
        _captureOwners,
        () => LlmRequestCapture.redactor,
        (value) => LlmRequestCapture.redactor = value,
        snapshot,
      );

  factory _RedactorSinkLease.error(SecretRedactor snapshot) =>
      _RedactorSinkLease(
        _errorOwners,
        () => activeErrorRedactor,
        (value) => activeErrorRedactor = value,
        snapshot,
      );

  static final List<_RedactorSinkLease> _captureOwners = [];
  static final List<_RedactorSinkLease> _errorOwners = [];
  final List<_RedactorSinkLease> _owners;
  final SecretRedactor? Function() _read;
  final void Function(SecretRedactor?) _write;
  SecretRedactor? _previousValue;
  _RedactorSinkLease? _previousOwner;
  SecretRedactor? _snapshot;
  bool _disposed = false;

  void update(SecretRedactor snapshot) {
    if (_disposed) return;
    final ownsSink = identical(_read(), _snapshot);
    _snapshot = snapshot;
    if (ownsSink) _write(snapshot);
  }

  SecretRedactor? get _restoreValue {
    var owner = _previousOwner;
    var previous = _previousValue;
    while (owner != null) {
      if (!owner._disposed) return owner._snapshot;
      previous = owner._previousValue;
      owner = owner._previousOwner;
    }
    return previous;
  }

  void dispose() {
    if (_disposed) return;
    final ownsSink = identical(_read(), _snapshot);
    _disposed = true;
    _owners.remove(this);
    if (ownsSink) _write(_restoreValue);
    _snapshot = null;
  }
}
