import 'secret_redactor.dart';

/// Trusted, feature-free snapshot owner. Registration and notification are
/// synchronous, before secrets can reach diagnostic consumers. Historical
/// values stay covered through rotation/deletion until this owner is disposed.
final class SecretRedactionCoordinator {
  SecretRedactionCoordinator({SecretRedactor? redactor})
    : _redactor = (redactor ?? SecretRedactor()).withKnownSecrets(const []);

  SecretRedactor _redactor;
  final Set<String> _registered = {};
  final List<void Function(SecretRedactor)> _listeners = [];
  bool _disposed = false;

  SecretRedactor get redactor => _redactor;

  void addListener(void Function(SecretRedactor) listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(void Function(SecretRedactor) listener) =>
      _listeners.remove(listener);

  void registerSecret(String raw) {
    if (_disposed || _redactor.redactText('') == SecretRedactor.limited) return;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    final added = <String>[];
    for (final value in {trimmed, raw}) {
      if (_registered.add(value)) added.add(value);
    }
    if (added.isEmpty) return;
    _redactor = _redactor.withKnownSecrets(added);
    if (_redactor.redactText('') == SecretRedactor.limited) _registered.clear();
    for (final listener in List.of(_listeners)) {
      listener(_redactor);
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
    _registered.clear();
    // Retained adapter references and late async work must fail closed too.
    _redactor = SecretRedactor(knownSecrets: List<String>.filled(257, ''));
  }

  @override
  String toString() => 'SecretRedactionCoordinator';
}
