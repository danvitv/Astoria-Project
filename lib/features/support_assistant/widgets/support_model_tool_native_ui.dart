import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../models/support_app_action_context.dart';
import '../models/support_model_tool_ui_ports.dart';
import '../models/support_source_tool_names.dart';

/// Actual original-screen UI. Route changes latch a revision, including A→B→A.
/// No model-selected path, generic approval callback or Send confirmation.
final class SupportModelToolNativeUi
    implements SupportAppConfirmationPort, SupportAppNavigationPort {
  SupportModelToolNativeUi({
    required this.context,
    required this.isOriginalUiCurrent,
  }) : _router = GoRouter.of(context) {
    _location = _router.routeInformationProvider.value.uri;
    _router.routeInformationProvider.addListener(_observeRoute);
  }
  final BuildContext context;
  final bool Function() isOriginalUiCurrent;
  final GoRouter _router;
  late Uri _location;
  int _revision = 0;
  bool _alive = true;
  final _pending = <void Function()>{};

  SupportModelToolUiPorts get ports =>
      SupportModelToolUiPorts(confirmation: this, navigation: this);

  bool get _current => _alive && context.mounted && isOriginalUiCurrent();
  bool get isCurrent => _current;

  void _observeRoute() {
    final next = _router.routeInformationProvider.value.uri;
    if (next == _location) return;
    _location = next;
    _revision++;
    _alive = false;
    for (final close in List.of(_pending)) {
      close();
    }
  }

  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    if (!_current || !request.current) return null;
    final revision = _revision, location = _location;
    bool original() =>
        _current && _revision == revision && _location == location;
    var open = true, decided = false, dismissed = false;
    SupportAppConfirmationLease? accepted;
    final navigator = Navigator.of(context, rootNavigator: true);
    final localizations = MaterialLocalizations.of(context);
    late final ModalBottomSheetRoute<void> route;
    void dismiss() {
      // Retain identities before push; mounted sheet elements may already be
      // deactivated during owner disposal and cannot resolve ancestors safely.
      if (dismissed ||
          !navigator.mounted ||
          !identical(route.navigator, navigator)) {
        return;
      }
      if (WidgetsBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        // A navigator can also be mounted but deactivated in this frame. Let
        // its teardown finish before attempting to mutate the retained route.
        WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
        return;
      }
      if (route.isCurrent) {
        dismissed = true;
        navigator.pop();
      } else if (route.isActive) {
        dismissed = true;
        navigator.removeRoute(
          route,
        ); // Only this original sheet, never route B.
      }
    }

    void close() {
      if (!open) return;
      open = false;
      dismiss();
    }

    try {
      route = ModalBottomSheetRoute<void>(
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
        barrierLabel: localizations.modalBarrierDismissLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(
          localizations.bottomSheetLabel,
        ),
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              if (!open) {
                WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
              }
              final sourceRead = SupportSourceToolNames.body.contains(
                request.action,
              );
              final cancel = GlazeActionButton(
                key: const ValueKey('support_tool_confirmation_cancel'),
                label: 'Отмена',
                icon: Icons.close_rounded,
                onTap: () {
                  if (!open || decided) return;
                  decided = true;
                  close();
                },
              );
              final accept = GlazeActionButton(
                key: const ValueKey('support_tool_confirmation_accept'),
                maxLabelLines: sourceRead ? null : 1,
                label: sourceRead ? 'Прочитать и передать модели' : 'Применить',
                icon: Icons.check_rounded,
                onTap: () {
                  if (!open || decided || !original() || !request.current) {
                    return;
                  }
                  decided = true;
                  // ONLY the actual final gesture creates this exact once lease.
                  accepted = SupportAppConfirmationLease(
                    request: request,
                    isOriginalUiCurrent: original,
                  );
                  close();
                },
              );
              // Keep the disclosure verb visible on phone-sized screens instead
              // of ellipsizing it beside Cancel.
              final footer = sourceRead && constraints.maxWidth < 600
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [accept, const SizedBox(height: 12), cancel],
                    )
                  : Row(
                      children: [
                        Expanded(child: cancel),
                        const SizedBox(width: 12),
                        Expanded(flex: sourceRead ? 2 : 1, child: accept),
                      ],
                    );
              // The declarative short-form sheet scrolls its entire child. This
              // exact preview can be long, so constrain the kit frame instead and
              // keep the original gesture controls outside the preview scroll.
              return GlazeBottomSheetFrame(
                maxHeight: constraints.maxHeight * 0.95,
                child: SizedBox(
                  height: constraints.maxHeight * 0.8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Text(
                          sourceRead
                              ? 'Чтение источника для выбранной модели'
                              : request.action.startsWith('astoria_connection_')
                              ? 'Изменение подключения'
                              : 'Изменение данных Astoria',
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey(
                            'support_tool_confirmation_preview',
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            sourceRead
                                ? _sourceReadPreview(request)
                                : 'Действие: ${request.action}\nЦель: ${request.target}\n'
                                      'Аргументы: ${jsonEncode(request.arguments)}\n'
                                      'Последствия: ${jsonEncode(request.preview)}\n'
                                      '${request.action.startsWith('astoria_connection_') ? 'Ключ не вводится, активное подключение не выбирается, сеть не проверяется.' : 'Применяется только показанная операция и её последствия. Доступ к существующему приватному содержимому не выдаётся.'}',
                          ),
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: footer,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      _pending.add(close);
      unawaited(request.context.cancelToken.whenCancel.then((_) => close()));
      unawaited(navigator.push<void>(route));
      // Join this exact route's disposal as well as its normal pop. Destroying
      // the original navigator need not complete Route.popped, but does dispose
      // its routes; it must not strand the native run awaiting confirmation.
      await route.completed;
      return original() && request.current ? accepted : null;
    } finally {
      open = false;
      decided = true;
      _pending.remove(close);
    }
  }

  @override
  Future<bool> open(
    SupportAppDestination destination,
    SupportAppActionContext original,
  ) async {
    if (!_current || !original.current) return false;
    final path = switch (destination) {
      SupportAppDestination.home => '/',
      SupportAppDestination.characters => '/characters',
      SupportAppDestination.tools => '/tools',
      SupportAppDestination.connections => '/tools/api',
      SupportAppDestination.personas => '/tools/personas',
      SupportAppDestination.presets => '/tools/presets',
      SupportAppDestination.regex => '/tools/regex',
      SupportAppDestination.lorebooks => '/tools/lorebooks',
      SupportAppDestination.embeddings => '/tools/embeddings',
      SupportAppDestination.settings => '/menu/settings',
      SupportAppDestination.themes => '/menu/themes',
      SupportAppDestination.about => '/menu/about',
      SupportAppDestination.glossary => '/menu/glossary',
    };
    // Retire this issuer synchronously BEFORE navigation can rebuild another UI.
    // The app adapter settles the navigation fact; the loop does not paint B.
    _alive = false;
    _revision++;
    _router.go(path);
    return true;
  }

  void dispose() {
    _alive = false;
    _router.routeInformationProvider.removeListener(_observeRoute);
    for (final close in List.of(_pending)) {
      close();
    }
    _pending.clear();
  }
}

String _sourceReadPreview(SupportAppConfirmationRequest request) {
  final p = request.preview;
  if (p['sourceNavigation'] == true) {
    final kind = switch (p['kind']) {
      'game' => 'Игра — активная история',
      'ordinaryPreset' => 'Обычный пресет — CURRENT SAVED',
      'studioPreset' => 'Studio — CURRENT SAVED',
      'memory' => 'Сохранённая память и производные записи',
      'savedSummary' => 'Сохранённое саммари',
      'ledgerState' => 'Текущее сохранённое состояние Ledger',
      'ledgerSnapshot' => 'Сохранённые снимки Ledger',
      'reconciliation' => 'Сохранённые записи реконcиляции',
      'characterKnowledge' => 'Сохранённые знания персонажей',
      _ => 'Источник приложения',
    };
    return 'Источник: ${p['sourceLabel']}\nТип: $kind\n'
        'Неизменяемая область исходного снимка: ${p['extent']}\n'
        'Разделы: ${jsonEncode(p['sections'])}\n'
        'Не включается: ${p['exclusions']}\n'
        'Общий предел: ${p['disclosureBytes']} байт; не более '
        '${p['bodyResults']} результатов с содержимым. '
        'Повторные передачи также расходуют предел.\n\n'
        'Получатель: ${p['connection']}\nМодель: ${p['model']}\n'
        'Протокол: ${p['protocol']}\nМаршрут: ${p['routing']}\n'
        'Адрес получателя: ${p['origin']}\n\n'
        'Кнопка разрешает локальное оглавление, буквальный поиск и адресное '
        'чтение только внутри показанной области для исходного запроса. '
        'Модели могут передаваться названия, найденные выдержки и выбранные '
        'записи; вся история автоматически не передаётся. Техническое '
        'дочитывание в этой же области не требует повторного подтверждения. '
        'Другой источник, расширение области и новый запрос требуют нового согласия. '
        'Stop, выход с исходного экрана или изменение источника прекращают доступ. '
        'Настройки и глобальные разрешения не меняются. Неподдерживаемые данные '
        'не чинятся и не подменяются. Сохранённые пресеты — не исторический '
        'собранный промпт; память, саммари и Ledger не доказывают, каким '
        'промптом был создан прежний ответ.';
  }
  final studio = p['kind'] == 'studioPreset';
  final studioExtent = !studio
      ? ''
      : 'После согласия весь сохранённый пресет (${p['storedTextBytes']} байт UTF-8) '
            'будет прочитан локально для строгой проверки формата и удаления секретов.\n'
            '${p['studioIsPaged'] == true ? 'Модели передаётся только часть ${(p['studioPage'] as int) + 1}: '
                      'до ${p['partCharacters']} единиц UTF-16 и ${p['partEscapedBytes']} '
                      'байт UTF-8 после двойного JSON-экранирования. Общее число частей '
                      'станет известно после проверки. Это не весь пресет; '
                      'каждая следующая часть требует отдельного согласия.\n' : 'Модели передаётся сохранённое определение целиком.\n'}';
  return 'Источник: ${p['sourceLabel']}\n'
      'Тип: ${p['kind'] == 'game' ? 'Игра — активная история' : 'Studio — CURRENT SAVED'}\n'
      'Точный объём: ${p['extent']}\n'
      '$studioExtent'
      'Выбрано: ${p['selectedCount']}; отступ от последних активных сообщений: ${p['activeMessageOffset']}\n'
      'Точные выбранные записи: ${jsonEncode(p['orderedSourceIds'])}\n'
      'Не включается: ${p['exclusions']}\n\n'
      'Получатель: ${p['connection']}\nМодель: ${p['model']}\n'
      'Протокол: ${p['protocol']}\nМаршрут: ${p['routing']}\n'
      'Адрес получателя: ${p['origin']}\nОперация: ${p['operation']}\n\n'
      'Кнопка разрешает одновременно локальное чтение только показанного объёма '
      'и передачу полученного текста этой выбранной модели для исходного запроса. '
      'Настройки и глобальные разрешения не меняются. Другие источники и будущие '
      'запросы не разрешаются; повтор требует нового подтверждения. '
      'Изменённый или неподдерживаемый источник будет отклонён без подстановки. '
      'Studio показывает текущие сохранённые определения, не исторический собранный промпт '
      'и не доказательство того, каким пресетом создан старый ответ.';
}
