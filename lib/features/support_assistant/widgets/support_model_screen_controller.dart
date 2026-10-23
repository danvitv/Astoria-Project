import 'dart:async';

import 'package:flutter/material.dart';

import '../state/support_model_provider.dart';
import 'support_composer_bar.dart';
import 'support_model_prompt_preview_sheet.dart';

/// UI lifetime and route ownership only. Native admission, writes, sanitation
/// and transport stay in the original provider-owned opaque send.
final class SupportModelScreenController extends ChangeNotifier {
  final Object _lifetime = Object();
  bool _alive = true, _queued = false;
  Object? _binding;
  SupportModelUiBridge? _bridge;
  SupportModelUiEmitter? _emitter;
  SupportModelUiSend? _send;
  TextEditingController? _controller;
  String? _session;
  void Function()? _unlisten;
  ModalRoute<bool>? _route;
  SupportModelRefusal refusal = SupportModelRefusal.none;

  SupportModelUiSend? get active => _send;

  /// Called at the emitted view, BEFORE its callback or any asynchronous work.
  SupportModelUiEmitter bindView(
    SupportModelUiBridge bridge,
    TextEditingController controller,
    String session,
  ) {
    if (!identical(bridge, _bridge) ||
        !identical(controller, _controller) ||
        session != _session ||
        (_send == null && _emitter?.isCurrent != true)) {
      _emitter?.retire();
      _send = null;
      _retireOriginalRoute();
      _unlisten?.call();
      _bridge = bridge;
      _controller = controller;
      _session = session;
      refusal = SupportModelRefusal.none;
      final binding = _binding = Object();
      _emitter = bridge.bindEmitter(
        controller: controller,
        uiLifetime: _lifetime,
        isEmitterCurrent: () =>
            _alive &&
            identical(binding, _binding) &&
            identical(controller, _controller),
      );
      _unlisten = bridge.listen(() {
        // Runtime retirement itself is synchronous. Route removal/presentation
        // is deferred because retirement can occur while a parent is building.
        _changed();
      });
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
    _retireOriginalRoute();
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
    // Independent synchronous latch. A retained old callback cannot rebind to
    // the newer issuer/session, even if the caller bypasses button disabling.
    if (!_alive || _send != null || !identical(emitter, _emitter)) {
      return Future.value(false);
    }
    refusal = SupportModelRefusal.none;
    final send = _send = emitter.send(
      text: draft.text,
      draftRevision: draft.revision,
      isDraftCurrent: draft.isCurrent,
    );
    _changed();
    unawaited(_review(emitter, send, context));
    unawaited(
      send.finished.then((_) {
        if (!_owns(emitter, send)) return;
        _closeOriginalRoute();
        _send = null;
        _changed();
      }),
    );
    // Acceptance does not await the preview route, HTTP, or reply settlement.
    return send.accepted;
  }

  Future<void> _review(
    SupportModelUiEmitter emitter,
    SupportModelUiSend send,
    BuildContext context,
  ) async {
    final prepared = await send.prepared;
    final preview = prepared.preview;
    if (!_owns(emitter, send) || !context.mounted) {
      if (preview != null) send.cancelPreview(preview);
      send.stop();
      return;
    }
    if (preview == null) {
      refusal = prepared.reason;
      _changed();
      return;
    }
    if (!send.isCurrent) {
      send.cancelPreview(preview);
      send.stop();
      return;
    }
    bool confirmed = false, decisionMade = false;
    ModalRoute<bool>? originalRoute;
    try {
      // Projection only. Keep the actual opaque preview for native approval;
      // never reconstruct approval authority from these display-only values.
      final values = SupportPromptPreviewValues(
        originLabel: preview.recipient.originLabel,
        operationLabel: preview.recipient.operationLabel,
        modelLabel: preview.recipient.recipient.modelId,
        gameMessageCount: preview.gameMessages,
        supportMessageCount: preview.supportMessages,
        sections: [
          for (final message in preview.messages)
            SupportPromptPreviewSection(
              role: switch (message.role) {
                'user' => SupportPromptPreviewRole.user,
                'assistant' => SupportPromptPreviewRole.assistant,
                'system' => SupportPromptPreviewRole.system,
                _ => throw const FormatException('Unsupported preview role'),
              },
              text: message.text,
            ),
        ],
      );
      // Stable function objects for this displayed snapshot. A sheet rebuild
      // (insets/scaling) must not rebind or retire an unchanged confirmation.
      bool isCurrent() =>
          _owns(emitter, send) && send.isCurrent && preview.isCurrent;
      void onDecision(bool decision) {
        final route = originalRoute;
        if (decisionMade || route?.isCurrent != true) return;
        decisionMade = true;
        if (decision && isCurrent()) {
          final approval = send.approve(preview);
          if (approval != null) {
            confirmed = true;
            unawaited(send.dispatch(approval));
          }
        }
        if (!confirmed) send.cancelPreview(preview);
        route!.navigator?.pop(confirmed);
      }

      await showModalBottomSheet<bool>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) {
          final route = ModalRoute.of<bool>(sheetContext)!;
          if (originalRoute == null) {
            originalRoute = route;
            unawaited(
              route.popped.then((_) {
                decisionMade = true;
                if (!confirmed) send.cancelPreview(preview);
              }),
            );
          }
          if (_owns(emitter, send) && send.isCurrent) {
            _route = route;
          } else {
            scheduleMicrotask(() => _removeRoute(route));
          }
          return SupportModelPromptPreviewSheet(
            values: values,
            isCurrent: isCurrent,
            onDecision: onDecision,
          );
        },
      );
    } catch (_) {
      // No raw transport/provider/route exception may become visible text.
      if (_owns(emitter, send)) {
        refusal = SupportModelRefusal.unavailable;
        _changed();
      }
    } finally {
      if (identical(_route, originalRoute)) _route = null;
      // Includes barrier, system Back, null result, stale/disposed UI and errors.
      // This handle can cancel ONLY its original run, never replacement work.
      if (!confirmed) {
        send.cancelPreview(preview);
        send.stop();
      }
    }
  }

  void _closeOriginalRoute() {
    final route = _route;
    _route = null;
    if (route != null) _removeRoute(route);
  }

  void _retireOriginalRoute() {
    final route = _route;
    _route = null;
    if (route != null) scheduleMicrotask(() => _removeRoute(route));
  }

  void _removeRoute(ModalRoute<bool> route) {
    if (route.isActive) route.navigator?.removeRoute(route);
  }

  void _changed() {
    if (!_alive || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_alive) return;
      if (_send?.isCurrent != true) _closeOriginalRoute();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    if (!_alive) return;
    _alive = false;
    _binding = null;
    _unlisten?.call();
    _emitter?.retire();
    // Removing a route during widget unmount is deferred, but original native
    // cancellation above is immediate and late decisions already fail closed.
    _retireOriginalRoute();
    super.dispose();
  }
}
