import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/support_consent_selection.dart';
import '../../../core/db/repositories/support_consent_selection_repo.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/support_native_view.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_recipient_resolution.dart';
import '../services/support_native_consent_controller.dart';
import '../state/support_native_provider.dart';
import 'support_history_selection_sheet.dart';
import 'support_privacy_review_sheet.dart';

typedef _PrivacyAction =
    Future<bool?> Function(
      SupportNativeConsentController,
      SupportNativeReview,
      bool Function(),
    );
typedef _RunDisplayed = void Function(_PrivacyAction action);

/// Shared desktop/mobile native controls. Toggles store prerequisites, not actions.
class SupportPrivacyGroup extends ConsumerStatefulWidget {
  const SupportPrivacyGroup({super.key});
  @override
  ConsumerState<SupportPrivacyGroup> createState() => _PrivacyGroupState();
}

class _PrivacyGroupState extends ConsumerState<SupportPrivacyGroup> {
  SupportNativeConsentController? _controller;
  int _operation = 0;
  bool _busy = false;
  String? _failure;
  void Function()? _cancelActive;
  Object _panelToken = Object();
  String? _failureSession;
  int? _failureLifetime;

  @override
  void initState() {
    super.initState();
    ref.listenManual(supportNativeConsentControllerProvider, (previous, next) {
      if (identical(previous, next)) return;
      previous?.invalidateDisplayedIntents();
      _cancelActive?.call();
      _cancelActive = null;
      _operation++;
      _panelToken = Object();
      _busy = false;
      _failure = null;
      _controller = next;
    });
  }

  @override
  void deactivate() {
    // Fence callbacks immediately, including temporary reparenting. The watching
    // child detaches before dispose cancels the captured native review.
    _operation++;
    _panelToken = Object();
    _busy = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _operation++;
    _cancelActive?.call();
    _cancelActive = null;
    super.dispose();
  }

  Future<void> _run(
    SupportNativeConsentController controller,
    SupportNativeDisplayedIntent? displayedIntent,
    Object panelToken,
    _PrivacyAction action, {
    bool local = false,
  }) async {
    if (_busy || !mounted || !identical(panelToken, _panelToken)) return;
    // The controller AND opaque intent come from the emitted view. Reading the
    // provider here only rejects replacement; it must never rebind old values.
    if (!identical(
          controller,
          ref.read(supportNativeConsentControllerProvider),
        ) ||
        !controller.isDisplayedIntentCurrent(displayedIntent)) {
      return;
    }
    // Capture every dependency before the first await; never use Ref afterwards.
    final runtime = controller.runtime;
    final session = runtime.sessionId, lifetime = runtime.lifetime;
    final initialOwner = runtime.writeOwner;
    final operation = ++_operation;
    _cancelActive = () {
      if (runtime.alive &&
          runtime.sessionId == session &&
          runtime.lifetime == lifetime &&
          runtime.writeOwner == initialOwner) {
        controller.cancelReview();
      }
    };
    setState(() {
      _busy = true;
      _failure = null;
    });
    bool ownsPanel() =>
        mounted &&
        operation == _operation &&
        identical(controller, _controller);
    bool ownsFeedback() =>
        ownsPanel() &&
        runtime.alive &&
        runtime.sessionId == session &&
        runtime.lifetime == lifetime;
    void fail() {
      if (!ownsFeedback()) return;
      setState(() {
        _failure = 'support_privacy_failure';
        _failureSession = session;
        _failureLifetime = lifetime;
      });
    }

    try {
      final review = await controller.prepareReview(
        displayedIntent: displayedIntent,
        resolveRecipient: !local,
      );
      if (!ownsPanel() ||
          runtime.sessionId != session ||
          runtime.lifetime != lifetime) {
        return;
      }
      if (review == null) {
        fail();
        return;
      }
      final owner = runtime.writeOwner;
      final configuration = runtime.configurationRevision();
      bool current() =>
          ownsPanel() &&
          runtime.alive &&
          runtime.sessionId == session &&
          runtime.lifetime == lifetime &&
          runtime.writeOwner == owner &&
          runtime.settingsPending == 0 &&
          runtime.pending == 0 &&
          runtime.configurationRevision() == configuration &&
          runtime.configurationStable();
      final success = await action(controller, review, current);
      if (!ownsPanel()) return;
      if (success == null) {
        // Cancel fences the old review; never invalidate a replacement session.
        if (current()) controller.cancelReview();
      } else if (!success) {
        fail();
      }
    } catch (_) {
      fail();
    } finally {
      if (ownsPanel()) {
        _cancelActive = null;
        setState(() => _busy = false);
      }
    }
  }

  void _review(_RunDisplayed run, {bool recovery = false}) =>
      run((controller, review, current) async {
        if (!current()) return false;
        if (!recovery && review.view.recipient is! SupportResolvedRecipient) {
          return false;
        }
        final confirmed = await showModalBottomSheet<bool>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SupportPrivacyReviewSheet(
            controller: controller,
            review: review,
            isCurrent: current,
            recovery: recovery,
          ),
        );
        if (!current()) return false;
        if (confirmed != true) return null;
        return recovery
            ? controller.recoverToDeny(review, confirmed: true)
            : controller.confirmRecipient(review);
      });

  void _history(
    _RunDisplayed run,
    SupportConsentSelectionRepo repo,
    SupportConsentSelectionSource source,
  ) {
    run((controller, review, current) async {
      if (!current()) return false;
      final selection =
          await showModalBottomSheet<SupportHistorySelectionResult>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => SupportHistorySelectionSheet(
              controller: controller,
              review: review,
              repo: repo,
              source: source,
              isCurrent: current,
            ),
          );
      if (!current()) return false;
      if (selection == null) return null;
      return controller.selectMessages(selection.choice, selection.ids);
    });
  }

  @override
  Widget build(BuildContext context) => Consumer(
    builder: (context, ref, _) => _contents(
      context,
      ref.watch(supportNativeViewProvider),
      ref.watch(supportNativeConsentControllerProvider),
      ref.watch(supportConsentSelectionRepoProvider),
    ),
  );

  Widget _contents(
    BuildContext context,
    SupportNativeView view,
    SupportNativeConsentController controller,
    SupportConsentSelectionRepo repo,
  ) {
    if (!identical(_controller, controller)) {
      _operation++;
      _busy = false;
      _cancelActive = null;
      _panelToken = Object();
      _failure = null;
      _controller = controller;
    }
    if (_failureSession != view.sessionId ||
        _failureLifetime != controller.runtime.lifetime) {
      _failure = null;
    }
    final panelToken = _panelToken;
    void run(_PrivacyAction action) =>
        _run(controller, view.displayedIntent, panelToken, action);
    void runLocal(_PrivacyAction action) =>
        _run(controller, view.displayedIntent, panelToken, action, local: true);
    final available =
        view.availability == SupportPermissionAvailability.available &&
        view.sessionId.isNotEmpty;
    final busy =
        _busy ||
        view.busy ||
        controller.runtime.settingsPending > 0 ||
        !controller.runtime.configurationStable();
    final inspection = view.inspection;
    return MenuCollapsibleSection(
      key: const ValueKey('support_privacy_group'),
      label: 'support_privacy_title'.tr(),
      children: [
        MenuGroup(
          header: 'support_privacy_scope_title'.tr(),
          description: 'support_privacy_intro'.tr(),
          items: [
            if (!available) _Notice(_availabilityKey(view.availability).tr()),
            _Notice(
              'support_privacy_saved_counts'.tr(
                args: [
                  '${view.gameMessageCount}',
                  '${view.supportMessageCount}',
                ],
              ),
            ),
            _Notice('support_privacy_saved_links'.tr()),
            _Action(
              'support_privacy_game_scope',
              'support_privacy_game_picker',
              busy || !available
                  ? null
                  : () => _history(
                      run,
                      repo,
                      SupportConsentSelectionSource.roleplay,
                    ),
            ),
            _Action(
              'support_privacy_support_scope',
              'support_privacy_support_picker',
              busy || !available
                  ? null
                  : () => _history(
                      run,
                      repo,
                      SupportConsentSelectionSource.support,
                    ),
            ),
            _Toggle(
              key: const ValueKey('support_privacy_theme_scope'),
              label: 'support_theme_scope'.tr(),
              description: 'support_theme_scope_notice'.tr(),
              value: view.themeSelected,
              onChanged: busy || !available
                  ? null
                  : (selected) => runLocal(
                      (c, r, current) => current()
                          ? c.selectTheme(r, selected)
                          : Future.value(false),
                    ),
            ),
            _Toggle(
              key: const ValueKey('support_privacy_connections_scope'),
              label: 'support_privacy_connections_scope'.tr(),
              description: 'support_privacy_chooser_not_consent'.tr(),
              value: view.connectionsSelected,
              onChanged: busy || !available
                  ? null
                  : (selected) => run(
                      (c, r, current) => current()
                          ? c.selectConnections(r, selected)
                          : Future.value(false),
                    ),
            ),
            _Notice('support_privacy_loaders_unavailable'.tr()),
            _Action(
              'support_privacy_recipient',
              'support_privacy_recipient_title',
              busy || !available ? null : () => _review(run),
            ),
            _Notice(
              (view.needsRecipientConfirmation
                      ? 'support_privacy_needs_confirmation'
                      : 'support_privacy_confirmed')
                  .tr(),
            ),
            if (view.recipient is SupportRecipientUnavailable)
              _Notice('support_privacy_recipient_unavailable'.tr()),
            if (view.availability == SupportPermissionAvailability.corrupt)
              _Action(
                'support_privacy_recovery',
                'support_privacy_recovery_title',
                busy ? null : () => _review(run, recovery: true),
              ),
            if (_failure != null || view.error != null)
              _Notice('support_privacy_failure'.tr()),
          ],
        ),
        for (final section in _sections)
          MenuGroup(
            header: 'support_privacy_section_${section.$1}'.tr(),
            description: 'support_privacy_section_${section.$1}_notice'.tr(),
            items: [
              for (final right in section.$2)
                _right(
                  view.rights.firstWhere((v) => v.right == right),
                  busy,
                  right == SupportPermission.readSafeSettings ||
                          right == SupportPermission.confirmedSettingsChanges
                      ? runLocal
                      : run,
                ),
            ],
          ),
        if (inspection != null)
          MenuGroup(
            key: const ValueKey('support_privacy_transient_inspection'),
            header: 'support_privacy_inspection_title'.tr(),
            description: 'support_privacy_inspection_notice'.tr(),
            items: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${inspection.connectionLabel} · ${inspection.protocolLabel} · ${inspection.modelLabel}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _Notice(
                'support_privacy_inspection_count'.tr(
                  args: [
                    (inspection.configured
                            ? 'support_privacy_yes'
                            : 'support_privacy_no')
                        .tr(),
                    '${inspection.characterCount}',
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _right(SupportNativeRightView right, bool busy, _RunDisplayed run) =>
      _Toggle(
        key: ValueKey('support_privacy_${right.right.name}'),
        label: 'support_privacy_right_${right.right.name}'.tr(),
        description:
            (!right.available && !right.enabled
                    ? 'support_privacy_right_unavailable'
                    : 'support_privacy_prerequisite')
                .tr(),
        value: right.enabled,
        onChanged: busy || (!right.available && !right.enabled)
            ? null
            : (enabled) => run(
                (c, r, current) => current()
                    ? c.setGrant(r, right.right, enabled)
                    : Future.value(false),
              ),
      );

  static String _availabilityKey(SupportPermissionAvailability value) =>
      switch (value) {
        SupportPermissionAvailability.locked => 'support_privacy_policy_locked',
        SupportPermissionAvailability.corrupt =>
          'support_privacy_policy_corrupt',
        _ => 'support_privacy_policy_unavailable',
      };
  static const _sections = [
    (
      'local',
      [
        SupportPermission.readSafeSettings,
        SupportPermission.readGameData,
        SupportPermission.readDiagnostics,
      ],
    ),
    (
      'model',
      [
        SupportPermission.modelGameHistory,
        SupportPermission.modelSupportHistory,
        SupportPermission.modelSafeSettingsDiagnostics,
        SupportPermission.modelGameData,
        SupportPermission.modelPromptProviderSnippets,
        SupportPermission.modelAttachments,
      ],
    ),
    ('changes', [SupportPermission.confirmedSettingsChanges]),
    ('network', [SupportPermission.confirmedConnectionTests]),
    (
      'report',
      [
        SupportPermission.reportGameHistory,
        SupportPermission.reportSupportHistory,
        SupportPermission.reportPersonalDataAttachments,
      ],
    ),
  ];
}

// MenuSwitchItem has a non-null callback. GlazeSwitch directly supplies a real
// disabled control without an extra inclusion switch or a misleading no-op.
class _Toggle extends StatelessWidget {
  const _Toggle({
    super.key,
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });
  final String label, description;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          Text(description, style: Theme.of(context).textTheme.bodySmall),
          Align(
            alignment: Alignment.centerRight,
            child: GlazeSwitch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(text));
}

class _Action extends StatelessWidget {
  const _Action(this.id, this.label, this.onTap);
  final String id, label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: GlazeActionButton(
      key: ValueKey(id),
      icon: Icons.chevron_right,
      label: label.tr(),
      onTap: onTap,
      expand: true,
    ),
  );
}
