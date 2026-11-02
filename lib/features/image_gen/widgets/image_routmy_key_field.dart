import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_provider.dart';

/// A native replacement draft, never a hydrated secret or settings snapshot.
class ImageRoutmyKeyField extends ConsumerStatefulWidget {
  const ImageRoutmyKeyField({super.key, required this.onAdmission});
  final VoidCallback onAdmission;

  @override
  ConsumerState<ImageRoutmyKeyField> createState() => _ImageRoutmyKeyFieldState();
}

class _ImageRoutmyKeyFieldState extends ConsumerState<ImageRoutmyKeyField> {
  final _draft = TextEditingController();
  bool _busy = false;

  Future<void> _commit({required bool clear}) async {
    if (!clear && _draft.text.trim().isEmpty) return;
    final notifier = ref.read(imageRoutmyAuthProvider.notifier);
    widget.onAdmission();
    final input = clear ? '' : _draft.text;
    setState(() => _busy = true);
    // Owner captures the native intent before awaiting; no placeholder or
    // encrypted envelope is ever interpreted as a user's replacement key.
    final pending = notifier.setApiKey(input);
    _draft.clear();
    await pending;
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(imageRoutmyAuthProvider).value;
    return MenuFieldItem(
      label: 'rout.my API Key',
      controller: _draft,
      obscure: true,
      placeholder: 'Enter a replacement key',
      helper: summary == null
          ? 'Reading protected storage…'
          : summary.unavailable
          ? 'Protected storage unavailable; no legacy fallback'
          : summary.configured
          ? summary.preferencesChanged
              ? 'Key stored (not validated); image settings changed during save'
              : 'Key configured (not validated)'
          : 'No key configured',
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
