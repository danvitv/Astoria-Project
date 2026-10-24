import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../core/llm/provider_token_usage.dart';

/// Exact emitted draft ownership, including content ABA before acceptance.
final class SupportComposerDraft {
  const SupportComposerDraft({
    required this.text,
    required this.revision,
    required this.isCurrent,
  });
  final String text;
  final int revision;
  final bool Function() isCurrent;
}

/// Clears only a durably accepted draft, never a failed or superseded one.
class SupportComposerBar extends StatefulWidget {
  final TextEditingController controller;
  final Future<bool> Function(String) onSend;
  final bool busy;
  final bool available;
  final String? sessionId;
  final VoidCallback? onRunQuickDiagnostics;
  final Future<bool> Function(SupportComposerDraft)? onNativeSend;
  final Future<bool> Function(String)? onLocalHelp;
  final VoidCallback? onStop;
  final Object? nativeOwner;
  final bool enterToSend;
  final VoidCallback? onCompact;
  final ProviderTokenUsage? usage;
  final bool usageIsCompaction;

  const SupportComposerBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.busy = false,
    this.available = true,
    this.sessionId,
    this.onRunQuickDiagnostics,
    this.onNativeSend,
    this.onLocalHelp,
    this.onStop,
    this.nativeOwner,
    this.enterToSend = true,
    this.onCompact,
    this.usage,
    this.usageIsCompaction = false,
  });

  @override
  State<SupportComposerBar> createState() => _SupportComposerBarState();
}

class _SupportComposerBarState extends State<SupportComposerBar> {
  bool _sending = false;
  String? _error;
  int _ownership = 0;
  int _draftRevision = 0;
  late String _lastText;
  final _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_draftChanged);
  }

  void _draftChanged() {
    final text = widget.controller.text;
    if (text == _lastText) return;
    _lastText = text;
    _draftRevision++;
  }

  @override
  void dispose() {
    _inputFocus.dispose();
    widget.controller.removeListener(_draftChanged);
    _ownership++;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SupportComposerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        !identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.nativeOwner, widget.nativeOwner)) {
      _ownership++;
      _error = null;
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_draftChanged);
      _lastText = widget.controller.text;
      _draftRevision++;
      widget.controller.addListener(_draftChanged);
    }
  }

  Future<void> _submit(
    SupportComposerBar emitted,
    int emittedOwnership, {
    bool local = false,
  }) async {
    if (_sending ||
        widget.busy ||
        !widget.available ||
        emittedOwnership != _ownership ||
        !identical(emitted.controller, widget.controller) ||
        !identical(emitted.nativeOwner, widget.nativeOwner) ||
        emitted.sessionId != widget.sessionId) {
      return;
    }
    final controller = emitted.controller;
    final draft = controller.text;
    if (draft.trim().isEmpty) return;
    final sessionId = emitted.sessionId;
    final ownership = _ownership;
    final revision = _draftRevision;
    final nativeOwner = emitted.nativeOwner;
    final nativeSend = local ? null : emitted.onNativeSend;
    final send = local ? emitted.onLocalHelp : emitted.onSend;
    bool ownsDraft() =>
        mounted &&
        ownership == _ownership &&
        revision == _draftRevision &&
        identical(nativeOwner, widget.nativeOwner) &&
        identical(controller, widget.controller) &&
        widget.sessionId == sessionId &&
        controller.text == draft;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final accepted = nativeSend != null
          ? await nativeSend(
              SupportComposerDraft(
                text: draft.trim(),
                revision: revision,
                isCurrent: ownsDraft,
              ),
            )
          : await send!(draft.trim());
      if (!mounted) return;
      if (accepted && ownsDraft()) {
        controller.clear();
      } else if (!accepted && ownsDraft() && nativeSend == null) {
        _error =
            'Сообщение не сохранено. Черновик оставлен для повторной отправки.';
      }
    } catch (_) {
      if (!ownsDraft()) return;
      _error =
          'Не удалось сохранить сообщение. Черновик сохранён в поле ввода.';
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _sending || widget.busy;
    final emitted = widget;
    final emittedOwnership = _ownership;
    KeyEventResult draftKey(FocusNode node, KeyEvent event) {
      if (!mounted ||
          !node.hasFocus ||
          event is! KeyDownEvent ||
          !identical(emitted, widget) ||
          emittedOwnership != _ownership ||
          emitted.enterToSend != widget.enterToSend ||
          !emitted.enterToSend ||
          (event.logicalKey != LogicalKeyboardKey.enter &&
              event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
          HardwareKeyboard.instance.isShiftPressed ||
          (widget.controller.value.composing.isValid &&
              !widget.controller.value.composing.isCollapsed) ||
          ((defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS) &&
              View.of(context).viewInsets.bottom > 0)) {
        return KeyEventResult.ignored;
      }
      unawaited(_submit(emitted, emittedOwnership));
      return KeyEventResult.handled;
    }

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
                    if (widget.onCompact != null)
                      IconButton(
                        key: const ValueKey('support_composer_compact_btn'),
                        tooltip:
                            'Сжать старый контекст выбранной моделью; история останется',
                        icon: const Icon(Icons.compress_rounded, size: 20),
                        onPressed: busy || !widget.available
                            ? null
                            : widget.onCompact,
                      ),
                    if (widget.onRunQuickDiagnostics != null)
                      IconButton(
                        key: const ValueKey('support_composer_diag_btn'),
                        tooltip: 'О диагностике (исполнитель пока недоступен)',
                        icon: const Icon(Icons.troubleshoot_rounded, size: 20),
                        onPressed: busy ? null : widget.onRunQuickDiagnostics,
                      ),
                    if (widget.onLocalHelp != null)
                      IconButton(
                        key: const ValueKey('support_composer_local_help_btn'),
                        tooltip: 'Локальная помощь без сети',
                        icon: const Icon(Icons.menu_book_outlined, size: 20),
                        onPressed: busy || !widget.available
                            ? null
                            : () => _submit(
                                emitted,
                                emittedOwnership,
                                local: true,
                              ),
                      ),
                    Expanded(
                      child: Focus(
                        onKeyEvent: draftKey,
                        child: GlazeTextField(
                          key: const ValueKey('support_composer_input'),
                          controller: widget.controller,
                          focusNode: _inputFocus,
                          maxLines: 4,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          isDense: true,
                          hint: 'Сообщение Астории (без API-ключей)…',
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('support_composer_send_btn'),
                      tooltip: widget.available
                          ? (widget.onNativeSend != null
                                ? 'Отправить модели'
                                : 'Сохранить сообщение')
                          : 'Отправка недоступна',
                      icon: busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded, size: 20),
                      onPressed: busy || !widget.available
                          ? null
                          : () => _submit(emitted, emittedOwnership),
                    ),
                    if (widget.onStop != null)
                      IconButton(
                        key: const ValueKey('support_composer_stop_btn'),
                        tooltip: 'Остановить отправку',
                        icon: Icon(Icons.stop_rounded, color: context.cs.error),
                        // Never a busy/disabled action: works before HTTP and
                        // while a quiet SSE response or settlement is pending.
                        onPressed: widget.onStop,
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${widget.usageIsCompaction ? 'Компакт' : 'Последний запрос'} · '
                    'вход: ${widget.usage?.inputTokens ?? 'нет данных'} · '
                    'выход: ${widget.usage?.outputTokens ?? 'нет данных'} · '
                    'всего: ${widget.usage?.totalTokens ?? 'нет данных'}',
                    key: const ValueKey('support_request_token_usage'),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
