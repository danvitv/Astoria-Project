import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_native_provenance_validator.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

import 'helpers/support_native_provenance_fixture.dart';
import 'helpers/support_text_context_fixture.dart';

void main() {
  final valid = SupportModelProvenanceCodec.encodeForEncryptedStorage(
    nativeRecipe(),
  );
  bool check(
    String? facts, {
    SecretRedactor? redactor,
    String session = SupportTextContextFixture.supportId,
    String message = 'support-b',
    String? run = 'synthetic-run',
  }) => SupportModelNativeProvenanceValidator.validate(
    session,
    SupportTextContextProvenance(
      messageId: message,
      runId: run,
      dedicatedFactsJson: facts,
    ),
    redactor ?? SecretRedactor(),
  );

  test('strict native v1 accepted without diagnostic field rewriting', () {
    final redactor = SecretRedactor();
    expect(redactor.redactText(valid), isNot(valid));
    expect(check(valid, redactor: redactor), isTrue);
    expect(SecretRedactor.isSecretField('supportSessionId'), isTrue);
    expect(SecretRedactor.isSecretField('sessionId'), isTrue);
    // Static syntax and enum names are not variable identifiers.
    final staticOnly = nativeRecipeObject();
    staticOnly['originalRanges'][0]['sessionId'] = 'opaque-source';
    staticOnly['originalRanges'][0]['orderedMessageIds'] = [
      'opaque-a',
      'opaque-b',
    ];
    expect(
      check(
        jsonEncode(staticOnly),
        redactor: SecretRedactor(
          knownSecrets: [
            'supportSessionId',
            'sessionId',
            'support.model_provenance',
            'game',
            'version',
          ],
        ),
      ),
      isTrue,
    );
  });

  for (final (label, raw) in <(String, String?)>[
    ('missing', null),
    ('empty', ''),
    ('malformed', '{'),
    ('null', 'null'),
    ('wrong version', valid.replaceFirst('"version":1', '"version":2')),
    ('wrong marker', valid.replaceFirst('support.model_provenance', 'unknown')),
    ('duplicate', valid.replaceFirst('"version":1', '"version":1,"version":1')),
    (
      'escaped duplicate',
      valid.replaceFirst('"version":1', r'"version":1,"\u0076ersion":1'),
    ),
    (
      'unknown',
      valid.replaceFirst('"version":1', '"version":1,"extra":"private"'),
    ),
    ('extra raw input', '$valid null'),
    ('raw budget', '$valid${' ' * 65536}'),
    ('depth budget', '${'[' * 25}0${']' * 25}'),
    ('array budget', '[${List.filled(513, '0').join(',')}]'),
    ('node budget', jsonEncode(List.generate(17, (_) => List.filled(512, 0)))),
  ]) {
    test('strict codec refuses $label', () => expect(check(raw), isFalse));
  }
  test('exact read target/session/reply/native run required', () {
    expect(check(valid, session: 'other'), isFalse);
    expect(check(valid, message: 'other'), isFalse);
    expect(check(valid, run: 'other'), isFalse);
    expect(check(valid, run: null), isFalse);
  });

  test(
    'inclusive raw and source-ID budgets, then shape/identity/source limits',
    () {
      expect(check('$valid${' ' * (65536 - valid.length)}'), isTrue);
      final value = nativeRecipeObject();
      value['originalRanges'][0]['orderedMessageIds'] = List.generate(
        512,
        (i) => 'game-$i',
      );
      expect(check(jsonEncode(value)), isTrue);
      value['originalRanges'][0]['orderedMessageIds'].add('game-over');
      expect(check(jsonEncode(value)), isFalse);
      value['originalRanges'][0]['orderedMessageIds'] = [
        'duplicate',
        'duplicate',
      ];
      expect(check(jsonEncode(value)), isFalse);
      value['originalRanges'][0]['orderedMessageIds'] = ['x' * 129];
      expect(check(jsonEncode(value)), isFalse);
      value['originalRanges'][0]['orderedMessageIds'] = ['game-a'];
      value['originalRanges'][0]['domain'] = 'unknown';
      expect(check(jsonEncode(value)), isFalse);
      value['originalRanges'][0]['domain'] = 'game';
      value['originalRanges'][0]['extra'] = 'private';
      expect(check(jsonEncode(value)), isFalse);
    },
  );

  // Every variable slot, including ranges and references, is independently
  // checked. Root slots need matching native binding to isolate secret rejection.
  for (final slot in [
    'supportSessionId',
    'replyMessageId',
    'runId',
    'currentUserMessageId',
    'rangeSession',
    'rangeId',
    'refSession',
    'refMessage',
    'refRun',
  ]) {
    for (final (kind, id, known) in <(String, String, String?)>[
      ('known', 'SYNTHETIC_SECRET_7b36', 'SYNTHETIC_SECRET_7b36'),
      (
        'base64',
        base64Encode(utf8.encode('SYNTHETIC_SECRET_7b36')),
        'SYNTHETIC_SECRET_7b36',
      ),
      (
        'encoded',
        Uri.encodeComponent('SYNTHETIC/key?772'),
        'SYNTHETIC/key?772',
      ),
      ('token', 'sk-synthetic987654', null),
      ('URL', 'https://fixture.invalid/path?api_key=canary', null),
      ('marker', SecretRedactor.removed, null),
    ]) {
      test('variable $slot refuses $kind', () {
        final value = nativeRecipeObject();
        switch (slot) {
          case 'rangeSession':
            value['originalRanges'][0]['sessionId'] = id;
          case 'rangeId':
            value['originalRanges'][0]['orderedMessageIds'][0] = id;
          case 'refSession':
            value['directReplies'][0]['sessionId'] = id;
          case 'refMessage':
            value['directReplies'][0]['messageId'] = id;
          case 'refRun':
            value['directReplies'][0]['runId'] = id;
          default:
            value[slot] = id;
        }
        expect(
          check(
            jsonEncode(value),
            session: slot == 'supportSessionId'
                ? id
                : SupportTextContextFixture.supportId,
            message: slot == 'replyMessageId' ? id : 'support-b',
            run: slot == 'runId' ? id : 'synthetic-run',
            redactor: SecretRedactor(knownSecrets: [?known]),
          ),
          isFalse,
        );
      });
    }
  }
  test('JSON Unicode escape cannot conceal a decoded known secret', () {
    final raw = valid.replaceFirst('"game-a"', r'"\u0053YNTHETIC_SECRET_7b36"');
    expect(
      check(
        raw,
        redactor: SecretRedactor(knownSecrets: ['SYNTHETIC_SECRET_7b36']),
      ),
      isFalse,
    );
  });
  test(
    'closed/exhausted policies stay closed and long keys retain coverage',
    () {
      expect(
        check(
          valid,
          redactor: SecretRedactor(knownSecrets: List.filled(257, 'known')),
        ),
        isFalse,
      );
      expect(
        check(
          valid,
          redactor: SecretRedactor(
            knownSecrets: ['s' * 200],
            maxInputLength: 128,
          ),
        ),
        isFalse,
      );
      expect(
        check(valid, redactor: SecretRedactor(knownSecrets: ['s' * 200])),
        isTrue,
      );
    },
  );
}
