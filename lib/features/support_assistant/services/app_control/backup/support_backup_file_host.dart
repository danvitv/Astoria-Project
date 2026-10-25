import '../../../../../core/db/app_db.dart';
import '../../../../../core/services/database_snapshot_service.dart';
import '../../../models/support_app_action.dart';

/// Implemented by the ORIGINAL model ROOT, bound to its actual AppDatabase.
/// LOCAL backup does not change a model source. Its read-only ROOT admits only
/// the exact native selected file capsule, without consuming a source-mutation
/// terminal permit (which deliberately cancels the requester).
abstract interface class SupportBackupOriginalDatabaseRoot
    implements SupportAppDomainRootPort {
  bool retainsBackupSource(
    NativeDataSourceIdentity source,
    SupportAppActionContext original,
  );
  Future<SupportBackupRootLease?> admitBackupFile(
    SupportBackupFileSelection selection,
    SupportAppActionContext original,
  );
}

/// Optional narrow mobile proposal on the SAME audited original ROOT.
abstract interface class SupportBackupAppPrivateDatabaseRoot
    implements SupportBackupOriginalDatabaseRoot {
  String? proposeAppPrivateSnapshotDestination(
    SupportAppActionContext original,
  );
}

/// Framework UI port only. Production is SupportBackupNativeUi, which invokes
/// FilePicker and renders an exact native confirmation; tests replace this port
/// with a synthetic framework dialog, never the snapshot/filesystem service.
abstract interface class SupportBackupFileUi {
  bool get isCurrent;
  Future<String?> chooseLocalFile(SupportAppActionContext original);
  Future<SupportAppConfirmationLease?> confirmLocalFile(
    SupportAppConfirmationRequest request,
    String privateDestination,
    String disclosure,
  );
}

/// Exact whole-DB LOCAL save consent. The destination never enters tool JSON.
final class SupportBackupNativeFileHost implements SupportAppConfirmationPort {
  SupportBackupNativeFileHost({required this.ui, this.otherConfirmation});
  final SupportBackupFileUi ui;
  final SupportAppConfirmationPort? otherConfirmation;
  static const action = 'astoria_database_snapshot';
  static const target = 'original-whole-database-local-file';
  static const disclosure =
      'Создать локальный снимок всей открытой базы Astoria в выбранном файле. '
      'Он содержит все сохранённые данные базы, в том числе личные тексты, '
      'зашифрованные данные и сохранённые байты учётных данных. '
      'Внешнее хранилище ключей, настройки и медиа не включаются. '
      'Astoria не отправляет этот файл в сеть или модели. '
      'Существующий файл не заменяется. '
      'Проверяется локальный снимок, а не восстановление, доступность ключей '
      'или гарантированная сохранность при сбое диска.';
  static const preview = <String, Object?>{
    'scope': 'wholeOriginalDatabase',
    'destination': 'nativeSelectedLocalFile',
    'existingFile': 'refused',
    'networkUpload': false,
    'modelBodyAccess': false,
    'runtimeRestore': false,
    'externalKeyVaultIncluded': false,
    'keyRecoverabilityKnown': false,
  };

  bool _disposed = false;
  final _selections = <SupportBackupFileSelection>{};
  bool get isCurrent => !_disposed && ui.isCurrent;

  Future<SupportBackupFileSelection?> choose(
    SupportAppActionContext original,
    NativeDataSourceIdentity source,
    bool Function() ownerCurrent,
  ) async {
    bool current() =>
        isCurrent &&
        original.current &&
        source.isCurrent &&
        ownerCurrent() &&
        isCurrent &&
        original.current;
    if (!current() || !identical(original.confirmation, this)) return null;
    final path = await ui.chooseLocalFile(original);
    if (!current()) return null;
    if (path == null) {
      throw const SupportAppActionRefused(SupportAppActionCode.cancelled);
    }
    // One finite original selection. New native choice retires any abandoned
    // confirmation; it cannot renew an old destination/context capsule.
    for (final previous in _selections) {
      previous._retired = true;
    }
    _selections.clear();
    // Core native pins still prove local/canonical/no-alias/no-replace identity.
    final selection = SupportBackupFileSelection._(
      this,
      original,
      source,
      path,
      current,
    );
    _selections.add(selection);
    return selection;
  }

  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    if (request.action != action) {
      return otherConfirmation?.confirm(request);
    }
    final selection = request.observation;
    if (selection is! SupportBackupFileSelection ||
        !_selections.contains(selection) ||
        !identical(selection._original, request.context) ||
        !identical(request.context.confirmation, this) ||
        request.target != target ||
        request.arguments.isNotEmpty ||
        request.preview.length != preview.length ||
        !preview.entries.every((e) => request.preview[e.key] == e.value) ||
        selection._request != null ||
        !selection.isCurrent ||
        !request.current) {
      return null;
    }
    selection._request = request; // Bind BEFORE the framework await.
    final lease = await ui.confirmLocalFile(
      request,
      selection._path,
      disclosure,
    );
    if (!selection.isCurrent ||
        !request.current ||
        lease == null ||
        !identical(lease.request, request))
      return null;
    selection._lease = lease; // Registry consumes the exact returned UI lease.
    return lease;
  }

  void dispose() {
    _disposed = true;
    _selections.clear();
  }
}

final class SupportBackupFileSelection {
  SupportBackupFileSelection._(
    this._host,
    this._original,
    this._source,
    this._path,
    this._current,
  );
  final SupportBackupNativeFileHost _host;
  final SupportAppActionContext _original;
  final NativeDataSourceIdentity _source;
  final String _path;
  final bool Function() _current;
  SupportAppConfirmationRequest? _request;
  SupportAppConfirmationLease? _lease;
  bool _consumed = false, _retired = false, _rootAdmitted = false;
  bool get isCurrent =>
      !_consumed && !_retired && _host.isCurrent && _current();

  bool belongsToOriginalDatabase(AppDatabase database) =>
      _source.belongsTo(database) && _current();

  bool belongsToOriginalContext(SupportAppActionContext original) =>
      identical(_original, original) && identical(original.confirmation, _host);

  /// Synchronous capsule operation called ONLY inside the ORIGINAL audited
  /// read ROOT. No callback, path, model token or replacement DB is accepted.
  SupportBackupRootLease? admitOriginalSource(AppDatabase originalDatabase) {
    if (_rootAdmitted ||
        !isCurrent ||
        _lease?.current != true ||
        _request == null ||
        !identical(_lease!.request, _request) ||
        !_request!.current ||
        !belongsToOriginalDatabase(originalDatabase))
      return null;
    _rootAdmitted = true;
    return SupportBackupRootLease._(this);
  }

  NativeDatabaseSnapshotOwner? consume({
    required SupportBackupRootLease custody,
    required bool Function() isCurrent,
  }) {
    if (!this.isCurrent ||
        _lease?.current != true ||
        !custody.isCurrent ||
        !identical(custody._selection, this) ||
        !_rootAdmitted ||
        !isCurrent())
      return null;
    _consumed = true; // BEFORE native construction or source/file access.
    _host._selections.remove(this);
    return _source.ownerForApprovedLocalFile(
      destinationPath: _path,
      isOriginalOwnerCurrent: () =>
          _host.isCurrent &&
          _current() &&
          _lease?.current == true &&
          custody.isCurrent &&
          isCurrent(),
    );
  }

  @override
  String toString() => 'SupportBackupFileSelection';
}

/// Exact original read-ROOT/file consent custody, never a reusable tool handle.
final class SupportBackupRootLease {
  SupportBackupRootLease._(this._selection);
  final SupportBackupFileSelection _selection;
  bool _closed = false;
  bool get isCurrent =>
      !_closed &&
      !_selection._retired &&
      _selection._host.isCurrent &&
      _selection._current() &&
      _selection._lease?.current == true &&
      _selection._source.isCurrent;
  void close() => _closed = true;
  @override
  String toString() => 'SupportBackupRootLease';
}
