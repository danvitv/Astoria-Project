part of 'support_model_service.dart';

extension _ModelToolActivity on _ModelRun {
  void beginTool(NativeToolCall call) {
    if (!current() || toolSequence >= NativeToolLimits.callsPerSession) return;
    toolSequence++;
    // Unknown provider names/arguments are not a display metadata capability.
    toolAction = originalActions!.definitions.any((d) => d.name == call.name)
        ? call.name
        : 'unknown';
    toolSourceLabel = null;
    toolSourcePart = null;
    toolFailureDetail = null;
    toolActivity(SupportModelToolStage.preparing);
  }

  void toolActivity(
    SupportModelToolStage stage, {
    String? sourceLabel,
    String? detail,
  }) {
    if (!current() || toolSequence == 0) return;
    try {
      if (sourceLabel != null) {
        toolSourceLabel = _safeText(
          service._redaction.redactor,
          sourceLabel,
          256,
        ).replaceAll(RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]'), ' ');
      }
      service._onToolActivity?.call(
        runId,
        sessionId,
        SupportModelToolActivity(
          sequence: toolSequence,
          action: toolAction!,
          stage: stage,
          sourceLabel: toolSourceLabel,
          detail: detail,
        ),
      );
    } catch (_) {
      // A presentation callback cannot grant authority or strand settlement.
    }
  }

  void refuseTool(String fixedExplanation) {
    toolFailureDetail = fixedExplanation;
    toolActivity(SupportModelToolStage.failed, detail: fixedExplanation);
  }

  void refuseSourceTool(
    SupportSourceReadException error,
  ) => refuseTool(switch (error.failure) {
    SupportSourceReadFailure.unsupportedFormat =>
      'Сохранённый формат источника не поддерживается безопасным чтением; текст не передан',
    SupportSourceReadFailure.tooLarge =>
      'Источник превышает допустимый размер; текст не обрезан и не передан',
    SupportSourceReadFailure.notFound =>
      'Выбранный источник больше не существует; другой источник не подставлялся',
    SupportSourceReadFailure.changed =>
      'Источник изменился после выбора или согласия; чтение остановлено',
    SupportSourceReadFailure.locked =>
      'Источник заблокирован для чтения; текст не передан',
    SupportSourceReadFailure.unavailable =>
      'Источник недоступен для безопасного чтения; текст не передан',
  });

  String finishTool(NativeToolResult result) {
    final ok = result.content['ok'] == true;
    final stopped = const {
      'cancelled',
      'stale',
    }.contains(result.content['code']);
    final detail = ok
        ? switch (result.name) {
            'astoria_sources_list' =>
              'Каталог источников получен; текст ещё не читался',
            'astoria_source_read' =>
              toolSourcePart == null
                  ? 'Одобренный текст прочитан для этого запроса'
                  : 'Одобренная часть $toolSourcePart прочитана; это не весь пресет',
            _ =>
              result.content['effect'] == 'persisted'
                  ? 'Изменение сохранено'
                  : 'Вызов завершён',
          }
        : toolFailureDetail ??
              switch (result.content['code']) {
                'cancelled' =>
                  'Остановлено; дальнейшее чтение и передача не выполняются',
                'stale' || 'conflict' =>
                  'Исходный источник или контекст изменился; чтение не продолжено',
                'denied' =>
                  'Вызов не разрешён; согласие не получено или ссылка на источник недействительна',
                'invalidArguments' =>
                  'Модель передала неподдерживаемые параметры инструмента',
                'unsafeMetadata' =>
                  'Вызов остановлен проверкой безопасных данных',
                'storageUncertain' =>
                  'Результат операции не подтверждён; автоматический повтор запрещён',
                'unknownAction' => 'Модель запросила неподключённый инструмент',
                _ =>
                  'Источник недоступен для этого чтения; текст не передан модели',
              };
    toolActivity(
      ok
          ? SupportModelToolStage.completed
          : stopped
          ? SupportModelToolStage.stopped
          : SupportModelToolStage.failed,
      detail: detail,
    );
    final kind = result.name == 'astoria_sources_list'
        ? 'Каталог источников'
        : 'Чтение источника';
    return '$toolSequence. $kind${toolSourceLabel == null ? '' : ' — $toolSourceLabel'}: $detail.';
  }
}

/// Presentation-only forwarding of the original native request and exact lease.
/// It cannot accept, replace, revive, or serialize a confirmation.
final class _ModelToolConfirmation implements SupportAppConfirmationPort {
  _ModelToolConfirmation(this.run, this.native);
  final _ModelRun run;
  final SupportAppConfirmationPort native;

  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) {
    run.toolActivity(
      SupportModelToolStage.confirmation,
      detail: request.action == 'astoria_source_read'
          ? run.toolSourcePart == null
                ? 'Ожидание твоего согласия на чтение и передачу выбранной модели'
                : 'Ожидание твоего согласия на часть ${run.toolSourcePart} и её передачу выбранной модели'
          : 'Ожидание твоего подтверждения действия',
    );
    return native.confirm(request);
  }
}
