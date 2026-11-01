import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../core/llm/provider_token_usage.dart';
import 'support_action_strip.dart';

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

/// Rebinding is permitted only after an explicit first-send consent, never for
/// an ordinary send whose provider, route or native owner changed underneath it.
enum SupportComposerAdmission { unchanged, consentGranted, rejected }

/// Clears only a durably accepted draft, never a failed or superseded one.
class SupportComposerBar extends StatefulWidget {
  final TextEditingController controller;
  final Future<bool> Function(String) onSend;
  final bool busy;
  final bool available;
  final String? sessionId;
  final VoidCallback? onRunQuickDiagnostics;
  final Future<bool> Function(SupportComposerDraft)? onNativeSend;

  /// First-send consent happens before binding the native draft. A successful
  /// permission change retires the old emitter; only the unchanged input may
  /// continue through the freshly displayed emitter after admission.
  final Future<SupportComposerAdmission> Function()? onBeforeNativeSend;
  final Future<bool> Function(String)? onLocalHelp;
  final VoidCallback? onStop;
  final Object? nativeOwner;
  final bool enterToSend;
  final VoidCallback? onCompact;
  final ProviderTokenUsage? usage;
  final bool usageIsCompaction;
  final List<Widget> auxiliaryActions;
  final bool useActionDrawer;

  const SupportComposerBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.busy = false,
    this.available = true,
    this.sessionId,
    this.onRunQuickDiagnostics,
    this.onNativeSend,
    this.onBeforeNativeSend,
    this.onLocalHelp,
    this.onStop,
    this.nativeOwner,
    this.enterToSend = true,
    this.onCompact,
    this.usage,
    this.usageIsCompaction = false,
    this.auxiliaryActions = const [],
    this.useActionDrawer = false,
  });

  @override
  SupportComposerBarState createState() => SupportComposerBarState();
}

class SupportComposerBarState extends State<SupportComposerBar> {
  bool _drawerOpen = false;

  /// Presentation back handling only; never stops or rebinds the active send.
  bool closeActions() {
    if (!_drawerOpen) return false;
    setState(() => _drawerOpen = false);
    return true;
  }

  bool _sending = false;
  String? _error;
  int _ownership = 0;
  int _inputOwnership = 0;
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
    final oldEmpty = _lastText.trim().isEmpty;
    _lastText = text;
    _draftRevision++;
    // Rebuild button availability only on empty/non-empty transitions, not
    // cursor, selection or every IME update (as in our ChatInputBar).
    if (text.trim().isEmpty != oldEmpty) setState(() {});
  }

  @override
  void dispose() {
    _inputFocus.dispose();
    widget.controller.removeListener(_draftChanged);
    _ownership++;
    _inputOwnership++;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SupportComposerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        !identical(oldWidget.controller, widget.controller)) {
      _inputOwnership++;
    }
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
    var ownership = _ownership;
    final inputOwnership = _inputOwnership;
    final revision = _draftRevision;
    var nativeOwner = emitted.nativeOwner;
    var nativeSend = local ? null : emitted.onNativeSend;
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
      if (!local && emitted.onBeforeNativeSend != null) {
        final admission = await emitted.onBeforeNativeSend!();
        if (admission == SupportComposerAdmission.rejected ||
            !mounted ||
            inputOwnership != _inputOwnership ||
            revision != _draftRevision ||
            !identical(controller, widget.controller) ||
            widget.sessionId != sessionId ||
            controller.text != draft) {
          return;
        }
        if (admission == SupportComposerAdmission.consentGranted) {
          // Native permission admission may legitimately replace the emitter.
          // Rebind only here, before creating a draft or authorizing any send.
          ownership = _ownership;
          nativeOwner = widget.nativeOwner;
          nativeSend = widget.onNativeSend;
        } else if (!ownsDraft()) {
          return;
        }
      }
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
    final keyboardUp = View.of(context).viewInsets.bottom > 0;
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

    final hasDraft = widget.controller.text.trim().isNotEmpty;
    final actions = <Widget>[
      ...widget.auxiliaryActions,
      SupportActionTile(
        key: const ValueKey('support_composer_compact_btn'),
        icon: Icons.compress_rounded,
        label: 'Компакт',
        tooltip: 'Сжать старый контекст выбранной моделью; история останется',
        busy: busy && widget.usageIsCompaction,
        onTap: busy || !widget.available ? null : widget.onCompact,
      ),
      if (widget.onLocalHelp != null)
        SupportActionTile(
          key: const ValueKey('support_composer_local_help_btn'),
          icon: Icons.menu_book_outlined,
          label: 'Помощь',
          tooltip: 'Локальная помощь без сети — использует текст в поле ввода',
          onTap: busy || !widget.available || !hasDraft
              ? null
              : () => _submit(emitted, emittedOwnership, local: true),
        ),
      if (widget.onRunQuickDiagnostics != null)
        SupportActionTile(
          key: const ValueKey('support_composer_diag_btn'),
          icon: Icons.troubleshoot_rounded,
          label: 'Диагностика',
          tooltip:
              'Обсудить диагностику; чтение использует общий доступ к данным',
          onTap: busy || !widget.available
              ? null
              : widget.onRunQuickDiagnostics,
        ),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Same arrangement as our ChatInputBar: input pill first, actions
            // underneath. Astoria retains its own exact draft acceptance rules.
            GlassSurface(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: context.cs.outlineVariant),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null)
                      Text(_error!, style: TextStyle(color: context.cs.error)),
                    Focus(
                      onKeyEvent: draftKey,
                      child: GlazeTextField(
                        key: const ValueKey('support_composer_input'),
                        controller: widget.controller,
                        focusNode: _inputFocus,
                        maxLines: keyboardUp ? 2 : 4,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        isDense: true,
                        hint: 'Сообщение Астории (без API-ключей)…',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.useActionDrawer)
                  Semantics(
                    expanded: _drawerOpen,
                    child: IconButton(
                      key: const ValueKey('support_drawer_toggle'),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      tooltip: 'Действия Астории',
                      isSelected: _drawerOpen,
                      icon: const Icon(Icons.auto_awesome_rounded),
                      onPressed: () =>
                          setState(() => _drawerOpen = !_drawerOpen),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
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
                ),
                IconButton(
                  key: const ValueKey('support_composer_send_btn'),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
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
                  onPressed: busy || !widget.available || !hasDraft
                      ? null
                      : () => _submit(emitted, emittedOwnership),
                ),
                if (widget.onStop != null)
                  IconButton(
                    key: const ValueKey('support_composer_stop_btn'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: 'Остановить отправку',
                    icon: Icon(Icons.stop_rounded, color: context.cs.error),
                    // Never a busy/disabled action: works before HTTP and
                    // while a quiet SSE response or settlement is pending.
                    onPressed: widget.onStop,
                  ),
              ],
            ),
            if (widget.useActionDrawer)
              // Only auxiliary content yields height under the actual screen
              // constraint. Input, Send and live Stop remain fixed siblings.
              Flexible(
                fit: FlexFit.loose,
                child: SupportActionDrawer(
                  open: _drawerOpen,
                  onClose: closeActions,
                  children: actions,
                ),
              )
            else
              SupportActionStrip(children: actions),
          ],
        ),
      ),
    );
  }
}
