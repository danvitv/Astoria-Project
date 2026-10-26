import 'dart:async';

import 'package:flutter/material.dart';

import '../models/support_model_tool_ui_ports.dart';
import '../models/support_workspace_models.dart';
import '../state/support_model_provider.dart';
import 'support_composer_bar.dart';
import 'support_model_tool_native_ui.dart';
import '../services/app_control/backup/support_backup_native_ui.dart';
import '../services/app_control/backup/support_backup_file_host.dart';

/// Displayed composer lifetime only. The original Send authorizes its exact
/// native request; admission, cancellation and settlement stay with its issuer.
final class SupportModelScreenController extends ChangeNotifier {
  final Object _lifetime = Object();
  bool _alive = true, _queued = false;
  Object? _binding;
  SupportModelUiBridge? _bridge;
  SupportModelUiEmitter? _emitter;
  SupportModelUiSend? _send;
  TextEditingController? _controller;
  String? _session;
  List<SupportModelConversationMessage> _conversation = const [];
  void Function()? _unlisten;
  Object? _nativeBinding;
  BuildContext? _nativeContext;
  SupportModelUiBridge? _nativeBridge;
  TextEditingController? _nativeController;
  String? _nativeSession;
  SupportModelToolNativeUi? _nativeUi;
  SupportBackupNativeUi? _backupUi;
  SupportBackupNativeFileHost? _backupHost;
  SupportModelToolUiPorts? _nativePorts;
  SupportModelRefusal refusal = SupportModelRefusal.none;

  SupportModelUiSend? get active => _send;

  SupportModelUiEmitter bindView(
    SupportModelUiBridge bridge,
    TextEditingController controller,
    String session, {
    List<SupportModelConversationMessage> visibleConversation = const [],
    SupportModelToolUiPorts? toolUi,
    bool Function()? isOriginalRouteCurrent,
    BuildContext? nativeContext,
    SupportBackupFileDialog backupFileDialog =
        const SupportBackupPlatformFileDialog(),
  }) {
    if (nativeContext != null) {
      if (!identical(nativeContext, _nativeContext) ||
          !identical(bridge, _nativeBridge) ||
          !identical(controller, _nativeController) ||
          session != _nativeSession) {
        _disposeNativeUi();
        final lifetime = _nativeBinding = Object();
        _nativeContext = nativeContext;
        _nativeBridge = bridge;
        _nativeController = controller;
        _nativeSession = session;
        bool originalUi() =>
            _alive &&
            nativeContext.mounted &&
            identical(_nativeBinding, lifetime);
        final native = _nativeUi = SupportModelToolNativeUi(
          context: nativeContext,
          isOriginalUiCurrent: originalUi,
        );
        final backup = _backupUi = SupportBackupNativeUi(
          context: nativeContext,
          isOriginalUiCurrent: originalUi,
          fileDialog: backupFileDialog,
        );
        final host = _backupHost = SupportBackupNativeFileHost(
          ui: backup,
          otherConfirmation: native,
        );
        _nativePorts = SupportModelToolUiPorts(
          confirmation: host,
          navigation: native,
          backupFileHost: host,
        );
      }
      toolUi = _nativePorts;
      final originalNativeUi = _nativeUi!;
      final callerRouteCurrent = isOriginalRouteCurrent;
      isOriginalRouteCurrent = () =>
          originalNativeUi.isCurrent && (callerRouteCurrent?.call() ?? true);
    }
    if (!identical(bridge, _bridge) ||
        !identical(controller, _controller) ||
        session != _session ||
        (_send == null &&
            !_sameConversation(_conversation, visibleConversation)) ||
        (_send == null && _emitter?.isCurrent != true)) {
      _emitter?.retire();
      _send = null;
      _unlisten?.call();
      _bridge = bridge;
      _controller = controller;
      _session = session;
      _conversation = List.unmodifiable(visibleConversation);
      refusal = SupportModelRefusal.none;
      final binding = _binding = Object();
      _emitter = bridge.bindEmitter(
        controller: controller,
        uiLifetime: _lifetime,
        visibleConversation: _conversation,
        toolUi: toolUi,
        isEmitterCurrent: () =>
            _alive &&
            (isOriginalRouteCurrent?.call() ?? true) &&
            identical(binding, _binding) &&
            identical(controller, _controller),
      );
      _unlisten = bridge.listen(_changed);
    }
    return _emitter!;
  }

  void retireView() {
    _binding = null;
    _unlisten?.call();
    _unlisten = null;
    _emitter?.retire();
    _emitter = null;
    _bridge = null;
    _controller = null;
    _send = null;
    _disposeNativeUi();
  }

  void _disposeNativeUi() {
    _nativeBinding = null;
    _backupHost?.dispose();
    _backupUi?.dispose();
    _nativeUi?.dispose();
    _backupHost = null;
    _backupUi = null;
    _nativeUi = null;
    _nativePorts = null;
    _nativeContext = null;
    _nativeBridge = null;
    _nativeController = null;
    _nativeSession = null;
  }

  Future<bool> rejectNoModel() {
    refusal = SupportModelRefusal.noModel;
    _changed();
    return Future.value(false);
  }

  bool _owns(SupportModelUiEmitter emitter, SupportModelUiSend send) =>
      _alive && identical(emitter, _emitter) && identical(send, _send);

  Future<bool> send(
    SupportModelUiEmitter emitter,
    SupportComposerDraft draft,
    BuildContext context,
  ) {
    if (!_alive ||
        !context.mounted ||
        _send != null ||
        !identical(emitter, _emitter)) {
      return Future.value(false);
    }
    refusal = SupportModelRefusal.none;
    final send = _send = emitter.send(
      text: draft.text,
      draftRevision: draft.revision,
      isDraftCurrent: draft.isCurrent,
    );
    _changed();
    unawaited(
      send.finished.then((result) {
        if (!_owns(emitter, send)) return;
        if (emitter.isCurrent) refusal = result.reason;
        _send = null;
        _changed();
      }),
    );
    // Acceptance is the original durable USER append, never HTTP success.
    return send.accepted;
  }

  void compact(SupportModelUiEmitter emitter) {
    if (!_alive || _send != null || !identical(emitter, _emitter)) return;
    refusal = SupportModelRefusal.none;
    final send = _send = emitter.compact();
    _changed();
    unawaited(
      send.finished.then((result) {
        if (!_owns(emitter, send)) return;
        if (emitter.isCurrent) refusal = result.reason;
        _send = null;
        _changed();
      }),
    );
  }

  void regenerate(SupportModelUiEmitter emitter, SupportMessageItem reply) {
    if (!_alive ||
        _send != null ||
        !identical(emitter, _emitter) ||
        !emitter.isCurrent ||
        reply.isLocked ||
        reply.runId == null ||
        reply.role != SupportMessageRole.assistant ||
        reply.cards.isNotEmpty ||
        !const {
          'complete',
          'limited',
          'stopped',
          'error',
        }.contains(reply.status) ||
        reply.sessionId != _session ||
        _conversation.isEmpty ||
        _conversation.last.id != reply.id)
      return;
    refusal = SupportModelRefusal.none;
    final send = _send = emitter.regenerate(
      SupportModelMessage(
        id: reply.id,
        sessionId: reply.sessionId,
        runId: reply.runId!,
        role: 'assistant',
        status: reply.status,
        createdAt: reply.createdAt.millisecondsSinceEpoch,
        text: _conversation.last.text,
      ),
    );
    _changed();
    unawaited(
      send.finished.then((result) {
        if (!_owns(emitter, send)) return;
        if (emitter.isCurrent) refusal = result.reason;
        _send = null;
        _changed();
      }),
    );
  }

  void _changed() {
    if (!_alive || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_alive) notifyListeners();
    });
  }

  @override
  void dispose() {
    if (!_alive) return;
    _alive = false;
    _binding = null;
    _unlisten?.call();
    _emitter?.retire();
    _disposeNativeUi();
    super.dispose();
  }
}

bool _sameConversation(
  List<SupportModelConversationMessage> a,
  List<SupportModelConversationMessage> b,
) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every(
      (i) =>
          a[i].id == b[i].id &&
          a[i].role == b[i].role &&
          a[i].text == b[i].text,
    );
