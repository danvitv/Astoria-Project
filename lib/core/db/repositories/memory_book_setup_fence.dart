part of 'memory_book_repo.dart';

final _setupBookOwners = Expando<_MemoryBookSetupOwner>();

/// Opaque original-DB ticket, never a model DTO or a durable revision number.
/// Every physical repository writer retires it, even same-value ABA. Raw bypass
/// writers/processes remain outside this in-isolate admission proof.
final class MemoryBookSetupTicket {
  MemoryBookSetupTicket._(this._owner, this._revision, this._retired);
  final _MemoryBookSetupOwner _owner;
  final int _revision;
  bool _retired;
  bool get current {
    if (!_retired && (_owner.exhausted || _owner.pending != 0 ||
        _owner.revision != _revision)) _retired = true;
    return !_retired;
  }
}

final class _MemoryBookSetupOwner {
  int revision = 0, pending = 0;
  bool exhausted = false;
  void advance() {
    if (revision >= 9007199254740991) { exhausted = true; }
    else { revision++; }
  }
  _MemoryBookSetupAdmission begin() {
    advance(); pending++;
    return _MemoryBookSetupAdmission(this, revision);
  }
  MemoryBookSetupTicket capture() =>
      MemoryBookSetupTicket._(this, revision, exhausted || pending != 0);
}

/// Own issued revision is retained BEFORE the write's first callback/await.
final class _MemoryBookSetupAdmission {
  _MemoryBookSetupAdmission(this.owner, this.revision);
  final _MemoryBookSetupOwner owner;
  final int revision;
  bool _closed = false;
  bool get current => !_closed && !owner.exhausted && owner.pending == 1 &&
      owner.revision == revision;
  MemoryBookSetupTicket? finish() {
    if (_closed) return null;
    final retained = current;
    _closed = true;
    owner.pending--; owner.advance();
    return retained && !owner.exhausted && owner.pending == 0 &&
      owner.revision == revision + 1 ?
      MemoryBookSetupTicket._(owner, revision + 1, false) : null;
  }
}

extension _MemoryBookSetupFences on MemoryBookRepo {
  _MemoryBookSetupOwner get _setupBookOwner =>
      _setupBookOwners[attachedDatabase] ??= _MemoryBookSetupOwner();

  Future<T> _trackSetupBookWrite<T>(Future<T> Function() effect) {
    final admission = _setupBookOwner.begin();
    return Future.sync(effect).whenComplete(() { admission.finish(); });
  }

  _MemoryBookSetupAdmission? _beginSetupBookWrite(MemoryBookSetupTicket ticket) {
    if (!identical(ticket._owner, _setupBookOwner) || !ticket.current) return null;
    return _setupBookOwner.begin();
  }
}

extension MemoryBookSetupTickets on MemoryBookRepo {
  MemoryBookSetupTicket captureSetupTicket() => _setupBookOwner.capture();
}
