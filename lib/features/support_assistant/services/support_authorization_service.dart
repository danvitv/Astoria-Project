import '../models/support_permission_preferences.dart';
import '../models/support_permission_provenance.dart';

final class SupportAuthorizationDenied extends StateError {
  SupportAuthorizationDenied() : super('Support operation not authorized.');
}

/// Unforgeable through model text: constructor and bound payload stay private.
/// A lease is data authorization, NOT an action/test/report-send confirmation.
final class SupportAuthorizationLease {
  SupportAuthorizationLease._(
    this._context,
    this._policy,
    this.use,
    Iterable<SupportPermissionSource> sources,
  ) : sources = List.unmodifiable(sources);
  final SupportNativePermissionContext _context;
  final SupportPermissionPreferences _policy;
  final SupportPermissionUse use;
  final List<SupportPermissionSource> sources;
}

/// No public payload/toJson or provenance-removing wrapper. Only the gate can
/// consume or transform the data, after current authorization is checked.
final class SupportAuthorizedData<T> {
  SupportAuthorizedData._(this._value, this._lease, this.wrapper);
  final T _value;
  final SupportAuthorizationLease _lease;
  final SupportProvenanceWrapper wrapper;
  List<SupportPermissionSource> get sources => _lease.sources;
}

/// Injectable standalone boundary. No Ref, network, action executor or tool
/// registry. Actual readers/egress MUST use this boundary and safe DTOs later;
/// this does not sandbox arbitrary Dart callbacks or enforce whole-app egress.
final class SupportAuthorizationService {
  const SupportAuthorizationService({
    required this.readPolicy,
    required this.currentNativeContext,
    this.allowsUse,
  });
  final Future<SupportPermissionSnapshot> Function(String sessionId) readPolicy;
  final SupportNativePermissionContext Function() currentNativeContext;

  /// Optional native lifetime/admission fence. Standalone policy semantics are
  /// unchanged when absent; this predicate never grants policy authority.
  final bool Function(SupportPermissionUse use)? allowsUse;

  Future<SupportAuthorizationLease?> prepare({
    required String supportSessionId,
    required SupportPermissionUse use,
    required Iterable<SupportPermissionSource> sources,
  }) async {
    final provenance = List<SupportPermissionSource>.unmodifiable(sources);
    if (provenance.isEmpty || provenance.length > 64 || !_allowed(use)) {
      return null;
    }
    final context = currentNativeContext();
    if (context.supportSessionId != supportSessionId) return null;
    final snapshot = await _read(supportSessionId);
    if (!context.sameAs(currentNativeContext()) ||
        !_allowed(use) ||
        !snapshot.isAvailable) {
      return null;
    }
    final p = snapshot.preferences!;
    if (!_matches(context, p) ||
        !provenance.every((s) => s.allowedFor(p, use))) {
      return null;
    }
    return SupportAuthorizationLease._(context, p, use, provenance);
  }

  /// Denied or stale authorization never invokes the local loader. Model/report
  /// rights cannot authorize a local read. No raw prompt/attachment loader is
  /// supported here: those need a separate native exact-preview custody path.
  Future<SupportAuthorizedData<T>> loadLocal<T>(
    SupportAuthorizationLease lease,
    Future<T> Function() loader,
  ) async {
    if (lease.use != SupportPermissionUse.localRead ||
        !await _valid(lease) ||
        !_current(lease)) {
      throw SupportAuthorizationDenied();
    }
    T result;
    try {
      result = await loader();
    } catch (_) {
      throw SupportAuthorizationDenied();
    }
    if (!await _valid(lease) || !_current(lease)) {
      throw SupportAuthorizationDenied();
    }
    return SupportAuthorizedData._(
      result,
      lease,
      SupportProvenanceWrapper.source,
    );
  }

  /// Synchronous, trusted native transformation of an already authorized DTO.
  /// Summaries/tool/agent wrappers retain ALL source requirements and the stamp.
  Future<SupportAuthorizedData<R>> wrapLocal<T, R>(
    SupportAuthorizationLease lease,
    SupportAuthorizedData<T> data,
    SupportProvenanceWrapper wrapper,
    R Function(T) transform,
  ) async {
    if (lease.use != SupportPermissionUse.localRead ||
        !_sameData(lease, data) ||
        !await _valid(lease) ||
        !_current(lease)) {
      throw SupportAuthorizationDenied();
    }
    return SupportAuthorizedData._(transform(data._value), lease, wrapper);
  }

  /// Rechecks after awaits immediately before a synchronous publication/use.
  /// Future egress adapters must dispatch synchronously here (with their own
  /// transport cancellation/redirect/secret rules), or revalidate after their
  /// further awaits. This callback must not be an async closure.
  Future<void> consume<T>(
    SupportAuthorizationLease lease,
    SupportAuthorizedData<T> data,
    void Function(T) consumeNow,
  ) async {
    if (!_sameData(lease, data) || !await _valid(lease) || !_current(lease)) {
      throw SupportAuthorizationDenied();
    }
    consumeNow(data._value);
  }

  Future<bool> _valid(SupportAuthorizationLease lease) async {
    if (!_current(lease)) return false;
    final snapshot = await _read(lease._context.supportSessionId);
    if (!_current(lease) || !snapshot.isAvailable) {
      return false;
    }
    final p = snapshot.preferences!;
    return p.policyIdentity == lease._policy.policyIdentity &&
        p.revision == lease._policy.revision &&
        _matches(lease._context, p) &&
        lease.sources.every((s) => s.allowedFor(p, lease.use));
  }

  bool _current(SupportAuthorizationLease lease) =>
      lease._context.sameAs(currentNativeContext()) && _allowed(lease.use);
  bool _allowed(SupportPermissionUse use) => allowsUse?.call(use) ?? true;
  bool _sameData<T>(
    SupportAuthorizationLease lease,
    SupportAuthorizedData<T> data,
  ) =>
      lease._context.sameAs(data._lease._context) &&
      lease._policy.policyIdentity == data._lease._policy.policyIdentity &&
      lease._policy.revision == data._lease._policy.revision &&
      lease.sources.length == data.sources.length &&
      List.generate(
        lease.sources.length,
        (i) => lease.sources[i].sameAs(data.sources[i]),
      ).every((v) => v);
  bool _matches(
    SupportNativePermissionContext c,
    SupportPermissionPreferences p,
  ) =>
      c.supportSessionId == p.supportSessionId &&
      (c.scope == null ? p.scope == null : c.scope!.sameAs(p.scope)) &&
      (c.recipient == null
          ? p.recipient == null
          : c.recipient!.sameAs(p.recipient));
  Future<SupportPermissionSnapshot> _read(String id) async {
    try {
      return await readPolicy(id);
    } catch (_) {
      return const SupportPermissionSnapshot(
        SupportPermissionAvailability.unavailable,
      );
    }
  }
}
