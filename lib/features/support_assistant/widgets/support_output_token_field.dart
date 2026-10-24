import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../state/support_workspace_provider.dart';

/// One manual output limit. The original display owns the whole edit.
class SupportOutputTokenField extends StatefulWidget {
  const SupportOutputTokenField({
    super.key,
    required this.value,
    required this.notifier,
    required this.intent,
  });

  final int value;
  final SupportWorkspaceNotifier notifier;
  final SupportWorkspaceSettingsIntent? intent;

  @override
  State<SupportOutputTokenField> createState() =>
      _SupportOutputTokenFieldState();
}

class _SupportOutputTokenFieldState extends State<SupportOutputTokenField> {
  static const _hint = '-1 — не передавать лимит ответа модели.';
  static const _invalid = 'Введи -1 или целое число от 1 до 2147483647.';
  final _focus = FocusNode();
  late final TextEditingController _controller;
  SupportWorkspaceSettingsIntent? _original;
  late SupportWorkspaceNotifier _notifier;
  bool _dirty = false;
  String? _error;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _original = widget.intent;
    _notifier = widget.notifier;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(covariant SupportOutputTokenField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuilds must never rebind a draft already owned by a focused display.
    if (!_focus.hasFocus && !_dirty) {
      _controller.text = widget.value.toString();
      _original = widget.intent;
      _notifier = widget.notifier;
      _error = null;
    }
  }

  int? _parse() {
    final text = _controller.text.trim();
    if (!RegExp(r'^-?[0-9]+$').hasMatch(text)) return null;
    final value = int.tryParse(text);
    if (value == null || (value != -1 && (value < 1 || value > 0x7fffffff))) {
      return null;
    }
    return value;
  }

  void _focusChanged(bool focused) {
    if (!mounted) return;
    if (focused) {
      // An invalid unfinished draft retains its original owner on refocus too.
      if (!_dirty) {
        _original = widget.intent;
        _notifier = widget.notifier;
      }
      return;
    }
    if (!_dirty) return;
    final value = _parse();
    if (value == null) {
      setState(() => _error = _invalid);
      return;
    }
    final original = _original;
    if (original == null || !original.isCurrent || _route?.isActive == false) {
      setState(() => _error = 'Предложение устарело. Открой его заново.');
      return;
    }
    _dirty = false;
    unawaited(_notifier.setMaxTokens(value, intent: original));
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onFocusChange: _focusChanged,
    child: IgnorePointer(
      ignoring: widget.intent?.isCurrent != true,
      child: MenuFieldItem(
        label: 'Лимит ответа',
        description: 'Токены',
        controller: _controller,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        helper: _error ?? _hint,
        helperIsError: _error != null,
        onChanged: (_) {
          if (!mounted) return;
          setState(() {
            _dirty = true;
            _error = _parse() == null ? _invalid : null;
          });
        },
      ),
    ),
  );
}
