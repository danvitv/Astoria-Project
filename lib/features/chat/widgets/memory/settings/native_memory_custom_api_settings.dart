import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/credentials/memory_custom_api_credential_owner.dart';
import '../../../../../core/models/memory_book_api_settings.dart';
import '../../../../../core/state/memory_custom_api_credentials_provider.dart';
import '../../../../../core/state/pipeline_settings_provider.dart';
import '../../../../../shared/widgets/glaze_action_button.dart';
import '../../../../../shared/widgets/menu_group.dart';

/// Native secret entry is an explicit action, separate from ordinary sheet Save.
/// Never prefill a saved key or put entered text in the settings form DTO.
class NativeMemoryCustomApiSettings extends ConsumerStatefulWidget {
  const NativeMemoryCustomApiSettings({
    super.key,
    required this.api,
    required this.onChanged,
  });
  final MemoryBookApiSettings api;
  final ValueChanged<MemoryBookApiSettings> onChanged;
  @override
  ConsumerState<NativeMemoryCustomApiSettings> createState() =>
      _NativeMemoryCustomApiSettingsState();
}

class _NativeMemoryCustomApiSettingsState
    extends ConsumerState<NativeMemoryCustomApiSettings> {
  final _key = TextEditingController();
  late final _endpoint = TextEditingController(
    text: widget.api.generationEndpoint,
  );
  late final _model = TextEditingController(text: widget.api.generationModel);
  bool _busy = false;
  String _status = 'Save the connection before setting its key.';

  @override
  void initState() {
    super.initState();
    _key.addListener(_keyChanged);
  }

  void _keyChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _key.removeListener(_keyChanged);
    _key.clear();
    _key.dispose();
    _endpoint.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _saveConnection() async {
    final notifier = ref.read(pipelineSettingsProvider.notifier);
    final settings = ref
        .read(pipelineSettingsProvider)
        .copyWith(memoryBookApi: widget.api);
    setState(() => _busy = true);
    try {
      await notifier.save(settings);
      if (!mounted || widget.api != settings.memoryBookApi) return;
      final summary = await ref
          .read(memoryCustomApiCredentialOwnerProvider)
          .load();
      if (!mounted || widget.api != settings.memoryBookApi) return;
      setState(
        () => _status = summary.unavailable
            ? 'Key status was not confirmed. Use Set key or Clear key.'
            : summary.configured
            ? 'Key configured for this exact connection.'
            : 'Key not configured for this connection.',
      );
    } catch (_) {
      if (mounted)
        setState(
          () => _status =
              'Connection save was not confirmed. Reopen settings before retrying.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _writeKey({required bool clear}) async {
    final saved = ref.read(pipelineSettingsProvider).memoryBookApi;
    final settings = clear ? saved : widget.api;
    if ((!clear && (settings != saved || _key.text.trim().isEmpty)) || _busy)
      return;
    final owner = ref.read(memoryCustomApiCredentialOwnerProvider);
    // Capture the native input/producer/settings lease BEFORE the first await.
    final pending = owner.setApiKey(
      clear ? '' : _key.text,
      settings: settings,
      isCurrent: () => mounted && (clear || widget.api == settings),
    );
    _key.clear();
    setState(() => _busy = true);
    final summary = await pending;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _describe(summary, clear);
    });
  }

  static String _describe(MemoryCustomApiAuthSummary summary, bool clear) {
    if (summary.verifiedCommit && summary.retired) {
      return 'Key write verified; settings changed before completion. Reopen settings.';
    }
    if (summary.unknownCommit)
      return 'Key write outcome is unknown. Nothing was rolled back.';
    if (summary.unavailable) return 'Key action was refused before writing.';
    return clear
        ? 'Key cleared in secure storage.'
        : 'Key stored for this exact connection.';
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(pipelineSettingsProvider).memoryBookApi;
    final custom = widget.api.generationSource == 'custom';
    final canSet =
        custom && saved == widget.api && !_busy && _key.text.trim().isNotEmpty;
    return MenuGroup(
      items: [
        MenuSwitchItem(
          label: 'Native custom Memory API',
          value: custom,
          description:
              'A separate key bound to the exact custom POST destination.',
          onChanged: (on) => widget.onChanged(
            widget.api.copyWith(
              generationSource: on ? 'custom' : 'current',
              generationApiKey: '',
            ),
          ),
        ),
        if (custom) ...[
          MenuFieldItem(
            label: 'Exact POST URL',
            controller: _endpoint,
            onChanged: (value) => widget.onChanged(
              widget.api.copyWith(
                generationEndpoint: value,
                generationApiKey: '',
              ),
            ),
          ),
          MenuFieldItem(
            label: 'Model',
            controller: _model,
            onChanged: (value) => widget.onChanged(
              widget.api.copyWith(generationModel: value, generationApiKey: ''),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: GlazeActionButton(
              icon: Icons.save_outlined,
              label: 'Save custom connection',
              busy: _busy,
              onTap: _busy ? null : _saveConnection,
            ),
          ),
          MenuFieldItem(
            label: 'New API key',
            controller: _key,
            obscure: true,
            description: _status,
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 12,
              children: [
                GlazeActionButton(
                  icon: Icons.key,
                  label: 'Set key',
                  busy: _busy,
                  onTap: canSet ? () => _writeKey(clear: false) : null,
                ),
                GlazeActionButton(
                  icon: Icons.key_off,
                  label: 'Clear key',
                  tone: GlazeActionTone.destructive,
                  busy: _busy,
                  onTap: _busy ? null : () => _writeKey(clear: true),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
