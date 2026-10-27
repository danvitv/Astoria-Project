import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/widgets/menu_group.dart';
import '../state/support_provider_ui_binding.dart';
import 'support_provider_fields.dart';
import 'support_provider_screen_controller.dart';
import 'support_surface_layout.dart';

/// Deterministic offline form. It creates only keyless setup input, never IDs.
class SupportProviderForm extends StatefulWidget {
  const SupportProviderForm({
    super.key,
    required this.controller,
    this.simple = false,
    this.onCancel,
  });
  final SupportProviderScreenController controller;
  final bool simple;
  final VoidCallback? onCancel;

  @override
  State<SupportProviderForm> createState() => _FormState();
}

class _FormState extends State<SupportProviderForm> {
  final _name = TextEditingController();
  final _model = TextEditingController();
  final _endpoint = TextEditingController();
  final _tokens = TextEditingController(text: '512');
  final _context = TextEditingController(text: '32768');
  final _temperature = TextEditingController(text: '0.7');
  String _protocol = 'openai';
  SupportProviderPurpose _purpose = SupportProviderPurpose.roleplay;
  bool _custom = false;
  String? _error;

  bool get _updating => widget.controller.updating != null;

  @override
  void initState() {
    super.initState();
    _purpose = widget.controller.purpose;
    final before = widget.controller.updating?.value;
    if (before != null) {
      _name.text = before.name;
      _model.text = before.model;
      _protocol = before.protocol;
      _endpoint.text = before.endpoint;
      _tokens.text = before.maxTokens.toString();
      _context.text = before.contextSize.toString();
      _temperature.text = before.temperature.toString();
    } else {
      _updateStandardEndpoint();
    }
  }

  void _updateStandardEndpoint() {
    if (_updating || _custom) return;
    try {
      _endpoint.text = widget.controller.standardEndpointFor(
        _protocol,
        _model.text.trim(),
      );
    } catch (_) {
      // Gemini's final standard URL requires a manually supplied valid model.
      _endpoint.clear();
    }
  }

  void _review() {
    if (!widget.controller.changesAllowed || widget.controller.busy) return;
    final tokens = int.tryParse(_tokens.text);
    final contextSize = int.tryParse(_context.text);
    final temperature = double.tryParse(_temperature.text.replaceAll(',', '.'));
    final uri = Uri.tryParse(_endpoint.text);
    if (_name.text.trim().isEmpty ||
        _model.text.trim().isEmpty ||
        tokens == null ||
        tokens < 1 ||
        tokens > 32768 ||
        contextSize == null ||
        contextSize < tokens ||
        contextSize > 2000000 ||
        temperature == null ||
        !temperature.isFinite ||
        temperature < 0 ||
        temperature > 2 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        _endpoint.text != _endpoint.text.trim()) {
      setState(() => _error = 'support_provider_invalid');
      return;
    }
    setState(() => _error = null);
    FocusScope.of(context).unfocus();
    widget.controller.prepare(
      SupportProviderSetupInput(
        purpose: _purpose,
        name: _name.text,
        protocol: _protocol,
        endpoint: _endpoint.text,
        model: _model.text,
        maxTokens: tokens,
        contextSize: contextSize,
        temperature: temperature,
      ),
    );
  }

  @override
  void dispose() {
    for (final field in [
      _name,
      _model,
      _endpoint,
      _tokens,
      _context,
      _temperature,
    ]) {
      field.clear();
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final enabled = c.changesAllowed && !c.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SupportProviderNotice('support_provider_offline'.tr()),
        if (_updating)
          SupportProviderNotice('support_provider_update_immutable'.tr()),
        SupportControlAvailability(
          enabled: enabled,
          child: MenuGroup(
            header: 'support_provider_route'.tr(),
            description: 'support_provider_purpose_notice'.tr(),
            items: [
              if (!_updating) ...[
                if (!widget.simple)
                  SupportProviderSelector<SupportProviderPurpose>(
                    id: 'purpose',
                    label: 'support_provider_purpose'.tr(),
                    value: _purpose,
                    values: SupportProviderPurpose.values,
                    labelFor: supportProviderPurposeLabel,
                    idFor: (value) => value.name,
                    onChanged: (value) => setState(() => _purpose = value),
                  ),
                SupportProviderSelector<String>(
                  id: 'protocol',
                  label: 'support_provider_protocol'.tr(),
                  value: _protocol,
                  values: supportProviderProtocols,
                  labelFor: supportProviderProtocolLabel,
                  idFor: (value) => value,
                  onChanged: (value) => setState(() {
                    _protocol = value;
                    _updateStandardEndpoint();
                  }),
                ),
                MenuSwitchItem(
                  key: const ValueKey('support_provider_custom_endpoint'),
                  label: 'support_provider_custom_endpoint'.tr(),
                  description: 'support_provider_custom_endpoint_notice'.tr(),
                  value: _custom,
                  onChanged: (value) => setState(() {
                    _custom = value;
                    if (_custom) {
                      _endpoint.clear();
                    } else {
                      _updateStandardEndpoint();
                    }
                  }),
                ),
              ] else ...[
                SupportProviderNotice(supportProviderPurposeLabel(_purpose)),
                SupportProviderNotice(supportProviderProtocolLabel(_protocol)),
              ],
              if (_custom && !_updating)
                MenuFieldItem(
                  key: const ValueKey('support_provider_endpoint'),
                  label: 'support_provider_endpoint'.tr(),
                  controller: _endpoint,
                  keyboardType: TextInputType.url,
                  inputFormatters: [LengthLimitingTextInputFormatter(512)],
                  helper: 'support_provider_destination_bounds'.tr(),
                )
              else
                SupportProviderNotice(
                  _endpoint.text.isEmpty
                      ? 'support_provider_model_for_endpoint'.tr()
                      : _endpoint.text,
                  key: const ValueKey('support_provider_endpoint'),
                ),
            ],
          ),
        ),
        if (widget.simple)
          SupportControlAvailability(
            enabled: enabled,
            child: MenuGroup(
              header: 'support_provider_profile'.tr(),
              items: [
                MenuFieldItem(
                  key: const ValueKey('support_provider_name'),
                  label: 'support_provider_name'.tr(),
                  controller: _name,
                  inputFormatters: [LengthLimitingTextInputFormatter(128)],
                ),
                MenuFieldItem(
                  key: const ValueKey('support_provider_model'),
                  label: 'support_provider_model'.tr(),
                  description: 'support_provider_model_manual'.tr(),
                  controller: _model,
                  inputFormatters: [LengthLimitingTextInputFormatter(192)],
                  onChanged: (_) => setState(_updateStandardEndpoint),
                ),
              ],
            ),
          )
        else
          SupportProviderFields(
            name: _name,
            model: _model,
            maxTokens: _tokens,
            contextSize: _context,
            temperature: _temperature,
            enabled: enabled,
            onModelChanged: (_) => setState(_updateStandardEndpoint),
          ),
        if (_error != null) SupportProviderNotice(_error!.tr()),
        SupportProviderButton(
          key: const ValueKey('support_provider_review'),
          label: 'support_provider_review'.tr(),
          icon: Icons.fact_check_outlined,
          primary: true,
          busy: c.busy,
          onTap: enabled ? _review : null,
        ),
        SupportProviderButton(
          key: const ValueKey('support_provider_form_cancel'),
          label:
              (widget.simple
                      ? 'support_provider_close'
                      : 'support_provider_back_list')
                  .tr(),
          onTap: !c.busy ? widget.onCancel ?? c.showList : null,
        ),
      ],
    );
  }
}
