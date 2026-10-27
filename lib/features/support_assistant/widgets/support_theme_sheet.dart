import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/sheet_view.dart';
import '../state/support_theme_provider.dart';
import 'support_theme_controls.dart';
import 'support_theme_history.dart';
import 'support_theme_mode_choices.dart';
import 'support_theme_screen_controller.dart';
import 'support_surface_layout.dart';
import '../../../shared/theme/app_colors.dart';

/// One owned route: choice, exact review, original outcome, separately reviewed
/// conditional Undo. All safe projections are requested anew on EVERY build.
class SupportThemeSheet extends ConsumerStatefulWidget {
  const SupportThemeSheet({super.key, required this.controller});
  final SupportThemeScreenController controller;

  @override
  ConsumerState<SupportThemeSheet> createState() => _SupportThemeSheetState();
}

class _SupportThemeSheetState extends ConsumerState<SupportThemeSheet> {
  ModalRoute<void>? _route;
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = _route = ModalRoute.of<void>(context)!;
    _navigator = Navigator.of(context);
    widget.controller.routeCurrent = () => mounted && route.isCurrent;
    route.popped.then((_) => widget.controller.retire());
  }

  void _close() {
    final route = _route, navigator = _navigator;
    widget.controller.retire();
    if (route?.isCurrent == true && navigator != null) navigator.pop();
  }

  @override
  void deactivate() {
    widget.controller.retire();
    super.deactivate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(supportThemePresentationProvider); // Signal, never cached labels.
    ref.watch(supportThemeUiBindingProvider);
    final c = widget.controller;
    final original = c.intent;
    final current = c.current;
    final observed = c.observation;
    final installed = current && original != null && observed != null
        ? original.installed(observed)
        : null;
    final review = c.review;
    final preview = current && original != null && review != null
        ? original.preview(review)
        : null;
    final fact = c.actualResult;
    final result = current && original != null && fact != null
        ? original.result(fact)
        : null;
    final completedReview = c.resultReview;
    final resultValues = result != null && completedReview != null
        ? original!.preview(completedReview)
        : null;
    final usable = current && original != null;

    return SheetView(
      title: 'support_theme_title'.tr(),
      showBack: false,
      titleWidget: SupportSheetTitle(
        title: 'support_theme_title'.tr(),
        onBack: _close,
        backKey: const ValueKey('support_theme_cancel'),
      ),
      onBack: _close,
      body: Builder(
        builder: (bodyContext) => SupportSheetDecisionBody(
          footer: review == null
              ? const SizedBox.shrink()
              : SupportThemeButton(
                  key: const ValueKey('support_theme_confirm'),
                  label:
                      (review.kind == SupportThemeActionKind.undo
                              ? 'support_theme_confirm_undo'
                              : 'support_theme_confirm_apply')
                          .tr(),
                  busy: c.busy,
                  onTap: preview != null && c.canConfirm
                      ? () => c.confirm(review)
                      : null,
                ),
          content: ListView(
            key: const ValueKey('support_theme_scroll'),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.paddingOf(bodyContext).bottom + 24,
            ),
            children: [
              Text('support_theme_permissions'.tr()),
              if (!usable || (observed != null && installed == null))
                Text('support_theme_unavailable'.tr()),
              if (c.notice != null) Text(c.notice!.tr()),
              if (c.busy) Text('support_theme_busy'.tr()),
              SupportThemeButton(
                key: const ValueKey('support_theme_refresh'),
                label: 'support_theme_refresh'.tr(),
                busy: c.busy,
                onTap: usable && !c.busy ? c.observe : null,
              ),
              if (review != null) ...[
                if (preview == null)
                  Text('support_theme_unavailable'.tr())
                else ...[
                  Text(
                    (preview.operation == SupportThemeOperation.mode
                            ? 'support_theme_mode_exact_review'
                            : 'support_theme_exact_review')
                        .tr(),
                  ),
                  SupportThemeValueBlock(
                    key: const ValueKey('support_theme_before'),
                    value: preview.before,
                    heading: 'support_theme_before'.tr(),
                  ),
                  SupportThemeValueBlock(
                    key: const ValueKey('support_theme_after'),
                    value: preview.after,
                    heading: 'support_theme_after'.tr(),
                  ),
                  SupportThemeSample(value: preview.after),
                ],
              ] else if (installed != null) ...[
                for (final choice in installed.choices)
                  if (choice.value case final value?)
                    _InstalledChoice(
                      value: value,
                      onTap: c.busy ? null : () => c.prepare(choice),
                    )
                  else
                    Text('support_theme_unavailable'.tr()),
                SupportThemeModeChoices(controller: c),
              ],
              if (fact != null)
                if (result == null)
                  Text('support_theme_unavailable'.tr())
                else ...[
                  Text('support_theme_effect_${result.effect.name}'.tr()),
                  Text('support_theme_journal_${result.journal.name}'.tr()),
                  if (resultValues != null) ...[
                    SupportThemeValueBlock(
                      value: resultValues.before,
                      heading: 'support_theme_before'.tr(),
                    ),
                    SupportThemeValueBlock(
                      value: resultValues.after,
                      heading: 'support_theme_after'.tr(),
                    ),
                  ],
                  if (result.operationId case final id?)
                    Text('support_theme_operation'.tr(args: [id])),
                  Text('support_theme_result_historical'.tr()),
                ],
              SupportThemeButton(
                key: const ValueKey('support_theme_undo'),
                label: 'support_theme_review_undo'.tr(),
                onTap: usable && !c.busy ? c.prepareUndo : null,
              ),
              SupportThemeHistory(controller: c),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstalledChoice extends StatelessWidget {
  const _InstalledChoice({required this.value, required this.onTap});
  final SupportThemeValue value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Semantics(
      selected: value.active,
      enabled: onTap != null,
      child: InkWell(
        key: ValueKey('support_theme_choice_${value.id}'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: value.active ? context.cs.primaryContainer : null,
            border: Border.all(
              color: value.active
                  ? context.cs.primary
                  : context.cs.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (value.active)
                Icon(
                  Icons.check_circle_outline,
                  color: context.cs.onPrimaryContainer,
                ),
              SupportThemeValueBlock(value: value),
            ],
          ),
        ),
      ),
    ),
  );
}
