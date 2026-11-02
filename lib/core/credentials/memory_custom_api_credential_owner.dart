import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/memory_book_api_settings.dart';
import '../preferences/saved_preferences_owner.dart';
import '../utils/error_format.dart' show activeErrorRedactor;
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'memory_custom_api_legacy_source.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

final class MemoryCustomApiAuthSummary {
  const MemoryCustomApiAuthSummary({
    this.configured = false,
    this.unavailable = false,
    this.preferencesChanged = false,
    this.revision = 0,
    this.verifiedCommit = false,
    this.unknownCommit = false,
    this.retired = false,
  });
  final bool configured, unavailable, preferencesChanged;
  final int revision;
  final bool verifiedCommit, unknownCommit, retired;
}

/// Native custom Memory custody only. No saved-connection purpose/route grant,
/// model tools, paid probe, plaintext cleanup or automatic destination rebind.
final class MemoryCustomApiCredentialOwner {
  MemoryCustomApiCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
    MemoryCustomApiLegacySource? originalSource,
  }) : _vault = vault,
       _redaction = redaction,
       source =
           originalSource ?? MemoryCustomApiLegacySource(originalPreferences);

  static final _slot = CredentialSlot(
    domain: 'memory.custom_api',
    id: 'native',
  );
  static final _nativeAdmissions = Expando<int>();
  static final _defaultRedactor = SecretRedactor();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final MemoryCustomApiLegacySource source;
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
      epoch == _epoch &&
      _seenAdmission == (_nativeAdmissions[_vault] ?? 0) &&
      source.current;

  Future<T> _run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  MemoryCustomApiInvocation capture(
    MemoryBookApiSettings settings, {
    required bool Function() isCurrent,
  }) => MemoryCustomApiInvocation._(
    this,
    _captureEpoch(),
    source.captureSettings(),
    settings.copyWith(generationApiKey: ''),
    isCurrent,
  );

  bool Function() capturePublicationGuard() {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    return () => _current(epoch) && lease.current;
  }

  static String destination(MemoryBookApiSettings settings) {
    final endpoint = settings.generationEndpoint.trim();
    final uri = Uri.tryParse(endpoint);
    if (endpoint.isEmpty ||
        uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        RegExp(r'[\s\\]').hasMatch(endpoint) ||
        uri.queryParameters.keys.any(SecretRedactor.isSecretField)) {
      throw const CredentialVaultAdmissionDenied();
    }
    return endpoint; // The original custom transport POSTS this exact URL.
  }

  static String _encode(String key, MemoryBookApiSettings settings) =>
      jsonEncode({
        'version': 1,
        'endpoint': destination(settings),
        'protocol': 'custom-chat-completion',
        'key': key,
      });

  static ({String key, String endpoint}) _decode(String record) {
    try {
      final json = jsonDecode(record);
      if (json is Map &&
          json['version'] == 1 &&
          json['protocol'] == 'custom-chat-completion' &&
          json['endpoint'] is String &&
          json['key'] is String) {
        return (
          key: json['key'] as String,
          endpoint: json['endpoint'] as String,
        );
      }
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }

  Future<void> _prepare(MemoryCustomApiInvocation original) async {
    original.requireCurrent();
    final prefs = await source.preferences(original._lease, original.isCurrent);
    original.requireCurrent();
    final root = MemoryCustomApiLegacySource.decode(
      prefs.get(MemoryCustomApiLegacySource.settingsKey),
    );
    source.registerAliases(root, _redaction);
    if (MemoryCustomApiLegacySource.settings(root) != original.settings) {
      throw const CredentialVaultAdmissionDenied();
    }
    final present = await _vault.hasStoredValue(_slot);
    original.requireCurrent();
    if (!present) {
      await source.importIfAbsent(
        vault: _vault,
        slot: _slot,
        redaction: _redaction,
        isCurrent: original.isCurrent,
        encode: _encode,
      );
      original.requireCurrent();
    }
  }

  Future<MemoryCustomApiAuthSummary> load() {
    final epoch = _captureEpoch();
    final lease = source.captureSettings();
    bool current() => _current(epoch) && lease.current;
    return _run(() async {
      try {
        final prefs = await source.preferences(lease, current);
        final root = MemoryCustomApiLegacySource.decode(
          prefs.get(MemoryCustomApiLegacySource.settingsKey),
        );
        source.registerAliases(root, _redaction);
        final original = MemoryCustomApiInvocation._(
          this,
          epoch,
          lease,
          MemoryCustomApiLegacySource.settings(root),
          current,
        );
        await _prepare(original);
        original.requireCurrent();
        final metadata = await _vault.metadata(_slot);
        original.requireCurrent();
        var configured = false;
        if (metadata.configured) {
          await _vault.useSecret(_slot, (record) async {
            original.requireCurrent();
            final credential = _decode(record);
            _redaction.registerSecret(credential.key);
            configured =
                credential.key.trim().isNotEmpty &&
                original.settings.generationSource == 'custom' &&
                credential.endpoint == destination(original.settings);
          });
          original.requireCurrent();
        }
        return MemoryCustomApiAuthSummary(
          configured: configured,
          revision: epoch,
        );
      } catch (_) {
        return MemoryCustomApiAuthSummary(unavailable: true, revision: epoch);
      }
    });
  }

  Future<MemoryCustomApiAuthSummary> setApiKey(
    String input, {
    required MemoryBookApiSettings settings,
    required bool Function() isCurrent,
  }) {
    _redaction.registerSecret(
      input,
    ); // Synchronous raw + trimmed alias coverage.
    _captureEpoch();
    _nativeAdmissions[_vault] = ++_seenAdmission;
    final epoch = ++_epoch;
    final original = capture(settings, isCurrent: isCurrent);
    final value = input.trim();
    return _run(() async {
      var submitted = false;
      try {
        original.requireCurrent();
        final prefs = await source.preferences(
          original._lease,
          original.isCurrent,
        );
        original.requireCurrent();
        final root = MemoryCustomApiLegacySource.decode(
          prefs.get(MemoryCustomApiLegacySource.settingsKey),
        );
        source.registerAliases(root, _redaction);
        if (MemoryCustomApiLegacySource.settings(root) != original.settings ||
            (value.isNotEmpty && settings.generationSource != 'custom')) {
          throw const CredentialVaultAdmissionDenied();
        }
        final record = value.isEmpty ? '' : _encode(value, settings);
        submitted = true;
        final committed = await _vault.storeGuarded(
          _slot,
          record,
          isCurrent: original.isCurrent,
        );
        // A verified write is a fact even if ordinary metadata retired its lease.
        // A newer native intent still owns summary publication; no rollback claim.
        return MemoryCustomApiAuthSummary(
          configured: committed.configured,
          preferencesChanged: !original.isCurrent(),
          revision: epoch,
          verifiedCommit: true,
          retired: !original.isCurrent(),
        );
      } on CredentialVaultAdmissionDenied {
        return MemoryCustomApiAuthSummary(
          unavailable: true,
          retired: true,
          revision: epoch,
        );
      } catch (_) {
        // Once the vault invoked a write, false/throw/readback failure is not
        // proof that nothing persisted. No rollback or plaintext fallback.
        return MemoryCustomApiAuthSummary(
          unavailable: true,
          unknownCommit: submitted,
          revision: epoch,
        );
      }
    });
  }

  /// Presence only under the ORIGINAL already-admitted ordinary writer. A
  /// present tombstone also prevents restart-time legacy destination rebinding.
  Future<bool> hasNativeRecord(bool Function() isCurrent) async {
    if (!isCurrent() || !source.current)
      throw const CredentialVaultAdmissionDenied();
    final present = await _vault.hasStoredValue(_slot);
    if (!isCurrent() || !source.current)
      throw const CredentialVaultAdmissionDenied();
    return present;
  }

  Future<T> _consume<T>(
    MemoryCustomApiInvocation original,
    Future<T> Function(String key, void Function() requireCurrent) consume,
  ) async {
    original.requireCurrent();
    if (original.settings.generationSource != 'custom') {
      throw const CredentialVaultAdmissionDenied();
    }
    final endpoint = destination(original.settings);
    final redactor = _redaction.redactor;
    await _run(() => _prepare(original));
    original.requireCurrent();
    late T result;
    String? safeError;
    await _vault.useSecret(_slot, (record) async {
      original.requireCurrent();
      final credential = _decode(record);
      _redaction.registerSecret(credential.key);
      if (credential.key.trim().isEmpty || credential.endpoint != endpoint) {
        throw const CredentialVaultAdmissionDenied();
      }
      try {
        result = await consume(credential.key, original.requireCurrent);
        original.requireCurrent();
      } catch (error) {
        safeError = redact(
          error.toString(),
          redactor.withKnownSecrets([credential.key]),
        );
      }
    });
    original.requireCurrent();
    if (safeError != null) {
      throw StateError(redact(safeError!, redactor));
    }
    return result;
  }

  String redact(String text, SecretRedactor original) {
    SecretRedactor full(SecretRedactor redactor) => redactor.withKnownSecrets(
      const [],
      maxInputLength: 200000,
      maxOutputLength: 400000,
      maxDepth: 32,
      maxNodes: 4096,
    );
    // No intermediate clip can cut a CURRENT alias before its policy sees it.
    return full(activeErrorRedactor ?? _defaultRedactor).redactText(
      full(_redaction.redactor).redactText(full(original).redactText(text)),
    );
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}

/// Denial-only original operation lease. Never renewed from matching metadata.
final class MemoryCustomApiInvocation {
  const MemoryCustomApiInvocation._(
    this._owner,
    this._epoch,
    this._lease,
    this.settings,
    this._callerCurrent,
  );
  final MemoryCustomApiCredentialOwner _owner;
  final int _epoch;
  final SavedPreferencesLease _lease;
  final MemoryBookApiSettings settings;
  final bool Function() _callerCurrent;
  SecretRedactor captureRedactor() => _owner._redaction.redactor;
  String redact(String text, SecretRedactor original) =>
      _owner.redact(text, original);
  bool isCurrent() {
    try {
      return _callerCurrent() && _owner._current(_epoch) && _lease.current;
    } catch (_) {
      return false;
    }
  }

  void requireCurrent() {
    if (!isCurrent()) throw const CredentialVaultAdmissionDenied();
  }

  Future<T> withApiKey<T>(
    Future<T> Function(String key, void Function() requireCurrent) consume,
  ) => _owner._consume(this, consume);
}
