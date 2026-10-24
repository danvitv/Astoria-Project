import 'package:flutter/material.dart';

import '../../../core/db/repositories/support_consent_selection_repo.dart';
import '../../../core/models/support_consent_selection.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../services/support_native_consent_controller.dart';
import '../services/support_native_runtime.dart';

/// Native metadata proposal only. The caller confirms its opaque choice once.
class SupportSessionScopeSheet extends StatefulWidget {
  const SupportSessionScopeSheet({
    super.key,
    required this.controller,
    required this.review,
    required this.repo,
    required this.source,
    required this.isCurrent,
  });
  final SupportNativeConsentController controller;
  final SupportNativeReview review;
  final SupportConsentSelectionRepo repo;
  final SupportConsentSelectionSource source;
  final bool Function() isCurrent;

  @override
  State<SupportSessionScopeSheet> createState() => _SessionScopeState();
}

class _SessionScopeState extends State<SupportSessionScopeSheet> {
  SupportConsentSessionPage? _page;
  SupportNativeSessionChoice? _choice;
  bool _busy = true, _decided = false;
  bool _catalogLoading = true;
  String? _pendingSession;
  int _read = 0;
  String? _notice;
  bool _retired = false;
  ModalRoute<void>? _route;

  bool get current =>
      mounted &&
      !_retired &&
      !_decided &&
      (_route?.isCurrent ?? true) &&
      widget.isCurrent() &&
      !_retired;

  bool _sameOwner(SupportSessionScopeSheet original) =>
      identical(original.controller, widget.controller) &&
      identical(original.review, widget.review) &&
      identical(original.repo, widget.repo) &&
      original.source == widget.source &&
      identical(original.isCurrent, widget.isCurrent);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<void>(context);
  }

  @override
  void didUpdateWidget(covariant SupportSessionScopeSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameOwner(oldWidget)) {
      _retired = true;
      _read++;
      _choice = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(0));
  }

  Future<void> _load(int offset) async {
    if (!current) return;
    final original = widget;
    final read = ++_read;
    setState(() {
      _busy = true;
      _catalogLoading = true;
      _pendingSession = null;
      _choice = null;
      _notice = null;
    });
    try {
      if (original.source == SupportConsentSelectionSource.support) {
        final choice = await original.controller.prepareSessionHistory(
          original.review,
          original.source,
          original.review.view.sessionId,
        );
        if (!current || read != _read || !_sameOwner(original)) return;
        setState(() => _choice = choice);
      } else {
        final page = await original.repo.listRoleplaySessions(offset: offset);
        if (!current || read != _read || !_sameOwner(original)) return;
        setState(() {
          _page = page;
          _catalogLoading = false;
        });
        final oldId =
            original.controller.runtime.localContext.scope?.gameSessionId;
        final proposed =
            page.items.where((v) => v.sessionId == oldId).firstOrNull ??
            page.items.firstOrNull;
        if (proposed != null) {
          _pendingSession = proposed.sessionId;
          final choice = await original.controller.prepareSessionHistory(
            original.review,
            original.source,
            proposed.sessionId,
          );
          if (!current || read != _read || !_sameOwner(original)) return;
          setState(() => _choice = choice);
        }
      }
      if (current && read == _read && _choice == null) {
        setState(() => _notice = 'Нет доступной сессии. История не прочитана.');
      }
    } catch (_) {
      if (current && read == _read) {
        setState(() => _notice = 'Не удалось проверить область сессии.');
      }
    } finally {
      if (current && read == _read) {
        setState(() {
          _busy = false;
          _catalogLoading = false;
          _pendingSession = null;
        });
      }
    }
  }

  Future<void> _choose(SupportConsentSessionOption option) async {
    if (!current ||
        _catalogLoading ||
        (_busy && _pendingSession == option.sessionId)) {
      return;
    }
    final original = widget;
    final read = ++_read;
    setState(() {
      _busy = true;
      _pendingSession = option.sessionId;
      _choice = null;
      _notice = null;
    });
    try {
      final choice = await original.controller.prepareSessionHistory(
        original.review,
        original.source,
        option.sessionId,
      );
      if (!current || read != _read || !_sameOwner(original)) return;
      setState(() {
        _choice = choice;
        if (choice == null) _notice = 'Сессия изменилась или недоступна.';
      });
    } catch (_) {
      if (current && read == _read) {
        setState(() => _notice = 'Не удалось проверить выбранную сессию.');
      }
    } finally {
      if (current && read == _read) {
        setState(() {
          _busy = false;
          _pendingSession = null;
        });
      }
    }
  }

  void _confirm() {
    final original = _choice;
    if (!current || _busy || original?.isCurrent != true) return;
    _decided = true;
    Navigator.of(context).pop(original);
  }

  @override
  void deactivate() {
    _retired = true;
    _read++;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    final choice = current && _choice?.isCurrent == true ? _choice : null;
    return SheetView(
      title: 'Область сессии',
      showBack: true,
      onBack: () => Navigator.of(context).pop(),
      body: Builder(
        builder: (bodyContext) => ListView(
          key: const ValueKey('support_session_scope_scroll'),
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(bodyContext).top + 12,
            16,
            MediaQuery.paddingOf(bodyContext).bottom + 24,
          ),
          children: [
            Text(
              widget.source == SupportConsentSelectionSource.support
                  ? 'Предлагаю текущую сессию с Асторией.'
                  : 'Предлагаю ранее выбранную или последнюю доступную ролевую сессию. Можно выбрать другую.',
            ),
            const SizedBox(height: 12),
            if (!current)
              const Text(
                'Область или настройки изменились. Закрой это окно '
                'и открой выбор снова — старое подтверждение не действует.',
              ),
            const Text(
              'Это область всей сессии, включая её новые обычные сообщения. '
              'Выбор области не включает чтение, передачу модели или репорт. '
              'Скрытые варианты, вложения, ключи и сырые промпты сюда не входят. '
              'Каждый запрос модели всё равно требует точного обзора и подтверждения.',
            ),
            if (_page case final page?)
              IgnorePointer(
                ignoring: !current || _catalogLoading,
                child: MenuGroup(
                  header: 'Доступные сессии — только метаданные',
                  items: [
                    for (final option in page.items)
                      MenuItem(
                        key: ValueKey(
                          'support_session_scope_option_${option.sessionId}',
                        ),
                        label: option.label,
                        subtitle:
                            'Сохранённых сообщений: ${option.messageCount ?? 'неизвестно'}',
                        onTap: () => _choose(option),
                      ),
                  ],
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_notice != null) Text(_notice!),
            if (choice != null) ...[
              const SizedBox(height: 16),
              Text(
                choice.metadata.roleplaySession?.label ??
                    'Текущая сессия Астории',
                key: const ValueKey('support_session_scope_proposal'),
              ),
              const SizedBox(height: 8),
              GlazeActionButton(
                key: const ValueKey('support_session_scope_confirm'),
                label: 'Добавить сессию в область доступа',
                icon: Icons.check_rounded,
                expand: true,
                onTap: !_busy ? _confirm : null,
              ),
            ],
            if (_page?.nextOffset case final int offset)
              GlazeActionButton(
                key: const ValueKey('support_session_scope_next'),
                icon: Icons.navigate_next_rounded,
                label: 'Другие сессии',
                onTap: current && !_busy ? () => _load(offset) : null,
              ),
          ],
        ),
      ),
    );
  }
}
