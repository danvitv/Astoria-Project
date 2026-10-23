import 'package:flutter/foundation.dart';

import '../state/support_provider_ui_binding.dart';

/// Presentation custody for one opened sheet; native owners retain every job.
final class SupportProviderScreenController extends ChangeNotifier {
  SupportProviderScreenController({
    required this.binding,
    required this.standardEndpointFor,
    required this.canChange,
    required void Function() Function(void Function()) listen,
  }) {
    _stop = listen(_presentationChanged);
  }

  final SupportProviderUiBinding binding;
  final String Function(String protocol, String model) standardEndpointFor;
  final bool Function() canChange;
  late final void Function() _stop;
  bool Function()? routeCurrent;
  bool _alive = true, busy = false, creating = false, customConfirmed = false;
  int _read = 0;
  SupportProviderPurpose purpose = SupportProviderPurpose.roleplay;
  SupportProviderConnections? connections;
  SupportProviderChoice? updating;
  Object formIdentity = Object();
  SupportProviderReview? review;
  SupportProviderActionResult? actualResult;
  Future<SupportProviderActionResult>? originalJob;
  SupportProviderNativeKeyEntry? keyEntry;
  final readiness =
      <SupportProviderConnectionHandle, SupportProviderReadiness>{};
  String? notice;

  bool get current =>
      _alive && binding.current && (routeCurrent?.call() ?? true);
  bool get changesAllowed => current && canChange();
  bool get hasForm => creating || updating != null;
  bool get canConfirm =>
      changesAllowed &&
      !busy &&
      review != null &&
      (review!.destinationKind == SupportProviderDestinationKind.standard ||
          customConfirmed);

  void _changed() {
    if (_alive) notifyListeners();
  }

  void _presentationChanged() {
    readiness
        .clear(); // A key/config fence is not proof that old counts persist.
    _changed(); // It never cancels or replaces this UI's original started job.
  }

  void selectPurpose(SupportProviderPurpose value) {
    if (!current || busy || value == purpose) return;
    _read++;
    purpose = value;
    connections = null;
    readiness.clear();
    _changed();
    observe();
  }

  Future<void> observe() async {
    if (!current || busy) return;
    final read = ++_read;
    busy = true;
    connections = null;
    readiness.clear();
    notice = null;
    _changed();
    try {
      final observed = await binding.observe(purpose);
      if (!current || read != _read) return;
      connections = observed;
      if (observed == null) notice = 'support_provider_unavailable';
      for (final choice
          in observed?.choices ?? const <SupportProviderChoice>[]) {
        final fact = await binding.readiness(choice);
        if (!current || read != _read) return;
        if (fact != null) readiness[choice] = fact;
      }
    } catch (_) {
      if (current && read == _read) notice = 'support_provider_unavailable';
    } finally {
      if (current && read == _read) {
        busy = false;
        _changed();
      }
    }
  }

  void newProfile() {
    if (!changesAllowed || busy) return;
    cancelReview();
    creating = true;
    formIdentity = Object();
    updating = null;
    actualResult = null;
    notice = null;
    _changed();
  }

  void edit(SupportProviderChoice original) {
    if (!changesAllowed || busy || original.value == null) return;
    cancelReview();
    creating = false;
    updating = original;
    formIdentity = original;
    purpose = original.purpose;
    actualResult = null;
    notice = null;
    _changed();
  }

  Future<void> prepare(SupportProviderSetupInput input) {
    if (!changesAllowed || busy) return Future.value();
    purpose = input.purpose; // Intended scope only, never an active assignment.
    return _prepare(() => binding.prepare(input, updating: updating));
  }

  Future<void> prepareUndo() {
    final applied = actualResult?.applied;
    if (applied == null || !binding.canUndo(applied)) return Future.value();
    return _prepare(() => binding.prepareUndo(applied));
  }

  Future<void> _prepare(Future<SupportProviderReview?> Function() issue) async {
    if (!changesAllowed || busy) return;
    final read = ++_read;
    busy = true;
    review = null;
    customConfirmed = false;
    notice = null;
    _changed();
    try {
      final original = await issue();
      if (!current || read != _read) return;
      review = original;
      if (original == null) notice = 'support_provider_refused';
    } catch (_) {
      if (current && read == _read) notice = 'support_provider_refused';
    } finally {
      if (current && read == _read) {
        busy = false;
        _changed();
      }
    }
  }

  void confirmCustom(SupportProviderReview original) {
    if (!changesAllowed || busy || !identical(original, review)) return;
    customConfirmed = binding.confirmCustomDestination(original);
    if (!customConfirmed) notice = 'support_provider_refused';
    _changed();
  }

  /// Final Apply/Undo: native admission/execution BEFORE any UI notification.
  void confirm(SupportProviderReview original) {
    if (!canConfirm || !identical(original, review)) return;
    busy = true; // Silent UI latch, BEFORE synchronous admission can reenter.
    Future<SupportProviderActionResult>? job;
    try {
      job = binding.confirm(original);
    } catch (_) {
      // Fixed refusal only; never echo native exceptions or start a retry.
    }
    if (job == null) {
      busy = false;
      notice = 'support_provider_refused';
      _changed();
      return;
    }
    originalJob = job;
    actualResult = null;
    notice = null;
    _changed();
    job.then(
      (fact) {
        actualResult = fact; // Original fact settles even after UI retirement.
        if (!current) return;
        busy = false;
        review = null;
        creating = false;
        updating = null;
        connections = null;
        readiness.clear();
        _changed();
      },
      onError: (Object _, StackTrace _) {
        if (!current) return;
        busy = false;
        review = null;
        notice = 'support_provider_storageUncertain';
        _changed();
      },
    );
  }

  void cancelReview() {
    if (busy) return;
    final original = review;
    if (original != null) binding.cancel(original);
    review = null;
    customConfirmed = false;
    _changed();
  }

  void showList() {
    if (!current || busy) return;
    cancelReview();
    keyEntry?.dispose();
    keyEntry = null;
    creating = false;
    updating = null;
    _changed();
    observe();
  }

  Future<void> openKey(SupportProviderConnectionHandle original) async {
    if (!changesAllowed || busy) return;
    final read = ++_read;
    busy = true;
    notice = null;
    _changed();
    try {
      final target = await binding.prepareKeyEntry(original);
      if (!current || read != _read) {
        target?.dispose();
        return;
      }
      keyEntry = target;
      if (target == null) notice = 'support_provider_key_unavailable';
    } catch (_) {
      if (current && read == _read) notice = 'support_provider_key_unavailable';
    } finally {
      if (current && read == _read) {
        busy = false;
        _changed();
      }
    }
  }

  void retire() {
    if (!_alive) return;
    _alive = false;
    _read++;
    _stop();
    keyEntry?.dispose();
    binding.dispose();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
