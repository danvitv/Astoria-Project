import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../utils/error_format.dart' show activeErrorRedactor;
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_openrouter_destinations.dart';
import 'image_openrouter_legacy_source.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

final class ImageOpenRouterAuthSummary {
  const ImageOpenRouterAuthSummary({
    this.configured = false,
    this.unavailable = false,
    this.revision = 0,
    this.verifiedCommit = false,
    this.unknownCommit = false,
    this.retired = false,
  });
  final bool configured, unavailable, verifiedCommit, unknownCommit, retired;
  final int revision;
}

/// Image-only native slot. Never adopts a shared LLM or DTO credential.
final class ImageOpenRouterCredentialOwner {
  ImageOpenRouterCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _redaction = redaction,
       source = ImageOpenRouterLegacySource(originalPreferences);

  static final _slot = CredentialSlot(domain: 'image.openrouter', id: 'native');
  static final _nativeAdmissions = Expando<int>();
  static final _verifiedNativeAdmissions = Expando<int>();
  static final _defaultRedactor = SecretRedactor();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final ImageOpenRouterLegacySource source;
  Future<void> _tail = Future<void>.value();
  int _epoch = 0, _seenAdmission = 0;
  bool _disposed = false;

  int _captureEpoch() {
    final latest = _nativeAdmissions[_vault] ?? 0;
    if (latest != _seenAdmission) {
      _seenAdmission = latest;
      _epoch++;
    }
    return _epoch;
  }

  bool _current(int epoch) =>
      !_disposed &&
      source.current &&
      epoch == _epoch &&
      _seenAdmission == (_nativeAdmissions[_vault] ?? 0);
  bool get _nativeReady =>
      _seenAdmission == 0 ||
      _verifiedNativeAdmissions[_vault] == _seenAdmission;
  void _check(int epoch, SavedPreferencesLease lease) {
    if (!_current(epoch) || !lease.current)
      throw const CredentialVaultAdmissionDenied();
  }

  Future<T> _run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  bool Function() captureGuard() {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    final admitted = _nativeReady;
    return () => admitted && _current(epoch) && lease.current && _nativeReady;
  }

  bool Function() captureAuthPublicationGuard() {
    final epoch = _captureEpoch();
    return () => _current(epoch);
  }

  bool isCurrentSummary(ImageOpenRouterAuthSummary summary) =>
      _current(summary.revision);

  bool Function(String) capturePublicTextGuard({bool url = false}) {
    final original = _redaction.redactor;
    final originalSink = activeErrorRedactor ?? _defaultRedactor;
    bool public(SecretRedactor policy, String value) {
      final full = url
          ? policy.withKnownSecrets(
              const [],
              maxInputLength: 33554432,
              maxOutputLength: 33554432,
            )
          : policy;
      return url
          ? ImageOpenRouterDestinations.knownSecretFreeValue(full, value)
          : full.redactText(value) == value;
    }

    return (value) =>
        !_disposed &&
        public(original, value) &&
        public(originalSink, value) &&
        public(_redaction.redactor, value) &&
        public(activeErrorRedactor ?? _defaultRedactor, value);
  }

  Future<void> _prepare(
    int epoch,
    SavedPreferencesLease lease,
    ImageOpenRouterDestinations? expected,
  ) async {
    // An invoked but unverified native Set/Clear is not permission to recover a
    // plaintext key or silently keep using an older protected key. Only a new
    // verified native intent can reopen THIS vault/isolate's admission.
    if (!_nativeReady) throw const CredentialVaultAdmissionDenied();
    final prefs = await source.preferences(lease, () => _current(epoch));
    final root = ImageOpenRouterLegacySource.decode(
      prefs.get(ImageOpenRouterLegacySource.settingsKey),
    );
    source.registerAliases(root, _redaction);
    if (expected != null &&
        !expected.same(ImageOpenRouterLegacySource.destinations(root))) {
      throw const CredentialVaultAdmissionDenied();
    }
    final present = await _vault.hasStoredValue(_slot);
    _check(epoch, lease);
    if (!present) {
      if (_seenAdmission != 0) throw const CredentialVaultAdmissionDenied();
      await source.importIfAbsent(
        vault: _vault,
        slot: _slot,
        redaction: _redaction,
        isCurrent: () => _current(epoch) && lease.current,
      );
      _check(epoch, lease);
    }
  }

  Future<ImageOpenRouterAuthSummary> load() {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    return _run(() async {
      try {
        await _prepare(epoch, lease, null);
        final prefs = await source.preferences(lease, () => _current(epoch));
        final destinations = ImageOpenRouterLegacySource.destinations(
          ImageOpenRouterLegacySource.decode(
            prefs.get(ImageOpenRouterLegacySource.settingsKey),
          ),
        );
        final metadata = await _vault.metadata(_slot);
        _check(epoch, lease);
        var configured = false;
        if (metadata.configured) {
          await _vault.useSecret(_slot, (record) async {
            _check(epoch, lease);
            _redaction.registerSecret(
              ImageOpenRouterDestinations.recordKey(record),
            );
            try {
              destinations.keyFromRecord(record);
              configured = true;
            } on CredentialVaultAdmissionDenied {
              /* Stored, but bound elsewhere. */
            }
          });
        }
        _check(epoch, lease);
        return ImageOpenRouterAuthSummary(
          configured: configured,
          revision: epoch,
        );
      } catch (_) {
        return ImageOpenRouterAuthSummary(unavailable: true, revision: epoch);
      }
    });
  }

  Future<ImageOpenRouterAuthSummary> setApiKey(
    String input, {
    required String endpoint,
  }) {
    _redaction.registerSecret(input);
    _captureEpoch();
    _nativeAdmissions[_vault] = ++_seenAdmission;
    final epoch = ++_epoch;
    final admission = _seenAdmission;
    final lease = source.captureSettings();
    final destinations = ImageOpenRouterDestinations(endpoint); // BEFORE await.
    final value = input.trim();
    return _run(() async {
      var submitted = false;
      try {
        final prefs = await source.preferences(lease, () => _current(epoch));
        final root = ImageOpenRouterLegacySource.decode(
          prefs.get(ImageOpenRouterLegacySource.settingsKey),
        );
        source.registerAliases(root, _redaction);
        if (!destinations.same(
          ImageOpenRouterLegacySource.destinations(root),
        )) {
          throw const CredentialVaultAdmissionDenied();
        }
        submitted = true;
        final committed = await _vault.storeGuarded(
          _slot,
          value.isEmpty ? '' : destinations.encode(value),
          isCurrent: () => _current(epoch) && lease.current,
        );
        if ((_nativeAdmissions[_vault] ?? 0) == admission) {
          _verifiedNativeAdmissions[_vault] = admission;
        }
        return ImageOpenRouterAuthSummary(
          configured: committed.configured,
          revision: epoch,
          verifiedCommit: true,
          retired: !_current(epoch) || !lease.current,
        );
      } on CredentialVaultAdmissionDenied {
        return ImageOpenRouterAuthSummary(revision: epoch, retired: true);
      } catch (_) {
        return ImageOpenRouterAuthSummary(
          unavailable: true,
          unknownCommit: submitted,
          revision: epoch,
        );
      }
    });
  }

  Future<bool> hasNativeRecord(bool Function() isCurrent) async {
    if (!isCurrent() || !source.current)
      throw const CredentialVaultAdmissionDenied();
    final present = await _vault.hasStoredValue(_slot);
    if (!isCurrent() || !source.current)
      throw const CredentialVaultAdmissionDenied();
    return present;
  }

  /// Capture exact recipients before asynchronous work; each HTTP/download and
  /// successful publication must call the original denial-only custody guard.
  Future<T> withApiKey<T>({
    required ImageOpenRouterDestinations destinations,
    required Future<T> Function(String key, void Function() checkCurrent)
    consume,
  }) async {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    final original = _redaction.redactor;
    final originalSink = activeErrorRedactor ?? _defaultRedactor;
    if (!_nativeReady) throw const CredentialVaultAdmissionDenied();
    await _run(() => _prepare(epoch, lease, destinations));
    _check(epoch, lease);
    late T result;
    String? safeError;
    await _vault.useSecret(_slot, (record) async {
      _check(epoch, lease);
      _redaction.registerSecret(ImageOpenRouterDestinations.recordKey(record));
      final key = destinations.keyFromRecord(record);
      try {
        result = await consume(key, () => _check(epoch, lease));
        _check(epoch, lease);
      } catch (error) {
        safeError = _redaction.redactor.redactText(
          originalSink.redactText(
            original.withKnownSecrets([key]).redactText(error.toString()),
          ),
        );
      }
    });
    _check(epoch, lease);
    if (safeError != null)
      throw StateError(
        (activeErrorRedactor ?? _defaultRedactor).redactText(
          _redaction.redactor.redactText(safeError!),
        ),
      );
    return result;
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}
