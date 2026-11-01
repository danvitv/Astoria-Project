part of 'support_report_coordinator.dart';

extension _ReportPreviewStore on SupportReportCoordinator {
  SupportReportPreview _exclude(
    SupportReportPreview preview,
    Set<String> blockIds,
  ) {
    final prepared = _require(preview);
    if (_exporting) _fail(SupportReportFailure.unavailable);
    if (blockIds.any((id) => !prepared.blocks.any((b) => b.id == id))) {
      _fail(SupportReportFailure.invalidArguments);
    }
    final removed = SupportReportExclusions.closure(prepared.blocks, blockIds);
    prepared.retired = true;
    final next = _Prepared(
      prepared.owner,
      prepared.snapshot,
      prepared.recipient,
      prepared.id,
      prepared.day,
      prepared.current,
      List.unmodifiable(prepared.blocks.where((b) => !removed.contains(b.id))),
      List.unmodifiable([
        ...prepared.omissions,
        for (final id in (removed.toList()..sort()))
          'Excluded block: $id (including dependent derivatives).',
      ]),
    );
    _active = next;
    return _preview(next);
  }

  SupportReportPreview _preview(_Prepared p) {
    final json = SupportReportJson.canonical({
      'version': 1,
      'reportId': p.id,
      'createdDay': p.day,
      'blocks': p.blocks.map((b) => b.toJson()).toList(),
      'omissions': p.omissions,
    });
    final preview = SupportReportPreview.internal(
      payloadJson: json,
      blocks: p.blocks,
      omissions: p.omissions,
      recipientConfigured: p.recipient != null,
      retired: () => p.retired || !p.current(),
    );
    p.preview = preview;
    return preview;
  }

  _Prepared _require(SupportReportPreview preview) {
    final p = _active;
    if (p == null ||
        !identical(p.preview, preview) ||
        p.retired ||
        !p.current() ||
        _disposed) {
      _fail(SupportReportFailure.changed);
    }
    return p;
  }

  void _retire() {
    _active?.retired = true;
    _active = null;
    _epoch++;
  }
}

final class _Prepared {
  _Prepared(
    this.owner,
    this.snapshot,
    this.recipient,
    this.id,
    this.day,
    this.current,
    this.blocks,
    this.omissions,
  );
  final SupportReportOwnership owner;
  final SupportReportReadSnapshot snapshot;
  final SupportReportRecipient? recipient;
  final String id;
  final int day;
  final bool Function() current;
  final List<SupportReportBlock> blocks;
  final List<String> omissions;
  bool retired = false, consumed = false;
  SupportReportPreview? preview;
}

/// Freeze actual objects synchronously, rather than trusting live getters to
/// silently substitute another database/source/key/redaction owner after await.
final class _CapturedReportOwnership implements SupportReportOwnership {
  _CapturedReportOwnership(this.delegate)
    : database = delegate.database,
      nativeSource = delegate.nativeSource,
      redactor = delegate.redactor,
      readCipher = delegate.readCipher;
  final SupportReportOwnership delegate;
  @override
  final AppDatabase database;
  @override
  final NativeDataSourceIdentity nativeSource;
  @override
  final SecretRedactor redactor;
  @override
  final SupportPayloadCipher readCipher;
  @override
  bool get isCurrent {
    try {
      return delegate.isCurrent &&
          identical(database, delegate.database) &&
          identical(nativeSource, delegate.nativeSource) &&
          identical(redactor, delegate.redactor) &&
          identical(readCipher, delegate.readCipher) &&
          nativeSource.belongsTo(database) &&
          !database.isClosing;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get allowsApplicationData => delegate.allowsApplicationData;
  @override
  NativeReportRootScope? get originalRoot => delegate.originalRoot;
  @override
  Future<T> withOriginalRoot<T>(Future<T> Function() work) =>
      delegate.withOriginalRoot(work);
  @override
  Future<T> admitOriginalRoot<T>({
    required Future<void> Function() validate,
    required T Function() dispatch,
  }) => delegate.admitOriginalRoot(validate: validate, dispatch: dispatch);
}

extension _ReportOriginalRootChecks on SupportReportCoordinator {
  NativeReportRootScope _root(SupportReportOwnership owner) {
    final root = owner.originalRoot;
    if (root == null || !root.belongsTo(owner.database)) {
      _fail(SupportReportFailure.changed);
    }
    root.check(owner.database);
    return root;
  }

  bool _rootCurrent(
    SupportReportOwnership owner,
    NativeReportRootScope root,
    bool Function() current,
  ) {
    try {
      root.check(owner.database);
      return identical(root, owner.originalRoot) &&
          root.belongsTo(owner.database) &&
          current();
    } catch (_) {
      return false;
    }
  }
}

/// An admitted native future is DATA in this capsule, never RootWork itself.
/// Both outcomes are consumed immediately, without waiting inside the ROOT.
final class _ReportSaveAdmission {
  _ReportSaveAdmission(Future<SupportReportSaveResult> admitted)
    : response = admitted.then(
        (value) => value,
        onError: (Object _, StackTrace _) => const SupportReportSaveResult(
          SupportReportSaveStatus.failed,
          reason: 'unavailable',
        ),
      );
  final Future<SupportReportSaveResult> response;
}
