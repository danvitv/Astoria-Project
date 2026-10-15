import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_text_field.dart';

/// Clears only a durably accepted draft, never a failed or superseded one.
class SupportComposerBar extends StatefulWidget {
  final TextEditingController controller;
  final Future<bool> Function(String) onSend;
  final bool busy;
  final String? sessionId;
  final VoidCallback? onRunQuickDiagnostics;

  const SupportComposerBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.busy = false,
    this.sessionId,
    this.onRunQuickDiagnostics,
  });

  @override
  State<SupportComposerBar> createState() => _SupportComposerBarState();
}

class _SupportComposerBarState extends State<SupportComposerBar> {
  bool _sending = false;
  String? _error;

  Future<void> _submit() async {
    if (_sending || widget.busy) return;
    final controller = widget.controller;
    final draft = controller.text;
    if (draft.trim().isEmpty) return;
    final sessionId = widget.sessionId;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final accepted = await widget.onSend(draft.trim());
      if (!mounted) return;
      if (accepted &&
          identical(controller, widget.controller) &&
          widget.sessionId == sessionId &&
          controller.text == draft) {
        controller.clear();
      } else if (!accepted) {
        _error =
            'Сообщение не сохранено. Черновик оставлен для повторной отправки.';
      }
    } catch (_) {
      if (!mounted) return;
      _error =
          'Не удалось сохранить сообщение. Черновик сохранён в поле ввода.';
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _sending || widget.busy;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.cs.outlineVariant),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null)
                  Text(_error!, style: TextStyle(color: context.cs.error)),
                Row(
                  children: [
                    if (widget.onRunQuickDiagnostics != null)
                      IconButton(
                        key: const ValueKey('support_composer_diag_btn'),
                        tooltip: 'О диагностике (исполнитель пока недоступен)',
                        icon: const Icon(Icons.troubleshoot_rounded, size: 20),
                        onPressed: busy ? null : widget.onRunQuickDiagnostics,
                      ),
                    Expanded(
                      child: GlazeTextField(
                        key: const ValueKey('support_composer_input'),
                        controller: widget.controller,
                        maxLines: 4,
                        isDense: true,
                        hint: 'Сообщение в историю (без API-ключей)…',
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('support_composer_send_btn'),
                      tooltip: 'Сохранить сообщение',
                      icon: busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded, size: 20),
                      onPressed: busy ? null : _submit,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
