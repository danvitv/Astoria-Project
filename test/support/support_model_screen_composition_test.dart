import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_screen_fixture.dart';
import 'support_recipient_send_helpers.dart';

const _send = ValueKey('support_composer_send_btn');
const _stop = ValueKey('support_composer_stop_btn');
const _confirm = ValueKey('support_prompt_preview_confirm');
const _cancel = ValueKey('support_prompt_preview_cancel');

TextEditingController _draft(WidgetTester tester) => tester
    .widget<SupportComposerBar>(find.byType(SupportComposerBar))
    .controller;

String _paint(WidgetTester tester) => tester
    .widgetList<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
    .map((widget) => widget.text)
    .join('\n');

// Service phase reporting precedes the bridge's actual finished-result publish.
bool _isTerminal(SupportModelRunView view) =>
    view.phase == SupportModelPhase.settled && !view.busy;

Future<SupportModelRunView> _phase(
  ModelScreenFixture fixture,
  bool Function(SupportModelRunView) predicate,
) {
  final original = fixture.bridge;
  if (predicate(original.view)) return Future.value(original.view);
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

// Measure the control's ORIGINAL outer ListView/Scrollable and the owning
// SheetView's whole positioned header, not its title text or an unrelated list.
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
  // SheetView paints this header above Positioned.fill(body). Its absent
  // bottom constraint distinguishes the actual header from the body viewport.
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
    // The start/end stay in the measured uncovered viewport of this owner.
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
        reason: 'The scroll gesture must hit the original owning Scrollable.',
      );
      return tester.dragFrom(bounds.visible.center, Offset(0, distance));
    });
    await tester.pumpAndSettle();
  }
  _expectSheetControl(tester, control, list);
}

Future<SupportModelPreview> _openPreview(
  WidgetTester tester,
  ModelScreenFixture fixture, {
  String text = 'Exact **native** current question',
}) async {
  final callback = tester.widget<IconButton>(find.byKey(_send)).onPressed!;
  // Capture BEFORE the first await/Send. Closed adapters from earlier approved
  // sends remain in fixture history; this preview must create/fetch nothing new.
  final adapters = fixture.adapters;
  final before = [
    for (final adapter in adapters)
      (
        adapter: adapter,
        fetches: adapter.fetches,
        options: adapter.options,
        upload: adapter.upload,
        responseListens: adapter.native.responseListens,
      ),
  ];
  final preview = await fixture.signal(
    tester,
    () => _phase(fixture, (view) => view.preview != null),
    label: 'original Send preview',
  );
  final controller = _draft(tester);
  await fixture.action(tester, () {
    controller.text = text;
    callback();
    callback(); // Same-turn duplicate MUST remain one actual native send.
  });
  final view = await fixture.finish(tester, preview);
  // An idle-started route ticker takes its epoch from its FIRST frame. A lone
  // 400 ms pump can therefore leave the original sheet at entrance value zero.
  await tester.pump();
  expect(find.byType(SupportModelPromptPreviewSheet), findsOneWidget);
  final route = ModalRoute.of<bool>(
    tester.element(find.byType(SupportModelPromptPreviewSheet)),
  )!;
  expect(route, isA<ModalBottomSheetRoute<bool>>());
  await tester.pump(route.transitionDuration);
  // Installed simulation completes only at time > duration, not equality.
  await tester.pump(const Duration(microseconds: 1));
  expect(route.animation!.status, AnimationStatus.completed);
  expect(route.isCurrent, isTrue);
  final list = find.byKey(const ValueKey('support_prompt_preview_scroll'));
  // Both first actions must fit WITHOUT scrolling; keep this geometry contract.
  _expectSheetControl(tester, find.byKey(_cancel), list);
  _expectSheetControl(tester, find.byKey(_confirm), list);
  expect(fixture.adapters, same(adapters));
  expect(adapters, hasLength(before.length));
  for (var i = 0; i < before.length; i++) {
    final prior = before[i];
    expect(adapters[i], same(prior.adapter));
    expect(prior.adapter.fetches, prior.fetches);
    expect(prior.adapter.options, same(prior.options));
    expect(prior.adapter.upload, prior.upload);
    expect(prior.adapter.native.responseListens, prior.responseListens);
  }
  expect(
    fixture.state.isBusy,
    isFalse,
    reason: 'Preview is outside durable/local FIFO.',
  );
  return view.preview!;
}

Future<void> _confirmPreview(WidgetTester tester, ModelScreenFixture fixture) =>
    _tapPreviewDecision(tester, fixture, confirmed: true);

Future<void> _tapPreviewDecision(
  WidgetTester tester,
  ModelScreenFixture fixture, {
  required bool confirmed,
}) async {
  final list = find.byKey(const ValueKey('support_prompt_preview_scroll'));
  final control = find.byKey(confirmed ? _confirm : _cancel);
  final route = ModalRoute.of<bool>(
    tester.element(find.byType(SupportModelPromptPreviewSheet)),
  )!;
  final popped = await fixture.signal(
    tester,
    () => route.popped,
    label: 'original ${confirmed ? 'Confirm' : 'Cancel'} gesture route result',
  );
  // Do not align an already-visible first action to viewport top: SheetView's
  // interactive header overlays that area and would receive the tap instead.
  await fixture.action(tester, () {
    expect(route.isCurrent, isTrue);
    _expectSheetControl(tester, find.byKey(_cancel), list);
    _expectSheetControl(tester, find.byKey(_confirm), list);
    expect(tester.widget<GlazeActionButton>(control).onTap, isNotNull);
    return tester.tap(control);
  });
  expect(
    await fixture.finish(tester, popped),
    confirmed,
    reason: 'The actual gesture must decide before any retained callback runs.',
  );
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
            () => f.workspace.refresh(),
            label: 'post-frame topic refresh',
          );
          await f.finish(tester, refreshed);
          await tester.pump();
          expect(f.state.lastHandledTopic, topic);
        }
        final before = f.state.activeMessages.length;
        final controller = _draft(tester);
        await f.action(tester, () async {
          controller.text = 'Help without network';
          await tester.tap(
            find.byKey(const ValueKey('support_composer_local_help_btn')),
          );
        });
        final refreshed = await f.signal(
          tester,
          () => f.workspace.refresh(),
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

  for (final configured in [false, true]) {
    testWidgets(
      'actual ${configured ? 'unconfirmed' : 'no model'} Send keeps draft and never falls back',
      (tester) async {
        final f = ModelScreenFixture(configured: configured, confirm: false);
        await f.run(tester, () async {
          final controller = _draft(tester);
          final before = f.state.activeMessages.map((m) => m.id).toList();
          if (configured) {
            // Send now opens recipient review, not a model refusal/run.
            final route = await openRecipientFromSend(
              tester,
              f,
              text: 'Retained prerequisite draft',
            );
            expect(f.adapters, isEmpty);
            expect(f.state.activeMessages.map((m) => m.id), before);
            await decideRecipient(tester, f, route, confirmed: false);
            expect(
              f.container
                  .read(supportNativeConsentControllerProvider)
                  .runtime
                  .recipientConfirmed,
              isFalse,
            );
          } else {
            await f.action(tester, () async {
              controller.text = 'Retained prerequisite draft';
              await tester.tap(find.byKey(_send));
            });
          }
          await tester.pumpAndSettle();
          expect(controller.text, 'Retained prerequisite draft');
          expect(f.adapters, isEmpty);
          expect(f.state.activeMessages.map((m) => m.id), before);
          expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
          if (!configured) {
            expect(
              find.text(SupportModelRefusal.noModel.label),
              findsOneWidget,
            );
          }
        });
      },
    );
  }

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
        // The explicit null catalog port keeps this a manual/no-network fixture.
        expect(find.text('Модель Астории'), findsOneWidget);
        expect(find.text('Идентификатор модели'), findsOneWidget);
        expect(f.adapters, isEmpty);
        expect(find.textContaining(ModelScreenFixture.key), findsNothing);
        expect(find.textContaining('SYNTHETIC_STALE_VAULT_KEY'), findsNothing);
        expect(
          find.textContaining(
            'Открытие списка не отправляет prompt и не запускает генерацию.',
          ),
          findsOneWidget,
        );
        await f.action(
          tester,
          () => f.router.routerDelegate.navigatorKey.currentState!.pop(),
        );
        await tester.pumpAndSettle();
        await f.action(
          tester,
          () => f.router.routerDelegate.navigatorKey.currentState!.pop(),
        );
        await tester.pumpAndSettle();
      });
    },
  );

  testWidgets(
    'retained actual Send after session ABA cannot mint a fresh issuer',
    (tester) async {
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        final controller = _draft(tester);
        final oldCallback = tester
            .widget<IconButton>(find.byKey(_send))
            .onPressed!;
        await f.action(tester, () {
          controller.text = 'Retained emitted Send';
          f.workspace.selectSession(ModelScreenFixture.other);
          f.workspace.selectSession(ModelScreenFixture.session);
          // Before any await/rebuild: the original emitted callback stays stale.
          oldCallback();
        });
        final refreshed = await f.signal(
          tester,
          () => f.workspace.refresh(),
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
    'actual full safe preview, once confirm, exact private wire and durable order',
    (tester) async {
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        final preview = await _openPreview(
          tester,
          f,
          text: 'Exact **question** ${ModelScreenFixture.secret}',
        );
        expect(
          _draft(tester).text,
          isEmpty,
          reason: 'Durable acceptance precedes user decision.',
        );
        final sheet = tester.widget<SupportModelPromptPreviewSheet>(
          find.byType(SupportModelPromptPreviewSheet),
        );
        expect(sheet.values.originLabel, preview.recipient.originLabel);
        expect(sheet.values.operationLabel, preview.recipient.operationLabel);
        expect(sheet.values.modelLabel, 'screen-selected-model');
        expect(
          sheet.values.sections.map((s) => s.text),
          preview.messages.map((m) => m.text),
        );
        expect(sheet.values.sections.last.text, contains('Exact **question**'));
        expect(
          sheet.values.sections.last.text,
          isNot(contains(ModelScreenFixture.secret)),
        );
        final before = f.state.activeMessages.map((m) => m.id).toList();
        final terminal = await f.signal(
          tester,
          () => _phase(f, _isTerminal),
          label: 'original approved terminal',
        );
        final decision = sheet.onDecision;
        await _confirmPreview(tester, f);
        await f.action(tester, () => decision(true)); // No second approval.
        final result = await f.finish(tester, terminal);
        await tester.pumpAndSettle();
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.dispatch, PrivateTextDispatch.admitted);
        expect(f.adapters, hasLength(1));
        final adapter = f.adapters.single;
        expect(adapter.fetches, 1);
        expect(adapter.options!.uri.toString(), f.api.endpoint);
        expect(
          adapter.options!.headers['Authorization'],
          'Bearer ${ModelScreenFixture.key}',
        );
        final wire = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        expect(wire['model'], 'screen-selected-model');
        expect(wire['temperature'], 0.25);
        expect(wire['max_tokens'], 512);
        expect(wire['messages'], [
          for (final m in preview.messages) {'role': m.role, 'content': m.text},
        ]);
        expect(adapter.upload, isNot(contains(ModelScreenFixture.excluded)));
        expect(adapter.upload, isNot(contains(ModelScreenFixture.secret)));
        expect(adapter.upload, isNot(contains(ModelScreenFixture.key)));
        expect(f.state.activeMessages.map((m) => m.id), before);
        expect(
          f.state.activeMessages.where((m) => m.runId == preview.runId),
          hasLength(2),
        );
        expect(f.state.activeMessages.last.status, 'complete');
        // The settings snapshot can occupy the first viewport of the lazy feed.
        // Reveal the actual sanitized reply instead of assuming it is mounted.
        final answer = find.byWidgetPredicate(
          (widget) =>
              widget is SupportPlainMarkdown &&
              widget.text.contains('Safe actual screen answer'),
        );
        final feedState = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SupportMessageList),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final originalFeed = find.byElementPredicate(
          (element) => identical(element, feedState.context),
        );
        await f.action(
          tester,
          () =>
              tester.scrollUntilVisible(answer, 250, scrollable: originalFeed),
        );
        expect(_paint(tester), contains('Safe actual screen answer'));
        expect(
          find.byKey(const ValueKey('support_text_only_notice')),
          findsOneWidget,
        );
      });
    },
  );

  for (final failure in ['append', 'terminal']) {
    testWidgets(
      'actual $failure failure preserves truthful composer acceptance without raw error',
      (tester) async {
        final f = ModelScreenFixture();
        await f.run(tester, () async {
          final controller = _draft(tester);
          SupportModelPreview? preview;
          if (failure == 'terminal') {
            preview = await _openPreview(tester, f);
            expect(controller.text, isEmpty);
            await f.action(
              tester,
              () => controller.text = 'New typing before failed settlement',
            );
          } else {
            await f.action(
              tester,
              () => controller.text = 'Unaccepted failed append draft',
            );
          }
          f.primitive.afterEncrypt = (aad) async {
            if (aad.contains('support_messages')) {
              throw StateError('RAW_CIPHER_PRIVATE_CANARY');
            }
          };
          final terminal = await f.signal(
            tester,
            () => _phase(f, _isTerminal),
            label: 'original $failure failure terminal',
          );
          if (preview != null) {
            await _confirmPreview(tester, f);
          } else {
            await f.action(tester, () => tester.tap(find.byKey(_send)));
          }
          final result = await f.finish(tester, terminal);
          f.primitive.afterEncrypt = null;
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
          expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
          if (preview != null) {
            expect(
              f.state.activeMessages
                  .singleWhere((m) => m.id == preview!.replyMessageId)
                  .body,
              isEmpty,
            );
          } else {
            expect(
              f.state.activeMessages.where((m) => m.runId != null),
              isEmpty,
            );
            expect(f.adapters, isEmpty);
          }
        });
      },
    );
  }

  for (final dismissal in [
    'cancel',
    'back',
    'barrier',
    'system-back',
    'unmount',
  ]) {
    testWidgets(
      'actual preview $dismissal cancels original but durable user stays accepted',
      (tester) async {
        final f = ModelScreenFixture();
        await f.run(tester, () async {
          final preview = await _openPreview(tester, f);
          final decision = tester
              .widget<SupportModelPromptPreviewSheet>(
                find.byType(SupportModelPromptPreviewSheet),
              )
              .onDecision;
          final terminal = await f.signal(
            tester,
            () => _phase(f, (v) => !v.busy),
            label: 'original $dismissal preview release',
          );
          switch (dismissal) {
            case 'cancel':
              await _tapPreviewDecision(tester, f, confirmed: false);
            case 'back':
              final sheet = tester.widget<SheetView>(find.byType(SheetView));
              await f.action(tester, sheet.onBack!);
            case 'barrier':
              await f.action(tester, () => tester.tapAt(const Offset(4, 4)));
            case 'system-back':
              await f.action(tester, tester.binding.handlePopRoute);
            case 'unmount':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          await f.action(tester, () => decision(true));
          // Retired UI may project idle instead of a terminal label. This waits
          // original claim release, not a guessed duration or speculative row.
          await f.finish(tester, terminal);
          await tester.pumpAndSettle();
          expect(f.adapters, isEmpty);
          final users = f.state.activeMessages.where(
            (m) => m.id == preview.userMessageId,
          );
          expect(users, hasLength(1));
          expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
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
        final f = ModelScreenFixture();
        await f.run(tester, () async {
          final gate = await f.action(tester, f.barrier);
          var paused = false;
          f.primitive.beforeDecrypt = (_) async {
            if (!paused) {
              paused = true;
              await gate.wait();
            }
          };
          final original = await f.action(tester, () => f.bridge);
          final idle = await f.signal(
            tester,
            () => _phase(f, (v) => v.phase == SupportModelPhase.preparing),
            label: 'original pre-read preparing',
          );
          final entered = await f.signal(
            tester,
            () => gate.entered.future,
            label: 'original decrypt barrier entered',
          );
          final controller = _draft(tester);
          await f.action(tester, () async {
            controller.text = 'ABA draft';
            await tester.tap(find.byKey(_send));
          });
          await f.finish(tester, entered);
          await f.finish(tester, idle);
          await tester.pump();
          final released = await f.signal(
            tester,
            () => invalidation == 'issuer'
                ? original.drained
                : _phase(f, (v) => !v.busy).then((_) {}),
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
            () => f.workspace.refresh(),
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

  testWidgets(
    'accepted immutable input survives later typing, quiet SSE Stop is real and old Stop cannot cancel replacement',
    (tester) async {
      final f = ModelScreenFixture()
        ..quiet = true
        ..response = '';
      await f.run(tester, () async {
        final first = await _openPreview(tester, f);
        final controller = _draft(tester);
        await f.action(
          tester,
          () => controller.text = 'New draft while reviewing',
        );
        final created = await f.signal(
          tester,
          () => f.adapterCreated.future,
          label: 'original quiet adapter created',
        );
        await _confirmPreview(tester, f);
        final adapter = await f.finish(tester, created);
        final listening = await f.signal(
          tester,
          () => adapter.responseListening,
          label: 'actual quiet SSE subscription',
        );
        await f.finish(tester, listening);
        await tester.pump();
        expect(controller.text, 'New draft while reviewing');
        expect(find.byKey(_stop).hitTestable(), findsOneWidget);
        final oldStop = tester.widget<IconButton>(find.byKey(_stop)).onPressed!;
        final terminal = await f.signal(
          tester,
          () => _phase(f, _isTerminal),
          label: 'original quiet Stop terminal',
        );
        final cancelled = await f.signal(
          tester,
          () => adapter.cancelObserved.future,
          label: 'actual quiet CancelToken observation',
        );
        final unsubscribed = await f.signal(
          tester,
          () => adapter.native.responseCancelled.future,
          label: 'actual quiet response subscription cancellation',
        );
        await f.action(tester, oldStop);
        await f.finish(tester, cancelled);
        await f.finish(tester, unsubscribed);
        await f.finish(tester, terminal);
        await tester.pumpAndSettle();
        expect(controller.text, 'New draft while reviewing');
        expect(
          f.state.activeMessages
              .singleWhere((m) => m.id == first.replyMessageId)
              .status,
          'stopped',
        );
        expect(f.adapters, [same(adapter)]);
        expect(adapter.fetches, 1);
        expect(adapter.native.responseListens, 1);
        expect(adapter.closed, isTrue);
        final second = await _openPreview(
          tester,
          f,
          text: 'Replacement current question',
        );
        await f.action(tester, () {
          oldStop();
          expect(second.isCurrent, isTrue);
        });
        final secondTerminal = await f.signal(
          tester,
          () => _phase(f, (v) => !v.busy),
          label: 'replacement preview release',
        );
        await _tapPreviewDecision(tester, f, confirmed: false);
        await f.finish(tester, secondTerminal);
        await tester.pumpAndSettle();
        expect(f.adapters, hasLength(1));
        expect(f.adapters.single, same(adapter));
        expect(adapter.fetches, 1);
        expect(adapter.native.responseListens, 1);
      });
    },
  );

  testWidgets(
    'accepted preview invalidation and retained confirmation cannot touch a new session/run',
    (tester) async {
      final f = ModelScreenFixture();
      await f.run(tester, () async {
        await _openPreview(tester, f);
        final oldDecision = tester
            .widget<SupportModelPromptPreviewSheet>(
              find.byType(SupportModelPromptPreviewSheet),
            )
            .onDecision;
        final released = await f.signal(
          tester,
          () => _phase(f, (v) => !v.busy),
          label: 'original accepted preview session retirement',
        );
        await f.action(
          tester,
          () => f.workspace.selectSession(ModelScreenFixture.other),
        );
        await f.finish(tester, released);
        final refreshed = await f.signal(
          tester,
          () => f.workspace.refresh(),
          label: 'new-session workspace refresh',
        );
        await f.finish(tester, refreshed);
        await tester.pumpAndSettle();
        await f.action(tester, () => oldDecision(true));
        expect(f.adapters, isEmpty);
        expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
        expect(f.state.activeSessionId, ModelScreenFixture.other);
        expect(f.state.activeMessages, isEmpty);
      });
    },
  );

  for (final error in [false, true]) {
    testWidgets(
      'actual ${error ? 'error' : 'split secret/reasoning/delta'} never paints raw provider data',
      (tester) async {
        final f = ModelScreenFixture()
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
          await _openPreview(tester, f);
          final terminal = await f.signal(
            tester,
            () => _phase(f, _isTerminal),
            label: 'original raw-data $error terminal',
          );
          final activity = error
              ? null
              : await f.signal(
                  tester,
                  () => _phase(f, (v) => v.phase == SupportModelPhase.activity),
                  label: 'original withheld raw activity',
                );
          await _confirmPreview(tester, f);
          if (!error) {
            final created = await f.signal(
              tester,
              () => f.adapterCreated.future,
              label: 'original raw-data adapter created',
            );
            final adapter = await f.finish(tester, created);
            final listening = await f.signal(
              tester,
              () => adapter.responseListening,
              label: 'actual raw-data SSE subscription',
            );
            await f.finish(tester, listening);
            await f.finish(tester, activity!);
            await tester.pump();
            expect(_paint(tester), isNot(contains('Safe prefix')));
            expect(_paint(tester), isNot(contains(ModelScreenFixture.secret)));
            await f.action(tester, () => tester.tap(find.byKey(_stop)));
          }
          await f.finish(tester, terminal);
          await tester.pumpAndSettle();
          final painted = _paint(tester);
          expect(painted, isNot(contains(ModelScreenFixture.secret)));
          expect(painted, isNot(contains('RAW_PROVIDER_CANARY')));
          expect(painted, isNot(contains('REASONING_CANARY')));
          expect(find.textContaining('RAW_PROVIDER_CANARY'), findsNothing);
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
          reason: 'Legacy complete appearance is unchanged.',
        );
        final scrollable = find
            .descendant(
              of: find.byType(SupportMessageList),
              matching: find.byType(Scrollable),
            )
            .first;
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
      'actual $width preview measured inset and quiet Stop remain hit-testable at 1.5 scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = ModelScreenFixture()
          ..quiet = true
          ..response = '';
        await f.run(tester, () async {
          await tester.pumpWidget(f.host(scale: 1.5));
          await tester.pumpAndSettle();
          await _openPreview(tester, f);
          final list = find.byKey(
            const ValueKey('support_prompt_preview_scroll'),
          );
          final sheet = find.byType(SheetView);
          expect(sheet, findsOneWidget);
          expect(
            MediaQuery.paddingOf(tester.element(list)).top,
            greaterThan(0),
          );
          expect(
            tester.getRect(find.byKey(_cancel)).top,
            greaterThanOrEqualTo(
              tester
                  .getRect(
                    find.byKey(const ValueKey('support_prompt_preview_header')),
                  )
                  .bottom,
            ),
          );
          expect(find.byKey(_cancel).hitTestable(), findsOneWidget);
          _expectSheetControl(tester, find.byKey(_cancel), list);
          _expectSheetControl(tester, find.byKey(_confirm), list);
          expect(find.byKey(_confirm).hitTestable(), findsOneWidget);
          await _confirmPreview(tester, f);
          final created = await f.signal(
            tester,
            () => f.adapterCreated.future,
            label: 'original $width geometry adapter',
          );
          final adapter = await f.finish(tester, created);
          final listening = await f.signal(
            tester,
            () => adapter.responseListening,
            label: 'actual $width geometry SSE subscription',
          );
          await f.finish(tester, listening);
          await tester.pump();
          expect(find.byKey(_stop).hitTestable(), findsOneWidget);
          final terminal = await f.signal(
            tester,
            () => _phase(f, _isTerminal),
            label: 'original $width geometry Stop terminal',
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
        await f.action(tester, () async {
          f.redaction.addListener(observePriming);
          controller.text = 'Original issuer draft';
          await tester.tap(find.byKey(_send));
        });
        await f.finish(tester, priming);
        await f.action(tester, () {
          f.redaction.removeListener(observePriming);
          // Read only the actual invalidated replacement in the real zone; the
          // captured original drain/controller remain the assertions' owners.
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
