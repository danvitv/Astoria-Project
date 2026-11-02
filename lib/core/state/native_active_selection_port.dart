import 'package:flutter_riverpod/legacy.dart';

import '../preferences/tracked_shared_preferences.dart';
import '../preferences/saved_preferences_owner.dart';

/// The two ordinary global selections, never Studio/API/embedding or bindings.
enum NativeActiveSelectionKind {
  persona('activePersonaId'),
  preset('activePresetId');

  const NativeActiveSelectionKind(this.key);
  final String key;
}

/// An ORIGINAL already-loaded controller and plugin producer. No Ref, startup,
/// refresh lookup or arbitrary preference key is accepted by this finite port.
final class NativeActiveSelectionPort {
  NativeActiveSelectionPort({
    required this.kind,
    required this.controller,
    required this.preferences,
    required this.isOriginalOwnerCurrent,
  }) {
    _unsubscribe = controller.addListener((_) => _revision++,
        fireImmediately: false);
  }
  final NativeActiveSelectionKind kind;
  final StateController<String?> controller;
  final TrackedSharedPreferences preferences;
  final bool Function() isOriginalOwnerCurrent;
  late final void Function() _unsubscribe;
  int _revision = 0;
  bool _retired = false;

  bool get current {
    if (_retired) return false;
    try {
      if (!controller.mounted || !preferences.store.current ||
          !isOriginalOwnerCurrent()) _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }

  void dispose() {
    _retired = true;
    _unsubscribe();
  }

  NativeActiveSelectionObservation? observe() {
    if (!current) return null;
    final lease = preferences.store.owner.capture([kind.key],
        store: preferences.store);
    final raw = preferences.get(kind.key);
    // A wrong typed cache or state/store divergence is not an empty selection.
    if ((raw != null && raw is! String) || !lease.current ||
        controller.state != raw || !current) return null;
    return NativeActiveSelectionObservation._(this, raw as String?,
        _revision, lease);
  }

  Future<NativeActiveSelectionWrite> write({
    required NativeActiveSelectionObservation observed,
    required String? value,
    required bool Function() isCurrent,
  }) async {
    if (!identical(observed.owner, this) || !isCurrent() || !observed.current) {
      return const NativeActiveSelectionWrite._(false, false, false, null);
    }
    final revision = observed._revision;
    ({bool started, bool accepted, SavedPreferencesLease? receipt}) result;
    var saved = false;
    try {
      result = await preferences.compareAndSetString(
        key: kind.key, expectedRaw: observed.value, value: value,
        expected: observed._lease,
        // The CAS itself compares/consumes the read lease. Checking it here
        // after admission would refuse our own single-key pending intent.
        isCurrent: () => isCurrent() && current && _revision == revision &&
            controller.state == observed.value,
      );
      // A true ORIGINAL plugin acknowledgement is a persistence fact even if
      // its store/controller retired in flight. Receipt currency grants reuse
      // and publication, not permission to erase an already acknowledged fact.
      saved = result.started && result.accepted;
    } catch (_) {
      // Unexpected producer/read delivery is not proof that no plugin effect
      // started. Keep uncertainty quarantined on the original key and store.
      preferences.store.owner.acknowledge(preferences.store, kind.key, false);
      return const NativeActiveSelectionWrite._(true, false, false, null);
    }
    // CAS retires its read lease itself. Completion retains its OWN receipt and
    // original controller revision instead of renewing the old read authority.
    if (!saved || !current || !isCurrent() || _revision != revision ||
        result.receipt?.current != true || preferences.get(kind.key) != value) {
      return NativeActiveSelectionWrite._(result.started, saved, false, null);
    }
    final publication = revision + (observed.value == value ? 0 : 1);
    try {
      controller.state = value;
    } catch (_) {
      // Listener failure follows an already acknowledged plugin effect. Keep
      // that fact even when the original state cannot be safely published.
      return NativeActiveSelectionWrite._(result.started, true, false, null);
    }
    if (!current || !isCurrent() || result.receipt?.current != true ||
        _revision != publication || controller.state != value) {
      return NativeActiveSelectionWrite._(result.started, true, false, null);
    }
    return NativeActiveSelectionWrite._(result.started, true, true,
        NativeActiveSelectionReceipt._(this, observed.value, value,
            publication, result.receipt!));
  }
}

final class NativeActiveSelectionObservation {
  NativeActiveSelectionObservation._(this.owner, this.value,
      this._revision, this._lease);
  final NativeActiveSelectionPort owner;
  final String? value;
  final int _revision;
  final SavedPreferencesLease _lease;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    if (!owner.current || !_lease.current || owner._revision != _revision ||
        owner.controller.state != value ||
        owner.preferences.get(owner.kind.key) != value) _retired = true;
    return !_retired;
  }
}

/// Genuine native custody, not reconstructible from persisted JSON.
final class NativeActiveSelectionReceipt {
  NativeActiveSelectionReceipt._(this.owner, this.before, this.after,
      this._revision, this._lease);
  final NativeActiveSelectionPort owner;
  final String? before, after;
  final int _revision;
  final SavedPreferencesLease _lease;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    if (!owner.current || !_lease.current || owner._revision != _revision ||
        owner.controller.state != after ||
        owner.preferences.get(owner.kind.key) != after) _retired = true;
    return !_retired;
  }
}

final class NativeActiveSelectionWrite {
  const NativeActiveSelectionWrite._(this.started, this.saved,
      this.published, this.receipt);
  final bool started, saved, published;
  final NativeActiveSelectionReceipt? receipt;
}
