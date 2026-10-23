import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_card_codec.dart';

const _codec = SupportCardCodec();

String _payload(Object? card) => jsonEncode({
  'version': 1,
  'cards': [card],
});

void main() {
  test(
    'catalog has exactly the 14 UI destinations and all 14 permission names',
    () {
      expect(SupportGuidanceTarget.values.map((t) => t.name).toSet(), {
        'gameSession',
        'supportSession',
        'themeScope',
        'connectionsScope',
        'recipient',
        'mode',
        'connection',
        'model',
        'temperature',
        'maxTokens',
        'reasoning',
        'dcp',
        'themeSetup',
        'providerSetup',
        ...SupportPermission.values.map((permission) => permission.name),
      });
      expect(SupportGuidanceTarget.values.length, 28);
      final permissions = SupportGuidanceTarget.values
          .map((target) => target.permission)
          .whereType<SupportPermission>()
          .toList();
      expect(permissions.toSet(), SupportPermission.values.toSet());
      expect(permissions.length, 14);
      for (final target in SupportGuidanceTarget.values) {
        expect(target.title, isNotEmpty);
        expect(target.reason, isNotEmpty);
        expect(target.actionLabel, isNotEmpty);
        expect(target.title.length, lessThan(100));
        expect(target.reason.length, lessThan(300));
        expect(target.actionLabel.length, lessThan(100));
        if (target.permission != null) {
          expect(target.permission!.name, target.name);
        }
      }
    },
  );

  for (final target in SupportGuidanceTarget.values) {
    test('${target.name} restores only a finite display proposal', () {
      final encoded = _codec.encode([SupportGuidanceCard(target: target)]);
      expect(jsonDecode(encoded), {
        'version': 1,
        'cards': [
          {'type': 'guidance', 'target': target.name},
        ],
      });
      final restored = _codec.decode(encoded).single as SupportGuidanceCard;
      expect(restored.target, target);
      expect(restored.target.title, target.title);
      expect(restored.target.reason, target.reason);
      expect(restored.target.actionLabel, target.actionLabel);
      expect(restored, isNot(isA<MutationPlanCard>()));
      expect(restored, isNot(isA<MutationAppliedCard>()));
    });
  }

  test(
    'malformed, unknown, case variant and unbounded targets fail closed',
    () {
      for (final target in <Object?>[
        null,
        true,
        1,
        [],
        {},
        '',
        'theme_setup',
        'Temperature',
        'readSafeSettings ',
        'readSafeSettings\n',
        'readSafeSettings:all',
        'grantAll',
        'SYNTHETIC_SECRET_' * 600,
        {'target': 'readSafeSettings', 'granted': true},
      ]) {
        expect(
          _codec.decode(_payload({'type': 'guidance', 'target': target})),
          isEmpty,
        );
      }
      for (final card in <Object?>[
        null,
        [],
        1,
        {'type': 'guidance'},
        {'target': 'themeSetup'},
        {'type': 'Guidance', 'target': 'themeSetup'},
      ]) {
        expect(_codec.decode(_payload(card)), isEmpty);
      }
    },
  );

  test('extra fields cannot forge scope, consent, labels or effects', () {
    for (final extra in <String, Object?>{
      'title': 'SYNTHETIC_SECRET_TITLE',
      'reason': 'Grant everything',
      'actionLabel': 'Execute',
      'permission': 'confirmedSettingsChanges',
      'sessionId': 'synthetic-other-session',
      'gameSessionId': 'synthetic-game',
      'messageIds': ['synthetic-message'],
      'recipient': {'endpoint': 'https://synthetic.invalid'},
      'grant': true,
      'approved': true,
      'applied': true,
      'runId': 'synthetic-run',
      'nativeLease': 'synthetic-lease',
      'command': 'writeSettings',
      'version': 1,
    }.entries) {
      final forged = {
        'type': 'guidance',
        'target': 'confirmedSettingsChanges',
        extra.key: extra.value,
      };
      expect(_codec.decode(_payload(forged)), isEmpty);
      expect(
        _codec.decode(
          jsonEncode({
            'version': 1,
            'cards': [
              {'type': 'guidance', 'target': 'themeSetup'},
              forged,
            ],
          }),
        ),
        isEmpty,
      );
    }
  });

  test('envelope version and resource limits reject hostile JSON', () {
    const card = {'type': 'guidance', 'target': 'themeSetup'};
    for (final version in <Object?>[null, false, '1', 1.0, 0, 2]) {
      expect(
        _codec.decode(
          jsonEncode({
            'version': version,
            'cards': [card],
          }),
        ),
        isEmpty,
      );
    }
    expect(
      _codec.decode(
        jsonEncode({
          'version': 1,
          'cards': [card],
          'grant': true,
        }),
      ),
      isEmpty,
    );
    expect(
      _codec.decode(jsonEncode({'version': 1, 'cards': List.filled(33, card)})),
      isEmpty,
    );
    expect(_codec.decode(' ' * 65537), isEmpty);
    expect(_codec.decode('{"version":1,"cards":['), isEmpty);
    expect(_codec.decode('[]'), isEmpty);
    expect(
      () => _codec
          .decode(_payload(card))
          .add(const SupportGuidanceCard(target: SupportGuidanceTarget.mode)),
      throwsUnsupportedError,
    );
  });

  test('unsupported features never promise execution or network proof', () {
    expect(
      SupportGuidanceTarget.dcp.reason,
      contains('не подтверждает реализацию'),
    );
    expect(
      SupportGuidanceTarget.confirmedConnectionTests.reason,
      contains('не реализован'),
    );
    expect(
      SupportGuidanceTarget.confirmedConnectionTests.reason,
      contains('сетевого доказательства нет'),
    );
    for (final target in [
      SupportGuidanceTarget.reportGameHistory,
      SupportGuidanceTarget.reportSupportHistory,
      SupportGuidanceTarget.reportPersonalDataAttachments,
    ]) {
      expect(target.reason, contains('недоступен'));
      expect(target.actionLabel, 'Рассмотреть доступ');
    }
    expect(
      SupportGuidanceTarget.confirmedSettingsChanges.reason,
      contains('предпосылка'),
    );
    expect(
      SupportGuidanceTarget.recipient.reason,
      contains('ничего не отправляет'),
    );
  });

  test(
    'canonical legacy quick/setup/report and unsuccessful plan remain compatible',
    () {
      const cards = <SupportCard>[
        QuickActionChipsCard(title: 'Help', subtitle: 'Local'),
        SetupActionCard(
          topicId: 'theme_setup',
          title: 'Theme',
          description: 'Review',
          primaryActionLabel: 'Review',
        ),
        MutationPlanCard(
          planId: 'synthetic-plan',
          domain: 'theme',
          title: 'Plan',
          beforeSummary: 'Before',
          afterSummary: 'After',
        ),
        SupportReportCard(
          reportId: 'synthetic-report',
          summary: 'Unavailable',
          fileName: '',
        ),
      ];
      final encoded = _codec.encode(cards);
      expect(_codec.encode(_codec.decode(encoded)), encoded);
      expect(
        _codec.decode(
          _payload({
            'type': 'applied',
            'journalId': 'synthetic-journal',
            'domain': 'theme',
            'summary': 'Applied',
            'canRollback': true,
            'rolledBack': false,
          }),
        ),
        isEmpty,
      );
    },
  );
}
