part of 'native_provider_transport.dart';

/// Original constructor-captured denial predicates, never an approval issuer.
/// A false/throw/reentrant check retires this job permanently; later TRUE cannot
/// repair old source custody. Native authority is rechecked AFTER each callback.
final class _NativeSourceCurrent {
  _NativeSourceCurrent(Iterable<bool Function()> predicates)
    : _predicates = List.unmodifiable(predicates);
  final List<bool Function()> _predicates;
  bool _retired = false;
  bool _checking = false;

  bool check(bool Function() ownsOriginalAuthority) {
    if (_retired) return false;
    if (_checking || !_nativeCurrent(ownsOriginalAuthority)) {
      _retired = true;
      return false;
    }
    _checking = true;
    try {
      for (final predicate in _predicates) {
        if (!_nativeCurrent(predicate) ||
            !_nativeCurrent(ownsOriginalAuthority) ||
            _retired) {
          _retired = true;
          return false;
        }
      }
      if (!_nativeCurrent(ownsOriginalAuthority) || _retired) {
        _retired = true;
        return false;
      }
      return true;
    } finally {
      _checking = false;
    }
  }
}
