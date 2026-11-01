import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/support_report/support_report_error.dart';
import '../../../core/support_report/support_report_save_port.dart';
import '../services/report/support_report_coordinator.dart';
import 'support_report_native_composition.dart';

export 'support_report_native_composition.dart';

class SupportReportUiState {
  const SupportReportUiState({
    this.preview,
    this.busy = false,
    this.displayed = false,
    this.message,
    this.removed = const [],
    this.finished = false,
    this.saveSupported = true,
  });
  final SupportReportPreview? preview;
  final bool busy, displayed, finished, saveSupported;
  final String? message;
  final List<String> removed;
  bool get canSave =>
      !busy &&
      !finished &&
      saveSupported &&
      displayed &&
      preview != null &&
      !preview!.isRetired &&
      preview!.recipientConfigured;
}

/// One native sheet lifetime, never a model action or a persisted report ID.
class SupportReportNotifier extends Notifier<SupportReportUiState> {
  SupportReportNotifier(this.launch);
  final Object launch;
  SupportReportNativeOperation? _operation;
  SupportReportCoordinator? _coordinator;
  Timer? _watch;
  bool _closed = false;
  int _serial = 0;

  @override
  SupportReportUiState build() {
    ref.onDispose(() {
      _closed = true;
      _serial++;
      _watch?.cancel();
      _operation?.dispose();
    });
    return const SupportReportUiState();
  }

  bool _owns(int serial, SupportReportNativeOperation operation) =>
      !_closed &&
      ref.mounted &&
      serial == _serial &&
      identical(_operation, operation);

  Future<void> prepare(SupportReportPrepareRequest request) async {
    if (_closed || state.busy) return;
    _operation?.dispose();
    _watch?.cancel();
    _coordinator = null;
    final serial = ++_serial;
    state = const SupportReportUiState(busy: true);
    try {
      // Factory captures original native/DB/redactor/permission custody NOW,
      // before sodium, assets or any other asynchronous initialization.
      final operation = ref.read(supportReportNativeFactoryProvider)();
      _operation = operation;
      _watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_owns(serial, operation) && !operation.isCurrent) _retire();
      });
      final coordinator = await operation.initialize();
      if (!_owns(serial, operation) || !operation.isCurrent) return;
      _coordinator = coordinator;
      final preview = await coordinator.prepare(request);
      if (!_owns(serial, operation) || !operation.isCurrent) return;
      state = SupportReportUiState(
        preview: preview,
        saveSupported: operation.saveSupported,
      );
    } on SupportReportException catch (error) {
      if (!_closed && ref.mounted && serial == _serial) {
        state = SupportReportUiState(
          message: supportReportFailureText(error.failure.name),
        );
      }
    } catch (_) {
      if (!_closed && ref.mounted && serial == _serial) {
        state = const SupportReportUiState(
          message: 'Репорт сейчас недоступен. Файл не создан.',
        );
      }
    }
  }

  /// UI calls only AFTER the exact replacement payload has completed a frame.
  void markDisplayed(SupportReportPreview preview) {
    if (_closed ||
        !ref.mounted ||
        state.busy ||
        !identical(preview, state.preview) ||
        preview.isRetired) {
      return;
    }
    state = SupportReportUiState(
      preview: preview,
      displayed: true,
      removed: state.removed,
      saveSupported: state.saveSupported,
    );
  }

  void exclude(String blockId) {
    final preview = state.preview;
    if (_closed || state.busy || preview == null || preview.isRetired) return;
    try {
      final replacement = _coordinator!.exclude(preview, {blockId});
      final kept = replacement.blocks.map((block) => block.id).toSet();
      state = SupportReportUiState(
        preview: replacement,
        saveSupported: state.saveSupported,
        removed: [
          ...state.removed,
          for (final block in preview.blocks)
            if (!kept.contains(block.id)) block.title,
        ],
      );
    } catch (_) {
      _retire();
    }
  }

  void discardPreview() {
    if (_closed || state.busy) return;
    _serial++;
    _watch?.cancel();
    _operation?.dispose();
    _operation = null;
    _coordinator = null;
    state = const SupportReportUiState();
  }

  Future<void> save() async {
    final operation = _operation, coordinator = _coordinator;
    if (!state.canSave || operation == null || coordinator == null) return;
    if (!operation.isCurrent) {
      _retire();
      return;
    }
    final preview = state.preview!;
    state = SupportReportUiState(preview: preview, busy: true);
    final serial = _serial;
    final result = await coordinator.exportDisplayed(preview);
    // Already admitted OS I/O is a fact, even after a subsequent revocation.
    if (!_closed &&
        ref.mounted &&
        identical(operation, _operation) &&
        (serial == _serial || result.status == SupportReportSaveStatus.saved)) {
      _watch?.cancel();
      state = SupportReportUiState(
        finished: true,
        message: switch (result.status) {
          SupportReportSaveStatus.saved =>
            'Сохранён зашифрованный файл astoria-support-report.astreport. '
                'Ничего не отправлено. Если ты поделишься файлом, разработчик получит ровно включённое содержимое.',
          SupportReportSaveStatus.canceled =>
            'Сохранение отменено. Полный зашифрованный репорт не сохранён; '
                'после выбора места мог остаться пустой или неполный документ.',
          SupportReportSaveStatus.failed =>
            'Системное сохранение не подтвердило успех. Проверь выбранный файл; ничего не отправлено.',
          _ => supportReportFailureText(result.reason),
        },
      );
    }
  }

  void _retire() {
    if (_closed || !ref.mounted) return;
    _serial++;
    _watch?.cancel();
    _operation
        ?.dispose(); // Native cancellation/preview retirement is synchronous.
    state = const SupportReportUiState(
      finished: true,
      message:
          'Источник, сессия, доступ или настройки изменились. Старый просмотр закрыт. Открой репорт заново.',
    );
  }

  void cancel() {
    if (_closed) return;
    _closed = true;
    _serial++;
    _watch?.cancel();
    _operation?.dispose();
  }
}

final supportReportProvider = NotifierProvider.autoDispose
    .family<SupportReportNotifier, SupportReportUiState, Object>(
      SupportReportNotifier.new,
    );

String supportReportFailureText(String? reason) =>
    '${switch (reason) {
      'recipientMissing' => 'Ключ получателя не настроен. Сохранение недоступно.',
      'changed' => 'Данные или настройки изменились. Открой репорт заново.',
      'tooLarge' => 'Выбранное содержимое превышает безопасный предел.',
      'invalidRecipient' => 'Публичный descriptor получателя недействителен.',
      _ => 'Репорт сейчас недоступен.',
    }} Если место уже выбрано, мог остаться пустой документ; проверь его.';
