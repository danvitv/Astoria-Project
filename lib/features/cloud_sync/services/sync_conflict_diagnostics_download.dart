import '../cloud_adapter.dart';
import '../cloud_read_only_adapter.dart';
import '../sync_models.dart';

class SyncDiagnosticAuthUnavailable implements Exception {
  const SyncDiagnosticAuthUnavailable();
  @override
  String toString() => 'Diagnostic authorization unavailable';
}

/// Validates the diagnostic boundary, then delegates to the selected capability.
/// No ordinary download fallback or credential access. The capability returns
/// a complete response; the runner's limit bounds parsing, not transfer or
/// response allocation. There is no transport cancellation contract here.
class SyncConflictDiagnosticDownload {
  final CloudAdapter adapter;

  const SyncConflictDiagnosticDownload(this.adapter);

  bool get supported => adapter is CloudReadOnlyAdapter;

  static bool validPath(String path) {
    final match = RegExp(
      '${RegExp.escape(cloudBase)}/'
      r'(characters|character_knowledge|memory_graphs)/[A-Za-z0-9_-]{1,512}\.json',
    ).matchAsPrefix(path);
    return match != null && match.end == path.length;
  }

  Future<String> download(String path) async {
    if (!validPath(path)) throw const SyncDiagnosticInvalidIdentity();
    final selected = adapter;
    if (selected is! CloudReadOnlyAdapter) {
      throw const SyncDiagnosticAdapterUnsupported();
    }
    try {
      return await (selected as CloudReadOnlyAdapter).downloadReadOnly(path);
    } on CloudReadOnlyDownloadException catch (error) {
      switch (error.status) {
        case CloudReadOnlyDownloadStatus.reauthenticate:
          throw const SyncDiagnosticAuthUnavailable();
        case CloudReadOnlyDownloadStatus.missing:
          throw const SyncDiagnosticDownloadMissing();
        case CloudReadOnlyDownloadStatus.invalidPath:
          throw const SyncDiagnosticInvalidIdentity();
        case CloudReadOnlyDownloadStatus.unreadable:
          throw const SyncDiagnosticDownloadFailed();
      }
    } catch (_) {
      throw const SyncDiagnosticDownloadFailed();
    }
  }
}

class SyncDiagnosticAdapterUnsupported implements Exception {
  const SyncDiagnosticAdapterUnsupported();
  @override
  String toString() => 'Diagnostic adapter unsupported';
}

class SyncDiagnosticInvalidIdentity implements Exception {
  const SyncDiagnosticInvalidIdentity();
  @override
  String toString() => 'Diagnostic identity invalid';
}

class SyncDiagnosticDownloadFailed implements Exception {
  const SyncDiagnosticDownloadFailed();
  @override
  String toString() => 'Diagnostic cloud read failed';
}

class SyncDiagnosticDownloadMissing implements Exception {
  const SyncDiagnosticDownloadMissing();
  @override
  String toString() => 'Diagnostic cloud payload unavailable';
}
