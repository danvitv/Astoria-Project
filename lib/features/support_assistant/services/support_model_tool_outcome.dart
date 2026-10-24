import '../../../core/llm/transport/native_tool_types.dart';
import '../../../core/llm/transport/private_text_outcome.dart';

/// Join typed native turns into the existing durable USER/reply lifecycle.
/// App failures override model prose, so a provider cannot turn a failed effect
/// into a successful visible claim. No tool payload is a normal chat message.
final class SupportModelToolOutcome {
  bool _wired = false;
  ProviderTokenUsage? _lastUsage;
  final _facts = <NativeToolResult>[];

  void observe(NativeToolTurn turn) {
    if (turn.dispatch != NativeToolDispatch.notAdmitted) {
      _wired = true;
      _lastUsage = turn.actualUsage; // Missing THIS POST stays unknown.
    }
  }

  void record(NativeToolResult result) => _facts.add(result);

  bool get uncertain => _facts.any((r) => r.content['effect'] == 'uncertain');
  bool get navigated => _facts.any((r) => r.content['effect'] == 'navigation');
  bool get failed => _facts.any((r) => r.content['ok'] != true);

  String factualText({bool interrupted = false}) {
    final lines = <String>[
      if (interrupted) 'Запрос остановлен. Дальнейшие действия не выполнялись.',
      for (final fact in _facts)
        '${fact.name}: ${fact.content['code']}; '
            '${switch (fact.content['effect']) {
              'persisted' => fact.name == 'astoria_database_snapshot' ? 'локальный файл сохранён' : 'изменение сохранено',
              'navigation' => 'выполнен только переход, данные не изменены',
              'uncertain' => 'результат изменения не подтверждён; повтор не выполнялся',
              _ => fact.content['ok'] == true ? 'чтение завершено или изменений нет' : 'успех действия не подтверждён',
            }}${fact.name == 'astoria_database_snapshot' && fact.content['effect'] == 'persisted' && fact.content['data'] is Map && (fact.content['data'] as Map)['status'] != 'verified' ? '; проверка снимка не подтверждена; повтор не выполнялся' : ''}${fact.content['effect'] == 'persisted' && fact.content['data'] is Map && (fact.content['data'] as Map)['refreshPending'] == true ? '; обновление нативных представлений ожидается' : ''}.',
    ];
    return lines.join('\n');
  }

  PrivateTextOutcome finish(NativeToolTurn turn, {bool interrupted = false}) {
    final complete = turn.status == NativeToolStatus.complete && !interrupted;
    return PrivateTextOutcome(
      status: interrupted
          ? PrivateTextStatus.stopped
          : switch (turn.status) {
              NativeToolStatus.complete =>
                failed || uncertain
                    ? PrivateTextStatus.error
                    : PrivateTextStatus.complete,
              NativeToolStatus.stopped => PrivateTextStatus.stopped,
              _ =>
                turn.reason == NativeToolReason.limit
                    ? PrivateTextStatus.limited
                    : PrivateTextStatus.error,
            },
      text: _facts.isNotEmpty && (!complete || failed || uncertain || navigated)
          ? factualText(
              interrupted:
                  interrupted || turn.status == NativeToolStatus.stopped,
            )
          : complete
          ? turn.text
          : '',
      reason: interrupted
          ? PrivateTextReason.notCurrent
          : switch (turn.reason) {
              NativeToolReason.none =>
                failed || uncertain
                    ? PrivateTextReason.denied
                    : PrivateTextReason.none,
              NativeToolReason.cancelled => PrivateTextReason.cancelled,
              NativeToolReason.notCurrent => PrivateTextReason.notCurrent,
              NativeToolReason.deadline => PrivateTextReason.deadline,
              NativeToolReason.limit => PrivateTextReason.providerLimit,
              NativeToolReason.denied ||
              NativeToolReason.unknownTool => PrivateTextReason.denied,
              NativeToolReason.invalidRequest =>
                PrivateTextReason.invalidRequest,
              NativeToolReason.malformed => PrivateTextReason.malformed,
              NativeToolReason.unsupported => PrivateTextReason.unsupported,
              NativeToolReason.httpStatus => PrivateTextReason.httpStatus,
              NativeToolReason.providerError => PrivateTextReason.providerError,
              NativeToolReason.transport => PrivateTextReason.transport,
            },
      dispatch: turn.dispatch == NativeToolDispatch.admittedFailed
          ? PrivateTextDispatch.admittedFailed
          : _wired
          ? PrivateTextDispatch.admitted
          : PrivateTextDispatch.notAdmitted,
      usage: _lastUsage,
    );
  }
}
