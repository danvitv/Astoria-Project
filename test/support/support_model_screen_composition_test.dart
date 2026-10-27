import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_provider_fixture_http.dart';
import 'helpers/support_model_screen_fixture.dart';

const _send = ValueKey('support_composer_send_btn');
const _stop = ValueKey('support_composer_stop_btn');
const _visible = 'Safe visible legacy conversation';

TextEditingController _draft(WidgetTester tester) => tester
    .widget<SupportComposerBar>(find.byType(SupportComposerBar))
    .controller;

String _paint(WidgetTester tester) => tester
    .widgetList<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
    .map((widget) => widget.text)
    .join('\n');

bool _isTerminal(SupportModelRunView view) =>
    view.phase == SupportModelPhase.settled && !view.busy;

// Subscribe BEFORE the action on its ORIGINAL issuer. An earlier terminal state
// cannot satisfy a later turn; neither a preview nor a replacement read is used.
Future<SupportModelRunView> _phase(
  SupportModelUiBridge original,
  bool Function(SupportModelRunView) predicate,
) {
  final reached = Completer<SupportModelRunView>();
  late final void Function() stop;
  stop = original.listen(() {
    if (!reached.isCompleted && predicate(original.view)) {
      stop();
      reached.complete(original.view);
    }
  });
  addTearDown(stop);
  return reached.future;
}

Future<void> _release(SupportModelUiBridge original) => Future.any([
  _phase(original, (view) => !view.busy).then((_) {}),
  original.drained,
]);

Future<VoidCallback> _emittedSend(
  WidgetTester tester,
  ModelScreenFixture fixture,
  String text,
) async {
  final controller = _draft(tester);
  await fixture.action(tester, () => controller.text = text);
  // Empty -> draft must rebuild the ORIGINAL composer before retaining Send.
  // Pumps stay outside the real/native action zone and before any dispatch.
  await tester.pump();
  expect(_draft(tester), same(controller));
  expect(controller.text, text);
  expect(find.byKey(_send).hitTestable(), findsOneWidget);
  final callback = tester.widget<IconButton>(find.byKey(_send)).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<void> _sendDirect(
  WidgetTester tester,
  ModelScreenFixture fixture, {
  String text = 'Exact native current question',
  bool duplicate = false,
}) async {
  final callback = await _emittedSend(tester, fixture, text);
  await fixture.action(tester, () {
    callback();
    if (duplicate) callback();
  });
}

// Measure the control's ORIGINAL outer ListView/Scrollable and the owning
// settings SheetView header. Removed prompt sheets have no geometry contract.
({Rect control, Rect visible, Finder scrollable}) _sheetControlBounds(
  WidgetTester tester,
  Finder control,
  Finder list,
) {
  expect(control, findsOneWidget);
  expect(list, findsOneWidget);
  final owningList = find.ancestor(
    of: control,
    matching: find.byType(ListView),
  );
  expect(owningList, findsOneWidget);
  expect(tester.element(owningList), same(tester.element(list)));
  final sheet = find.ancestor(of: list, matching: find.byType(SheetView));
  expect(sheet, findsOneWidget);
  final sheetWidget = tester.widget<SheetView>(sheet);
  final title = find.descendant(
    of: sheet,
    matching: sheetWidget.titleWidget != null
        ? find.byWidget(sheetWidget.titleWidget!)
        : find.text(sheetWidget.title!),
  );
  expect(title, findsOneWidget);
  final header = find.descendant(
    of: sheet,
    matching: find.ancestor(
      of: title,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Positioned &&
            widget.top == 0 &&
            widget.left == 0 &&
            widget.right == 0 &&
            widget.bottom == null,
      ),
    ),
  );
  expect(header, findsOneWidget);
  final original = Scrollable.of(tester.element(control));
  final scrollable = find.descendant(
    of: list,
    matching: find.byElementPredicate(
      (element) => identical(element, original.context),
    ),
  );
  expect(scrollable, findsOneWidget);
  expect(original.position.hasContentDimensions, isTrue);
  final viewport = tester
      .getRect(scrollable)
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  final headerRect = tester.getRect(header);
  expect(headerRect.height, greaterThan(0));
  final visible = Rect.fromLTRB(
    viewport.left,
    headerRect.bottom > viewport.top ? headerRect.bottom : viewport.top,
    viewport.right,
    viewport.bottom,
  );
  expect(visible.height, greaterThan(0));
  return (
    control: tester.getRect(control),
    visible: visible,
    scrollable: scrollable,
  );
}

void _expectSheetControl(WidgetTester tester, Finder control, Finder list) {
  final bounds = _sheetControlBounds(tester, control, list);
  expect(bounds.control.top, greaterThanOrEqualTo(bounds.visible.top));
  expect(bounds.control.bottom, lessThanOrEqualTo(bounds.visible.bottom));
  expect(bounds.control.left, greaterThanOrEqualTo(bounds.visible.left));
  expect(bounds.control.right, lessThanOrEqualTo(bounds.visible.right));
  expect(control.hitTestable(), findsOneWidget);
}

Future<void> _revealSheetControl(
  WidgetTester tester,
  ModelScreenFixture fixture,
  Finder control,
  Finder list,
) async {
  for (var drag = 0; drag < 8; drag++) {
    final bounds = _sheetControlBounds(tester, control, list);
    if (bounds.control.top >= bounds.visible.top &&
        bounds.control.bottom <= bounds.visible.bottom) {
      _expectSheetControl(tester, control, list);
      return;
    }
    expect(bounds.control.height, lessThanOrEqualTo(bounds.visible.height));
    final delta = bounds.control.bottom > bounds.visible.bottom
        ? bounds.visible.bottom - bounds.control.bottom
        : bounds.visible.top - bounds.control.top;
    final distance = delta
        .clamp(-bounds.visible.height / 2, bounds.visible.height / 2)
        .toDouble();
    await fixture.action(tester, () {
      expect(
        tester
            .hitTestOnBinding(bounds.visible.center)
            .path
            .any(
              (entry) => identical(
                entry.target,
                tester.renderObject(bounds.scrollable),
              ),
            ),
        isTrue,
      );
      return tester.dragFrom(bounds.visible.center, Offset(0, distance));
    });
    await tester.pumpAndSettle();
  }
  _expectSheetControl(tester, control, list);
}

void main() {
  for (final topic in [null, 'provider_setup']) {
    testWidgets('actual configured open/restore/topic $topic are zero HTTP', (
      tester,
    ) async {
      final f = ModelScreenFixture(topic: topic);
      await f.run(tester, () async {
        expect(f.adapters, isEmpty);
        expect(
          find.byKey(const ValueKey('support_text_only_notice')),
          findsOneWidget,
        );
        if (topic != null) {
          final refreshed = await f.signal(
            tester,
            f.workspace.refresh,
            label: 'post-frame topic refresh',
          );
          await f.finish(tester, refreshed);
          await tester.pump();
          expect(f.state.lastHandledTopic, topic);
        }
        final before = f.state.activeMessages.length;
        await f.action(tester, () async {
          _draft(tester).text = 'Help without network';
        });
        await tester.pump();
        final drawer = find.byKey(const ValueKey('support_drawer_toggle'));
        if (drawer.evaluate().isNotEmpty) {
          await f.action(tester, () => tester.tap(drawer));
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const ValueKey('support_composer_local_help_btn')),
            ),
            alignment: .5,
          );
          await tester.pump();
        }
        await f.action(tester, () async {
          await tester.tap(
            find.byKey(const ValueKey('support_composer_local_help_btn')),
          );
        });
        final refreshed = await f.signal(
          tester,
          f.workspace.refresh,
          label: 'original local-help FIFO refresh',
        );
        await f.finish(tester, refreshed);
        await tester.pumpAndSettle();
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.length, before + 2);
        expect(
          f.state.activeMessages.last.body,
          contains('Сетевые запросы и исправления не выполнялись.'),
        );
      });
    });
  }

  testWidgets('actual no-model Send keeps draft and never falls back', (
    tester,
  ) async {
    final f = ModelScreenFixture(configured: false, confirm: false);
    await f.run(tester, () async {
      final controller = _draft(tester);
      final before = f.state.activeMessages.map((m) => m.id).toList();
      await _sendDirect(tester, f, text: 'Retained prerequisite draft');
      await tester.pumpAndSettle();
      expect(controller.text, 'Retained prerequisite draft');
      expect(f.adapters, isEmpty);
      expect(f.state.activeMessages.map((m) => m.id), before);
      expect(find.text(SupportModelRefusal.noModel.label), findsOneWidget);
    });
  });

  testWidgets(
    'actual settings/manual model picker only projects metadata and never probes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        await f.action(
          tester,
          () => tester.tap(
            find.byKey(const ValueKey('mobile_open_settings_btn')),
          ),
        );
        await tester.pumpAndSettle();
        final selector = find.byKey(const ValueKey('support_model_selector'));
        final settingsList = find.ancestor(
          of: selector,
          matching: find.byType(ListView),
        );
        await _revealSheetControl(tester, f, selector, settingsList);
        await f.action(tester, () {
          _expectSheetControl(tester, selector, settingsList);
          return tester.tap(selector);
        });
        await tester.pumpAndSettle();
        expect(find.text('Модель Астории'), findsOneWidget);
        expect(find.text('Идентификатор модели'), findsOneWidget);
        expect(f.adapters, isEmpty);
        expect(find.textContaining(ModelScreenFixture.key), findsNothing);
        expect(find.textContaining('SYNTHETIC_STALE_VAULT_KEY'), findsNothing);
        expect(
          find.textContaining('Открытие списка не отправляет prompt'),
          findsOneWidget,
        );
        for (var route = 0; route < 2; route++) {
          await f.action(
            tester,
            () => f.router.routerDelegate.navigatorKey.currentState!.pop(),
          );
          await tester.pumpAndSettle();
        }
      });
    },
  );

  testWidgets(
    'retained actual Send after session ABA cannot mint a fresh issuer',
    (tester) async {
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        final controller = _draft(tester);
        final oldCallback = await _emittedSend(
          tester,
          f,
          'Retained emitted Send',
        );
        await f.action(tester, () {
          f.workspace.selectSession(ModelScreenFixture.other);
          f.workspace.selectSession(ModelScreenFixture.session);
          oldCallback();
        });
        final refreshed = await f.signal(
          tester,
          f.workspace.refresh,
          label: 'retained Send session-ABA refresh',
        );
        await f.finish(tester, refreshed);
        await tester.pumpAndSettle();
        expect(f.adapters, isEmpty);
        expect(controller.text, 'Retained emitted Send');
        expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
      });
    },
  );

  testWidgets(
    'actual direct duplicate latch, safe private wire and durable order',
    (tester) async {
      final f = ModelScreenFixture(confirm: false, oldBody: _visible);
      await f.run(tester, () async {
        final original = await f.action(tester, () => f.bridge);
        final terminal = await f.signal(
          tester,
          () => _phase(original, _isTerminal),
          label: 'original direct Send completion',
        );
        const text = 'Exact **question** ${ModelScreenFixture.secret}';
        final safeText = f.redaction.redactor.redactText(text);
        await _sendDirect(tester, f, text: text, duplicate: true);
        final result = await f.finish(tester, terminal);
        await tester.pumpAndSettle();
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.dispatch, PrivateTextDispatch.admitted);
        expect(_draft(tester).text, isEmpty);
        expect(f.adapters, hasLength(1));
        final adapter = f.adapters.single;
        expect(adapter.fetches, 1);
        expect(adapter.options!.method, 'POST');
        expect(adapter.options!.uri.toString(), f.api.endpoint);
        expect(
          adapter.options!.headers['Authorization'],
          'Bearer ${ModelScreenFixture.key}',
        );
        final wire = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        expect(wire['model'], 'screen-selected-model');
        expect(wire['temperature'], 0.25);
        expect(wire['max_tokens'], 512);
        final messages = (wire['messages'] as List)
            .cast<Map<String, dynamic>>();
        expect(messages.where((m) => m['role'] != 'system'), [
          {'role': 'assistant', 'content': _visible},
          {'role': 'user', 'content': safeText},
        ]);
        for (final excluded in [
          ModelScreenFixture.excluded,
          ModelScreenFixture.secret,
          ModelScreenFixture.key,
          'SYNTHETIC_STALE_VAULT_KEY',
        ]) {
          expect(adapter.upload, isNot(contains(excluded)));
        }
        final owned = f.state.activeMessages
            .where((m) => m.runId == result.runId)
            .toList();
        expect(owned, hasLength(2));
        expect(owned.map((m) => m.role), [
          SupportMessageRole.user,
          SupportMessageRole.assistant,
        ]);
        expect(owned.first.body, safeText);
        expect(owned.last.status, 'complete');
        expect(owned.last.createdAt.isAfter(owned.first.createdAt), isTrue);
        final durable = await f.signal(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
          label: 'original direct durable order',
        );
        final rows = await f.finish(tester, durable);
        expect(rows.map((m) => m.id), f.state.activeMessages.map((m) => m.id));
        final answer = find.byWidgetPredicate(
          (widget) =>
              widget is SupportPlainMarkdown &&
              widget.text.contains('Safe actual screen answer'),
        );
        final feed = find
            .descendant(
              of: find.byType(SupportMessageList),
              matching: find.byType(Scrollable),
            )
            .first;
        await f.action(
          tester,
          () => tester.scrollUntilVisible(answer, 250, scrollable: feed),
        );
        expect(_paint(tester), contains('Safe actual screen answer'));
      });
    },
  );

  for (final failure in ['append', 'terminal']) {
    testWidgets(
      'actual $failure failure preserves truthful direct acceptance without raw error',
      (tester) async {
        final f = ModelScreenFixture(confirm: false, oldBody: _visible)
          ..quiet = failure == 'terminal'
          ..response = '';
        await f.run(tester, () async {
          final controller = _draft(tester);
          final original = await f.action(tester, () => f.bridge);
          final terminal = await f.signal(
            tester,
            () => _phase(original, _isTerminal),
            label: 'original $failure failure completion',
          );
          void failWrites() {
            f.primitive.afterEncrypt = (aad) async {
              if (aad.contains('support_messages')) {
                throw StateError('RAW_CIPHER_PRIVATE_CANARY');
              }
            };
          }

          if (failure == 'append') {
            await f.action(tester, failWrites);
            await _sendDirect(
              tester,
              f,
              text: 'Unaccepted failed append draft',
            );
          } else {
            final created = await f.signal(
              tester,
              () => f.adapterCreated.future,
              label: 'original accepted fault adapter',
            );
            await _sendDirect(tester, f);
            final adapter = await f.finish(tester, created);
            final listening = await f.signal(
              tester,
              () => adapter.responseListening,
              label: 'original accepted fault response subscription',
            );
            await f.finish(tester, listening);
            await tester.pump();
            expect(controller.text, isEmpty);
            await f.action(tester, () async {
              controller.text = 'New typing before failed settlement';
              failWrites();
              await tester.tap(find.byKey(_stop));
            });
          }
          final result = await f.finish(tester, terminal);
          await f.action(tester, () => f.primitive.afterEncrypt = null);
          await tester.pumpAndSettle();
          expect(result.accepted, failure == 'terminal');
          expect(result.saved, isFalse);
          expect(
            controller.text,
            failure == 'terminal'
                ? 'New typing before failed settlement'
                : 'Unaccepted failed append draft',
          );
          expect(
            find.textContaining('RAW_CIPHER_PRIVATE_CANARY'),
            findsNothing,
          );
          if (failure == 'append') {
            expect(
              f.state.activeMessages.where((m) => m.runId != null),
              isEmpty,
            );
            expect(f.adapters, isEmpty);
          } else {
            expect(f.state.activeMessages.last.body, isEmpty);
            expect(f.adapters.single.fetches, 1);
          }
        });
      },
    );
  }

  for (final invalidation in [
    'draft-ABA',
    'session-ABA',
    'issuer',
    'Stop',
    'unmount',
  ]) {
    testWidgets(
      'actual emitted $invalidation before first awaited read never appends/rebinds',
      (tester) async {
        final f = ModelScreenFixture(confirm: false);
        await f.run(tester, () async {
          final gate = await f.action(tester, f.barrier);
          await f.action(tester, () {
            var paused = false;
            f.primitive.beforeDecrypt = (_) async {
              if (!paused) {
                paused = true;
                await gate.wait();
              }
            };
          });
          final original = await f.action(tester, () => f.bridge);
          final preparing = await f.signal(
            tester,
            () =>
                _phase(original, (v) => v.phase == SupportModelPhase.preparing),
            label: 'original pre-read preparing',
          );
          final entered = await f.signal(
            tester,
            () => gate.entered.future,
            label: 'original decrypt barrier entered',
          );
          final controller = _draft(tester);
          await _sendDirect(tester, f, text: 'ABA draft');
          await f.finish(tester, entered);
          await f.finish(tester, preparing);
          await tester.pump();
          final released = await f.signal(
            tester,
            () => _release(original),
            label: 'original pre-read $invalidation release',
          );
          switch (invalidation) {
            case 'draft-ABA':
              await f.action(tester, () {
                controller.text = 'Changed away';
                controller.text = 'ABA draft';
              });
            case 'session-ABA':
              await f.action(tester, () {
                f.workspace.selectSession(ModelScreenFixture.other);
                f.workspace.selectSession(ModelScreenFixture.session);
              });
            case 'issuer':
              await f.action(tester, () {
                f.container.invalidate(supportModelUiBridgeProvider);
                f.bridge;
              });
            case 'Stop':
              expect(find.byKey(_stop).hitTestable(), findsOneWidget);
              await f.action(tester, () async {
                controller.text = 'New typing survives Stop';
                await tester.tap(find.byKey(_stop));
              });
            case 'unmount':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          await f.action(tester, () {
            gate.release();
            f.primitive.beforeDecrypt = null;
          });
          await f.finish(tester, released);
          final refreshed = await f.signal(
            tester,
            f.workspace.refresh,
            label: 'original pre-read $invalidation workspace refresh',
          );
          await f.finish(tester, refreshed);
          await tester.pumpAndSettle();
          expect(f.adapters, isEmpty);
          expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
          if (invalidation != 'unmount') {
            expect(
              controller.text,
              invalidation == 'Stop' ? 'New typing survives Stop' : 'ABA draft',
            );
          }
        });
      },
    );
  }

  // These complement the new direct custody cohort: source body/membership,
  // session ABA and the saved API row (not its UI settings or deletion signal).
  for (final invalidation in [
    'source body',
    'source membership',
    'session ABA',
    'API row',
  ]) {
    testWidgets('actual $invalidation at final fake-adapter ROOT denies wire', (
      tester,
    ) async {
      final f = ModelScreenFixture(confirm: false, oldBody: _visible);
      await f.run(tester, () async {
        final original = await f.action(tester, () => f.bridge);
        final gate = await f.action(tester, f.barrier);
        final entered = await f.signal(
          tester,
          () => gate.entered.future,
          label: 'original final-adapter ROOT entered',
        );
        await f.action(tester, () {
          f.onFinalAdapter = (_) {
            f.sql.afterSelect = (statement, _) async {
              if (statement == 'PRAGMA busy_timeout' && !gate.released) {
                // This provisional SQL fault runs in the ORIGINAL transaction
                // zone before its first main-data read. Never await an outside
                // DB writer while holding this ROOT barrier: it would deadlock.
                f.sql.afterSelect = null;
                switch (invalidation) {
                  case 'source body':
                    final old = await f.repo.getMessageById('old');
                    await f.repo.putMessage(
                      old!.copyWith(body: 'Changed visible source'),
                    );
                  case 'source membership':
                    await f.repo.putMessage(
                      const SupportMessage(
                        id: 'new-historical-row',
                        sessionId: ModelScreenFixture.session,
                        role: 'user',
                        body: 'Not in the original emitted conversation',
                        createdAt: 3,
                      ),
                    );
                  case 'API row':
                    await ApiConfigRepo(f.db).put(
                      f.api.copyWith(
                        endpoint: 'https://changed.invalid/v1/chat/completions',
                      ),
                    );
                  case 'session ABA':
                    break;
                }
                await gate.wait();
              }
            };
          };
        });
        await _sendDirect(
          tester,
          f,
          text: 'Original accepted final-boundary USER',
        );
        await f.finish(tester, entered);
        await tester.pump();
        final adapter = f.adapters.single;
        expect(adapter.fetches, 0);
        expect(original.view.busy, isTrue);
        expect(_draft(tester).text, isEmpty);
        final released = await f.signal(
          tester,
          () => _release(original),
          label: 'original final $invalidation release',
        );
        if (invalidation == 'session ABA') {
          await f.action(tester, () {
            f.workspace.selectSession(ModelScreenFixture.other);
            f.workspace.selectSession(ModelScreenFixture.session);
          });
        }
        await f.action(tester, () {
          f.onFinalAdapter = null;
          f.sql.afterSelect = null;
          gate.release();
        });
        await f.finish(tester, released);
        final refreshed = await f.signal(
          tester,
          f.workspace.refresh,
          label: 'original final $invalidation workspace refresh',
        );
        await f.finish(tester, refreshed);
        final durable = await f.signal(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
          label: 'original accepted USER after final invalidation',
        );
        final rows = await f.finish(tester, durable);
        expect(
          rows.where(
            (m) =>
                m.role == 'user' &&
                m.body == 'Original accepted final-boundary USER',
          ),
          hasLength(1),
        );
        expect(f.adapters, [same(adapter)]);
        expect(adapter.fetches, 0);
        expect(adapter.upload, isNull);
        expect(adapter.native.responseListens, 0);
      });
    });
  }

  testWidgets(
    'accepted direct input survives later typing and old quiet-SSE Stop cannot cancel replacement',
    (tester) async {
      final f = ModelScreenFixture(confirm: false, oldBody: _visible)
        ..quiet = true
        ..response = '';
      await f.run(tester, () async {
        final original = await f.action(tester, () => f.bridge);
        final created = await f.signal(
          tester,
          () => f.adapterCreated.future,
          label: 'original quiet adapter',
        );
        await _sendDirect(tester, f);
        final adapter = await f.finish(tester, created);
        final listening = await f.signal(
          tester,
          () => adapter.responseListening,
          label: 'original quiet response subscription',
        );
        await f.finish(tester, listening);
        await tester.pump();
        final controller = _draft(tester);
        await f.action(
          tester,
          () => controller.text = 'New draft while waiting',
        );
        final oldStop = tester.widget<IconButton>(find.byKey(_stop)).onPressed!;
        final terminal = await f.signal(
          tester,
          () => _phase(original, _isTerminal),
          label: 'original quiet Stop completion',
        );
        final cancelled = await f.signal(
          tester,
          () => adapter.cancelObserved.future,
          label: 'original quiet CancelToken',
        );
        final unsubscribed = await f.signal(
          tester,
          () => adapter.native.responseCancelled.future,
          label: 'original quiet response cancellation',
        );
        await f.action(tester, oldStop);
        await f.finish(tester, cancelled);
        await f.finish(tester, unsubscribed);
        final first = await f.finish(tester, terminal);
        await tester.pumpAndSettle();
        expect(controller.text, 'New draft while waiting');
        expect(f.state.activeMessages.last.status, 'stopped');
        expect(adapter.fetches, 1);
        expect(adapter.native.responseListens, 1);
        expect(adapter.closed, isTrue);
        final secondAdapter = await f.action(
          tester,
          Completer<ModelProviderHttpAdapter>.new,
        );
        await f.action(tester, () => f.onFinalAdapter = secondAdapter.complete);
        final next = await f.signal(
          tester,
          () => secondAdapter.future,
          label: 'replacement original quiet adapter',
        );
        await _sendDirect(tester, f, text: 'Replacement current question');
        final replacement = await f.finish(tester, next);
        final replacementListening = await f.signal(
          tester,
          () => replacement.responseListening,
          label: 'replacement actual quiet response subscription',
        );
        await f.finish(tester, replacementListening);
        await tester.pump();
        final replacementRun = original.view.runId;
        expect(replacementRun, isNot(first.runId));
        await f.action(tester, oldStop);
        expect(original.view.busy, isTrue);
        expect(original.view.runId, replacementRun);
        expect(replacement.cancelObserved.isCompleted, isFalse);
        expect(replacement.closed, isFalse);
        final secondTerminal = await f.signal(
          tester,
          () => _phase(original, _isTerminal),
          label: 'replacement current Stop completion',
        );
        final secondCancelled = await f.signal(
          tester,
          () => replacement.cancelObserved.future,
          label: 'replacement current CancelToken',
        );
        await f.action(tester, () => tester.tap(find.byKey(_stop)));
        await f.finish(tester, secondCancelled);
        await f.finish(tester, secondTerminal);
        expect(f.adapters, [same(adapter), same(replacement)]);
        expect(replacement.fetches, 1);
      });
    },
  );

  for (final error in [false, true]) {
    testWidgets(
      'actual direct ${error ? 'error' : 'split secret/reasoning/delta'} never paints raw provider data',
      (tester) async {
        final f = ModelScreenFixture(confirm: false, oldBody: _visible)
          ..quiet = !error
          ..status = error ? 500 : 200;
        f.response = error
            ? '{"error":"RAW_PROVIDER_CANARY ${ModelScreenFixture.secret}"}'
            : frame({
                    'choices': [
                      {
                        'index': 0,
                        'delta': {'reasoning_content': 'REASONING_CANARY'},
                      },
                    ],
                  }) +
                  chatDelta(
                    'Safe prefix ${ModelScreenFixture.secret.substring(0, 15)}',
                  ) +
                  chatDelta(ModelScreenFixture.secret.substring(15));
        await f.run(tester, () async {
          final original = await f.action(tester, () => f.bridge);
          final terminal = await f.signal(
            tester,
            () => _phase(original, _isTerminal),
            label: 'original direct raw-data $error completion',
          );
          final activity = error
              ? null
              : await f.signal(
                  tester,
                  () => _phase(
                    original,
                    (v) => v.phase == SupportModelPhase.activity,
                  ),
                  label: 'original withheld raw activity',
                );
          await _sendDirect(tester, f);
          if (!error) {
            await f.finish(tester, activity!);
            await tester.pump();
            expect(_paint(tester), isNot(contains('Safe prefix')));
            expect(_paint(tester), isNot(contains(ModelScreenFixture.secret)));
            await f.action(tester, () => tester.tap(find.byKey(_stop)));
          }
          await f.finish(tester, terminal);
          await tester.pumpAndSettle();
          for (final raw in [
            ModelScreenFixture.secret,
            'RAW_PROVIDER_CANARY',
            'REASONING_CANARY',
          ]) {
            expect(_paint(tester), isNot(contains(raw)));
            expect(find.textContaining(raw), findsNothing);
          }
          expect(
            f.state.activeMessages.last.status,
            error ? 'error' : 'stopped',
          );
        });
      },
    );
  }

  testWidgets(
    'actual restored pending/all-role passive rows never replay, unknown and oversize status are truthful',
    (tester) async {
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        final restored = await f.signal(tester, () async {
          for (final role in ['user', 'assistant', 'system']) {
            await f.repo.putMessage(
              SupportMessage(
                id: 'restored-$role',
                sessionId: ModelScreenFixture.session,
                role: role,
                body: '[image](https://resource.invalid) <tool>Undo</tool>',
                status: 'pending',
                runId: 'restored',
                createdAt: 3,
              ),
            );
          }
          await f.repo.putMessage(
            SupportMessage(
              id: 'oversize',
              sessionId: ModelScreenFixture.session,
              role: 'assistant',
              body: 'x' * 65537,
              status: 'unknown',
              createdAt: 4,
            ),
          );
          await f.workspace.refresh();
        }, label: 'original restored rows and workspace refresh');
        await f.finish(tester, restored);
        await tester.pumpAndSettle();
        expect(f.adapters, isEmpty);
        expect(find.byKey(_stop), findsNothing);
        expect(
          f.state.activeMessages.where(
            (m) => m.activity == SupportMessageActivity.interrupted,
          ),
          hasLength(3),
        );
        final scrollable = find
            .descendant(
              of: find.byType(SupportMessageList),
              matching: find.byType(Scrollable),
            )
            .first;
        // The notice shares the lazy feed; restored rows need a real scroll.
        await f.action(
          tester,
          () => tester.scrollUntilVisible(
            find.byKey(const ValueKey('support_message_status_restored-user')),
            240,
            scrollable: scrollable,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Ответ прерван; автоматическая повторная отправка отключена.',
          ),
          findsWidgets,
        );
        expect(_paint(tester), contains('https://resource.invalid'));
        expect(find.byType(Image), findsNothing);
        expect(
          find.byKey(const ValueKey('support_message_status_old')),
          findsNothing,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('support_message_status_oversize')),
          240,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        expect(
          _paint(tester),
          contains('Текст сообщения недоступен: превышен лимит длины.'),
        );
        expect(
          find.text('Состояние сохранённого ответа недоступно.'),
          findsOneWidget,
        );
      });
    },
  );

  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'actual $width direct Send and quiet Stop are hit-testable at 1.5 scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = ModelScreenFixture(confirm: false, oldBody: _visible)
          ..quiet = true
          ..response = '';
        await f.run(tester, () async {
          await tester.pumpWidget(f.host(scale: 1.5));
          await tester.pumpAndSettle();
          expect(find.byKey(_send).hitTestable(), findsOneWidget);
          final original = await f.action(tester, () => f.bridge);
          final created = await f.signal(
            tester,
            () => f.adapterCreated.future,
            label: 'original $width geometry adapter',
          );
          await _emittedSend(tester, f, 'Scaled direct question');
          await f.action(tester, () => tester.tap(find.byKey(_send)));
          final adapter = await f.finish(tester, created);
          final listening = await f.signal(
            tester,
            () => adapter.responseListening,
            label: 'original $width geometry response subscription',
          );
          await f.finish(tester, listening);
          await tester.pump();
          expect(find.byKey(_stop).hitTestable(), findsOneWidget);
          final terminal = await f.signal(
            tester,
            () => _phase(original, _isTerminal),
            label: 'original $width geometry Stop completion',
          );
          await f.action(tester, () => tester.tap(find.byKey(_stop)));
          await f.finish(tester, terminal);
          await tester.pumpAndSettle();
        });
      },
    );
  }

  testWidgets(
    'row-key priming replaces original issuer instead of transplanting emitted draft',
    (tester) async {
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        final original = await f.action(tester, () => f.bridge);
        final replaced = await f.signal(
          tester,
          () => ApiConfigRepo(
            f.db,
          ).put(f.api.copyWith(apiKey: 'SYNTHETIC_UNOBSERVED_NEW_KEY_98231')),
          label: 'current row-key synthetic update',
        );
        await f.finish(tester, replaced);
        final primed = await f.action(tester, Completer<void>.new);
        void observePriming(Object _) {
          if (!primed.isCompleted) primed.complete();
        }

        final priming = await f.signal(
          tester,
          () => primed.future,
          label: 'actual current-row key priming',
        );
        final drained = await f.signal(
          tester,
          () => original.drained,
          label: 'original issuer retired by key priming',
        );
        final controller = _draft(tester);
        await f.action(tester, () => f.redaction.addListener(observePriming));
        await _emittedSend(tester, f, 'Original issuer draft');
        await f.action(tester, () => tester.tap(find.byKey(_send)));
        await f.finish(tester, priming);
        await f.action(tester, () {
          f.redaction.removeListener(observePriming);
          f.bridge;
        });
        final providers = await f.signal(
          tester,
          () => f.container.pump(),
          label: 'actual priming provider replacement',
        );
        await f.finish(tester, providers);
        await tester.pump();
        await f.finish(tester, drained);
        await tester.pumpAndSettle();
        expect(controller.text, 'Original issuer draft');
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
      });
    },
  );
}
