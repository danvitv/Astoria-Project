import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_evidence_codec.dart';

import 'support_theme_mode_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  modeActionTest(
    'exact encrypted mode reservation precedes full-list invocation',
    (f) async {
      const codec = SupportThemeEvidenceCodec(
        operation: SupportThemeOperation.mode,
      );
      final review = await modeReview(f, 'system');
      final preview = f.service.projectReview(review)!;
      final beforeList = List.of(f.backing.presets);
      final gate = f.themeGate();
      modeStore(f).modeGates.add(gate);
      final job = f.service.execute(f.service.approve(review)!);
      await gate.started.future;
      f.events.add('mode-invoked'); // Actual shared invocation checkpoint.
      final record = (await f.record())!;
      expect(record.status, 'pending');
      expect(
        record.beforeJson,
        codec.encode(
          sessionId: ThemeActionFixture.session,
          value: preview.before,
          policy: f.redaction.redactor,
        ),
      );
      expect(
        record.afterJson,
        codec.encode(
          sessionId: ThemeActionFixture.session,
          value: preview.after,
          policy: f.redaction.redactor,
        ),
      );
      final raw = await f.db.select(f.db.supportMutationJournal).getSingle();
      expect(raw.beforeCiphertext, isNot(contains(record.beforeJson)));
      expect(raw.afterCiphertext, isNot(contains(record.afterJson)));
      expect(f.backing.presets, beforeList);
      expect(modeStore(f).modeWrites.single, [
        beforeList.first.copyWith(themeMode: 'system'),
        ...beforeList.skip(1),
      ]);
      final invocation = f.events.indexOf('mode-invoked');
      final insert = f.events.indexWhere(
        (e) =>
            e.startsWith('insert:') && e.contains('support_mutation_journal'),
      );
      final encryptions = f.events
          .take(invocation)
          .where(
            (e) =>
                e.startsWith('encrypt:') &&
                e.contains('support_mutation_journal'),
          );
      expect(insert, greaterThanOrEqualTo(0));
      expect(insert, lessThan(invocation));
      expect(encryptions, hasLength(2));
      final native = SupportMutationEvidence.decode(record.afterJson)!;
      expect(jsonDecode(native), {
        'v': 1,
        'domain': 'theme.mode',
        'target': 'active-preset-mode',
        'sessionId': ThemeActionFixture.session,
        'id': 'a',
        'name': 'Theme A',
        'mode': 'system',
        'accent': '#F5C400',
        'active': true,
      });
      expect(native, isNot(contains(ThemeActionFixture.privateCanary)));
      expect(native, isNot(contains('customFont')));
      gate.release.complete();
      expect((await job).effect, SupportThemeEffect.applied);
    },
  );

  modeActionTest(
    'mode known-name redaction reprojects and retires exact approval',
    (f) async {
      await f.theme.updatePreset(
        ThemeActionFixture.themeA.copyWith(
          name: ThemeActionFixture.labelCanary,
        ),
      );
      final observed = (await f.service.observe(f.intent()))!;
      final choice = f.service.projectModeChoices(observed)!.choices[1];
      final review = (await f.service.prepareApply(choice))!;
      final approval = f.service.approve(review)!;
      f.redaction.registerSecret(ThemeActionFixture.labelCanary);
      expect(choice.value!.name, SecretRedactor.removed);
      expect(
        f.service.projectReview(review)!.after.name,
        SecretRedactor.removed,
      );
      expect(
        (await f.service.execute(approval)).effect,
        SupportThemeEffect.refused,
      );
      expect(modeStore(f).modeWrites, isEmpty);
      expect((await modeApply(f)).effect, SupportThemeEffect.applied);
      final record = (await f.record())!;
      final safe = '${record.beforeJson}${record.afterJson}';
      expect(safe, contains(SecretRedactor.removed));
      expect(safe, isNot(contains(ThemeActionFixture.labelCanary)));
      expect(safe, isNot(contains(ThemeActionFixture.privateCanary)));
      final raw = await f.db.select(f.db.supportMutationJournal).getSingle();
      expect(
        jsonEncode(raw.toJson()),
        isNot(contains(ThemeActionFixture.labelCanary)),
      );
      expect(
        jsonEncode(raw.toJson()),
        isNot(contains(ThemeActionFixture.privateCanary)),
      );
    },
  );

  modeActionTest(
    'selection v1 bytes remain exact and mode codec is strictly separate',
    (f) async {
      const selection = SupportThemeEvidenceCodec();
      const mode = SupportThemeEvidenceCodec(
        operation: SupportThemeOperation.mode,
      );
      const value = SupportThemeValue(
        id: 'a',
        name: 'Safe A',
        mode: 'light',
        accent: '#112233',
        active: true,
      );
      final selectionEncoded = selection.encode(
        sessionId: ThemeActionFixture.session,
        value: value,
        policy: f.redaction.redactor,
      )!;
      final exactSelection =
          '{"v":1,"domain":"theme.selection",'
          '"target":"installed-active-selection","sessionId":"synthetic-theme-session",'
          '"id":"a","name":"Safe A","mode":"light","accent":"#112233","active":true}';
      expect(selectionEncoded, SupportMutationEvidence.encode(exactSelection));
      final modeEncoded = mode.encode(
        sessionId: ThemeActionFixture.session,
        value: value,
        policy: f.redaction.redactor,
      )!;
      expect(
        selection.decode(
          encoded: modeEncoded,
          sessionId: ThemeActionFixture.session,
          policy: f.redaction.redactor,
        ),
        isNull,
      );
      expect(
        mode.decode(
          encoded: selectionEncoded,
          sessionId: ThemeActionFixture.session,
          policy: f.redaction.redactor,
        ),
        isNull,
      );
      final canonical = SupportMutationEvidence.decode(modeEncoded)!;
      final hostile = <String>[
        ' $canonical',
        canonical.replaceFirst('"v":1', '"v":1,"v":1'),
        canonical.replaceFirst('"v":1', '"v":2'),
        canonical.replaceFirst('"id":"a"', '"id":"a","receipt":"restore"'),
        canonical.replaceFirst('theme.mode', 'theme.selection'),
        canonical.replaceFirst(
          'active-preset-mode',
          'installed-active-selection',
        ),
        canonical.replaceFirst('"mode":"light"', '"mode":"arbitrary"'),
        canonical.replaceFirst('"active":true', '"active":false'),
        canonical.replaceFirst(
          '"name":"Safe A"',
          '"name":"https://private/font"',
        ),
      ];
      for (final native in hostile) {
        expect(
          mode.decode(
            encoded: SupportMutationEvidence.encode(native),
            sessionId: ThemeActionFixture.session,
            policy: f.redaction.redactor,
          ),
          isNull,
        );
      }
      expect(
        mode.decode(
          encoded: ' $modeEncoded',
          sessionId: ThemeActionFixture.session,
          policy: f.redaction.redactor,
        ),
        isNull,
      );
      expect(modeStore(f).modeWrites, isEmpty);
    },
  );
}
