import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_novelai_auth_provider.dart';

/// Blank replacement draft. Neither hydration nor reveal of protected keys.
class ImageNovelAiKeyField extends ConsumerStatefulWidget {
  const ImageNovelAiKeyField({
    super.key,
    required this.endpoint,
    required this.model,
    required this.onAdmission,
  });
  final String endpoint, model;
  final VoidCallback onAdmission;
  @override
  ConsumerState<ImageNovelAiKeyField> createState() =>
      _ImageNovelAiKeyFieldState();
}

class _ImageNovelAiKeyFieldState extends ConsumerState<ImageNovelAiKeyField> {
  final _draft = TextEditingController();
  bool _busy = false;
  Future<void> _commit({required bool clear}) async {
    if (!clear && _draft.text.trim().isEmpty) return;
    final notifier = ref.read(imageNovelAiAuthProvider.notifier);
    final input = clear ? '' : _draft.text;
    widget.onAdmission();
    setState(() => _busy = true);
    final pending = notifier.setApiKey(
      input,
      endpoint: widget.endpoint,
      model: widget.model,
    );
    _draft.clear();
    try {
      await pending;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(imageNovelAiAuthProvider).value;
    return MenuFieldItem(
      label: 'NovelAI API Key',
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
          ? 'Key configured for this endpoint and model (not validated)'
          : 'No key configured for this endpoint and model',
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
