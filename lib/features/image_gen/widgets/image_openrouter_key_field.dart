import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_provider.dart';

/// Blank native replacement draft; never a readable/hydrated settings key.
class ImageOpenRouterKeyField extends ConsumerStatefulWidget {
  const ImageOpenRouterKeyField({
    super.key,
    required this.endpoint,
    required this.onAdmission,
  });
  final String endpoint;
  final VoidCallback onAdmission;

  @override
  ConsumerState<ImageOpenRouterKeyField> createState() =>
      _ImageOpenRouterKeyFieldState();
}

class _ImageOpenRouterKeyFieldState
    extends ConsumerState<ImageOpenRouterKeyField> {
  final _draft = TextEditingController();
  bool _busy = false;

  Future<void> _commit({required bool clear}) async {
    if (!clear && _draft.text.trim().isEmpty) return;
    final notifier = ref.read(imageOpenRouterAuthProvider.notifier);
    final endpoint = widget.endpoint;
    final input = clear ? '' : _draft.text;
    widget.onAdmission();
    setState(() => _busy = true);
    final pending = notifier.setApiKey(input, endpoint: endpoint);
    _draft.clear();
    try {
      await pending;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(imageOpenRouterAuthProvider).value;
    return MenuFieldItem(
      label: 'OpenRouter API Key',
      controller: _draft,
      obscure: true,
      placeholder: 'Enter a replacement key',
      helper: summary == null
          ? 'Reading protected storage…'
          : summary.unknownCommit
          ? 'Protected write outcome unknown; no legacy fallback'
          : summary.unavailable
          ? 'Protected storage unavailable; no legacy fallback'
          : summary.verifiedCommit && summary.retired
          ? 'Key stored (not validated); image settings changed during save'
          : summary.retired
          ? 'Key action retired; no write admitted'
          : summary.configured
          ? 'Key configured for this endpoint (not validated)'
          : 'No key configured for this endpoint',
      helperIsError: summary?.unavailable == true,
      suffix: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Replace key',
            icon: const Icon(Icons.save_outlined),
            onPressed: _busy ? null : () => _commit(clear: false),
          ),
          IconButton(
            tooltip: 'Clear protected key',
            icon: const Icon(Icons.key_off_outlined),
            onPressed: _busy ? null : () => _commit(clear: true),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }
}
