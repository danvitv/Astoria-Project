import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_evidence_codec.dart';
import 'support_theme_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  themeActionTest(
    'public installed projection and encrypted plaintext omit full preset resources',
    (f) async {
      final observed = (await f.service.observe(f.intent()))!;
      final view = f.service.projectInstalled(observed)!;
      expect(view.choices.map((c) => c.value!.id), ['a', 'b', 'c']);
      expect(view.choices.where((c) => c.value!.active).single.value!.id, 'a');
      final labels = view.choices.map((c) => f.publicValue(c.value)).join();
      expect(labels, isNot(contains(ThemeActionFixture.privateCanary)));
      await f.apply();
      final evidence = (await f.record())!;
      expect(
        '${evidence.beforeJson}${evidence.afterJson}',
        isNot(contains(ThemeActionFixture.privateCanary)),
      );
      expect(evidence.beforeJson, isNot(contains('customFont')));
      expect(evidence.afterJson, isNot(contains('chatBgImage')));
      final row = await f.db.select(f.db.supportMutationJournal).getSingle();
      expect(row.beforeCiphertext, isNot(contains('Theme A')));
      expect(row.afterCiphertext, isNot(contains('Theme B')));
      expect(view.choices.first.value!.accent, '#F5C400');
    },
  );

  themeActionTest(
    'CURRENT coordinator reprojects retained row labels and retires old exact approval',
    (f) async {
      await f.theme.importPreset(
        ThemeActionFixture.themeB.copyWith(
          name: ThemeActionFixture.labelCanary,
        ),
      );
      final observed = (await f.service.observe(f.intent()))!;
      final choice = f.service
          .projectInstalled(observed)!
          .choices
          .singleWhere((c) => c.value!.id == 'b');
      final review = (await f.service.prepareApply(choice))!;
      final approval = f.service.approve(review)!;
      expect(choice.value!.name, ThemeActionFixture.labelCanary);
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
      expect(f.themeStore.checkedWrites, isEmpty);
      final fresh = await f.apply();
      expect(fresh.effect, SupportThemeEffect.applied);
      final record = (await f.record())!;
      expect(record.afterJson, isNot(contains(ThemeActionFixture.labelCanary)));
      expect(record.afterJson, contains(SecretRedactor.removed));
    },
  );

  for (final secret in ['b', ThemeActionFixture.session]) {
    themeActionTest(
      'known unsafe identifier $secret refuses projection/admission without aliases',
      (f) async {
        f.redaction.registerSecret(secret);
        final emitted = f.service.emit(
          controller: f.controller,
          uiLifetime: f.uiLifetime,
          isCurrent: () => true,
        );
        if (secret == ThemeActionFixture.session) {
          expect(emitted, isNull);
        } else {
          expect(await f.service.observe(emitted!), isNull);
        }
        expect(f.themeStore.checkedWrites, isEmpty);
      },
    );
  }

  themeActionTest(
    'closed coordinator refuses retained labels reviews and all new actions',
    (f) async {
      final observed = (await f.service.observe(f.intent()))!;
      final choice = f.service.projectInstalled(observed)!.choices.last;
      final review = (await f.service.prepareApply(choice))!;
      f.redaction.dispose();
      expect(choice.value, isNull);
      expect(f.service.projectInstalled(observed), isNull);
      expect(f.service.projectReview(review), isNull);
      expect(f.service.approve(review), isNull);
      expect(
        f.service.emit(
          controller: f.controller,
          uiLifetime: f.uiLifetime,
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );

  themeActionTest(
    'exhausted known-value policy fails closed rather than choosing a raw label fallback',
    (f) async {
      final observed = (await f.service.observe(f.intent()))!;
      for (var i = 0; i < 257; i++) {
        f.redaction.registerSecret('synthetic-secret-$i');
      }
      expect(f.service.projectInstalled(observed), isNull);
      expect(
        f.service.emit(
          controller: f.controller,
          uiLifetime: f.uiLifetime,
          isCurrent: () => true,
        ),
        isNull,
      );
    },
  );

  themeActionTest(
    'recovered retained history is reprojected with current known labels',
    (f) async {
      await f.theme.importPreset(
        ThemeActionFixture.themeB.copyWith(
          name: ThemeActionFixture.labelCanary,
        ),
      );
      await f.apply();
      final recovered = await f.service.recover(f.intent(), f.lastId);
      expect(recovered.after!.name, ThemeActionFixture.labelCanary);
      f.redaction.registerSecret(ThemeActionFixture.labelCanary);
      expect(recovered.after!.name, SecretRedactor.removed);
      f.redaction.registerSecret('b');
      expect(recovered.after, isNull);
    },
  );

  themeActionTest(
    'strict codec preserves fixed sessionId schema keys while sanitizing variable values',
    (f) async {
      const codec = SupportThemeEvidenceCodec();
      f.redaction.registerSecret(ThemeActionFixture.labelCanary);
      final value = SupportThemeValue(
        id: 'b',
        name: ThemeActionFixture.labelCanary,
        mode: 'system',
        accent: '#112233',
        active: true,
      );
      final encoded = codec.encode(
        sessionId: ThemeActionFixture.session,
        value: value,
        policy: f.redaction.redactor,
      )!;
      final native = SupportMutationEvidence.decode(encoded)!;
      final map = jsonDecode(native) as Map;
      expect(map.keys, [
        'v',
        'domain',
        'target',
        'sessionId',
        'id',
        'name',
        'mode',
        'accent',
        'active',
      ]);
      expect(map['sessionId'], ThemeActionFixture.session);
      expect(map['name'], SecretRedactor.removed);
      expect(
        codec
            .decode(
              encoded: encoded,
              sessionId: ThemeActionFixture.session,
              policy: f.redaction.redactor,
            )!
            .name,
        SecretRedactor.removed,
      );
      expect(utf8.encode(native).length, lessThanOrEqualTo(8192));
    },
  );

  for (final mutation in [
    'version',
    'extra',
    'duplicate',
    'whitespace',
    'wrongSession',
    'wrongDomain',
    'wrongTarget',
    'wrongActive',
    'wrongType',
    'oversize',
    'pathName',
    'unknownMode',
    'unsafeId',
  ]) {
    themeActionTest(
      'strict theme evidence rejects $mutation without restored authority',
      (f) async {
        const codec = SupportThemeEvidenceCodec();
        const value = SupportThemeValue(
          id: 'b',
          name: 'Safe B',
          mode: 'dark',
          accent: '#112233',
          active: true,
        );
        final encoded = codec.encode(
          sessionId: ThemeActionFixture.session,
          value: value,
          policy: f.redaction.redactor,
        )!;
        var native = SupportMutationEvidence.decode(encoded)!;
        final map = jsonDecode(native) as Map<String, dynamic>;
        switch (mutation) {
          case 'version':
            map['v'] = 2;
          case 'extra':
            map['plan'] = 'Apply now';
          case 'duplicate':
            native = native.replaceFirst('"v":1', '"v":1,"v":1');
          case 'whitespace':
            native = ' $native';
          case 'wrongSession':
            map['sessionId'] = 'other-session';
          case 'wrongDomain':
            map['domain'] = 'provider';
          case 'wrongTarget':
            map['target'] = 'theme-mode';
          case 'wrongActive':
            map['active'] = false;
          case 'wrongType':
            map['accent'] = 123;
          case 'oversize':
            map['name'] = 'z' * 513;
          case 'pathName':
            map['name'] = 'C:\\private\\font.ttf';
          case 'unknownMode':
            map['mode'] = 'arbitrary';
          case 'unsafeId':
            map['id'] = 'b\n';
        }
        if (mutation != 'duplicate' && mutation != 'whitespace') {
          native = jsonEncode(map);
        }
        final hostile = SupportMutationEvidence.encode(native);
        expect(
          codec.decode(
            encoded: hostile,
            sessionId: ThemeActionFixture.session,
            policy: f.redaction.redactor,
          ),
          isNull,
        );
        expect(f.themeStore.checkedWrites, isEmpty);
      },
    );
  }
  for (final invalid in [
    'path',
    'control',
    'unknownMode',
    'oversize',
    'jsonLabel',
    'tooMany',
  ]) {
    themeActionTest(
      'actual installed native $invalid input fails safe public projection',
      (f) async {
        final preset = switch (invalid) {
          'path' => ThemeActionFixture.themeB.copyWith(
            name: 'C:\\private\\theme',
          ),
          'control' => ThemeActionFixture.themeB.copyWith(name: 'A\nB'),
          'unknownMode' => ThemeActionFixture.themeB.copyWith(
            themeMode: 'unknown',
          ),
          'oversize' => ThemeActionFixture.themeB.copyWith(name: 'x' * 129),
          'jsonLabel' => ThemeActionFixture.themeB.copyWith(
            name: '{"tool":"apply"}',
          ),
          _ => ThemeActionFixture.themeB,
        };
        f.backing.presets = [
          ThemeActionFixture.themeA,
          preset,
          ThemeActionFixture.themeC,
        ];
        if (invalid == 'tooMany') {
          f.backing.presets.addAll(
            List.generate(
              128,
              (i) => ThemeActionFixture.themeB.copyWith(id: 'extra-$i'),
            ),
          );
        }
        await f.replaceTheme();
        expect(await f.service.observe(f.intent()), isNull);
        expect(f.themeStore.checkedWrites, isEmpty);
      },
    );
  }
}
