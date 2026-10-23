import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_display_redaction_screen_actions.dart';
import 'helpers/support_model_screen_fixture.dart';

const _oversize = 'Текст сообщения недоступен: превышен лимит длины.';
const _unsafe = 'Текст сообщения недоступен: не удалось безопасно отобразить.';
const _context = SupportContextBlock(
  id: 'f1-retained-context',
  sessionId: ModelScreenFixture.session,
  startMessageId: 'old',
  endMessageId: 'old',
  summary: 'F1 retained original summary',
  protectedFactsJson: '["F1 retained original fact"]',
  isActive: false,
  createdAt: 2,
);

Future<T> _join<T>(
  WidgetTester tester,
  ModelScreenFixture f,
  Future<T> Function() original,
  String label,
) async => f.finish(tester, await f.signal(tester, original, label: label));

Future<void> _seed(
  WidgetTester tester,
  ModelScreenFixture f,
  List<SupportMessage> messages,
) async {
  await _join(tester, f, () async {
    for (final message in messages) {
      await f.repo.putMessage(message);
    }
    await f.repo.putContextBlock(_context);
  }, 'F1 actual encrypted restored rows');
  // Capture AFTER intended fixture writes, BEFORE the actual display load. A
  // write triggered by decrypt/publication/paint cannot disappear into setup.
  final beforeDisplay = await _Baseline.capture(tester, f);
  await _join(
    tester,
    f,
    () => f.workspace.refresh(),
    'F1 original broad restored display refresh',
  );
  await tester.pumpAndSettle();
  await beforeDisplay.unchanged(tester, f);
}

SupportMessage _row(String id, String body, {String role = 'assistant'}) =>
    SupportMessage(
      id: id,
      sessionId: ModelScreenFixture.session,
      role: role,
      body: body,
      runId: 'f1-restored-original-run',
      status: 'complete',
      createdAt: 3,
    );

/// Observe the actual mounted passive renderer AND its native EditableText and
/// RenderEditable text, not a second projection/toTextSpan computed by the test.
void _expectPaint(WidgetTester tester, String expected) {
  final passive = find.byWidgetPredicate(
    (widget) => widget is SupportPlainMarkdown && widget.text == expected,
  );
  expect(passive, findsWidgets);
  for (final element in passive.evaluate()) {
    final editable = find.descendant(
      of: find.byElementPredicate((candidate) => identical(candidate, element)),
      matching: find.byType(EditableText),
    );
    expect(editable, findsOneWidget);
    final native = tester.widget<EditableText>(editable);
    expect(native.readOnly, isTrue);
    expect(native.contextMenuBuilder, isNull);
    expect(native.controller.text, expected);
    expect(
      tester
          .state<EditableTextState>(editable)
          .renderEditable
          .text!
          .toPlainText(),
      expected,
    );
  }
}

void _expectAbsent(WidgetTester tester, Iterable<String> forbidden) {
  final painted = [
    ...tester
        .widgetList<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
        .map((widget) => widget.text),
    ...tester
        .widgetList<EditableText>(find.byType(EditableText))
        .map((widget) => widget.controller.text),
    ...tester
        .stateList<EditableTextState>(find.byType(EditableText))
        .map((state) => state.renderEditable.text!.toPlainText()),
    ...tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? ''),
    ...tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText()),
  ];
  for (final text in painted) {
    for (final value in forbidden) {
      expect(text, isNot(contains(value)));
    }
  }
  expect(find.byType(Image), findsNothing);
  expect(find.byType(RawImage), findsNothing);
  expect(find.byType(BackdropFilter), findsNothing);
}

/// Snapshot every declared synthetic table, including exact ciphertext and
/// inactive context/provenance/permissions. This never resets boundary spies.
Future<String> _durable(ModelScreenFixture f) async {
  final rows = <String, Object?>{};
  for (final table in f.db.allTables) {
    final result = await f.db
        .customSelect('SELECT * FROM "${table.actualTableName}" ORDER BY rowid')
        .get();
    rows[table.actualTableName] = result.map((row) => row.data).toList();
  }
  return jsonEncode(rows);
}

final class _Baseline {
  _Baseline(ModelScreenFixture f, this.durable)
    : writes = List.of(f.sql.writes),
      encryptions = List.of(f.primitive.encryptAads),
      vaultWrites = f.storage.operations.where((op) => op != 'read').toList(),
      native = f.container.read(supportNativeRuntimeProvider),
      workspace = f.workspace,
      credentialAdapter = f.container.read(apiConfigCredentialAdapterProvider),
      adapters = [
        for (final adapter in f.adapters)
          (
            owner: adapter,
            options: adapter.options,
            upload: adapter.upload,
            fetches: adapter.fetches,
            responseListening: adapter.responseListening,
            listens: adapter.native.responseListens,
            closed: adapter.closed,
          ),
      ];

  final String durable;
  final List<String> writes, encryptions, vaultWrites;
  final Object native, workspace, credentialAdapter;
  final List<
    ({
      Object owner,
      Object? options,
      String? upload,
      int fetches,
      Future<void> responseListening,
      int listens,
      bool closed,
    })
  >
  adapters;

  static Future<_Baseline> capture(
    WidgetTester tester,
    ModelScreenFixture f,
  ) async => _Baseline(
    f,
    await _join(
      tester,
      f,
      () => _durable(f),
      'F1 original raw durable baseline',
    ),
  );

  void noEffects(ModelScreenFixture f) {
    expect(f.sql.writes, writes);
    expect(f.primitive.encryptAads, encryptions);
    expect(
      f.storage.operations.where((op) => op != 'read').toList(),
      vaultWrites,
    );
    expect(f.adapters, hasLength(adapters.length));
    for (var i = 0; i < adapters.length; i++) {
      final before = adapters[i], current = f.adapters[i];
      expect(current, same(before.owner));
      expect(current.options, same(before.options));
      expect(current.upload, before.upload);
      expect(current.fetches, before.fetches);
      expect(current.responseListening, same(before.responseListening));
      expect(current.native.responseListens, before.listens);
      expect(current.closed, before.closed);
    }
    expect(f.isolation.attempts, isEmpty);
  }

  Future<void> unchanged(WidgetTester tester, ModelScreenFixture f) async {
    expect(
      await _join(
        tester,
        f,
        () => _durable(f),
        'F1 original durable comparison',
      ),
      durable,
    );
    expect(f.container.read(supportNativeRuntimeProvider), same(native));
    expect(f.workspace, same(workspace));
    expect(
      f.container.read(apiConfigCredentialAdapterProvider),
      same(credentialAdapter),
    );
    noEffects(f);
    expect(
      await _join(
        tester,
        f,
        () => f.repo.getContextBlockById(_context.id),
        'F1 original protected facts comparison',
      ),
      _context,
    );
  }
}

/// No override/remount/provider pump is allowed to make the first reactive paint
/// pass. A real registration, then one widget frame, must suffice by itself.
Future<void> _register(
  WidgetTester tester,
  ModelScreenFixture f,
  String secret,
) async {
  final original = f.container.read(supportNativeRuntimeProvider);
  final authority = (
    epoch: original.epoch,
    owner: original.writeOwner,
    lifetime: original.lifetime,
    confirmed: original.recipientConfirmed,
    preferences: original.snapshot.preferences,
    recipient: original.recipient,
  );
  await f.action(tester, () => f.redaction.registerSecret(secret));
  await tester.pump();
  expect(
    f.container.read(secretRedactionCoordinatorProvider),
    same(f.redaction),
  );
  expect(f.container.read(secretRedactorProvider), same(f.redaction.redactor));
  expect(f.redaction.redactor.redactText(secret), SecretRedactor.removed);
  expect(f.container.read(supportNativeRuntimeProvider), same(original));
  expect(original.epoch, authority.epoch);
  expect(original.writeOwner, authority.owner);
  expect(original.lifetime, authority.lifetime);
  expect(original.recipientConfirmed, authority.confirmed);
  expect(original.snapshot.preferences, same(authority.preferences));
  expect(original.recipient, same(authority.recipient));
}

Future<void> _reopen(WidgetTester tester, ModelScreenFixture f) async {
  await f.action(
    tester,
    () => f.workspace.selectSession(ModelScreenFixture.other),
  );
  await _join(
    tester,
    f,
    () => f.workspace.refresh(),
    'F1 original other-session refresh',
  );
  await tester.pumpAndSettle();
  expect(f.state.activeSessionId, ModelScreenFixture.other);
  expect(f.state.activeMessages, isEmpty);
  await f.action(
    tester,
    () => f.workspace.selectSession(ModelScreenFixture.session),
  );
  await _join(
    tester,
    f,
    () => f.workspace.refresh(),
    'F1 original same-session reopen',
  );
  await tester.pumpAndSettle();
  expect(f.state.activeSessionId, ModelScreenFixture.session);
}

void main() {
  testWidgets(
    'F1 existing old unselected row-key is known before passive/native paint',
    (tester) async {
      final f = ModelScreenFixture();
      late _Baseline baseline;
      await f.run(tester, () async {
        expect(f.state.activeMessages.single.id, 'old');
        expect(f.state.activeMessages.single.body, ModelScreenFixture.excluded);
        // No API get/registration here: initialize's actual onConfigObserved already
        // registered the UNSELECTED row key before the actual screen mounted.
        expect(
          f.redaction.redactor.redactText(ModelScreenFixture.excluded),
          SecretRedactor.removed,
        );
        expect(
          f.container.read(secretRedactorProvider),
          same(f.redaction.redactor),
        );
        _expectPaint(tester, SecretRedactor.removed);
        _expectAbsent(tester, [
          ModelScreenFixture.excluded,
          ModelScreenFixture.key,
        ]);
        await _seed(tester, f, const []);
        baseline = await _Baseline.capture(tester, f);
        await baseline.unchanged(tester, f);
      });
      baseline.noEffects(f); // Original tripwires/baseline survive ALL cleanup.
    },
  );

  for (final role in ['user', 'assistant', 'system']) {
    testWidgets(
      'F1 restored $role secrets absent from actual passive/native paint',
      (tester) async {
        final f = ModelScreenFixture();
        late _Baseline baseline;
        final canary = 'F1_UNKNOWN_${role.toUpperCase()}_BODY_57139';
        final body =
            '$role before ${ModelScreenFixture.secret} after ${ModelScreenFixture.excluded} future $canary';
        final safe = '$role before [REDACTED] after [REDACTED] future $canary';
        await f.run(tester, () async {
          await _seed(tester, f, [_row('f1-$role', body, role: role)]);
          baseline = await _Baseline.capture(tester, f);
          _expectPaint(tester, safe);
          _expectAbsent(tester, [
            ModelScreenFixture.secret,
            ModelScreenFixture.excluded,
          ]);
          expect(f.redaction.redactor.redactText(canary), canary);
          await _register(tester, f, canary);
          _expectPaint(
            tester,
            '$role before [REDACTED] after [REDACTED] future [REDACTED]',
          );
          _expectAbsent(tester, [canary, ModelScreenFixture.excluded]);
          final item = f.state.activeMessages.singleWhere(
            (m) => m.id == 'f1-$role',
          );
          expect(item.body, body); // Display only: source remains original.
          expect(item.role.name, role);
          expect(item.status, 'complete');
          expect(item.activity, SupportMessageActivity.inactive);
          expect(
            await _join(
              tester,
              f,
              () => f.repo.getMessageById(item.id),
              'F1 original restored role custody',
            ),
            _row(item.id, body, role: role),
          );
          await baseline.unchanged(tester, f);
        });
        baseline.noEffects(f);
      },
    );
  }

  testWidgets(
    'F1 genuine once-complete reply reprojects new secret without send or durable rewrite',
    (tester) async {
      const canary = 'F1_PREVIOUSLY_UNKNOWN_REPLY_CANARY_59283';
      const body = 'Actual complete answer $canary remains useful.';
      final f = ModelScreenFixture()..response = chatComplete(body);
      late _Baseline baseline;
      await f.run(tester, () async {
        await _seed(tester, f, const []);
        expect(f.redaction.redactor.redactText(canary), canary);
        final preview = await displayScreenOpenPreview(
          tester,
          f,
          'F1 exact **current** question',
        );
        final original = await f.action(tester, () => f.bridge);
        final terminal = await f.signal(
          tester,
          () => displayScreenPhase(original, displayScreenTerminal),
          label: 'F1 original once-approved actual terminal !busy',
        );
        final created = await f.signal(
          tester,
          () => f.adapterCreated.future,
          label: 'F1 actual private adapter created',
        );
        await displayScreenConfirm(tester, f);
        final adapter = await f.finish(tester, created);
        await _join(
          tester,
          f,
          () => adapter.responseListening,
          'F1 actual private SSE response subscription',
        );
        final result = await f.finish(tester, terminal);
        await tester.pumpAndSettle();
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.busy, isFalse);
        expect(result.status, PrivateTextStatus.complete);
        expect(result.dispatch, PrivateTextDispatch.admitted);
        expect(result.runId, preview.runId);
        expect(
          f.state.activeMessages
              .where((message) => message.runId == preview.runId)
              .map((message) => message.id),
          [preview.userMessageId, preview.replyMessageId],
        );
        expect(f.adapters, [same(adapter)]);
        expect(adapter.fetches, 1);
        expect(adapter.native.responseListens, 1);
        expect(adapter.closed, isTrue);
        expect(adapter.options!.uri.toString(), f.api.endpoint);
        expect(
          adapter.options!.headers['Authorization'],
          'Bearer ${ModelScreenFixture.key}',
        );
        final wire = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        expect(wire['model'], f.settings.modelId);
        expect(wire['temperature'], f.settings.temperature);
        expect(wire['max_tokens'], f.settings.maxTokens);
        expect(wire['messages'], [
          for (final message in preview.messages)
            {'role': message.role, 'content': message.text},
        ]);
        expect(adapter.upload, isNot(contains(ModelScreenFixture.excluded)));
        expect(adapter.upload, isNot(contains(ModelScreenFixture.secret)));
        expect(adapter.upload, isNot(contains(ModelScreenFixture.key)));
        _expectPaint(tester, body);
        final reply = await _join(
          tester,
          f,
          () => f.repo.getMessageById(preview.replyMessageId),
          'F1 actual complete encrypted reply custody',
        );
        expect(reply!.body, body);
        expect(reply.status, 'complete');
        expect(reply.runId, preview.runId);
        final provenance = await _join(
          tester,
          f,
          () => f.repo.getContextBlocksForSession(ModelScreenFixture.session),
          'F1 original complete reply provenance',
        );
        final ownedProvenance = provenance.singleWhere(
          (block) =>
              block.id == 'support.reply_provenance:${preview.replyMessageId}',
        );
        expect(ownedProvenance.sessionId, ModelScreenFixture.session);
        expect(ownedProvenance.startMessageId, preview.replyMessageId);
        expect(ownedProvenance.endMessageId, preview.replyMessageId);
        expect(ownedProvenance.isActive, isFalse);
        expect(ownedProvenance.isLocked, isFalse);
        expect(ownedProvenance.summary, isEmpty);
        expect(ownedProvenance.protectedFactsJson, isNotEmpty);
        baseline = await _Baseline.capture(tester, f);
        await _register(tester, f, canary);
        _expectPaint(
          tester,
          'Actual complete answer [REDACTED] remains useful.',
        );
        _expectAbsent(tester, [canary, ModelScreenFixture.excluded]);
        baseline.noEffects(f);
        await _join(
          tester,
          f,
          () => f.workspace.refresh(),
          'F1 original complete display refresh',
        );
        await tester.pumpAndSettle();
        _expectPaint(
          tester,
          'Actual complete answer [REDACTED] remains useful.',
        );
        _expectAbsent(tester, [canary]);
        await _reopen(tester, f);
        _expectPaint(
          tester,
          'Actual complete answer [REDACTED] remains useful.',
        );
        _expectAbsent(tester, [canary, ModelScreenFixture.excluded]);
        expect(
          await _join(
            tester,
            f,
            () => f.repo.getMessageById(reply.id),
            'F1 exact original complete reply after reopen',
          ),
          reply,
        );
        expect(
          await _join(
            tester,
            f,
            () => f.repo.getContextBlocksForSession(ModelScreenFixture.session),
            'F1 exact original provenance after reopen',
          ),
          provenance,
        );
        await baseline.unchanged(tester, f);
      });
      baseline.noEffects(f);
    },
  );

  for (final boundary in ['decrypt', 'read']) {
    testWidgets(
      'F1 new policy paints before/after held actual broad display $boundary',
      (tester) async {
        final f = ModelScreenFixture();
        late _Baseline baseline;
        final canary = 'F1_UNKNOWN_HELD_${boundary.toUpperCase()}_68319';
        final body = 'Held $boundary $canary end';
        final safe = 'Held $boundary [REDACTED] end';
        await f.run(tester, () async {
          await _seed(tester, f, [_row('f1-held', body)]);
          _expectPaint(tester, body);
          baseline = await _Baseline.capture(tester, f);
          final gate = await f.action(tester, f.barrier);
          var held = false;
          await f.action(tester, () {
            if (boundary == 'decrypt') {
              f.primitive.beforeDecrypt = (aad) async {
                if (!held && aad.contains('support_messages')) {
                  held = true;
                  await gate.wait();
                }
              };
            } else {
              f.sql.afterSelect = (statement, args) async {
                if (!held &&
                    statement.toLowerCase().contains('support_messages')) {
                  held = true;
                  await gate.wait();
                }
              };
            }
          });
          final entered = await f.signal(
            tester,
            () => gate.entered.future,
            label: 'F1 original broad display $boundary barrier entered',
          );
          final refreshed = await f.signal(
            tester,
            () => f.workspace.refresh(),
            label: 'F1 original held broad display $boundary refresh',
          );
          await f.finish(tester, entered);
          expect(held, isTrue);
          expect(gate.released, isFalse);
          expect(f.state.isBusy, isTrue);
          await _register(tester, f, canary);
          _expectPaint(
            tester,
            safe,
          ); // BEFORE pending display read can publish.
          _expectAbsent(tester, [canary, ModelScreenFixture.excluded]);
          baseline.noEffects(f);
          await f.action(tester, () {
            gate.release();
            f.primitive.beforeDecrypt = null;
            f.sql.afterSelect = null;
          });
          expect(await f.finish(tester, refreshed), isTrue);
          await tester.pumpAndSettle();
          _expectPaint(tester, safe); // AFTER original broad read publishes.
          _expectAbsent(tester, [canary, ModelScreenFixture.excluded]);
          expect(
            f.state.activeMessages.singleWhere((m) => m.id == 'f1-held').body,
            body,
          );
          await _reopen(tester, f);
          _expectPaint(tester, safe);
          _expectAbsent(tester, [canary]);
          await baseline.unchanged(tester, f);
        });
        baseline.noEffects(f);
      },
    );
  }

  testWidgets(
    'F1 actual exhausted immutable policy shows whole fixed-safe label for ALL roles',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = ModelScreenFixture();
      late _Baseline baseline;
      await f.run(tester, () async {
        await _seed(tester, f, [
          for (final role in ['user', 'assistant', 'system'])
            _row(
              'f1-closed-$role',
              'F1_CLOSED_${role.toUpperCase()}_CANARY',
              role: role,
            ),
        ]);
        baseline = await _Baseline.capture(tester, f);
        final native = f.container.read(supportNativeRuntimeProvider);
        final authority = (
          epoch: native.epoch,
          owner: native.writeOwner,
          lifetime: native.lifetime,
          confirmed: native.recipientConfirmed,
          preferences: native.snapshot.preferences,
          recipient: native.recipient,
        );
        await f.action(tester, () {
          for (var i = 0; i < 260; i++) {
            f.redaction.registerSecret('F1_EXHAUST_POLICY_${i}_63917');
          }
        });
        await tester.pump();
        expect(native.epoch, authority.epoch);
        expect(native.writeOwner, authority.owner);
        expect(native.lifetime, authority.lifetime);
        expect(native.recipientConfirmed, authority.confirmed);
        expect(native.snapshot.preferences, same(authority.preferences));
        expect(native.recipient, same(authority.recipient));
        expect(f.redaction.redactor.redactText(''), SecretRedactor.limited);
        expect(
          f.redaction.redactor
              .withKnownSecrets(
                const [],
                maxInputLength: 65536,
                maxOutputLength: 65536,
              )
              .redactText('safe'),
          SecretRedactor.limited,
        );
        expect(
          f.container.read(secretRedactorProvider),
          same(f.redaction.redactor),
        );
        final bodies = tester
            .widgetList<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
            .toList();
        expect(bodies, hasLength(4));
        expect(bodies.map((widget) => widget.text), everyElement(_unsafe));
        _expectPaint(tester, _unsafe);
        _expectAbsent(tester, [
          SecretRedactor.limited,
          'F1_CLOSED_',
          ModelScreenFixture.excluded,
        ]);
        await _join(
          tester,
          f,
          () => f.workspace.refresh(),
          'F1 original closed-policy display refresh',
        );
        await tester.pumpAndSettle();
        _expectPaint(tester, _unsafe);
        _expectAbsent(tester, [SecretRedactor.limited, 'F1_CLOSED_']);
        await baseline.unchanged(tester, f);
      });
      baseline.noEffects(f);
    },
  );

  for (final length in [65536, 65537]) {
    testWidgets('F1 actual feed inclusive $length UTF16 whole-body allowance', (
      tester,
    ) async {
      final f = ModelScreenFixture();
      late _Baseline baseline;
      final body = '😀${'x' * (length - 2)}';
      expect(body.length, length);
      await f.run(tester, () async {
        await _seed(tester, f, [_row('f1-bound', body)]);
        baseline = await _Baseline.capture(tester, f);
        _expectPaint(tester, length == 65536 ? body : _oversize);
        if (length == 65537) {
          _expectAbsent(tester, ['😀', 'x' * 40, SecretRedactor.limited]);
        }
        expect(
          f.state.activeMessages.singleWhere((m) => m.id == 'f1-bound').body,
          body,
        );
        await baseline.unchanged(tester, f);
      });
      baseline.noEffects(f);
    });
  }

  for (final failure in ['output-expansion', 'partial-json-budget']) {
    testWidgets(
      'F1 actual $failure sanitation refuses WHOLE body with exact unsafe label',
      (tester) async {
        final f = ModelScreenFixture();
        late _Baseline baseline;
        final body = failure == 'output-expansion'
            ? 'q' * 20000
            : '{"ordinary":"F1_PARTIAL_RAW_CANARY","deep":${'[' * 14}0${']' * 14}}';
        await f.run(tester, () async {
          await _seed(tester, f, [_row('f1-unsafe', body)]);
          baseline = await _Baseline.capture(tester, f);
          if (failure == 'output-expansion') {
            await _register(tester, f, 'q');
          }
          _expectPaint(tester, _unsafe);
          _expectAbsent(tester, [
            SecretRedactor.limited,
            'F1_PARTIAL_RAW_CANARY',
            'q' * 40,
          ]);
          expect(
            f.state.activeMessages.singleWhere((m) => m.id == 'f1-unsafe').body,
            body,
          );
          await baseline.unchanged(tester, f);
        });
        baseline.noEffects(f);
      },
    );
  }
}
