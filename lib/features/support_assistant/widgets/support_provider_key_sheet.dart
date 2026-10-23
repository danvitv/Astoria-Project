import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/credentials/credential_metadata.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../state/support_provider_ui_binding.dart';
import 'support_provider_fields.dart';

/// Trusted native input, embedded INSIDE the original provider SheetView route.
/// No raw key callbacks, form DTOs, assistant state, history or logging.
class SupportProviderKeySheet extends StatefulWidget {
  const SupportProviderKeySheet({
    super.key,
    required this.target,
    required this.onBack,
  });
  final SupportProviderNativeKeyEntry target;
  final VoidCallback onBack;

  @override
  State<SupportProviderKeySheet> createState() => _KeySheetState();
}

class _KeySheetState extends State<SupportProviderKeySheet> {
  final _secret = TextEditingController();
  Future<CredentialMetadata>? _originalJob;
  CredentialMetadata? _actualFact;
  String? _notice;
  bool _busy = false;

  void _clear() => _secret.clear();

  Future<void> _confirmDestination() async {
    final original = widget.target;
    if (_busy || !original.current) return;
    _clear();
    final job = original.confirmDestination();
    setState(() => _busy = true);
    try {
      final approved = await job;
      if (!mounted ||
          !identical(original, widget.target) ||
          !original.current) {
        return;
      }
      setState(() {
        _busy = false;
        _notice = approved ? null : 'support_provider_key_unavailable';
      });
    } catch (_) {
      if (!mounted || !original.current) return;
      setState(() {
        _busy = false;
        _notice = 'support_provider_key_unavailable';
      });
    }
  }

  void _submit() {
    final original = widget.target;
    if (_busy || !original.readyForInput) {
      _clear();
      return;
    }
    if (_secret.text.isEmpty || _secret.text.runes.length > 4096) {
      _clear();
      setState(() => _notice = 'support_provider_key_invalid');
      return;
    }
    Future<CredentialMetadata>? job;
    try {
      // ONLY this trusted local controller passes raw text. Start native custody
      // and secret registration FIRST; clear BEFORE setState/notify/any await.
      job = original.submitNativeSecret(_secret.text);
    } catch (_) {
      // Never expose a variable exception or echo even invalid input.
    } finally {
      _clear();
    }
    FocusScope.of(context).unfocus();
    if (job == null) {
      setState(() => _notice = 'support_provider_key_unavailable');
      return;
    }
    _originalJob = job;
    setState(() {
      _busy = true;
      _notice = null;
    });
    job.then(
      (fact) {
        _actualFact = fact; // Actual future fact, not a replacement job/read.
        if (!mounted ||
            !identical(original, widget.target) ||
            !original.current) {
          return;
        }
        setState(() => _busy = false);
      },
      onError: (Object _, StackTrace _) {
        if (!mounted || !original.current) return;
        setState(() {
          _busy = false;
          _notice = 'support_provider_key_uncertain';
        });
      },
    );
  }

  @override
  void deactivate() {
    _clear();
    widget.target.dispose();
    super.deactivate();
  }

  @override
  void dispose() {
    _clear();
    _secret.dispose();
    widget.target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final original = widget.target;
    final current = original.current;
    final value = original.value;
    final fact = current ? _actualFact : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SupportProviderNotice('support_provider_key_notice'.tr()),
        if (value != null) ...[
          SupportProviderNotice(value.name),
          SupportProviderNotice(supportProviderPurposeLabel(original.purpose)),
          SupportProviderNotice(value.model),
        ],
        MenuGroup(
          header: 'support_provider_key_destinations'.tr(),
          description: 'support_provider_key_destination_notice'.tr(),
          items: [
            for (final endpoint in original.destinations)
              SupportProviderNotice(endpoint),
          ],
        ),
        if (!current)
          SupportProviderNotice('support_provider_key_unavailable'.tr()),
        if (_notice != null && current) SupportProviderNotice(_notice!.tr()),
        if (current && original.requiresCustomConfirmation)
          SupportProviderButton(
            key: const ValueKey('support_provider_key_custom_confirm'),
            label: 'support_provider_key_custom_confirm'.tr(),
            icon: Icons.public_outlined,
            busy: _busy,
            onTap: !_busy ? _confirmDestination : null,
          ),
        if (current && original.readyForInput && _originalJob == null) ...[
          MenuGroup(
            header: 'support_provider_key_title'.tr(),
            items: [
              Padding(
                padding: const EdgeInsets.all(16),
                // The kit's fields cannot disable autofill, IME learning or
                // restoration. Raw Material is required for this trusted boundary.
                child: TextField(
                  key: const ValueKey('support_provider_key_input'),
                  controller: _secret,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  autofillHints: const <String>[],
                  restorationId: null,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  spellCheckConfiguration:
                      const SpellCheckConfiguration.disabled(),
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  maxLines: 1,
                  maxLength: 4096,
                  inputFormatters: [LengthLimitingTextInputFormatter(4096)],
                  decoration: InputDecoration(
                    labelText: 'support_provider_key_title'.tr(),
                    counterText: '',
                    filled: true,
                    fillColor: context.inputFill,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ],
          ),
          SupportProviderButton(
            key: const ValueKey('support_provider_key_submit'),
            label: 'support_provider_key_submit'.tr(),
            primary: true,
            icon: Icons.key_outlined,
            onTap: _submit,
          ),
        ],
        if (_busy) SupportProviderNotice('support_provider_key_busy'.tr()),
        if (fact != null) ...[
          SupportProviderNotice(
            fact.configured
                ? 'support_provider_key_saved'.tr(
                    args: [fact.characterCount.toString()],
                  )
                : 'support_provider_key_not_saved'.tr(),
          ),
          SupportProviderNotice('support_provider_unverified'.tr()),
        ],
        SupportProviderButton(
          key: const ValueKey('support_provider_key_cancel'),
          label:
              (_busy ? 'support_provider_close' : 'support_provider_back_list')
                  .tr(),
          icon: Icons.close_rounded,
          onTap: () {
            _clear();
            original.dispose();
            widget.onBack();
          },
        ),
      ],
    );
  }
}
