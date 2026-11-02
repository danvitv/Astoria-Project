part of 'support_app_action_context.dart';

/// Finite application effects, deliberately separate from connection/key custody.
enum SupportAppDomainOperation {
  character('astoria_character_manage'),
  persona('astoria_persona_manage'),
  lorebook('astoria_lorebook_manage'),
  loreEntry('astoria_lorebook_entry_manage'),
  preset('astoria_preset_manage'),
  presetBlock('astoria_preset_block_manage'),
  studioPreset('astoria_studio_preset_manage'),
  studioBlock('astoria_studio_block_manage'),
  studioAgent('astoria_studio_agent_set'),
  studioRuntime('astoria_studio_runtime_manage'),
  memoryCreate('astoria_memory_create'),
  memorySettings('astoria_memory_settings'),
  memoryDraft('astoria_memory_draft_vector'),
  memoryCatalog('astoria_memory_catalog_rebuild'),
  memoryEntryText('astoria_memory_entry_text_revise'),
  memoryEntryTextUndo('astoria_memory_entry_text_undo'),
  extensionDisable('astoria_extension_block_disable'),
  databaseRepair('astoria_database_repair'),
  databaseUndo('astoria_database_repair_undo'),
  sessionRepair('astoria_session_repair'),
  sessionUndo('astoria_session_repair_undo'),
  sessionRename('astoria_session_rename'),
  sessionTitleUndo('astoria_session_rename_undo'),
  activePersona('astoria_active_persona_set'),
  activePreset('astoria_active_preset_set'),
  activeSelectionUndo('astoria_active_selection_undo'),
  globalRegexDisable('astoria_global_regex_disable'),
  globalRegexUndo('astoria_global_regex_undo');

  const SupportAppDomainOperation(this.action);
  final String action;
  static SupportAppDomainOperation? forAction(String action) =>
      values.where((v) => v.action == action).firstOrNull;
}

abstract interface class SupportAppDomainRootPort {
  Future<void> admitDomain(SupportAppDomainDispatch dispatch);
}

/// No effect callback. ROOT can only admit this identical confirmed capsule.
final class SupportAppDomainDispatch {
  SupportAppDomainDispatch._(this.context, this.request, this.operation);
  final SupportAppActionContext context;
  final SupportAppConfirmationRequest request;
  final SupportAppDomainOperation operation;
  bool _open = true, _admitted = false, _consumed = false;
  bool Function()? _nativeCurrent;
  void Function()? _retireRequester;

  bool get isCurrent =>
      _open &&
      !_admitted &&
      context.current &&
      identical(context._confirmation?.request, request) &&
      context._confirmation!.current &&
      request.current;

  /// Called synchronously by the ORIGINAL model ROOT, never by tool JSON.
  void admit({
    required bool Function() isOriginalNativeCurrent,
    required void Function() retireOriginalRequester,
  }) {
    if (!isCurrent || !isOriginalNativeCurrent()) return;
    _admitted = true;
    _nativeCurrent = isOriginalNativeCurrent;
    _retireRequester = retireOriginalRequester;
  }

  SupportAppDomainCustody? consume() {
    if (!_open ||
        !_admitted ||
        _consumed ||
        !context.current ||
        context._confirmation?.current != true ||
        !_nativeCurrent!()) {
      return null;
    }
    _consumed =
        true; // BEFORE the first source fence, callback or effect await.
    _open = false;
    final custody = SupportAppDomainCustody._(this);
    final retire = _retireRequester;
    _retireRequester = null; // Never retain another ModelRun action capability.
    retire!(); // Original request retires; admitted native custody does not.
    return custody;
  }
}

/// Only factual already-admitted native custody. No requester token, network
/// issuer, renewed source authority, UI grant or reusable dispatch is retained.
final class SupportAppDomainCustody {
  SupportAppDomainCustody._(this._dispatch);
  final SupportAppDomainDispatch _dispatch;
  bool _closed = false;
  SupportAppDomainOperation get operation => _dispatch.operation;
  SupportAppConfirmationRequest get request => _dispatch.request;
  bool get isCurrent {
    if (_closed) return false;
    try {
      if (_dispatch._nativeCurrent?.call() != true) _closed = true;
    } catch (_) {
      _closed = true;
    }
    return !_closed;
  }

  void close() => _closed = true;
}

/// Native-owned source events, not source/body access or an authorization bool.
abstract interface class SupportAppDomainSourceLease {
  bool get isCurrent;
  bool coversSession(String sessionId);
  int? publicationForSession(String sessionId);
  void settle();
}

extension SupportAppDomainContext on SupportAppActionContext {
  Future<SupportAppDomainDispatch?> admitDomainEffect({
    required SupportAppDomainOperation operation,
    required String target,
    required Object observation,
  }) async {
    final lease = _confirmation;
    final root = domainRoot;
    if (_domainRequested ||
        root == null ||
        lease == null ||
        !current ||
        !lease.current ||
        lease.request.action != operation.action ||
        lease.request.target != target ||
        !identical(lease.request.observation, observation)) {
      return null;
    }
    _domainRequested = true;
    final dispatch = SupportAppDomainDispatch._(this, lease.request, operation);
    try {
      await root.admitDomain(dispatch); // ROOT releases before this returns.
      return dispatch._admitted && current ? dispatch : null;
    } catch (_) {
      // This capsule has no effect callback. Until consume(), even a ROOT
      // release error cannot have admitted a domain write or source fence.
      dispatch._open = false;
      dispatch._retireRequester = null;
      return null;
    } finally {
      if (!dispatch._admitted) dispatch._open = false;
    }
  }

  bool bindDomainEffect(
    SupportAppDomainCustody custody,
    SupportAppDomainSourceLease source,
  ) {
    if (_domainCustody != null ||
        !identical(custody.request.context, this) ||
        !custody.isCurrent ||
        !source.isCurrent) {
      return false;
    }
    _domainCustody = custody;
    _domainSource = source;
    return true;
  }

  bool get domainEffectCurrent =>
      _domainCustody?.isCurrent == true && _domainSource?.isCurrent == true;

  /// Read-only proof of the already-consumed native effect. This cannot admit a
  /// dispatch, renew the requester or replace its bound native source fence.
  SupportAppDomainCustody? get nativeDomainCustody =>
      domainEffectCurrent ? _domainCustody : null;
  bool domainEffectForSession(String id) =>
      domainEffectCurrent && _domainSource!.coversSession(id);
  bool domainEffectForOperation(SupportAppDomainOperation operation) =>
      domainEffectCurrent && _domainCustody!.operation == operation;
  int? domainPublication(String id) => domainEffectForSession(id)
      ? _domainSource!.publicationForSession(id)
      : null;
  bool domainEffectMatches(String target, Object observation) =>
      domainEffectCurrent &&
      _domainCustody!.request.target == target &&
      identical(_domainCustody!.request.observation, observation);
  void closeDomainEffect() {
    _domainSource?.settle();
    _domainCustody?.close();
    _domainSource = null;
    _domainCustody = null;
    _domainRequested = false;
  }
}
