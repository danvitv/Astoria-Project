part of '../support_text_context_repo.dart';

Never _fail(SupportTextContextFailure failure) =>
    throw SupportTextContextException(failure);

bool _identity(String id, SecretRedactor redactor) =>
    id.isNotEmpty &&
    id.trim() == id &&
    id.length <= SupportTextContextRepo.maxIdentityChars &&
    !RegExp(r'[\x00-\x20\x7f|]').hasMatch(id) &&
    redactor.redactText(id) == id &&
    !id.contains(SecretRedactor.removed) &&
    !id.contains(SecretRedactor.limited);

int _textBytes(String text) {
  if (text.length > SupportTextContextRepo.maxTextChars) {
    _fail(SupportTextContextFailure.limited);
  }
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final u = text.codeUnitAt(i);
    if (u < 0x80) {
      bytes++;
    } else if (u < 0x800) {
      bytes += 2;
    } else if (u >= 0xd800 &&
        u <= 0xdbff &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xdc00 &&
        text.codeUnitAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
    if (bytes > SupportTextContextRepo.maxTextBytes) {
      _fail(SupportTextContextFailure.limited);
    }
  }
  return bytes;
}

bool _sameValues(Map<String, Object?> a, Map<String, Object?> b) =>
    a.length == b.length && a.keys.every((key) => a[key] == b[key]);

bool _sameIds(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((same) => same);

bool _sameMessages(
  List<SupportTextContextMessage> a,
  List<SupportTextContextMessage> b,
) =>
    a.length == b.length &&
    List.generate(
      a.length,
      (i) => a[i].role == b[i].role && a[i].text == b[i].text,
    ).every((same) => same);

final class _RawTextBody {
  const _RawTextBody(this._role, this._text);
  final String _role, _text;
}

/// Projection-only primitive observations. No arbitrary source objects, cards,
/// fingerprints, serialized raw state or caller-readable observation getters.
final class _TextRead {
  _TextRead(
    QueryRow header,
    List<QueryRow> rows,
    this._bodies, {
    List<SupportTextContextProvenance> provenance = const [],
    List<QueryRow> provenanceRows = const [],
  }) : _header = Map.unmodifiable(header.data),
       _rows = List.unmodifiable(
         rows.map((row) => Map<String, Object?>.unmodifiable(row.data)),
       ),
       _membershipRows = const [],
       _provenance = List.unmodifiable(provenance),
       _provenanceRows = List.unmodifiable(
         provenanceRows.map(
           (row) => Map<String, Object?>.unmodifiable(row.data),
         ),
       );
  _TextRead._session(_TextRead base, List<QueryRow> membership)
    : _header = base._header,
      _rows = base._rows,
      _bodies = base._bodies,
      _provenance = base._provenance,
      _provenanceRows = base._provenanceRows,
      _membershipRows = List.unmodifiable(
        membership.map((row) => Map<String, Object?>.unmodifiable(row.data)),
      );
  final Map<String, Object?> _header;
  final List<Map<String, Object?>> _rows;
  final List<_RawTextBody> _bodies;
  final List<SupportTextContextProvenance> _provenance;
  final List<Map<String, Object?>> _provenanceRows;
  final List<Map<String, Object?>> _membershipRows;

  bool _same(_TextRead other) =>
      _sameValues(_header, other._header) &&
      _rows.length == other._rows.length &&
      _membershipRows.length == other._membershipRows.length &&
      List.generate(
        _membershipRows.length,
        (i) => _sameValues(_membershipRows[i], other._membershipRows[i]),
      ).every((same) => same) &&
      _provenanceRows.length == other._provenanceRows.length &&
      List.generate(
        _provenanceRows.length,
        (i) => _sameValues(_provenanceRows[i], other._provenanceRows[i]),
      ).every((same) => same) &&
      List.generate(
        _rows.length,
        (i) => _sameValues(_rows[i], other._rows[i]),
      ).every((same) => same) &&
      _bodies.length == other._bodies.length &&
      List.generate(
        _bodies.length,
        (i) =>
            _bodies[i]._role == other._bodies[i]._role &&
            _bodies[i]._text == other._bodies[i]._text,
      ).every((same) => same);
}

final class _OwnedTextSnapshot implements SupportTextContextSnapshot {
  _OwnedTextSnapshot(
    this._owner,
    this.source,
    this.sessionId,
    this.messageIds,
    this.messages,
    this.provenance,
    this._observation,
    this._stamp, {
    this._wholeSession,
  });
  final SupportTextContextRepo _owner;
  @override
  final SupportTextContextSource source;
  @override
  final String sessionId;
  @override
  final List<String> messageIds;
  @override
  final List<SupportTextContextMessage> messages;
  @override
  final List<SupportTextContextProvenance> provenance;
  final _TextRead _observation;
  final (int, int) _stamp;
  final _WholeSessionSpec? _wholeSession;
  @override
  bool get isWholeSession => _wholeSession != null;
  @override
  SupportSessionHistoryBoundary? get currentInput => _wholeSession?._boundary;
  bool _revoked = false;
  bool _revoke() {
    _revoked = true;
    return false;
  }

  @override
  String toString() => 'SupportTextContextSnapshot';
}
