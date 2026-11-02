import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../utils/error_format.dart' show activeErrorRedactor;
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_novelai_destinations.dart';
import 'image_novelai_legacy_source.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

final class ImageNovelAiAuthSummary {
  const ImageNovelAiAuthSummary({
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

/// Image-only native custody. No readable key state or shared LLM fallback.
final class ImageNovelAiCredentialOwner {
  ImageNovelAiCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _redaction = redaction,
       source = ImageNovelAiLegacySource(originalPreferences);

  static final _slot = CredentialSlot(domain: 'image.novelai', id: 'native');
  static final _nativeAdmissions = Expando<int>();
  static final _verifiedNativeAdmissions = Expando<int>();
  static final _defaultRedactor = SecretRedactor();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final ImageNovelAiLegacySource source;
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
    if (!_current(epoch) || !lease.current || !_nativeReady)
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

  bool isCurrentSummary(ImageNovelAiAuthSummary summary) =>
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
          ? ImageNovelAiDestinations.knownSecretFreeValue(full, value)
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
    ImageNovelAiDestinations? expected,
  ) async {
    if (!_nativeReady) throw const CredentialVaultAdmissionDenied();
    final prefs = await source.preferences(lease, () => _current(epoch));
    final root = ImageNovelAiLegacySource.decode(
      prefs.get(ImageNovelAiLegacySource.settingsKey),
    );
    source.registerAliases(root, _redaction);
    if (expected != null &&
        !expected.same(ImageNovelAiLegacySource.destinations(root))) {
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

  Future<ImageNovelAiAuthSummary> load() {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    return _run(() async {
      try {
        await _prepare(epoch, lease, null);
        final prefs = await source.preferences(lease, () => _current(epoch));
        final destinations = ImageNovelAiLegacySource.destinations(
          ImageNovelAiLegacySource.decode(
            prefs.get(ImageNovelAiLegacySource.settingsKey),
          ),
        );
        final metadata = await _vault.metadata(_slot);
        _check(epoch, lease);
        var configured = false;
        if (metadata.configured) {
          await _vault.useSecret(_slot, (record) async {
            _check(epoch, lease);
            _redaction.registerSecret(
              ImageNovelAiDestinations.recordKey(record),
            );
            try {
              destinations.keyFromRecord(record);
              configured = true;
            } on CredentialVaultAdmissionDenied {
              /* Bound elsewhere, never rebound. */
            }
          });
        }
        _check(epoch, lease);
        return ImageNovelAiAuthSummary(configured: configured, revision: epoch);
      } catch (_) {
        return ImageNovelAiAuthSummary(unavailable: true, revision: epoch);
      }
    });
  }

  Future<ImageNovelAiAuthSummary> setApiKey(
    String input, {
    required String endpoint,
    required String model,
  }) {
    _redaction.registerSecret(input);
    _captureEpoch();
    _nativeAdmissions[_vault] = ++_seenAdmission;
    final epoch = ++_epoch;
    final admission = _seenAdmission;
    final lease = source.captureSettings();
    final value = input.trim();
    // Recipient parsing belongs to the admitted action, but failures stay typed
    // keyless metadata. Never throw the replacement draft into provider state.
    ImageNovelAiDestinations? destinations;
    try {
      destinations = ImageNovelAiDestinations(endpoint, model);
    } catch (_) {}
    return _run(() async {
      var submitted = false;
      try {
        if (destinations == null) throw const CredentialVaultAdmissionDenied();
        final prefs = await source.preferences(lease, () => _current(epoch));
        final root = ImageNovelAiLegacySource.decode(
          prefs.get(ImageNovelAiLegacySource.settingsKey),
        );
        source.registerAliases(root, _redaction);
        if (!destinations.same(ImageNovelAiLegacySource.destinations(root))) {
          throw const CredentialVaultAdmissionDenied();
        }
        submitted = true;
        final committed = await _vault.storeGuarded(
          _slot,
          value.isEmpty ? '' : destinations.encode(value),
          isCurrent: () => _current(epoch) && lease.current,
        );
        if ((_nativeAdmissions[_vault] ?? 0) == admission)
          _verifiedNativeAdmissions[_vault] = admission;
        return ImageNovelAiAuthSummary(
          configured: committed.configured,
          revision: epoch,
          verifiedCommit: true,
          retired: !_current(epoch) || !lease.current,
        );
      } on CredentialVaultAdmissionDenied {
        return ImageNovelAiAuthSummary(revision: epoch, retired: true);
      } catch (_) {
        return ImageNovelAiAuthSummary(
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

  Future<T> withApiKey<T>({
    required ImageNovelAiDestinations destinations,
    required Future<T> Function(String key, void Function() checkCurrent)
    consume,
  }) async {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    final original = _redaction.redactor;
    final originalSink = activeErrorRedactor ?? _defaultRedactor;
    final publicRoute = capturePublicTextGuard(url: true);
    if (!_nativeReady) throw const CredentialVaultAdmissionDenied();
    await _run(() => _prepare(epoch, lease, destinations));
    void check() {
      _check(epoch, lease);
      if (!publicRoute(destinations.generation) ||
          !publicRoute(destinations.check) ||
          !publicRoute(destinations.model)) {
        throw const CredentialVaultAdmissionDenied();
      }
    }

    // Refuse known-private routing/model material before opening the protected
    // consumer. Otherwise its pre-admission refusal becomes a vault failure.
    check();
    late T result;
    String? safeError;
    await _vault.useSecret(_slot, (record) async {
      _check(epoch, lease);
      _redaction.registerSecret(ImageNovelAiDestinations.recordKey(record));
      final key = destinations.keyFromRecord(record);
      check();
      try {
        result = await consume(key, check);
        check();
      } catch (error) {
        safeError = _redaction.redactor.redactText(
          originalSink.redactText(
            original.withKnownSecrets([key]).redactText(error.toString()),
          ),
        );
      }
    });
    check();
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
