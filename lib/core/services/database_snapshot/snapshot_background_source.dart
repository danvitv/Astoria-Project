part of '../database_snapshot_service.dart';

/// Constructor injection from the real connection owner, not a model port.
final class NativeBackgroundDatabaseSnapshotSource {
  NativeBackgroundDatabaseSnapshotSource({
    required this.namespace,
    required this.sourcePath,
    required Set<String> registeredTableNames,
    required this.isCurrent,
    required this.retainUnsettled,
  }) : registeredTableNames = Set.unmodifiable(registeredTableNames);
  final AndroidSnapshotNamespace namespace;
  final String sourcePath;
  final Set<String> registeredTableNames;
  final bool Function() isCurrent;
  final void Function(Object) retainUnsettled;
  late final Future<void> Function(Future<void> Function()) _exclusively,
      _inReadTransaction;
  late final Future<Map<String, Object?>> Function(String, String) _command;
  bool _bound = false;

  void bind({
    required Future<void> Function(Future<void> Function()) exclusively,
    required Future<void> Function(Future<void> Function()) inReadTransaction,
    required Future<Map<String, Object?>> Function(String, String) command,
  }) {
    if (_bound) throw StateError('Original snapshot source already bound');
    _bound = true;
    _exclusively = exclusively;
    _inReadTransaction = inReadTransaction;
    _command = command;
  }
}
