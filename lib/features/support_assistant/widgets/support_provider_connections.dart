import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../state/support_provider_ui_binding.dart';
import 'support_provider_fields.dart';
import 'support_provider_preview.dart';
import 'support_provider_screen_controller.dart';
import 'support_surface_layout.dart';

class SupportProviderConnectionsList extends StatelessWidget {
  const SupportProviderConnectionsList({super.key, required this.controller});
  final SupportProviderScreenController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final choices = c.current ? c.connections?.choices : null;
    return Column(
      key: const ValueKey('support_provider_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SupportProviderNotice('support_provider_list_notice'.tr()),
        SupportControlAvailability(
          enabled: c.current && !c.busy,
          child: MenuGroup(
            items: [
              SupportProviderSelector<SupportProviderPurpose>(
                id: 'purpose',
                label: 'support_provider_purpose'.tr(),
                description: 'support_provider_purpose_notice'.tr(),
                value: c.purpose,
                values: SupportProviderPurpose.values,
                labelFor: supportProviderPurposeLabel,
                idFor: (value) => value.name,
                onChanged: c.selectPurpose,
              ),
            ],
          ),
        ),
        SupportProviderButton(
          key: const ValueKey('support_provider_refresh'),
          label: 'support_provider_refresh'.tr(),
          icon: Icons.refresh_rounded,
          busy: c.busy,
          onTap: c.current && !c.busy ? c.observe : null,
        ),
        if (choices?.isEmpty == true)
          SupportProviderNotice('support_provider_empty'.tr()),
        if (choices != null)
          for (var index = 0; index < choices.length; index++)
            if (choices[index].value case final value?)
              _ConnectionRow(
                key: ValueKey('support_provider_choice_$index'),
                value: value,
                readiness: c.readiness[choices[index]],
                onEdit: c.changesAllowed && !c.busy
                    ? () => c.edit(choices[index])
                    : null,
                onKey: c.changesAllowed && !c.busy
                    ? () => c.openKey(choices[index])
                    : null,
              )
            else
              SupportProviderNotice('support_provider_unavailable'.tr()),
      ],
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    super.key,
    required this.value,
    required this.readiness,
    required this.onEdit,
    required this.onKey,
  });
  final SupportProviderSetupValue value;
  final SupportProviderReadiness? readiness;
  final VoidCallback? onEdit, onKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.cs.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    value.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  key: const ValueKey('support_provider_edit'),
                  tooltip: 'support_provider_edit'.tr(),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  key: const ValueKey('support_provider_key_open'),
                  tooltip: 'support_provider_key_title'.tr(),
                  icon: const Icon(Icons.key_outlined),
                  onPressed: onKey,
                ),
              ],
            ),
            Text(
              '${supportProviderProtocolLabel(value.protocol)} · ${value.model}',
            ),
            const SizedBox(height: 4),
            Text(
              value.endpoint,
              style: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            Text('support_provider_prepared'.tr()),
            if (readiness case final r?)
              Text(
                r.credentialConfigured
                    ? 'support_provider_key_saved'.tr(
                        args: [r.characterCount.toString()],
                      )
                    : 'support_provider_key_not_saved'.tr(),
              )
            else
              Text('support_provider_key_metadata_unavailable'.tr()),
            Text(
              'support_provider_unverified'.tr(),
              style: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SupportProviderResult extends StatelessWidget {
  const SupportProviderResult({
    super.key,
    required this.controller,
    required this.view,
  });
  final SupportProviderScreenController controller;
  final SupportProviderActionView view;

  @override
  Widget build(BuildContext context) {
    final applied = controller.actualResult?.applied;
    final after = view.preview?.after;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SupportProviderNotice(
          'support_provider_${view.code.name}'.tr(),
          key: const ValueKey('support_provider_result'),
        ),
        if (after != null)
          SupportProviderValues(
            heading: 'support_provider_after'.tr(),
            value: after,
          ),
        if (view.code == SupportProviderActionCode.applied &&
            applied != null) ...[
          SupportProviderNotice('support_provider_no_assignment'.tr()),
          SupportProviderNotice('support_provider_unverified'.tr()),
          SupportProviderButton(
            key: const ValueKey('support_provider_result_key_open'),
            label: 'support_provider_key_title'.tr(),
            icon: Icons.key_outlined,
            onTap: controller.changesAllowed && !controller.busy
                ? () => controller.openKey(applied)
                : null,
          ),
          if (controller.binding.canUndo(applied))
            SupportProviderButton(
              key: const ValueKey('support_provider_undo'),
              label: 'support_provider_review_undo'.tr(),
              icon: Icons.undo_rounded,
              onTap: controller.changesAllowed && !controller.busy
                  ? controller.prepareUndo
                  : null,
            ),
        ],
      ],
    );
  }
}
