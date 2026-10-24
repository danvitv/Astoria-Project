import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

import 'helpers/support_model_screen_fixture.dart';
import 'support_guidance_screen_isolation.dart';

export 'helpers/support_model_screen_fixture.dart' show ModelScreenFixture;

const compactButton = ValueKey('support_composer_compact_btn');
const compactSend = ValueKey('support_composer_send_btn');
const compactStop = ValueKey('support_composer_stop_btn');
const compactSummary = 'SYNTHETIC_COMPACT_SUMMARY_GOALS_AND_DECISIONS';

void compactionTest(
  String name,
  Future<void> Function(WidgetTester, ModelScreenFixture) body,
) {
  testWidgets(name, (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(EasyLocalization.ensureInitialized);
    final isolation = GuidanceScreenIsolation();
    await isolation.run(tester, () async {
      final f = ModelScreenFixture(confirm: false, oldBody: 'OLDER_LOCAL_HELP');
      await f.run(tester, () async {
        await f.action(tester, () async {
          for (var i = 0; i < 3; i++) {
            for (final role in ['user', 'assistant']) {
              await f.repo.appendMessage(
                SupportMessage(
                  id: 'pair-$i-$role',
                  sessionId: ModelScreenFixture.session,
                  role: role,
                  body: 'SYNTHETIC_${i}_$role',
                  createdAt: 10 + i * 2 + (role == 'assistant' ? 1 : 0),
                ),
              );
            }
          }
          await f.workspace.refresh();
        });
        await tester.pumpAndSettle();
        await body(tester, f);
      });
    });
  });
}

Future<SupportModelRunView> compactionTerminal(
  ModelScreenFixture f, {
  SupportModelUiBridge? original,
}) {
  final bridge = original ?? f.bridge, done = Completer<SupportModelRunView>();
  var started = false;
  late void Function() stop;
  stop = bridge.listen(() {
    if (bridge.view.busy) started = true;
    if (started &&
        !done.isCompleted &&
        bridge.view.phase == SupportModelPhase.settled &&
        !bridge.view.busy) {
      stop();
      done.complete(bridge.view);
    }
  });
  addTearDown(stop);
  return done.future;
}

Future<void> compactionReleased(SupportModelUiBridge bridge) {
  final done = Completer<void>();
  late void Function() stop;
  stop = bridge.listen(() {
    if (!bridge.view.busy && !done.isCompleted) {
      stop();
      done.complete();
    }
  });
  addTearDown(stop);
  return Future.any([done.future, bridge.drained]);
}

Future<SupportModelRunView> compactTap(
  WidgetTester tester,
  ModelScreenFixture f,
  Key key,
) async {
  final original = await compactReadyButton(tester, f, key);
  final done = await f.signal(
    tester,
    () => compactionTerminal(f, original: original),
    label: 'original compact/send settlement',
  );
  await compactGesture(tester, f, key, original: original);
  return f.finish(tester, done);
}

/// Wait for actual emitted presentation, not a fabricated native ready flag.
/// In particular, a finished Send can still have a queued idle-emitter rebuild.
/// This small frame bound is separate from, and does not enlarge, the original
/// fixture's 1024-turn operation budget.
Future<SupportModelUiBridge> compactReadyButton(
  WidgetTester tester,
  ModelScreenFixture f,
  Key key,
) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump();
    await f.action(tester, () => Future<void>.delayed(Duration.zero));
    final finder = find.byKey(key);
    if (finder.evaluate().length != 1) continue;
    final composer = tester.widget<SupportComposerBar>(
      find.byType(SupportComposerBar),
    );
    final owner = composer.nativeOwner;
    if (tester.widget<IconButton>(finder).onPressed != null &&
        finder.hitTestable().evaluate().length == 1 &&
        composer.available &&
        !composer.busy &&
        owner is SupportModelUiEmitter &&
        owner.isCurrent) {
      return f.bridge;
    }
  }
  throw StateError(
    'Actual compact/send button did not become enabled, '
    'hit-testable and bound to its current original emitter in 8 frames.',
  );
}

/// Gestures must originate in ModelScreenFixture.action's guarded REAL async
/// zone, just like the already-passing Send/Enter screen tests. A widget-test
/// fake-zone tap captures native SQL/AEAD/Future continuations on the wrong
/// event queue; pumping zero-time frames cannot substitute for real async work.
Future<void> compactGesture(
  WidgetTester tester,
  ModelScreenFixture f,
  Key key, {
  SupportModelUiBridge? original,
}) async {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget);
  expect(finder.hitTestable(), findsOneWidget);
  expect(tester.widget<IconButton>(finder).onPressed, isNotNull);
  final composer = tester.widget<SupportComposerBar>(
    find.byType(SupportComposerBar),
  );
  final owner = composer.nativeOwner;
  expect(owner, isA<SupportModelUiEmitter>());
  expect((owner as SupportModelUiEmitter).isCurrent, isTrue);
  if (key == compactStop) {
    expect(composer.onStop, isNotNull);
    await f.action(tester, () => tester.tap(finder));
    return;
  }
  expect(composer.available, isTrue);
  expect(composer.busy, isFalse);
  final bridge = original ?? f.bridge;
  var claimed = false;
  final stop = bridge.listen(() {
    if (bridge.view.busy) claimed = true;
  });
  try {
    // Actual enabled button, not direct invocation of a retained callback.
    await f.action(tester, () => tester.tap(finder));
    expect(
      claimed,
      isTrue,
      reason:
          'Actual gesture must synchronously claim its ORIGINAL native bridge.',
    );
  } finally {
    stop();
  }
}

TextEditingController compactDraft(WidgetTester tester) => tester
    .widget<SupportComposerBar>(find.byType(SupportComposerBar))
    .controller;

List<Map<String, dynamic>> compactWire(ModelScreenFixture f, int index) {
  final adapter = f.adapters[index];
  expect(adapter.fetches, 1);
  expect(adapter.options!.uri.toString(), f.api.endpoint);
  expect(
    adapter.options!.headers['Authorization'],
    'Bearer ${ModelScreenFixture.key}',
  );
  final raw = adapter.upload!;
  expect(raw, isNot(contains('support.model_provenance')));
  expect(raw, isNot(contains(ModelScreenFixture.secret)));
  expect(raw, isNot(contains(ModelScreenFixture.key)));
  return ((jsonDecode(raw) as Map<String, dynamic>)['messages'] as List)
      .cast<Map<String, dynamic>>();
}

String compactResponse(String text, {int? input, int? output, int? total}) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {'content': text},
        },
      ],
    })}\n\n'
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
      ],
      if (input != null || output != null || total != null) 'usage': {'prompt_tokens': ?input, 'completion_tokens': ?output, 'total_tokens': ?total},
    })}\n\n'
    'data: [DONE]\n\n';

Future<SupportContextBlock?> compactBlock(ModelScreenFixture f) =>
    f.repo.getContextBlockById(
      SupportCompactionStore.checkpointId(ModelScreenFixture.session),
    );
