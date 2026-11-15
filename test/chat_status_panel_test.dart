import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_job_repo.dart';
import 'package:glaze_flutter/core/state/card_evolution_worker_provider.dart';
import 'package:glaze_flutter/features/chat/state/post_cleaner_state_provider.dart';
import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';
import 'package:glaze_flutter/features/chat/state/studio_cycle_state_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_status_panel.dart';

import 'helpers/pump_localized.dart';

const _job = CardEvolutionJobRow(
  id: 'job-1',
  sessionId: 'session-1',
  characterId: 'character-1',
  reconciliationRunId: 'run-1',
  reconciliationChainHash: 'chain',
  routingSnapshotJson: '{}',
  routingSnapshotHash: 'hash',
  availableAt: 0,
  status: 'running',
  createdAt: 0,
  updatedAt: 0,
);

// Only the cancellation port is used: unexpected database access fails loudly.
class _UnusedDatabase implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access: ${invocation.memberName}');
}

class _CancelRepo extends CardEvolutionJobRepo {
  _CancelRepo() : super(_UnusedDatabase());
  final cancelled = <String>[];

  @override
  Future<bool> cancel({
    required String id,
    required int now,
    String? resultDetail,
  }) async {
    cancelled.add(id);
    return true;
  }

  @override
  Future<List<CardEvolutionJobRow>> listUnfinished() async => [];
}

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  double scale = 1,
  List<CardEvolutionJobRow> jobs = const [_job],
  _CancelRepo? cancelRepo,
}) async {
  await pumpLocalized(
    tester,
    MediaQuery(
      data: MediaQueryData(
        size: const Size(320, 576),
        textScaler: TextScaler.linear(scale),
      ),
      child: const Column(
        children: [
          Expanded(child: SizedBox(key: ValueKey('transcript'))),
          ChatStatusPanel(sessionId: 'session-1'),
          SizedBox(key: ValueKey('composer'), height: 64),
        ],
      ),
    ),
    locale: const Locale('en'),
    surfaceSize: const Size(320, 576),
    overrides: [
      cardEvolutionJobsProvider(
        'session-1',
      ).overrideWith((_) => Stream.value(jobs)),
      if (cancelRepo != null)
        cardEvolutionBackgroundProvider.overrideWith((ref) {
          final controller = CardEvolutionBackgroundController(ref, cancelRepo);
          ref.onDispose(controller.dispose);
          return controller;
        }),
    ],
  );
  return ProviderScope.containerOf(
    tester.element(find.byType(ChatStatusPanel)),
  );
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'simultaneous Ledger/evolution fit a 576px phone at scale $scale',
      (tester) async {
        final repo = _CancelRepo();
        final container = await _pumpPanel(
          tester,
          scale: scale,
          jobs: [_job.copyWith(status: scale == 1 ? 'pending' : 'running')],
          cancelRepo: repo,
        );
        final status = container.read(postGenStatusProvider.notifier);
        final run = status.startRun(
          sessionId: 'session-1',
          task: PostGenTask.ledger,
        );
        status.updateRunDetail(run, 'Ledger running 2nd attempt...');
        await tester.pump();

        expect(tester.takeException(), isNull);
        final panel = tester.getRect(find.byType(ChatStatusPanel));
        expect(panel.height, lessThanOrEqualTo(112));
        expect(panel.top, greaterThanOrEqualTo(400));
        expect(
          tester.getRect(find.byKey(const ValueKey('transcript'))).bottom,
          panel.top,
        );
        expect(
          panel.bottom,
          tester.getRect(find.byKey(const ValueKey('composer'))).top,
        );
        expect(find.text('Ledger running 2nd attempt...'), findsOneWidget);
        expect(find.text('Card Evolution'), findsOneWidget);
        expect(find.textContaining('Preparing Card Evolution'), findsNothing);

        // The two actions retain different ownership: hide is not Stop.
        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();
        expect(status.ownsRun(run), isTrue);
        expect(repo.cancelled, isEmpty);
        await tester.tap(find.byIcon(Icons.stop_circle_outlined));
        await tester.pump();
        expect(repo.cancelled, ['job-1']);
        expect(status.ownsRun(run), isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('extra rows scroll without hiding cleaner Stop or error labels', (
    tester,
  ) async {
    final repo = _CancelRepo();
    final container = await _pumpPanel(tester, scale: 2, cancelRepo: repo);
    final token = CancelToken();
    container.read(cleanerCancelTokenProvider.notifier).state = token;
    container
        .read(postCleanerStateProvider.notifier)
        .state = const PostCleanerState.running(
      sessionId: 'session-1',
      messageId: 'message-1',
      originalChars: 100,
    );
    container.read(studioCycleStateProvider.notifier).state =
        const StudioCycleState.error(sessionId: 'session-1');
    container
        .read(postGenStatusProvider.notifier)
        .startRun(sessionId: 'session-1', task: PostGenTask.ledger);
    await tester.pump();

    expect(tester.getSize(find.byType(ChatStatusPanel)).height, 112);
    expect(find.text('Studio failed'), findsOneWidget);
    await tester.ensureVisible(find.text('Card Evolution'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined).last);
    await tester.pump();
    expect(repo.cancelled, ['job-1']);
    expect(token.isCancelled, isFalse);
    await tester.ensureVisible(find.byIcon(Icons.stop_circle_outlined).first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined).first);
    expect(token.isCancelled, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the existing Studio presentation auto-dismiss callback.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('idle statuses reserve no composer space', (tester) async {
    await _pumpPanel(tester, jobs: []);
    expect(tester.getSize(find.byType(ChatStatusPanel)).height, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed evolution remains an explicit dismissible failure', (
    tester,
  ) async {
    await _pumpPanel(tester, jobs: [_job.copyWith(status: 'failed')]);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('Card Evolution'), findsNothing);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(tester.getSize(find.byType(ChatStatusPanel)).height, 0);
  });

  testWidgets('a completed queue check does not promise generated proposals', (
    tester,
  ) async {
    await _pumpPanel(tester, jobs: [_job.copyWith(status: 'completed')]);
    expect(find.text('Card Evolution'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.textContaining('review preparation'), findsNothing);
    // pumpLocalized mounts under runAsync, so the card's Timer uses the real
    // clock rather than the widget-test fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2600)),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(ChatStatusPanel)).height, 0);
  });
}
