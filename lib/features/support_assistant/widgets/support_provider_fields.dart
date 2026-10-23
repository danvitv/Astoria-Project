import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/support_provider_values.dart';

const supportProviderProtocols = <String>[
  'openai',
  'openai_responses',
  'anthropic',
  'gemini',
  'openrouter',
  'custom_chat_completion',
];

/// In-place picker: no secondary route can revoke the original sheet custody.
class SupportProviderSelector<T> extends StatefulWidget {
  const SupportProviderSelector({
    super.key,
    required this.id,
    required this.label,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.idFor,
    required this.onChanged,
    this.description,
  });
  final String id, label;
  final String? description;
  final T value;
  final List<T> values;
  final String Function(T) labelFor, idFor;
  final ValueChanged<T> onChanged;

  @override
  State<SupportProviderSelector<T>> createState() => _SelectorState<T>();
}

class _SelectorState<T> extends State<SupportProviderSelector<T>> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MenuSelectorItem(
        key: ValueKey('support_provider_${widget.id}'),
        label: widget.label,
        description: widget.description,
        currentValue: widget.labelFor(widget.value),
        onTap: () => setState(() => _expanded = !_expanded),
      ),
      if (_expanded)
        for (final value in widget.values)
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey(
                'support_provider_${widget.id}_${widget.idFor(value)}',
              ),
              onTap: () {
                setState(() => _expanded = false);
                widget.onChanged(value);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      value == widget.value
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: context.cs.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(widget.labelFor(value))),
                  ],
                ),
              ),
            ),
          ),
    ],
  );
}

class SupportProviderFields extends StatelessWidget {
  const SupportProviderFields({
    super.key,
    required this.name,
    required this.model,
    required this.maxTokens,
    required this.contextSize,
    required this.temperature,
    required this.onModelChanged,
    required this.enabled,
  });
  final TextEditingController name, model, maxTokens, contextSize, temperature;
  final ValueChanged<String> onModelChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: MenuGroup(
      header: 'support_provider_profile'.tr(),
      items: [
        MenuFieldItem(
          key: const ValueKey('support_provider_name'),
          label: 'support_provider_name'.tr(),
          controller: name,
          inputFormatters: [LengthLimitingTextInputFormatter(128)],
        ),
        MenuFieldItem(
          key: const ValueKey('support_provider_model'),
          label: 'support_provider_model'.tr(),
          description: 'support_provider_model_manual'.tr(),
          controller: model,
          inputFormatters: [LengthLimitingTextInputFormatter(192)],
          onChanged: onModelChanged,
        ),
        MenuFieldItem(
          key: const ValueKey('support_provider_max_tokens'),
          label: 'support_provider_max_tokens'.tr(),
          controller: maxTokens,
          helper: 'support_provider_max_tokens_bounds'.tr(),
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(5),
          ],
        ),
        MenuFieldItem(
          key: const ValueKey('support_provider_context_size'),
          label: 'support_provider_context_size'.tr(),
          controller: contextSize,
          helper: 'support_provider_context_bounds'.tr(),
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(7),
          ],
        ),
        MenuFieldItem(
          key: const ValueKey('support_provider_temperature'),
          label: 'support_provider_temperature'.tr(),
          controller: temperature,
          helper: 'support_provider_temperature_bounds'.tr(),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [LengthLimitingTextInputFormatter(12)],
        ),
      ],
    ),
  );
}

class SupportProviderButton extends StatelessWidget {
  const SupportProviderButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = Icons.arrow_forward_rounded,
    this.primary = false,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onTap;
  final IconData icon;
  final bool primary, busy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: GlazeActionButton(
      icon: icon,
      label: label,
      onTap: onTap,
      busy: busy,
      expand: true,
      tone: primary ? GlazeActionTone.primary : GlazeActionTone.neutral,
    ),
  );
}

class SupportProviderNotice extends StatelessWidget {
  const SupportProviderNotice(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      text,
      style: TextStyle(
        color: context.cs.onSurfaceVariant,
        fontSize: 13,
        height: 1.4,
      ),
    ),
  );
}

String supportProviderPurposeLabel(SupportProviderPurpose value) =>
    'support_provider_purpose_${value.name}'.tr();

String supportProviderProtocolLabel(String value) =>
    'support_provider_protocol_$value'.tr();
