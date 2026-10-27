import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../models/support_recipient_resolution.dart';
import '../services/support_native_consent_controller.dart';
import 'support_surface_layout.dart';

/// Native review chrome. Keeps no transient inspection or raw route metadata.
class SupportPrivacyReviewSheet extends StatefulWidget {
  const SupportPrivacyReviewSheet({
    super.key,
    required this.controller,
    required this.review,
    required this.isCurrent,
    this.recovery = false,
  });
  final SupportNativeConsentController controller;
  final SupportNativeReview review;
  final bool Function() isCurrent;
  final bool recovery;

  @override
  State<SupportPrivacyReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<SupportPrivacyReviewSheet> {
  late final void Function() _stop;
  bool _closed = false;
  ModalRoute<bool>? _route;
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    _stop = widget.controller.runtime.listen(() {
      if (mounted && !_closed) setState(() {});
    });
  }

  @override
  void dispose() {
    _closed = true;
    _stop();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<bool>(context);
    _navigator ??= Navigator.of(context);
  }

  @override
  void deactivate() {
    _closed = true;
    super.deactivate();
  }

  void _finish(bool confirmed) {
    if (!mounted ||
        _closed ||
        _route?.isCurrent != true ||
        (confirmed && !widget.isCurrent()) ||
        !mounted ||
        _closed ||
        _route?.isCurrent != true) {
      return;
    }
    _closed = true;
    _navigator?.pop(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    final recipient = widget.review.view.recipient;
    final current = widget.isCurrent();
    return SheetView(
      title:
          (widget.recovery
                  ? 'support_privacy_recovery_title'
                  : 'support_privacy_recipient_title')
              .tr(),
      showBack: false,
      titleWidget: SupportSheetTitle(
        title:
            (widget.recovery
                    ? 'support_privacy_recovery_title'
                    : 'support_privacy_recipient_title')
                .tr(),
        onBack: () => _finish(false),
      ),
      onBack: () => _finish(false),
      collapsedFraction: 0.85,
      body: Builder(
        builder: (context) => SupportSheetDecisionBody(
          content: ListView(
            key: const ValueKey('support_privacy_review_scroll'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              MenuGroup(
                header: 'support_privacy_review_scope'.tr(),
                description:
                    widget.controller.runtime.snapshot.preferences?.isGlobal ==
                        true
                    ? 'Общий профиль Астории. Выбранные сообщения не переносятся в другой чат; весь текущий чат доступен только при явном выборе этой области. Каждое действие по-прежнему требует своего подтверждения.'
                    : 'support_privacy_session_only'.tr(),
                items: [
                  _Notice(
                    'support_privacy_saved_counts'.tr(
                      args: [
                        '${widget.review.view.gameMessageCount}',
                        '${widget.review.view.supportMessageCount}',
                      ],
                    ),
                  ),
                  _Notice(
                    'support_privacy_review_connections'.tr(
                      args: [
                        (widget.review.view.connectionsSelected
                                ? 'support_privacy_yes'
                                : 'support_privacy_no')
                            .tr(),
                      ],
                    ),
                  ),
                  _Notice('support_privacy_saved_links'.tr()),
                  if (widget.recovery)
                    _Notice('support_privacy_recovery_notice'.tr())
                  else if (recipient is SupportResolvedRecipient) ...[
                    _SafeLabel(
                      'support_privacy_connection'.tr(),
                      recipient.connectionLabel,
                    ),
                    _SafeLabel(
                      'support_privacy_model'.tr(),
                      recipient.recipient.modelId,
                    ),
                    _SafeLabel(
                      'support_privacy_protocol'.tr(),
                      recipient.protocolLabel,
                    ),
                    _SafeLabel(
                      'support_privacy_origin'.tr(),
                      recipient.originLabel,
                    ),
                    _SafeLabel(
                      'support_privacy_operation'.tr(),
                      recipient.operationLabel,
                    ),
                    _SafeLabel(
                      'support_privacy_routing'.tr(),
                      recipient.routingLabel,
                    ),
                    _Notice('support_privacy_router_limit'.tr()),
                  ] else
                    _Notice('support_privacy_recipient_unavailable'.tr()),
                  _Notice('support_privacy_no_action'.tr()),
                  if (!current) _Notice('support_privacy_stale'.tr()),
                ],
              ),
            ],
          ),
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlazeActionButton(
                  key: const ValueKey('support_privacy_review_confirm'),
                  icon: widget.recovery ? Icons.restart_alt : Icons.check,
                  label:
                      (widget.recovery
                              ? 'support_privacy_recovery_confirm'
                              : 'support_privacy_recipient_confirm')
                          .tr(),
                  expand: true,
                  maxLabelLines: null,
                  tone: widget.recovery
                      ? GlazeActionTone.destructive
                      : GlazeActionTone.primary,
                  onTap:
                      current &&
                          (widget.recovery ||
                              recipient is SupportResolvedRecipient)
                      ? () => _finish(true)
                      : null,
                ),
              ),
              Padding(
                padding: EdgeInsets.zero,
                child: GlazeActionButton(
                  key: const ValueKey('support_privacy_review_cancel'),
                  icon: Icons.close,
                  label: 'support_privacy_cancel'.tr(),
                  expand: true,
                  onTap: () => _finish(false),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SafeLabel extends StatelessWidget {
  const _SafeLabel(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        // Bounded safe values must remain fully distinguishable at narrow widths.
        Text(value),
      ],
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
