import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../utils/error_format.dart' show activeErrorRedactor;
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_naistera_destinations.dart';
import 'image_naistera_legacy_source.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

final class ImageNaisteraAuthSummary {
  const ImageNaisteraAuthSummary({
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

/// Native IMAGE-only custody, with same-vault latest-intent fences. No DTO key
/// adoption, LLM/NovelAI fallback, route rebinding, cleanup or readable key state.
final class ImageNaisteraCredentialOwner {
  ImageNaisteraCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
    String baseUrl = ImageNaisteraDestinations.defaultBase,
  }) : _vault = vault,
       _redaction = redaction,
       destinations = ImageNaisteraDestinations(baseUrl),
       source = ImageNaisteraLegacySource(originalPreferences);
  static final _slot = CredentialSlot(domain: 'image.naistera', id: 'native');
  static final _admissions = Expando<int>(), _verified = Expando<int>();
  static final _uncertainImport = Expando<bool>();
  static final _defaultPolicy = SecretRedactor();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final ImageNaisteraDestinations destinations;
  final ImageNaisteraLegacySource source;
  Future<void> _tail = Future<void>.value();
  int _epoch = 0, _seen = 0;
  bool _disposed = false;
  int _captureEpoch() {
    final latest = _admissions[_vault] ?? 0;
    if (_seen != latest) {
      _seen = latest;
      _epoch++;
    }
    return _epoch;
  }

  bool _current(int epoch) =>
      !_disposed &&
      source.current &&
      epoch == _epoch &&
      _seen == (_admissions[_vault] ?? 0);
  bool get _ready =>
      (_seen == 0 || _verified[_vault] == _seen) &&
      _uncertainImport[_vault] != true;
  void _check(int epoch, SavedPreferencesLease lease) {
    if (!_current(epoch) || !lease.current || !_ready) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  Future<T> _run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  bool Function() captureGuard() {
    final epoch = _captureEpoch(), lease = source.captureSettings();
    final admitted = _ready;
    return () => admitted && _current(epoch) && lease.current && _ready;
  }

  bool Function() captureAuthPublicationGuard() {
    final epoch = _captureEpoch();
    return () => _current(epoch);
  }

  bool isCurrentSummary(ImageNaisteraAuthSummary summary) =>
      _current(summary.revision);

  /// WHOLE original/current text plus one percent-decoded known-secret layer.
  /// This is not URL validation: local paths, JSON and instruction prose work.
  bool Function(String) capturePublicTextGuard({bool url = false}) {
    final original = _redaction.redactor;
    final originalSink = activeErrorRedactor ?? _defaultPolicy;
    bool public(SecretRedactor policy, String value) {
      final full = policy.withKnownSecrets(
        const [],
        maxInputLength: 33554432,
        maxOutputLength: 33554432,
      );
      return ImageNaisteraDestinations.knownSecretFreeValue(full, value);
    }

    return (value) =>
        !_disposed &&
        public(original, value) &&
        public(originalSink, value) &&
        public(_redaction.redactor, value) &&
        public(activeErrorRedactor ?? _defaultPolicy, value);
  }

  Future<void> _prepare(
    int epoch,
    SavedPreferencesLease lease,
    ImageNaisteraDestinations? expected, [
    String? selectedModel,
    bool Function(String)? originalPublic,
  ]) async {
    _check(epoch, lease);
    if (expected != null && !destinations.same(expected)) {
      throw const CredentialVaultAdmissionDenied();
    }
    final prefs = await source.preferences(lease, () => _current(epoch));
    source.registerAliases(prefs, _redaction);
    final public = originalPublic ?? capturePublicTextGuard();
    if (![
      destinations.generation,
      destinations.models,
      destinations.check,
    ].every(public)) {
      throw const CredentialVaultAdmissionDenied();
    }
    if (selectedModel != null) {
      final raw = ImageNaisteraLegacySource.model(prefs);
      if (!public(raw) ||
          !public(selectedModel) ||
          !public(ImageNaisteraDestinations.normalizeModel(raw)) ||
          ImageNaisteraDestinations.normalizeModel(raw) !=
              ImageNaisteraDestinations.normalizeModel(selectedModel)) {
        throw const CredentialVaultAdmissionDenied();
      }
    }
    final present = await _vault.hasStoredValue(_slot);
    _check(epoch, lease);
    if (!present) {
      if (_seen != 0) throw const CredentialVaultAdmissionDenied();
      try {
        await source.importIfAbsent(
          vault: _vault,
          slot: _slot,
          redaction: _redaction,
          destinations: destinations,
          isCurrent: () => _current(epoch) && lease.current && _ready,
        );
      } on CredentialVaultException {
        // An invoked import may have persisted despite failed verification.
        // Only a later explicit, verified native Set/Clear resolves uncertainty.
        if ((_admissions[_vault] ?? 0) == 0) _uncertainImport[_vault] = true;
        rethrow;
      }
      _check(epoch, lease);
    }
  }

  Future<ImageNaisteraAuthSummary> load() {
    final epoch = _captureEpoch(), lease = source.captureSettings();
    final public = capturePublicTextGuard();
    return _run(() async {
      try {
        await _prepare(epoch, lease, null, null, public);
        final metadata = await _vault.metadata(_slot);
        _check(epoch, lease);
        var configured = false;
        if (metadata.configured) {
          await _vault.useSecret(_slot, (record) async {
            _check(epoch, lease);
            _redaction.registerSecret(
              ImageNaisteraDestinations.recordKey(record),
            );
            try {
              destinations.keyFromRecord(record);
              configured = true;
            } on CredentialVaultAdmissionDenied {
              /* Bound elsewhere. */
            }
          });
        }
        _check(epoch, lease);
        return ImageNaisteraAuthSummary(
          configured: configured,
          revision: epoch,
        );
      } catch (_) {
        return ImageNaisteraAuthSummary(unavailable: true, revision: epoch);
      }
    });
  }

  Future<ImageNaisteraAuthSummary> setApiKey(String input) {
    _redaction.registerSecret(input);
    _captureEpoch();
    _admissions[_vault] = ++_seen;
    final admission = _seen, epoch = ++_epoch;
    final lease = source.captureSettings(), value = input.trim();
    final public = capturePublicTextGuard();
    return _run(
      () => SavedPreferencesWrites.serializeImageRoutmy(() async {
        var submitted = false;
        try {
          final prefs = await source.preferences(lease, () => _current(epoch));
          source.registerAliases(prefs, _redaction);
          if (![
            destinations.generation,
            destinations.models,
            destinations.check,
          ].every(public)) {
            throw const CredentialVaultAdmissionDenied();
          }
          submitted = true;
          final committed = await _vault.storeGuarded(
            _slot,
            value.isEmpty ? '' : destinations.encode(value),
            isCurrent: () => _current(epoch) && lease.current,
          );
          if ((_admissions[_vault] ?? 0) == admission) {
            _verified[_vault] = admission;
            _uncertainImport[_vault] = false;
          }
          return ImageNaisteraAuthSummary(
            configured: committed.configured,
            revision: epoch,
            verifiedCommit: true,
            retired: !_current(epoch) || !lease.current,
          );
        } on CredentialVaultAdmissionDenied {
          return ImageNaisteraAuthSummary(revision: epoch, retired: true);
        } catch (_) {
          return ImageNaisteraAuthSummary(
            unavailable: true,
            unknownCommit: submitted,
            revision: epoch,
          );
        }
      }),
    );
  }

  Future<T> withApiKey<T>({
    required ImageNaisteraDestinations destinations,
    required String model,
    required Future<T> Function(String key, void Function() checkCurrent)
    consume,
  }) async {
    final epoch = _captureEpoch(), lease = source.captureSettings();
    final public = capturePublicTextGuard(); // Before prefs/storage/HTTP await.
    await _run(() => _prepare(epoch, lease, destinations, model, public));
    void check() {
      _check(epoch, lease);
      if (![
        destinations.generation,
        destinations.models,
        destinations.check,
        model,
        ImageNaisteraDestinations.normalizeModel(model),
      ].every(public)) {
        throw const CredentialVaultAdmissionDenied();
      }
    }

    check();
    late T result;
    var failed = false;
    await _vault.useSecret(_slot, (record) async {
      _check(epoch, lease);
      _redaction.registerSecret(ImageNaisteraDestinations.recordKey(record));
      final key = destinations.keyFromRecord(record);
      check();
      try {
        result = await consume(key, check);
        check();
      } catch (_) {
        failed = true;
      }
    });
    check();
    if (failed) throw StateError('Naistera image request unavailable');
    return result;
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}
