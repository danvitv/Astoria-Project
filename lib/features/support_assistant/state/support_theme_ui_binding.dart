import '../../../core/credentials/secret_redactor.dart';
import '../models/support_native_view.dart';
import '../services/support_native_consent_controller.dart';
import '../services/support_theme_action_service.dart';
import 'support_theme_original_handles.dart';

/// Ref-free original native composition. Pending is independent of the consent
/// runtime and of the workspace display FIFO: it must not revoke its own action.
final class SupportThemeUiBinding {
  SupportThemeUiBinding({
    required this.service,
    required this.controller,
    required this.handles,
  }) {
    _stopRuntime = controller.runtime.listen(_changed);
    _secretChanged = (_) => _changed();
    service.redaction.addListener(_secretChanged);
  }
  final SupportThemeActionService service;
  final SupportNativeConsentController controller;
  final SupportThemeOriginalHandles handles;
  late final void Function() _stopRuntime;
  late final void Function(SecretRedactor) _secretChanged;
  final _listeners = <void Function()>{};
  bool _alive = true;
  int _pending = 0;
  bool get busy => _pending > 0;

  void Function() listen(void Function() listener) {
    if (_alive) _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _changed() {
    for (final listener in List.of(_listeners)) {
      if (!_alive || !_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (_) {
        // Presentation cannot prevent original fact settlement.
      }
    }
  }

  /// Call at DISPLAY with the actual emitted C anchor and original UI lifetime.
  /// An old emitted anchor can never be transplanted onto a fresh controller.
  SupportThemeUiIntent? emit({
    required SupportNativeDisplayedIntent displayedIntent,
    required Object uiLifetime,
    required bool Function() isUiCurrent,
  }) {
    bool current() =>
        _alive &&
        isUiCurrent() &&
        controller.isDisplayedIntentCurrent(displayedIntent);
    final intent = service.emit(
      controller: controller,
      uiLifetime: uiLifetime,
      isCurrent: current,
    );
    return intent == null
        ? null
        : SupportThemeUiIntent._(this, intent, controller.runtime.sessionId);
  }

  Future<SupportThemeActionResult>? _confirm(
    SupportThemeReview review,
    String session,
  ) {
    if (!_alive || busy) return null;
    // Latch before approval's synchronous owner predicates can reenter this UI.
    // This counter is never native.pending and therefore cannot self-revoke S.
    _pending++;
    final approval = service.approve(review);
    if (approval == null) {
      _pending--;
      return null;
    }
    final theme = service.theme;
    final stamp = handles.begin(
      session,
      undo: review.kind == SupportThemeActionKind.undo,
    );
    // Consume the exact opaque approval before notifying potentially reentrant UI.
    final originalJob = service.execute(approval);
    _changed();
    return originalJob
        .then((result) {
          handles.accept(session, theme, result, stamp);
          return result;
        })
        .whenComplete(() {
          _pending--;
          _changed();
        });
  }

  void dispose() {
    if (!_alive) return;
    _alive = false;
    _stopRuntime();
    service.redaction.removeListener(_secretChanged);
    _listeners.clear();
    // The Future returned by confirm remains the authoritative original result.
  }
}

/// Emitted original controller/UI/session binding. This has no public factory,
/// string dispatch, persistence codec, resource loader or late provider lookup.
final class SupportThemeUiIntent {
  SupportThemeUiIntent._(this._owner, this._intent, this._session);
  final SupportThemeUiBinding _owner;
  final SupportThemeIntent _intent;
  final String _session;
  final _observations = Expando<bool>();
  final _choices = Expando<bool>();
  final _reviews = Expando<bool>();
  final _historyPages = Expando<bool>();
  final _historyCursors = Expando<bool>();

  Future<SupportThemeObservation?> observe() async {
    final observation = await _owner.service.observe(_intent);
    if (observation != null) _observations[observation] = true;
    return observation;
  }

  SupportThemeInstalledView? installed(SupportThemeObservation observation) {
    if (_observations[observation] != true) return null;
    final view = _owner.service.projectInstalled(observation);
    for (final choice in view?.choices ?? <SupportThemeChoice>[]) {
      _choices[choice] = true;
    }
    return view;
  }

  Future<SupportThemeReview?> prepareApply(SupportThemeChoice choice) async {
    if (_choices[choice] != true) return null;
    final review = await _owner.service.prepareApply(choice);
    if (review != null) _reviews[review] = true;
    return review;
  }

  Future<SupportThemeReview?> prepareUndo(SupportThemeApplied applied) async {
    final review = await _owner.service.prepareUndo(_intent, applied);
    if (review != null) _reviews[review] = true;
    return review;
  }

  Future<SupportThemeReview?> prepareLastUndo() {
    final applied = _owner.handles.forSession(_session, _owner.service.theme);
    return applied == null ? Future.value(null) : prepareUndo(applied);
  }

  SupportThemePreview? preview(SupportThemeReview review) =>
      _reviews[review] == true ? _owner.service.projectReview(review) : null;

  /// Exact final native Apply/Undo gesture, NOT a prerequisite permission review.
  /// Null is admission refusal; non-null Future is original factual custody even
  /// after this UI/controller/runtime/service retires. Never paint it directly.
  Future<SupportThemeActionResult>? confirm(SupportThemeReview review) =>
      _reviews[review] == true ? _owner._confirm(review, _session) : null;
  SupportThemeActionResult? result(SupportThemeActionResult result) =>
      _owner.service.projectResult(_intent, result);
  Future<SupportThemeRecovery> recover(String operationId) =>
      _owner.service.recover(_intent, operationId);

  Future<SupportThemeHistoryPage?> discoverHistory({
    SupportThemeHistoryCursor? cursor,
  }) async {
    // P ownership is independent of S ownership: another emitted UI intent
    // cannot transplant a native cursor even within the same service.
    if (cursor != null && _historyCursors[cursor] != true) {
      return null; // Explicit foreign continuation refusal before S/SQL.
    }
    final page = await _owner.service.discoverHistory(_intent, cursor: cursor);
    _historyPages[page] = true;
    return page;
  }

  SupportThemeHistoryView? history(SupportThemeHistoryPage page) {
    if (_historyPages[page] != true) return null;
    final view = _owner.service.projectHistory(_intent, page);
    final cursor = view.nextCursor;
    if (cursor != null) _historyCursors[cursor] = true;
    return view;
  }
}
