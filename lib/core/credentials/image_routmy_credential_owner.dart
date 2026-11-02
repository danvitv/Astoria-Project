import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../utils/error_format.dart' show activeErrorRedactor;
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_routmy_legacy_source.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

/// Configured means stored, not authenticated/valid. This never auto-probes.
final class ImageRoutmyAuthSummary {
  const ImageRoutmyAuthSummary({
    this.configured = false,
    this.unavailable = false,
    this.preferencesChanged = false,
    this.revision = 0,
  });
  final bool configured, unavailable;
  /// The secure write was verified, but the original settings lease retired.
  /// This is not a protected-storage failure or permission to publish old work.
  final bool preferencesChanged;
  final int revision;
}

/// Trusted image-only owner: deliberately no LLM purpose or broker auth reuse.
final class ImageRoutmyCredentialOwner {
  ImageRoutmyCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _redaction = redaction,
       source = ImageRoutmyLegacySource(originalPreferences);

  static final _slot = CredentialSlot(domain: 'image.routmy', id: 'native');
  // Same injected vault/slot, including overlapping native provider containers.
  // This does not claim coordination between independently constructed vaults.
  static final _nativeAdmissions = Expando<int>();
  static const _origins = {'https://api.rout.my', 'https://ru-api.rout.my'};
  static final _defaultRedactor = SecretRedactor();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final ImageRoutmyLegacySource source;
  Future<void> _tail = Future<void>.value();
  int _epoch = 0;
  int _seenAdmission = 0;
  bool _disposed = false;

  int _captureEpoch() {
    final latest = _nativeAdmissions[_vault] ?? 0;
    if (_seenAdmission != latest) {
      _seenAdmission = latest;
      _epoch++;
    }
    return _epoch;
  }

  bool _current(int epoch) =>
      !_disposed && epoch == _epoch &&
      _seenAdmission == (_nativeAdmissions[_vault] ?? 0);
  void _check(int epoch, SavedPreferencesLease? lease) {
    if (!_current(epoch) || lease?.current != true) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  bool Function() captureGuard() {
    final epoch = _captureEpoch();
    final lease = source.captureCredential();
    return () => _current(epoch) && lease?.current == true;
  }

  bool isCurrentSummary(ImageRoutmyAuthSummary summary) =>
      _current(summary.revision) && source.current;

  /// Metadata publication is owned by the native setter/owner, independently
  /// of an ordinary settings lease. It grants no HTTP or message-write custody.
  bool Function() captureAuthPublicationGuard() {
    final epoch = _captureEpoch();
    return () => _current(epoch) && source.current;
  }

  /// Successful public fields must survive unchanged, never be clipped or
  /// repaired into a credential fragment. Retain original coverage and consult
  /// the actual current sink as well as this injected owner on every call.
  bool Function(String) capturePublicTextGuard() {
    final original = _redaction.redactor;
    final originalSink = activeErrorRedactor ?? _defaultRedactor;
    return (value) => !_disposed &&
        original.redactText(value) == value &&
        originalSink.redactText(value) == value &&
        _redaction.redactor.redactText(value) == value &&
        (activeErrorRedactor ?? _defaultRedactor).redactText(value) == value;
  }

  Future<T> _run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _prepare(int epoch, SavedPreferencesLease? lease) async {
    await source.preferences(lease, () => _current(epoch));
    _check(epoch, lease);
    // Failure is not absence. A protected empty value blocks every legacy key.
    final present = await _vault.hasStoredValue(_slot);
    _check(epoch, lease);
    if (!present) {
      await source.importIfAbsent(
        vault: _vault,
        slot: _slot,
        redaction: _redaction,
        isCurrent: () => _current(epoch) && lease?.current == true,
      );
      _check(epoch, lease);
    }
  }

  Future<ImageRoutmyAuthSummary> load() {
    final epoch = _captureEpoch();
    final lease = source.captureCredential();
    return _run(() async {
      try {
        await _prepare(epoch, lease);
        final metadata = await _vault.metadata(_slot);
        _check(epoch, lease);
        if (metadata.configured) {
          await _vault.useSecret(_slot, (key) async {
            _check(epoch, lease);
            _redaction.registerSecret(key);
          });
        }
        _check(epoch, lease);
        return ImageRoutmyAuthSummary(
          configured: metadata.configured,
          revision: epoch,
        );
      } catch (_) {
        return ImageRoutmyAuthSummary(unavailable: true, revision: epoch);
      }
    });
  }

  Future<ImageRoutmyAuthSummary> setApiKey(String input) {
    _redaction.registerSecret(input); // Before any queue/await/error publication.
    _captureEpoch();
    _seenAdmission++;
    _nativeAdmissions[_vault] = _seenAdmission;
    final epoch = ++_epoch;
    final lease = source.captureCredential();
    final value = input.trim();
    return _run(() async {
      await source.preferences(lease, () => _current(epoch));
      _check(epoch, lease);
      final committed = await _vault.storeGuarded(
        _slot,
        value, // Empty is a verified durable native-clear tombstone.
        isCurrent: () => _current(epoch) && lease?.current == true,
      );
      // Backend invocation has already settled verified readback. An ordinary
      // settings save (even a failed one) cannot turn that commit into a secure
      // storage failure. A newer native intent/disposed owner still wins.
      if (!_current(epoch) || !source.current) {
        throw const CredentialVaultAdmissionDenied();
      }
      return ImageRoutmyAuthSummary(
        configured: committed.configured,
        preferencesChanged: lease?.current != true,
        revision: epoch,
      );
    });
  }

  /// Consumer runs within ephemeral custody. It must call checkCurrent before
  /// EACH HTTP invocation and may not retain/return the credential. Publication
  /// is checked again after it completes. HTTP errors leave as sanitized text,
  /// never as a Dio request/options object holding the Authorization header.
  Future<T> withApiKey<T>({
    required String origin,
    required Future<T> Function(String key, void Function() checkCurrent) consume,
  }) async {
    final epoch = _captureEpoch();
    final lease = source.captureCredential();
    final originalRedactor = _redaction.redactor;
    final originalSink = activeErrorRedactor ?? _defaultRedactor;
    if (!_origins.contains(origin)) throw const CredentialVaultAdmissionDenied();
    await _run(() => _prepare(epoch, lease));
    final prefs = await source.preferences(lease, () => _current(epoch));
    final settings = ImageRoutmyLegacySource.decode(
      prefs.get(ImageRoutmyLegacySource.settingsKey),
    );
    final mirror = settings?['routmyMirror'];
    if (mirror != null && mirror != 'global' && mirror != 'ru') {
      throw const CredentialVaultAdmissionDenied();
    }
    final configuredOrigin = settings?['routmyMirror'] == 'ru' ||
            (settings?['routmyMirror'] == null && settings?['apiType'] == 'ruRoutmy')
        ? 'https://ru-api.rout.my'
        : 'https://api.rout.my';
    if (origin != configuredOrigin) throw const CredentialVaultAdmissionDenied();
    _check(epoch, lease);
    late T result;
    String? safeError;
    await _vault.useSecret(_slot, (key) async {
      _check(epoch, lease);
      _redaction.registerSecret(key);
      final original = originalRedactor.withKnownSecrets([key]);
      try {
        result = await consume(key, () => _check(epoch, lease));
        _check(epoch, lease);
      } catch (error) {
        safeError = _redaction.redactor.redactText(
          originalSink.redactText(original.redactText(error.toString())),
        );
      }
    });
    _check(epoch, lease);
    if (safeError != null) {
      // useSecret adds an await between extraction and actual publication.
      // A different live coordinator may now own the global error sink.
      throw StateError((activeErrorRedactor ?? _defaultRedactor).redactText(
        _redaction.redactor.redactText(safeError!),
      ));
    }
    return result;
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}
