import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/keyless_api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_tool_native_ui.dart';

import 'support_tool_loop_screen_fixture.dart';

export 'support_tool_loop_fixture.dart';
export 'support_tool_loop_screen_fixture.dart';

const configurationName = 'Exact synthetic terminal profile';
const configurationCreate = <String, Object?>{
  'template': 'openaiChat',
  'name': configurationName,
  'model': 'synthetic-model',
  'maxTokens': 2048,
  'contextSize': 16384,
  'temperature': 0.3,
};

final _configurationReleases = Expando<List<Completer<void>>>();

void configurationWidgetTest(
  String name,
  Future<void> Function(WidgetTester, ToolLoopScreenFixture) body,
) => toolLoopWidgetTest(name, (tester, f) async {
  try {
    await body(tester, f);
  } finally {
    // Failed assertions must not strand an actual started future in teardown.
    for (final gate in _configurationReleases[f] ?? <Completer<void>>[]) {
      if (!gate.isCompleted) gate.complete();
    }
    f.core.native.sql.afterSelect = null;
    f.core.native.sql.afterWrite = null;
    f.core.native.storage.beforeRead = null;
    f.core.native.storage.beforeWrite = null;
    f.core.native.storage.writeThenThrow = false;
  }
});

Completer<void> configurationRelease(ToolLoopScreenFixture f) {
  final gate = Completer<void>();
  (_configurationReleases[f] ??= []).add(gate);
  return gate;
}

/// Issue only the original native action in the REAL async zone. Keep widget
/// pumps outside it. Awaiting firstFetch cannot transfer a previously fake-zone
/// SQL/AEAD/credential-owner continuation onto this event queue.
Future<T> configurationAction<T>(
  WidgetTester tester,
  FutureOr<T> Function() issue,
) async {
  late T value;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    try {
      value = await issue();
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  return value;
}

Future<void> configurationModal(
  WidgetTester tester,
  ToolLoopScreenFixture f,
) async {
  for (
    var turn = 0;
    turn < 128 &&
        find
            .byKey(const ValueKey('support_tool_confirmation_accept'))
            .evaluate()
            .isEmpty;
    turn++
  ) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  if (find
      .byKey(const ValueKey('support_tool_confirmation_accept'))
      .evaluate()
      .isEmpty) {
    // One bounded synthetic-only observation of the ACTUAL original reply and
    // ROOT entries. Emit only known enums/counts, never body/exception/key JSON.
    final rows = await configurationAction(
      tester,
      () => f.core.native.repo.getMessagesForSession(f.core.native.session),
    );
    final original = rows.where(
      (row) => row.role == 'assistant' && row.runId != null,
    );
    final reply = original.isEmpty ? null : original.single;
    final replyStatus =
        const {
          'preparing',
          'pending',
          'complete',
          'error',
          'stopped',
          'limited',
        }.contains(reply?.status)
        ? reply!.status
        : 'unavailable';
    final nativeFact = reply == null
        ? null
        : RegExp(
            '^astoria_connection_(?:create|update): '
            '(${SupportAppActionCode.values.map((code) => code.name).join('|')});',
            multiLine: true,
          ).firstMatch(reply.body)?.group(1);
    final rootEntries = f.core.native.sql.observations
        .where((entry) => entry.statement.contains('PRAGMA busy_timeout'))
        .length;
    final view = f.core.bridge.view;
    throw TestFailure(
      'Original native confirmation was not rendered: '
      'posts=${f.core.wire.length}, roots=$rootEntries, busy=${view.busy}, '
      'reason=${view.reason.name}, status=${view.status?.name}, '
      'replyStatus=$replyStatus, nativeCode=${nativeFact ?? 'noNativeFact'}.',
    );
  }
  final accept = find.byKey(const ValueKey('support_tool_confirmation_accept'));
  expect(accept, findsOneWidget);
  final route = ModalRoute.of<void>(tester.element(accept))!;
  expect(route, isA<ModalBottomSheetRoute<void>>());
  expect(route.isCurrent, isTrue);
  // Only this sheet's finite entrance; the original model is still busy.
  await tester.pump(); // Establish the original ticker's first frame.
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.animation!.status, AnimationStatus.completed);
  expect(route.isCurrent, isTrue);
  // Keep the shared helper's real 800x600 footer checks, without global idle.
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  for (final name in ['cancel', 'accept']) {
    final button = find.byKey(ValueKey('support_tool_confirmation_$name'));
    expect(button, findsOneWidget);
    expect(button.hitTestable(), findsOneWidget);
    final bounds = tester.getRect(button);
    expect(viewport.contains(bounds.topLeft), isTrue);
    expect(viewport.contains(bounds.bottomRight), isTrue);
  }
  final preview = find.byKey(
    const ValueKey('support_tool_confirmation_preview'),
  );
  expect(preview, findsOneWidget);
  expect(
    find.descendant(
      of: preview,
      matching: find.byKey(const ValueKey('support_tool_confirmation_accept')),
    ),
    findsNothing,
  );
}

Future<void> configurationDecision(WidgetTester tester, String decision) async {
  final button = find.byKey(ValueKey('support_tool_confirmation_$decision'));
  expect(button, findsOneWidget);
  final route = ModalRoute.of<void>(tester.element(button))!;
  expect(route, isA<ModalBottomSheetRoute<void>>());
  final reverseDuration = route.reverseTransitionDuration;
  await configurationAction(tester, () {
    expect(route.isCurrent, isTrue);
    return tester.tap(button);
  });
  // Pop only the captured original sheet. Native gates belong to the caller;
  // the still-busy model/composer need not reach global frame idleness here.
  await tester.pump();
  await tester.pump(reverseDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.isCurrent, isFalse);
}

/// Source/ROOT retirement can forbid ANY view publication. Join the actual
/// original durable reply stream, never saved=true on a replacement UI/source.
Future<void> configurationIdle(WidgetTester tester, ToolLoopScreenFixture f) {
  // The subscription also owns async encrypted reads. Capture that original
  // future without flattening/awaiting settlement inside runAsync.
  Future<List<SupportMessage>> observe() => f.core.native.repo
      .watchMessagesForSession(f.core.native.session)
      .firstWhere(
        (rows) => rows.any(
          (row) =>
              row.role == 'assistant' &&
              row.runId != null &&
              const {
                'complete',
                'error',
                'stopped',
                'limited',
              }.contains(row.status),
        ),
      );
  return configurationAction(
    tester,
    () => (future: observe()),
  ).then((signal) => f.join(tester, signal.future)).then((_) {});
}

Future<SupportMessage> configurationReply(
  WidgetTester tester,
  ToolLoopScreenFixture f,
) async {
  final messages = await tester.runAsync(
    () => f.core.native.repo.getMessagesForSession(f.core.native.session),
  );
  return messages!
      .where((m) => m.role == 'assistant' && m.runId != null)
      .single;
}

Future<void> configurationSend(
  WidgetTester tester,
  ToolLoopScreenFixture f,
) async {
  await tester.enterText(
    find.byType(TextField).first,
    'Edit this exact connection.',
  );
  await configurationAction(
    tester,
    () => tester.tap(find.byKey(const ValueKey('support_composer_send_btn'))),
  );
  await f.join(tester, f.core.firstFetch.future);
  await configurationModal(tester, f);
}

SupportModelToolNativeUi configurationUi(
  WidgetTester tester,
  ToolLoopScreenFixture f,
) => SupportModelToolNativeUi(
  context: tester.element(find.byType(TextField).first),
  isOriginalUiCurrent: () => f.core.emitterCurrent,
);

/// Native guarded ordinary setup in the SYNTHETIC memory root only. Make the
/// keyed source compatible with the existing keyless shape; keep its actual
/// protected key identity/model/purpose unchanged and freshly native-confirm it.
Future<void> configurationUpdateSource(
  WidgetTester tester,
  ToolLoopScreenFixture f,
) async {
  await tester.runAsync(() async {
    final row = await f.core.native.apiRepo.getById(f.core.native.api.id);
    await f.core.native.apiRepo.put(row!.copyWith(embeddingUseSame: false));
    f.core.native.api = (await f.core.native.apiRepo.getById(row.id))!;
    await f.core.native.reconfirm();
    await f.core.container.pump();
  });
  await tester.pumpAndSettle();
}

void configurationNoEgress(ToolLoopScreenFixture f, String visible) {
  final all = '${jsonEncode(f.core.wire)}\n$visible';
  for (final excluded in [
    f.core.boundSyntheticSecret,
    'SYNTHETIC_HIDDEN_PROMPT',
    'SYNTHETIC_EXCLUDED_BODY',
    'SYNTHETIC_NATIVE_FAILURE_RAW',
  ]) {
    expect(all, isNot(contains(excluded)));
  }
}

KeylessApiConfigDraft configurationDraft() => KeylessApiConfigDraft(
  nativeId: NativeKeylessConnectionId.generate(),
  displayName: configurationName,
  providerId: 'openai',
  protocol: 'openai',
  endpoint: 'https://api.openai.com/v1/chat/completions',
  model: 'synthetic-model',
  maxTokens: 2048,
  contextSize: 16384,
  temperature: 0.3,
);

/// Negative native contract fixture: even a current trusted port returning from
/// admit() cannot authorize any effect without consuming the opaque capsule.
final class ConfigurationNoCapsulePort
    implements KeylessTerminalEffectAdmissionPort {
  ConfigurationNoCapsulePort(this.rootCurrent);
  final bool Function() rootCurrent;
  KeylessApiConfigTerminalPlan? plan;
  KeylessTerminalEffectDispatch? retained;
  int attempts = 0;
  @override
  bool isCurrent(KeylessApiConfigTerminalPlan expected) =>
      identical(plan, expected) && rootCurrent();
  @override
  Future<void> admit(KeylessTerminalEffectDispatch dispatch) async {
    attempts++;
    retained = dispatch; // Deliberately NO dispatch(), NO lease and NO effect.
  }
}

/// Denial-only regression port. Preview formation must not dispatch or require
/// this ROOT before any native gesture; it supplies NO model/effect authority.
final class ConfigurationPreviewOnlyRoot implements SupportAppTerminalRootPort {
  int attempts = 0;
  @override
  Future<void> admit(KeylessTerminalEffectDispatch dispatch) async {
    attempts++;
    throw const KeylessApiConfigException();
  }
}
