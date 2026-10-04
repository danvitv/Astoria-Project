import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/features/chat/services/manual_ledger_clock_service.dart';
import 'package:glaze_flutter/features/chat/widgets/manual_ledger_clock_sheet.dart';
import 'helpers/pump_localized.dart';

class _ClockService implements ManualLedgerClockService {
  final saved = <ManualLedgerClockCorrection>[];

  @override
  Future<List<ManualLedgerClockEntry>> loadRecent(
    String sessionId, {
    int limit = 5,
  }) async => [
    for (var index = 0; index < limit; index++)
      ManualLedgerClockEntry(
        messageNumber: index * 2 + 1,
        messageId: 'a$index',
        swipeId: 0,
        agentSwipeId: 0,
        committed: true,
        clock: GameTimeState(time: '20:0$index', date: '21.09.2026', day: 0),
      ),
  ];

  @override
  Future<void> save(
    String sessionId,
    List<ManualLedgerClockCorrection> corrections,
  ) async => saved.addAll(corrections);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('last clock row and save stay reachable above the keyboard', (
    tester,
  ) async {
    final service = _ClockService();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showModalBottomSheet<bool>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => ManualLedgerClockSheet(
              sessionId: 'session',
              onSaved: () async {},
            ),
          ),
          child: const Text('Open'),
        ),
      ),
      overrides: [manualLedgerClockServiceProvider.overrideWithValue(service)],
      surfaceSize: const Size(412, 900),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final lastTime = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == '20:04',
    );
    await tester.scrollUntilVisible(
      lastTime,
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(lastTime);
    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      lastTime,
      100,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(lastTime).bottom, lessThanOrEqualTo(560));
    await tester.enterText(lastTime, '20:20');
    final save = find.text('Сохранить исправления');
    await tester.scrollUntilVisible(
      save,
      100,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(save).bottom, lessThanOrEqualTo(560));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(service.saved.last.clock.time, '20:20');
    expect(tester.takeException(), isNull);
  });
}
