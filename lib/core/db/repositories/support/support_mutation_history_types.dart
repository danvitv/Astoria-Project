part of '../support_repo.dart';

/// Primitive metadata only. No evidence, reservation or mutation authority.
typedef SupportMutationHistoryMetadata = ({
  String id,
  int createdAt,
  String status,
});

/// Native-only continuation. No caller factory, serialization or copyWith.
final class SupportMutationHistoryCursor {
  const SupportMutationHistoryCursor._(
    this._reader,
    this._filter,
    this._parent,
    this._newest,
    this._boundary,
  );
  final _SupportMutationHistoryReader _reader;
  final _SupportHistoryFilter _filter;
  final SupportSessionRow _parent;
  final SupportMutationHistoryMetadata _newest, _boundary;
}

/// A bounded observation, not a durable snapshot or executable journal handle.
final class SupportMutationHistoryPage {
  SupportMutationHistoryPage._(
    this._reader,
    this._filter,
    this._parent,
    this._position,
    this._newest,
    Iterable<SupportMutationHistoryMetadata> observed,
  ) : _observed = List.unmodifiable(observed);
  static const pageSize = 32;
  final _SupportMutationHistoryReader _reader;
  final _SupportHistoryFilter _filter;
  final SupportSessionRow _parent;
  final SupportMutationHistoryCursor? _position;
  final SupportMutationHistoryMetadata? _newest;
  final List<SupportMutationHistoryMetadata> _observed;
  List<SupportMutationHistoryMetadata> get entries =>
      List.unmodifiable(_observed.take(pageSize));
  SupportMutationHistoryCursor? get nextCursor => _observed.length > pageSize
      ? SupportMutationHistoryCursor._(
          _reader,
          _filter,
          _parent,
          _newest!,
          _observed[pageSize - 1],
        )
      : null;
}

typedef _SupportHistoryFilter = ({
  String sessionId,
  String domain,
  String targetId,
});
