/// Local, bounded presentation of actual native calls. Never a tool transcript,
/// source body, model reasoning, argument dump or reusable permission.
enum SupportModelToolStage {
  preparing,
  confirmation,
  executing,
  completed,
  failed,
  stopped,
}

final class SupportModelToolActivity {
  const SupportModelToolActivity({
    required this.sequence,
    required this.action,
    required this.stage,
    this.sourceLabel,
    this.detail,
  });

  final int sequence;

  /// Registry-validated canonical name, never arbitrary provider text.
  final String action;
  final SupportModelToolStage stage;

  /// Redacted catalog metadata only; rendered through display redaction again.
  final String? sourceLabel;

  /// Fixed native explanation, never a raw exception or model-authored text.
  final String? detail;

  String get title => switch (action) {
    'astoria_sources_list' => 'Поиск доступных источников',
    'astoria_source_read' => 'Чтение источника',
    'unknown' => 'Неподключённый инструмент',
    _ => 'Инструмент приложения: $action',
  };

  String get label =>
      detail ??
      switch (stage) {
        SupportModelToolStage.preparing => 'Подготовка вызова…',
        SupportModelToolStage.confirmation =>
          'Ожидание твоего согласия на чтение и передачу модели',
        SupportModelToolStage.executing => 'Выполнение…',
        SupportModelToolStage.completed => 'Завершено',
        SupportModelToolStage.failed => 'Не выполнено',
        SupportModelToolStage.stopped => 'Остановлено',
      };
}
