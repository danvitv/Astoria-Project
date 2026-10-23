import 'theme_preset.dart';

part 'theme_selection_owner.dart';
part 'theme_selection_effect.dart';

/// Optional capability: legacy ThemePresetStore implementations remain valid.
/// Reads must refresh their backing-store cache and reject malformed data.
/// setActiveChecked must START the external write synchronously when called;
/// its Future represents completion, not a deferred admission or retry.
abstract interface class ThemeSelectionStore {
  Future<ThemeSelectionStoredState> readSelectionFresh();
  Future<bool> setActiveChecked(String id);
}

/// Native storage-only projection, never an assistant payload or journal codec.
class ThemeSelectionStoredState {
  ThemeSelectionStoredState({
    required List<ThemePreset> presets,
    required this.activeId,
  }) : presets = List.unmodifiable(presets) {
    final ids = <String>{};
    for (final preset in presets) {
      if (preset.id.isEmpty ||
          !ids.add(preset.id) ||
          !_scalarFontSize(preset.uiFontSize) ||
          !_scalarFontSize(preset.chatFontSize) ||
          !RegExp(
            r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$',
          ).hasMatch(preset.accentColor)) {
        throw const ThemeSelectionInvalidStorage();
      }
    }
    if (!ids.contains(activeId)) throw const ThemeSelectionInvalidStorage();
  }

  final List<ThemePreset> presets;
  final String activeId;
  ThemePreset get active => presets.firstWhere((p) => p.id == activeId);
  ThemePreset? installed(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}

bool _scalarFontSize(Object? value) =>
    value is String || (value is num && value.isFinite);

class ThemeSelectionInvalidStorage implements Exception {
  const ThemeSelectionInvalidStorage();
  @override
  String toString() => 'ThemeSelectionInvalidStorage';
}

enum ThemeSelectionCode {
  ready,
  applied,
  noOp,
  revoked,
  ownerChanged,
  conflict,
  alreadyConsumed,
  unsupportedStorage,
  invalidStorage,
  preparationFailed,
  readFailed,
  writeRejected,
  writeThrew,
  verificationFailed,
  verificationConflict,
}

enum ThemeSelectionWriteAcceptance { notStarted, accepted, rejected, unknown }

enum ThemeSelectionFreshObservation {
  notRead,
  before,
  after,
  other,
  unavailable,
}

/// ONLY native display input. The feature must bound/sanitize these strings
/// before assistant cards, model disclosure, logs or journal serialization.
/// No font, image, path, raw JSON or content hash is exposed by an opaque plan.
class ThemeSelectionDisplay {
  ThemeSelectionDisplay._(ThemePreset preset)
    : id = preset.id,
      name = preset.name,
      mode = preset.themeMode,
      accent = preset.accentColor;
  final String id;
  final String name;
  final String mode;
  final String accent;
}

/// Transient observation, not a restored approval or historical causal proof.
class ThemeSelectionObservation {
  ThemeSelectionObservation._(this._owner, this._revision, this._stored);
  final Object _owner;
  final int _revision;
  final ThemeSelectionStoredState _stored;

  ThemeSelectionDisplay get active => ThemeSelectionDisplay._(_stored.active);
  List<ThemeSelectionDisplay> get installed =>
      List.unmodifiable(_stored.presets.map(ThemeSelectionDisplay._));

  /// Minting a domain precondition does NOT authorize an assistant action.
  /// Native approval and its live predicate are the feature owner's obligation.
  ThemeSelectionPlan? planFor(String installedId) {
    final target = _stored.installed(installedId);
    return target == null
        ? null
        : ThemeSelectionPlan._(_owner, _revision, _stored.active, target);
  }
}

class ThemeSelectionPlan {
  ThemeSelectionPlan._(this._owner, this._revision, this._before, this._after);
  final Object _owner;
  final int _revision;
  final ThemePreset _before;
  final ThemePreset _after;
  ThemeSelectionDisplay get before => ThemeSelectionDisplay._(_before);
  ThemeSelectionDisplay get after => ThemeSelectionDisplay._(_after);
}

/// Immutable, once-usable same-owner Undo evidence. Never serialize this object
/// or recreate it from journal IDs. Recreation permits observation/fresh review,
/// not recovery of this owner's revision/ABA proof or old native approvals.
class ThemeSelectionReceipt {
  ThemeSelectionReceipt._(
    this._owner,
    this._revision,
    this._before,
    this._after,
  );
  final Object _owner;
  final int _revision;
  final ThemePreset _before;
  final ThemePreset _after;
  ThemeSelectionDisplay get before => ThemeSelectionDisplay._(_before);
  ThemeSelectionDisplay get after => ThemeSelectionDisplay._(_after);
}

class ThemeSelectionReadResult {
  const ThemeSelectionReadResult(this.code, [this.observation]);
  final ThemeSelectionCode code;
  final ThemeSelectionObservation? observation;
}

/// Fixed codes only: backend exceptions may contain user secrets.
/// `effectStarted` means backend invocation, NOT proof of a physical disk write.
/// Even thrown/rejected writes can freshly observe `after`; never blindly retry.
class ThemeSelectionResult {
  const ThemeSelectionResult(
    this.code, {
    this.effectStarted = false,
    this.writeAcceptance = ThemeSelectionWriteAcceptance.notStarted,
    this.freshObserved = ThemeSelectionFreshObservation.notRead,
    this.ownerCurrent = false,
    this.receipt,
  });
  final ThemeSelectionCode code;
  final bool effectStarted;
  final ThemeSelectionWriteAcceptance writeAcceptance;
  final ThemeSelectionFreshObservation freshObserved;
  final bool ownerCurrent;
  final ThemeSelectionReceipt? receipt;
  bool get writeAccepted =>
      writeAcceptance == ThemeSelectionWriteAcceptance.accepted;
}
