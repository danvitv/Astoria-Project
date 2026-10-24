import 'package:dio/dio.dart';

import '../../../core/db/repositories/api_config_repo.dart';

import 'support_app_action_definition.dart';

part 'support_app_domain_terminal.dart';

/// Trusted original-run authority. None of these ports is a tool argument.
final class SupportAppActionContext {
  SupportAppActionContext({
    required this.runId,
    required this.sessionId,
    required this.cancelToken,
    required this.isCurrent,
    required this.allowReversibleChanges,
    this.confirmation,
    this.navigation,
    this.sourceAccess,
    this.terminalRoot,
    this.domainRoot,
  });

  final String runId, sessionId;
  final CancelToken cancelToken;
  final bool Function() isCurrent;
  final bool allowReversibleChanges;
  final SupportAppConfirmationPort? confirmation;
  final SupportAppNavigationPort? navigation;
  final SupportAppSourceAccessPort? sourceAccess;
  final SupportAppTerminalRootPort? terminalRoot;
  final SupportAppDomainRootPort? domainRoot;
  SupportAppDomainCustody? _domainCustody;
  SupportAppDomainSourceLease? _domainSource;
  SupportAppConfirmationLease? _confirmation;
  bool _terminalRequested = false;
  bool _domainRequested = false;
  bool _retired = false;
  bool _checking = false;

  /// A failed/reentrant check permanently retires this ORIGINAL context.
  bool get current {
    if (_checking) _retired = true;
    if (_retired || cancelToken.isCancelled) return false;
    _checking = true;
    try {
      final accepted = isCurrent();
      if (!accepted || cancelToken.isCancelled || _retired) _retired = true;
      return !_retired;
    } catch (_) {
      _retired = true;
      return false;
    } finally {
      _checking = false;
    }
  }

  /// An accepted exact native gesture binds this opaque repository plan. This
  /// only admits its terminal mutation, never a replacement source or POST.
  bool isConfirmedTerminalPlan(KeylessApiConfigTerminalPlan plan) {
    final lease = _confirmation;
    return current &&
        lease != null &&
        identical(lease.request.context, this) &&
        identical(lease.request.observation, plan) &&
        lease.request.target == plan.connectionId &&
        lease.request.action ==
            (plan.before == null
                ? 'astoria_connection_create'
                : 'astoria_connection_update') &&
        lease.current &&
        lease.request.current &&
        current;
  }

  Future<void> admitConnectionTerminal(
    KeylessTerminalEffectDispatch dispatch,
  ) async {
    if (_terminalRequested || !isConfirmedTerminalPlan(dispatch.plan)) {
      throw const KeylessApiConfigException();
    }
    _terminalRequested = true;
    final root = terminalRoot;
    if (root != null) {
      await root.admit(dispatch);
    } else {
      // Standalone native configuration UI has no model ROOT/network source.
      // Its exact consumed confirmation and current native lifetime still apply.
      dispatch.dispatch();
    }
  }
}

/// The actual original model run implements this port; it cannot come from a
/// tool call. Effects are never awaited/written inside its read-only ROOT.
abstract interface class SupportAppTerminalRootPort {
  Future<void> admit(KeylessTerminalEffectDispatch dispatch);
}

/// Native UI must render this exact immutable request. Retained/replaced UI
/// cannot accept it; the returned lease must retain original UI lifetime too.
abstract interface class SupportAppConfirmationPort {
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  );
}

final class SupportAppConfirmationRequest {
  SupportAppConfirmationRequest({
    required this.context,
    required this.callId,
    required this.action,
    required this.target,
    required Map<String, Object?> arguments,
    required this.observation,
    required this.observationIsCurrent,
    required Map<String, Object?> preview,
  }) : arguments = SupportAppActionJson.immutable(arguments),
       preview = SupportAppActionJson.immutable(preview);

  final SupportAppActionContext context;
  final String callId, action, target;
  final Map<String, Object?> arguments, preview;
  // Native-only precondition; never serialize it into model content.
  final Object observation;
  final bool Function() observationIsCurrent;
  bool get current =>
      context.current && observationIsCurrent() && context.current;
}

/// Construct only after an exact native gesture, not from a model bool.
final class SupportAppConfirmationLease {
  SupportAppConfirmationLease({
    required this.request,
    required this.isOriginalUiCurrent,
  });
  final SupportAppConfirmationRequest request;
  final bool Function() isOriginalUiCurrent;
  bool _consumed = false;
  bool _accepted = false;
  bool _checking = false;

  bool accept(SupportAppConfirmationRequest original) {
    if (_consumed || !identical(request, original)) return false;
    _consumed = true;
    _accepted = request.current && isOriginalUiCurrent() && request.current;
    if (_accepted) request.context._confirmation = this;
    return _accepted;
  }

  /// Domain CAS owns observation checks once its own mutation has started.
  bool get current {
    if (_checking) _accepted = false;
    if (!_accepted) return false;
    _checking = true;
    try {
      if (!request.context.current ||
          !isOriginalUiCurrent() ||
          !request.context.current) {
        _accepted = false;
      }
      return _accepted;
    } catch (_) {
      _accepted = false;
      return false;
    } finally {
      _checking = false;
    }
  }
}

enum SupportAppDestination {
  home,
  characters,
  tools,
  connections,
  personas,
  presets,
  regex,
  lorebooks,
  embeddings,
  settings,
  themes,
  about,
  glossary,
}

/// Finite native navigation only, never a route/path supplied by the model.
abstract interface class SupportAppNavigationPort {
  Future<bool> open(
    SupportAppDestination destination,
    SupportAppActionContext context,
  );
}

/// Later body adapters must acquire exact source leases; Send is not this grant.
abstract interface class SupportAppSourceAccessPort {
  Future<SupportAppSourceLease?> acquire({
    required String domain,
    required String sourceId,
    required Object observation,
    required SupportAppActionContext context,
  });
}

abstract interface class SupportAppSourceLease {
  bool get isCurrent;
  void release();
}
