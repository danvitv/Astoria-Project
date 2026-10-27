import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/history_source_index_repo.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../state/support_source_preparation_provider.dart';
import 'support_surface_layout.dart';

/// The sole explicit app entry to bounded local index maintenance. It neither
/// sends anything nor grants model access. Stop/disposal retires the original
/// gesture synchronously, while maintenance drains under AppDatabase.borrow.
class SupportSourcePreparationSheet extends ConsumerStatefulWidget {
  const SupportSourcePreparationSheet({super.key});

  @override
  ConsumerState<SupportSourcePreparationSheet> createState() =>
      _PreparationState();
}

class _PreparationState extends ConsumerState<SupportSourcePreparationSheet> {
  int _after = 0;
  Object? _gesture;
  Future<void>? _pending;
  String? _working;
  String? _message;

  @override
  void dispose() {
    _gesture = null;
    // The pending ORIGINAL future still owns the native borrow/reservation.
    // AppDatabase.close joins it; no replacement future or raw writer exists.
    super.dispose();
  }

  Future<void> _prepare(HistoryIndexLocalCandidate source) async {
    if (_pending != null) return;
    final db = ref.read(appDbProvider),
        native = ref.read(appDbProvider).nativeDataSourceIdentity;
    if (native == null || db.isClosing || !db.hasCompletedOpening) return;
    final gesture = Object();
    _gesture = gesture;
    bool current() =>
        mounted &&
        identical(_gesture, gesture) &&
        identical(ref.read(appDbProvider), db) &&
        !db.isClosing &&
        identical(db.nativeDataSourceIdentity, native);
    setState(() {
      _working = source.sessionId;
      _message = null;
    });
    final pending = db.historySourceIndex.maintain(
      sessionId: source.sessionId,
      isCurrent: current,
      // Finite per-gesture work. An explicit later tap continues the retained
      // checkpoint, or rebuilds after mutation/new native owner.
      maxSteps: 256,
      deadline: const Duration(seconds: 30),
    );
    _pending = pending
        .then<void>(
          (result) {
            if (!current()) return;
            _message = switch (result.state) {
              HistoryIndexMaintenanceState.ready =>
                'Готово для текущего снимка. Чтение моделью требует отдельного согласия.',
              HistoryIndexMaintenanceState.incomplete =>
                'Подготовка неполна. Продолжи отдельным нажатием; после изменения источника будет пересборка.',
              HistoryIndexMaintenanceState.unsupported =>
                'Формат не поддерживается. История не изменена.',
            };
          },
          onError: (Object _, StackTrace _) {
            if (current()) {
              _message =
                  'Подготовка недоступна или неполна. История не изменена.';
            }
          },
        )
        .whenComplete(() {
          // Clear busy only when the actual original maintenance future settles.
          _pending = null;
          if (mounted) {
            setState(() {
              _working = null;
            });
          }
        });
    await _pending;
  }

  void _stop() {
    _gesture = null;
    setState(() {
      _message =
          'Остановлено. Ожидаю завершения исходной операции; готовность не подтверждена.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(supportSourcePreparationPageProvider(_after));
    return SupportSheetDecisionBody(
      footer: _pending == null
          ? const SizedBox.shrink()
          : GlazeActionButton(
              key: const ValueKey('support_source_prepare_stop'),
              icon: Icons.stop_rounded,
              label: 'Остановить подготовку',
              expand: true,
              maxLabelLines: null,
              onTap: _stop,
            ),
      content: ListView(
        key: const ValueKey('support_source_preparation_scroll'),
        padding: supportSurfacePadding(context, sheetHosted: false),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Локальная подготовка читает выбранную историю только для производного индекса. '
              'Оригинал сохраняется точно; передачи модели и разрешения на чтение нет. '
              'Готовность проверяется на текущем native-владельце и теряется при изменении источника.',
            ),
          ),
          if (_message != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_message!)),
          ...page.when(
            data: (value) => <Widget>[
              SupportControlAvailability(
                enabled: _pending == null,
                child: MenuGroup(
                  header: 'Истории — локальный выбор',
                  items: [
                    for (final source in value.items)
                      SupportControlAvailability(
                        enabled:
                            source.state !=
                            HistoryIndexMaintenanceState.unsupported,
                        child: MenuItem(
                          key: ValueKey(
                            'support_source_prepare_${source.sessionId}',
                          ),
                          icon: Icons.manage_search_rounded,
                          label: '${source.label} · чат ${source.sessionIndex}',
                          subtitle: _working == source.sessionId
                              ? 'Подготовка…'
                              : switch (source.state) {
                                  HistoryIndexMaintenanceState.ready =>
                                    'Текущий индекс готов · пересобрать',
                                  HistoryIndexMaintenanceState.incomplete =>
                                    'Не готов · подготовить / продолжить',
                                  HistoryIndexMaintenanceState.unsupported =>
                                    'Неподдерживаемый формат',
                                },
                          onTap: () {
                            if (_pending != null) return;
                            unawaited(_prepare(source));
                          },
                        ),
                      ),
                    if (value.items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('На этой странице нет доступных историй.'),
                      ),
                    if (value.nextRowid != null)
                      MenuItem(
                        key: const ValueKey('support_source_prepare_next'),
                        icon: Icons.navigate_next_rounded,
                        label: 'Следующая страница (до 16 кандидатов)',
                        onTap: () {
                          if (_pending != null) return;
                          setState(() {
                            _after = value.nextRowid!;
                            _message = null;
                          });
                        },
                      ),
                    if (_after != 0)
                      MenuItem(
                        icon: Icons.first_page_rounded,
                        label: 'В начало',
                        onTap: () {
                          if (_pending != null) return;
                          setState(() {
                            _after = 0;
                            _message = null;
                          });
                        },
                      ),
                  ],
                ),
              ),
            ],
            loading: () => [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Проверка локальной готовности…'),
              ),
            ],
            error: (error, stack) => [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Оригинальный native-владелец или индекс недоступен.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
