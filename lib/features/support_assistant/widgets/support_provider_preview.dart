import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../state/support_provider_ui_binding.dart';
import 'support_provider_fields.dart';
import 'support_provider_screen_controller.dart';

class SupportProviderPreview extends StatelessWidget {
  const SupportProviderPreview({
    super.key,
    required this.controller,
    required this.review,
    required this.preview,
    this.showActions = true,
  });
  final SupportProviderScreenController controller;
  final SupportProviderReview review;
  final SupportProviderSetupPreview preview;
  final bool showActions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SupportProviderNotice('support_provider_exact_review'.tr()),
      SupportProviderNotice(supportProviderPurposeLabel(preview.purpose)),
      SupportProviderValues(
        key: const ValueKey('support_provider_before'),
        heading: 'support_provider_before'.tr(),
        value: preview.before,
      ),
      SupportProviderValues(
        key: const ValueKey('support_provider_after'),
        heading: 'support_provider_after'.tr(),
        value: preview.after,
      ),
      SupportProviderNotice('support_provider_no_assignment'.tr()),
      if (preview.destinationKind ==
          SupportProviderDestinationKind.customHttps) ...[
        SupportProviderNotice('support_provider_custom_review'.tr()),
        SupportProviderButton(
          key: const ValueKey('support_provider_custom_confirm'),
          label:
              (controller.customConfirmed
                      ? 'support_provider_custom_confirmed'
                      : 'support_provider_custom_confirm')
                  .tr(),
          icon: Icons.public_outlined,
          onTap:
              controller.changesAllowed &&
                  !controller.busy &&
                  !controller.customConfirmed
              ? () => controller.confirmCustom(review)
              : null,
        ),
      ],
      if (showActions)
        SupportProviderReviewActions(
          controller: controller,
          review: review,
          preview: preview,
        ),
    ],
  );
}

/// The exact original final decisions can be pinned below the review scroll.
class SupportProviderReviewActions extends StatelessWidget {
  const SupportProviderReviewActions({
    super.key,
    required this.controller,
    required this.review,
    required this.preview,
  });
  final SupportProviderScreenController controller;
  final SupportProviderReview review;
  final SupportProviderSetupPreview preview;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SupportProviderButton(
        key: const ValueKey('support_provider_confirm'),
        label:
            (preview.kind == SupportProviderActionKind.undo
                    ? 'support_provider_confirm_undo'
                    : 'support_provider_confirm_apply')
                .tr(),
        primary: true,
        busy: controller.busy,
        icon: Icons.check_rounded,
        onTap: controller.canConfirm ? () => controller.confirm(review) : null,
      ),
      SupportProviderButton(
        key: const ValueKey('support_provider_review_cancel'),
        label: 'support_provider_review_cancel'.tr(),
        icon: Icons.close_rounded,
        onTap: !controller.busy ? controller.cancelReview : null,
      ),
    ],
  );
}

/// Plain rows in two structural groups, not a blur surface for every field.
class SupportProviderValues extends StatelessWidget {
  const SupportProviderValues({
    super.key,
    required this.heading,
    required this.value,
  });
  final String heading;
  final SupportProviderSetupValue? value;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return MenuGroup(
      header: heading,
      items: v == null
          ? [SupportProviderNotice('support_provider_no_profile'.tr())]
          : [
              _Value('support_provider_name'.tr(), v.name),
              _Value(
                'support_provider_protocol'.tr(),
                supportProviderProtocolLabel(v.protocol),
              ),
              _Value('support_provider_endpoint'.tr(), v.endpoint),
              _Value('support_provider_model'.tr(), v.model),
              _Value(
                'support_provider_max_tokens'.tr(),
                v.maxTokens.toString(),
              ),
              _Value(
                'support_provider_context_size'.tr(),
                v.contextSize.toString(),
              ),
              _Value(
                'support_provider_temperature'.tr(),
                v.temperature.toString(),
              ),
            ],
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(color: context.cs.onSurface, fontSize: 14),
        ),
      ],
    ),
  );
}
