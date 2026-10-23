import 'dart:math';

import '../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/support_models.dart';
import '../../../shared/theme/theme_provider.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_provenance.dart';
import '../models/support_permission_scope.dart';
import '../models/support_theme_values.dart';
import 'support_native_runtime.dart';
import 'support_theme_evidence_codec.dart';

export '../models/support_theme_values.dart';

part 'support_theme_action_authority.dart';
part 'support_theme_action_execution.dart';
part 'support_theme_action_recovery.dart';
part 'support_theme_action_history.dart';
part 'support_theme_history_types.dart';
part 'support_theme_history_boundary.dart';

/// Trusted native composition only. No Ref, model, recipient resolution, raw
/// preferences, resource fetch or string-based action dispatch is supported.
final class SupportThemeActionService {
  SupportThemeActionService({
    required this.runtime,
    required this.theme,
    required this.custody,
    required this.redaction,
    required this.isOriginalThemeOwner,
    String Function()? newOperationId,
    int Function()? now,
  }) : _newOperationId = newOperationId ?? _uuid,
       _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final SupportNativeRuntime runtime;
  final ThemeNotifier theme;
  final SupportThemeActionCustody custody;
  final SecretRedactionCoordinator redaction;
  final bool Function() isOriginalThemeOwner;
  final String Function() _newOperationId;
  final int Function() _now;
  static const _codec = SupportThemeEvidenceCodec();
  static const _modeCodec = SupportThemeEvidenceCodec(
    operation: SupportThemeOperation.mode,
  );
  static SupportThemeEvidenceCodec _codecFor(SupportThemeOperation operation) =>
      switch (operation) {
        SupportThemeOperation.selection => _codec,
        SupportThemeOperation.mode => _modeCodec,
      };
  static SupportThemeOperation _operation(ThemeSelectionOperation operation) =>
      switch (operation) {
        ThemeSelectionOperation.selection => SupportThemeOperation.selection,
        ThemeSelectionOperation.mode => SupportThemeOperation.mode,
      };
  final _consumed = Expando<bool>();
  Object _issuer = Object();
  bool _alive = true;

  /// UI supplies its ORIGINAL controller/lifetime and a captured identity
  /// predicate at emission, never a provider lookup that rebinds at click time.
  SupportThemeIntent? emit({
    required Object controller,
    required Object uiLifetime,
    required bool Function() isCurrent,
  }) {
    try {
      runtime.checkConfiguration();
      final p = runtime.snapshot.preferences;
      if (p == null || !_readAllowed(p)) return null;
      final binding = _ThemeBinding(this, controller, uiLifetime, isCurrent, p);
      return _current(binding) ? SupportThemeIntent._(binding) : null;
    } catch (_) {
      return null;
    }
  }

  void retireIntents() => _issuer = Object();
  void dispose() {
    _alive = false;
    retireIntents();
    // Original jobs belong to custody, not the retired screen/service.
  }

  Future<SupportThemeObservation?> observe(SupportThemeIntent intent) async {
    final b = intent._binding;
    if (!_current(b)) return null;
    try {
      final lease = await runtime.authorization.prepare(
        supportSessionId: b.sessionId,
        use: SupportPermissionUse.localRead,
        sources: [
          SupportPermissionSource.safeProjection(
            b.sessionId,
            SupportSafeCategory.theme,
          ),
        ],
      );
      if (lease == null || !_current(b)) return null;
      final data = await runtime.authorization.loadLocal(
        lease,
        () => theme.observeInstalledThemes(isCurrent: () => _current(b)),
      );
      if (!_current(b)) return null;
      SupportThemeObservation? result;
      await runtime.authorization.consume(lease, data, (read) {
        if (_current(b) &&
            read.code == ThemeSelectionCode.ready &&
            read.observation != null) {
          result = SupportThemeObservation._(b, read.observation!);
        }
      });
      if (!_current(b) || result == null || projectInstalled(result!) == null) {
        return null;
      }
      return result;
    } catch (_) {
      return null; // Never format native exceptions.
    }
  }

  /// Retained native values are reprojected with CURRENT policy every time.
  /// Exact old authority still expires; display reprojection cannot renew it.
  SupportThemeInstalledView? projectInstalled(SupportThemeObservation handle) {
    final b = handle._binding;
    if (!_displayCurrent(b)) return null;
    final installed = handle._native.installed;
    if (installed.isEmpty ||
        installed.length > SupportThemeEvidenceCodec.maxInstalled) {
      return null;
    }
    final policy = redaction.redactor;
    final choices = <SupportThemeChoice>[];
    for (final row in installed) {
      final value = _project(row, row.id == handle._native.active.id, policy);
      final plan = handle._native.planFor(row.id);
      if (value == null || plan == null) return null;
      choices.add(SupportThemeChoice._(b, plan));
    }
    return _displayCurrent(b) && identical(policy, redaction.redactor)
        ? SupportThemeInstalledView._(choices)
        : null;
  }

  Future<SupportThemeReview?> prepareApply(SupportThemeChoice choice) async {
    final b = choice._binding;
    if (!await _fresh(b, changes: true) || !_current(b, changes: true)) {
      return null;
    }
    return SupportThemeReview._(b, choice._plan, null);
  }

  /// Only the active preset captured by this native observation can be edited.
  /// Mode strings choose a finite plan, never a target ID or action dispatcher.
  SupportThemeInstalledView? projectModeChoices(
    SupportThemeObservation handle,
  ) {
    final b = handle._binding;
    if (!_displayCurrent(b) ||
        handle._native.installed.isEmpty ||
        handle._native.installed.length >
            SupportThemeEvidenceCodec.maxInstalled) {
      return null;
    }
    final policy = redaction.redactor;
    final choices = <SupportThemeChoice>[];
    for (final mode in const ['dark', 'light', 'system']) {
      final plan = handle._native.planForMode(mode);
      if (plan == null ||
          _project(plan.before, true, policy) == null ||
          _project(plan.after, true, policy) == null) {
        return null;
      }
      choices.add(SupportThemeChoice._(b, plan));
    }
    return _displayCurrent(b) && identical(policy, redaction.redactor)
        ? SupportThemeInstalledView._(choices)
        : null;
  }

  Future<SupportThemeReview?> prepareUndo(
    SupportThemeIntent intent,
    SupportThemeApplied applied,
  ) async {
    final b = intent._binding;
    if (!identical(applied._custody, custody) ||
        !identical(applied._theme, theme) ||
        applied._reservation.record.sessionId != b.sessionId ||
        !await _fresh(b, changes: true) ||
        !_current(b, changes: true)) {
      return null;
    }
    return SupportThemeReview._(b, null, applied);
  }

  SupportThemePreview? projectReview(SupportThemeReview review) {
    final b = review._binding;
    if (!_displayCurrent(b)) return null;
    final undo = review._applied;
    final before = undo == null ? review._plan!.before : undo._receipt.after;
    final after = undo == null ? review._plan!.after : undo._receipt.before;
    final policy = redaction.redactor;
    final a = _project(before, true, policy), z = _project(after, true, policy);
    if (a == null ||
        z == null ||
        !_displayCurrent(b) ||
        !identical(policy, redaction.redactor)) {
      return null;
    }
    return SupportThemePreview(
      kind: review.kind,
      operation: review.operation,
      before: a,
      after: z,
    );
  }

  /// Call only from the exact native final Apply/Undo gesture. A review, DTO,
  /// domain plan, journal ID or grant merge is never itself approval.
  SupportThemeApproval? approve(SupportThemeReview review) {
    if (_consumed[review] == true ||
        !_current(review._binding, changes: true) ||
        projectReview(review) == null) {
      return null;
    }
    _consumed[review] = true;
    return SupportThemeApproval._(review);
  }

  SupportThemeValue? _project(
    ThemeSelectionDisplay row,
    bool active,
    SecretRedactor p,
  ) => _codec.project(
    id: row.id,
    name: row.name,
    mode: row.mode,
    accent: row.accent,
    active: active,
    policy: p,
  );

  static String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
