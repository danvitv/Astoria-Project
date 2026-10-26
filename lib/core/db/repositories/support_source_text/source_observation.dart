part of '../support_source_text_repo.dart';

final class SupportSourceCatalogEntry {
  SupportSourceCatalogEntry._(this._owner, this.domain, this._header);
  final SupportSourceTextRepo _owner;
  final SupportSourceDomain domain;
  final Map<String, Object?> _header;
  String get sourceId => _header['source_id'] as String;

  /// Unsanitized bounded LOCAL metadata; native adapter sanitizes before egress.
  String get label => _header['label'] as String;
  int get updatedAt => _header['updated_at'] as int;
  String? get characterId => _header['character_id'] as String?;
  int? get sessionIndex => _header['session_index'] as int?;
  @override
  String toString() => 'SupportSourceCatalogEntry';
}

final class SupportSourceCatalogPage {
  SupportSourceCatalogPage._(
    List<SupportSourceCatalogEntry> entries,
    this.nextOffset,
    this.activeStudioSourceId,
  ) : entries = List.unmodifiable(entries);
  final List<SupportSourceCatalogEntry> entries;
  final int? nextOffset;

  /// Bounded native metadata, selected at this listing only. Never a grant.
  final String? activeStudioSourceId;
  @override
  String toString() => 'SupportSourceCatalogPage';
}

/// Opaque native original observation. Public metadata describes EXACT extent
/// for original confirmation. No body, digest, recipient, or permissions.
final class SupportSourceObservation {
  SupportSourceObservation._(
    this._owner,
    this.domain,
    this._header,
    this._stamp,
    List<String> ids,
    this.activeMessageOffset,
    this.totalActiveMessages,
    this.textCharacters,
    this.textBytes,
    this._discovery,
    this.studioPage,
  ) : orderedSourceIds = List.unmodifiable(ids);
  final SupportSourceTextRepo _owner;
  final SupportSourceDomain domain;
  final Map<String, Object?> _header;
  final (int, int) _stamp;
  final List<Map<String, Object?>>? _discovery;
  final List<String> orderedSourceIds;
  final int activeMessageOffset, totalActiveMessages, textCharacters, textBytes;
  final int studioPage;
  bool get studioIsPaged =>
      domain == SupportSourceDomain.studioPreset &&
      textBytes > SupportSourceTextRepo.studioUnpagedStoredBytes;
  String get sourceId => _header['source_id'] as String;
  String get label => _header['label'] as String;
  int get updatedAt => _header['updated_at'] as int;
  String get extentDescription => domain == SupportSourceDomain.game
      ? 'Exact trailing active message page; ${orderedSourceIds.length} messages; '
            'offset $activeMessageOffset of $totalActiveMessages; $textBytes UTF-8 bytes.'
      : studioIsPaged
      ? 'CURRENT SAVED Studio preset definition and instruction configuration; '
            'FULL preset ($textBytes stored UTF-8 bytes) read locally after consent for strict validation and redaction. '
            'ONLY Part ${studioPage + 1} (studioPage $studioPage) disclosed, split deterministically on Unicode scalar boundaries; '
            'at most ${SupportSourceTextRepo.maxStudioPartCharacters} UTF-16 units and '
            '${SupportSourceTextRepo.maxStudioPartDoubleJsonBytes} double-JSON escaped UTF-8 content bytes. '
            'Total parts determined only after consent. Each part needs independent consent; '
            'one part is not the full definition or a whole-preset disclosure grant. Not a historical assembled prompt.'
      : 'CURRENT SAVED Studio preset definition and instruction configuration; '
            'FULL preset ($textBytes stored UTF-8 bytes) read locally after consent for strict validation and redaction, '
            'then the complete saved definition disclosed (studioPage 0 only). Not a historical assembled prompt.';
  @override
  String toString() => 'SupportSourceObservation';
}

/// Immutable private body custody. Digest is accessible ONLY as explicitly
/// named encrypted provenance input. It must never enter model-visible JSON.
final class SupportSourceSnapshot {
  SupportSourceSnapshot._(
    this._owner,
    this._observation,
    this._json,
    this._digest,
  );
  final SupportSourceTextRepo _owner;
  final SupportSourceObservation _observation;
  final String _json, _digest;
  bool _revoked = false;
  SupportSourceReadFailure? _refusal;
  SupportSourceDomain get domain => _observation.domain;
  String get sourceId => _observation.sourceId;
  List<String> get orderedSourceIds => _observation.orderedSourceIds;
  String get snapshotDigestForEncryptedProvenance => _digest;
  @override
  String toString() => 'SupportSourceSnapshot';
}
