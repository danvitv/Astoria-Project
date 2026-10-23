import 'package:flutter/foundation.dart';

import '../models/support_native_view.dart';
import '../state/support_theme_provider.dart';

/// UI lifetime only. Native authority and original job custody stay in P/S.
/// Retains opaque observations/reviews/pages, never previously safe label DTOs.
final class SupportThemeScreenController extends ChangeNotifier {
  SupportThemeScreenController({
    required this.binding,
    required this.displayedIntent,
    required bool Function() isUiCurrent,
  }) : _externalCurrent = isUiCurrent {
    _epoch = binding.controller.runtime.epoch;
    _redactor = binding.service.redaction.redactor;
    intent = binding.emit(
      displayedIntent: displayedIntent,
      uiLifetime: _lifetime,
      isUiCurrent: () => current,
    );
  }

  final SupportThemeUiBinding binding;
  final SupportNativeDisplayedIntent displayedIntent;
  final bool Function() _externalCurrent;
  final Object _lifetime = Object();
  late final int _epoch;
  late final Object _redactor;
  late final SupportThemeUiIntent? intent;
  bool _alive = true, _working = false, _consumed = false;
  int _read = 0;
  bool Function()? routeCurrent;
  SupportThemeObservation? observation;
  SupportThemeReview? review;
  SupportThemeReview? resultReview;
  SupportThemeActionResult? actualResult;
  Future<SupportThemeActionResult>? originalJob;
  final pages = <SupportThemeHistoryPage>[];
  bool historyRequested = false;
  SupportThemeOperation historyOperation = SupportThemeOperation.selection;
  String? notice;

  bool get current =>
      _alive &&
      _externalCurrent() &&
      binding.controller.runtime.epoch == _epoch &&
      identical(binding.service.redaction.redactor, _redactor) &&
      (routeCurrent?.call() ?? true) &&
      binding.controller.isDisplayedIntentCurrent(displayedIntent);
  bool get busy => _working || binding.busy;
  bool get canConfirm => current && !busy && !_consumed && review != null;

  void _changed() {
    if (_alive) notifyListeners();
  }

  /// Ordinary theme writes expire point-in-time choices, NOT original STARTED
  /// jobs. A write from our confirmed job must not revoke its own settlement.
  void themeChanged() {
    observation = null;
    if (originalJob == null || actualResult != null) {
      _read++;
      _working = false;
      review = null;
      notice = 'support_theme_changed';
    }
    _changed();
  }

  Future<void> observe() async {
    final original = intent;
    if (!current || original == null || busy) return;
    final read = ++_read;
    _working = true;
    observation = null;
    review = null;
    notice = null;
    _changed();
    try {
      final value = await original.observe();
      if (!current || read != _read) return;
      observation = value;
      if (value == null) notice = 'support_theme_unavailable';
    } finally {
      if (_alive && read == _read) {
        _working = false;
        _changed();
      }
    }
  }

  Future<void> prepare(SupportThemeChoice choice) =>
      _prepare((original) => original.prepareApply(choice));

  Future<void> prepareUndo() => _prepare((original) {
    final applied = actualResult?.applied;
    return applied == null
        ? original.prepareLastUndo()
        : original.prepareUndo(applied);
  });

  Future<void> _prepare(
    Future<SupportThemeReview?> Function(SupportThemeUiIntent) issue,
  ) async {
    final original = intent;
    if (!current || original == null || busy) return;
    final read = ++_read;
    _working = true;
    _consumed = false;
    review = null;
    notice = null;
    _changed();
    try {
      final value = await issue(original);
      if (!current || read != _read) return;
      review = value;
      if (value == null) notice = 'support_theme_unavailable';
    } finally {
      if (_alive && read == _read) {
        _working = false;
        _changed();
      }
    }
  }

  /// Exact final gesture: latch BEFORE synchronous native admission/reentry.
  /// The original Future is deliberately retained even after UI retirement.
  void confirm(SupportThemeReview originalReview) {
    final original = intent;
    if (!canConfirm || original == null || !identical(review, originalReview)) {
      return;
    }
    _consumed = true;
    final job = original.confirm(originalReview);
    if (job == null) {
      notice = 'support_theme_refused';
      _changed();
      return;
    }
    originalJob = job;
    resultReview = originalReview;
    actualResult = null;
    _working = true;
    notice = null;
    _changed();
    // Never access Ref/context here, retry, cancel persistence or auto-Undo.
    job.then(
      (fact) {
        actualResult = fact;
        if (!current) return;
        _working = false;
        review = null;
        observation = null;
        _changed();
      },
      onError: (Object _, StackTrace _) {
        if (!current) return;
        _working = false;
        notice = 'support_theme_uncertain';
        _changed();
      },
    );
  }

  void selectHistoryOperation(SupportThemeOperation operation) {
    if (!current || busy || operation == historyOperation) return;
    _read++;
    historyOperation = operation;
    pages.clear();
    historyRequested = false;
    _changed();
  }

  Future<void> discover({SupportThemeHistoryCursor? cursor}) async {
    final original = intent;
    if (!current || original == null || busy) return;
    final read = ++_read;
    _working = true;
    historyRequested = true;
    if (cursor == null) pages.clear();
    _changed();
    try {
      final page = await original.discoverHistory(
        cursor: cursor,
        operation: historyOperation,
      );
      if (!current || read != _read) return;
      if (page == null) {
        notice = 'support_theme_history_unavailable';
      } else {
        pages.add(page);
      }
    } finally {
      if (_alive && read == _read) {
        _working = false;
        _changed();
      }
    }
  }

  void retire() {
    if (!_alive) return;
    _alive = false;
    _read++;
    // No native cancellation: already-started original facts still finish.
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
