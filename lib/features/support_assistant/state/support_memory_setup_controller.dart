import 'package:flutter/foundation.dart';

import '../services/memory_setup/memory_setup_service.dart';

/// Modal presentation state only. Durable work stays on retained service/native
/// owners, and can settle its original journal after this presentation closes.
final class SupportMemorySetupController extends ChangeNotifier {
  SupportMemorySetupController(this.service);
  final MemorySetupService service;
  MemorySetupAnswers answers = const MemorySetupAnswers();
  List<MemorySetupConnection> connections = const [];
  MemorySetupReview? review;
  MemorySetupReadiness? readiness;
  final receipts = <MemorySetupScope, MemorySetupReceipt>{};
  int question = 0;
  bool busy = false, selected = false, finished = false, _alive = true;
  String? status;

  void update(MemorySetupAnswers next) {
    if (busy || !_alive) return;
    service.answersChanged();
    answers = next;
    review = null;
    _notify();
  }

  Future<void> selectTarget(MemorySetupTarget owner) async {
    if (busy || selected || !service.selectTarget(owner)) return;
    selected = true;
    busy = true;
    _notify();
    try {
      connections = await service.savedConnections();
      if (connections.isNotEmpty)
        answers = answers.copyWith(connection: connections.first);
    } catch (_) {
      status =
          'Сохранённые подключения недоступны; сессионный план остаётся отдельным.';
    } finally {
      busy = false;
      _notify();
    }
  }

  void next() {
    if (busy || !selected || !_alive) return;
    if (question < 4) {
      question++;
    } else {
      finished = true;
    }
    _notify();
  }

  void back() {
    if (busy || !_alive) return;
    review = null;
    if (finished) {
      finished = false;
    } else if (question > 0) {
      question--;
    }
    service.answersChanged();
    _notify();
  }

  Future<void> prepare(MemorySetupScope scope) async {
    if (busy || !_alive) return;
    busy = true;
    review = null;
    status = null;
    _notify();
    try {
      review = await service.prepare(answers, scope);
      if (review == null)
        status =
            'Нет изменений, конфликт источника или исходный владелец недоступен. Глобальный план требует доверенного загруженного хранилища; старый flat pipeline здесь не мигрируется.';
    } catch (_) {
      status = 'Подготовка недоступна; изменения не запускались.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> prepareUndo(MemorySetupScope scope) async {
    final receipt = receipts[scope];
    if (busy || !_alive || receipt == null) return;
    busy = true;
    review = null;
    status = null;
    _notify();
    try {
      review = await service.prepareUndo(receipt);
      if (review == null)
        status =
            'Undo отказал: исходное хранилище, намерение или изменённые поля больше не совпадают. Поздние данные не перезаписаны.';
    } catch (_) {
      status = 'Свежий обзор Undo недоступен; восстановление не запускалось.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> confirm(MemorySetupReview painted) async {
    if (busy || !_alive || !identical(painted, review) || !painted.current)
      return;
    busy = true;
    review = null;
    if (painted.isUndo) receipts.remove(painted.scope);
    _notify();
    MemorySetupResult result;
    try {
      result = await service.apply(painted);
    } catch (_) {
      result = const MemorySetupResult(
        MemorySetupEffect.reconciliationRequired,
      );
    }
    if (result.receipt case final receipt?) receipts[painted.scope] = receipt;
    status = switch (result.effect) {
      MemorySetupEffect.applied =>
        'Этот план сохранён. Другие области не применены автоматически.',
      MemorySetupEffect.undone => 'Изменения этого плана отменены.',
      MemorySetupEffect.conflict =>
        'Конфликт: этот план не принят. Подготовь новый обзор.',
      MemorySetupEffect.refused =>
        'Подтверждение устарело или исходный владелец недоступен.',
      MemorySetupEffect.reconciliationRequired =>
        'Частичный / неопределённый результат: запись могла сохраниться, но подтверждение или журнал не завершены. Автоматический повтор и Undo недоступны; проверь нативные настройки.',
    };
    if (result.refreshPending)
      status = '$status Обновление отображения ещё не подтверждено.';
    busy = false;
    _notify();
  }

  Future<void> checkReadiness() async {
    if (busy || !_alive) return;
    busy = true;
    _notify();
    try {
      readiness = await service.readiness();
    } catch (_) {
      readiness = null;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (_alive) notifyListeners();
  }

  @override
  void dispose() {
    _alive = false;
    service.retire();
    super.dispose();
  }
}
