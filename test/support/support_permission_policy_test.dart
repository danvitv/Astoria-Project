import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'helpers/support_permission_test_fixtures.dart';

void main() {
  const codec = SupportPermissionCodec();
  const id = 'synthetic-support';
  test(
    'synthetic scope IDs require a complete string with no newline or raw URL syntax',
    () {
      for (final invalid in [
        'synthetic-id\n',
        'synthetic-id\r',
        'synthetic-id\r\n',
        'synthetic-id\u2028',
        'synthetic-id\u2029',
        'synthetic-id\u0000',
        ' synthetic-id',
        'synthetic-id ',
        'synthetic?id',
        'synthetic#id',
        r'synthetic\id',
        'synthetic%2Fid',
      ]) {
        expect(() => requireSupportPermissionId(invalid), throwsStateError);
        expect(() => SupportMessageSelection([invalid]), throwsStateError);
        expect(
          () => SupportPermissionScope(
            selectionRevision: 1,
            gameSessionId: invalid,
          ),
          throwsStateError,
        );
        expect(
          () => permissionRecipient(connection: invalid),
          throwsStateError,
        );
        expect(() => permissionRecipient(model: invalid), throwsStateError);
      }
      for (final valid in [
        'synthetic-id',
        'synthetic.scope:1',
        'synthetic/model-1',
      ]) {
        expect(() => requireSupportPermissionId(valid), returnsNormally);
      }
    },
  );
  test(
    'synthetic native routes reject complete-string, empty query/fragment and path aliases',
    () {
      final block = codec.encode(
        permissionPolicy(grants: SupportPermission.values),
        1,
      );
      for (final invalid in [
        'https://synthetic.invalid/v1\n',
        'https://synthetic.invalid/v1\r\n',
        'https://synthetic.invalid/v1\u2028',
        'https://synthetic.invalid/v1\u0000',
        'https://synthetic.invalid/v1?',
        'https://synthetic.invalid/v1#',
        'https://synthetic.invalid/v1?#',
        'https://synthetic.invalid/v1?key=STATIC_SYNTHETIC_CANARY',
        'https://user:STATIC_SYNTHETIC_CANARY@synthetic.invalid/v1',
        'https://synthetic.invalid/./v1',
        'https://synthetic.invalid/a/../v1',
        'https://synthetic.invalid/v1/.',
        'https://synthetic.invalid/v1/..',
        'https://synthetic.invalid//v1',
        'https://synthetic.invalid/v1//messages',
        'https://synthetic.invalid/v1/',
        'https://synthetic.invalid/%2e/v1',
        'https://synthetic.invalid/a/%2E%2E/v1',
        'https://synthetic.invalid/v1%2Fmessages',
        r'https://synthetic.invalid\v1',
        r'https://synthetic.invalid/v1\messages',
        'https://synthetic.invalid/v1:unknownOperation',
        'https://synthetic.invalid/:generateContent',
        'https://synthetic.invalid/v1/.:generateContent',
        'https://synthetic.invalid/v1/model:generateContent/extra',
      ]) {
        expect(() => permissionRecipient(route: invalid), throwsStateError);
        final m = jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
        m['recipient']['route'] = invalid;
        expect(
          () => codec.decode(
            id,
            block.copyWith(protectedFactsJson: jsonEncode(m)),
          ),
          throwsA(
            isA<SupportPermissionsUnavailable>().having(
              (e) => e.availability,
              'availability',
              SupportPermissionAvailability.corrupt,
            ),
          ),
        );
      }
    },
  );
  for (final operation in ['generateContent', 'streamGenerateContent']) {
    test(
      'synthetic legitimate Gemini $operation route retains exact recipient binding',
      () {
        final route =
            'https://synthetic.invalid/v1beta/models/synthetic-model:$operation';
        final recipient = permissionRecipient(
          route: route,
          protocol: SupportRecipientProtocol.gemini,
        );
        final p = permissionPolicy(
          grants: [SupportPermission.modelGameHistory],
          recipient: recipient,
        );
        final decoded = codec.decode(id, codec.encode(p, 1));
        expect(decoded.recipient!.nativeRoute, route);
        expect(decoded.recipient!.sameAs(recipient), isTrue);
        expect(decoded.allows(SupportPermission.modelGameHistory), isTrue);
        final other = permissionRecipient(
          route: route.replaceFirst('synthetic-model:', 'other-model:'),
          protocol: SupportRecipientProtocol.gemini,
        );
        expect(recipient.sameAs(other), isFalse);
      },
    );
  }
  test(
    'synthetic missing preferences are available default deny with no implied scope',
    () {
      final p = codec.decode(id, null);
      expect(p.grants, isEmpty);
      expect(p.scope, isNull);
      expect(p.recipient, isNull);
      for (final r in SupportPermission.values) {
        expect(p.allows(r), isFalse);
      }
    },
  );
  test(
    'synthetic duplicate JSON keys and non-integer version cannot grant',
    () {
      final block = codec.encode(permissionPolicy(), 1);
      for (final payload in [
        block.protectedFactsJson.replaceFirst(
          '"modelGameHistory":false',
          '"modelGameHistory":false,"modelGameHistory":true',
        ),
        block.protectedFactsJson.replaceFirst('"version":1', '"version":1.0'),
        block.protectedFactsJson.replaceFirst(
          '"version":1',
          '"version":999,"version":1',
        ),
      ]) {
        expect(
          () => codec.decode(id, block.copyWith(protectedFactsJson: payload)),
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
      }
    },
  );
  test(
    'synthetic selected native files/snippets do not imply a game or local diagnostics read',
    () {
      final scope = SupportPermissionScope(
        selectionRevision: 1,
        selectedData: {
          SupportDataCategory.attachment: ['selected-native-file'],
          SupportDataCategory.promptSnippet: ['selected-native-preview'],
        },
      );
      final p = SupportPermissionPreferences(
        supportSessionId: id,
        policyIdentity: 'synthetic-policy',
        revision: 1,
        scope: scope,
        recipient: permissionRecipient(),
        grants: [
          SupportPermission.modelAttachments,
          SupportPermission.modelPromptProviderSnippets,
          SupportPermission.reportPersonalDataAttachments,
        ],
      );
      for (final e in scope.selectedData.entries) {
        final s = SupportPermissionSource.selectedData(
          id,
          null,
          e.key,
          e.value,
        );
        expect(s.allowedFor(p, SupportPermissionUse.modelContext), isTrue);
        expect(s.allowedFor(p, SupportPermissionUse.localRead), isFalse);
      }
      expect(p.allows(SupportPermission.readDiagnostics), isFalse);
      expect(scope.gameSessionId, isNull);
    },
  );
  for (final r in SupportPermission.values) {
    test('synthetic ${r.name} is independent of every other right', () {
      final p = permissionPolicy(grants: [r]);
      for (final other in SupportPermission.values) {
        expect(p.allows(other), other == r);
      }
      final roundTrip = codec.decode(id, codec.encode(p, 1));
      expect(roundTrip.grants, {r});
      expect(roundTrip.scope!.sameAs(p.scope), isTrue);
      expect(roundTrip.recipient!.sameAs(p.recipient), isTrue);
    });
  }
  test(
    'synthetic all rights still never create a secret/SQL/file/prefs/HTTP capability',
    () {
      expect(SupportPermission.values.length, 14);
      expect(
        SupportDataCategory.values.map((c) => c.name),
        isNot(contains('secret')),
      );
      expect(
        permissionPolicy(grants: SupportPermission.values).grants.length,
        14,
      );
    },
  );
  for (final bad in [
    'version',
    'unknown-field',
    'unknown-grant',
    'not-bool',
    'unknown-category',
    'duplicate-category',
    'unknown-data',
    'empty-range',
    'duplicate-range',
    'no-game',
    'query-route',
    'credentials-route',
    'fragment-route',
    'protocol',
    'wrong-session',
    'negative-revision',
    'overflow-revision',
    'missing-key',
    'unscoped-grant',
  ]) {
    test(
      'synthetic malformed $bad refuses the entire schema with a fixed error',
      () {
        final block = codec.encode(
          permissionPolicy(grants: SupportPermission.values),
          1,
        );
        final m = jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
        switch (bad) {
          case 'version':
            m['version'] = 999;
          case 'unknown-field':
            m['secret'] = 'STATIC_SYNTHETIC_CANARY';
          case 'unknown-grant':
            m['grants']['arbitrarySql'] = true;
          case 'not-bool':
            m['grants']['modelGameHistory'] = 'true';
          case 'unknown-category':
            m['scope']['safeCategories'] = ['secrets'];
          case 'duplicate-category':
            m['scope']['safeCategories'] = ['theme', 'theme'];
          case 'unknown-data':
            m['scope']['data']['secrets'] = ['synthetic'];
          case 'empty-range':
            m['scope']['gameHistory'] = <String>[];
          case 'duplicate-range':
            m['scope']['gameHistory'] = ['game-1', 'game-1'];
          case 'no-game':
            m['scope']['gameSession'] = null;
          case 'query-route':
            m['recipient']['route'] =
                'https://synthetic.invalid/v1?token=STATIC_SYNTHETIC_CANARY';
          case 'credentials-route':
            m['recipient']['route'] =
                'https://user:STATIC_SYNTHETIC_CANARY@synthetic.invalid/v1';
          case 'fragment-route':
            m['recipient']['route'] =
                'https://synthetic.invalid/v1#STATIC_SYNTHETIC_CANARY';
          case 'protocol':
            m['recipient']['protocol'] = 'arbitrary-http';
          case 'wrong-session':
            m['session'] = 'other-support';
          case 'negative-revision':
            m['revision'] = -1;
          case 'overflow-revision':
            m['revision'] = maxSupportPermissionRevision + 1;
          case 'missing-key':
            m.remove('grants');
          case 'unscoped-grant':
            m['scope'] = null;
        }
        expect(
          () => codec.decode(
            id,
            block.copyWith(protectedFactsJson: jsonEncode(m)),
          ),
          throwsA(
            isA<SupportPermissionsUnavailable>()
                .having(
                  (e) => e.availability,
                  'availability',
                  SupportPermissionAvailability.corrupt,
                )
                .having(
                  (e) => e.toString(),
                  'safe error',
                  isNot(contains('STATIC_SYNTHETIC_CANARY')),
                ),
          ),
        );
      },
    );
  }
  test(
    'synthetic inactive/wrong row/locked/deep/large policies fail closed',
    () {
      final block = codec.encode(permissionPolicy(), 1);
      for (final invalid in [
        block.copyWith(isActive: false),
        block.copyWith(id: 'other'),
        block.copyWith(startMessageId: 'game-1'),
        block.copyWith(protectedFactsJson: '[' * 20 + ']' * 20),
        block.copyWith(
          protectedFactsJson: 'x' * (SupportPermissionCodec.maxChars + 1),
        ),
      ]) {
        expect(
          () => codec.decode(id, invalid),
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
      }
      expect(
        () => codec.decode(id, block.copyWith(isLocked: true)),
        throwsA(
          isA<SupportPermissionsUnavailable>().having(
            (e) => e.availability,
            'availability',
            SupportPermissionAvailability.locked,
          ),
        ),
      );
    },
  );
  test(
    'synthetic missing exact selection/recipient cannot grant dependent rights',
    () {
      for (final right in SupportPermission.values.where(
        (r) => r != SupportPermission.confirmedSettingsChanges,
      )) {
        expect(
          () => SupportPermissionPreferences(
            supportSessionId: id,
            policyIdentity: 'synthetic',
            revision: 1,
            grants: [right],
          ),
          throwsStateError,
        );
      }
      expect(() => SupportMessageSelection([]), throwsStateError);
      expect(
        () => SupportPermissionScope(
          selectionRevision: 1,
          gameHistory: SupportMessageSelection(['game-1']),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'synthetic recipient change revokes model/test rights but not local/report grants',
    () {
      final p = permissionPolicy(grants: SupportPermission.values);
      final changed = p.withNativeRecipient(
        permissionRecipient(model: 'new-model', revision: 2),
      );
      expect(changed.revision, 2);
      expect(changed.allows(SupportPermission.readGameData), isTrue);
      expect(changed.allows(SupportPermission.reportGameHistory), isTrue);
      expect(changed.allows(SupportPermission.modelGameHistory), isFalse);
      expect(
        changed.allows(SupportPermission.confirmedConnectionTests),
        isFalse,
      );
      expect(
        changed
            .withNativeRecipient(p.recipient)
            .allows(SupportPermission.modelGameHistory),
        isFalse,
      );
    },
  );
  test(
    'synthetic scope change revokes data grants and ABA cannot reuse them',
    () {
      final p = permissionPolicy(grants: SupportPermission.values);
      final changed = p.withNativeScope(
        permissionScope(revision: 2, gameMessages: ['game-2']),
      );
      expect(changed.grants, {
        SupportPermission.confirmedSettingsChanges,
        SupportPermission.confirmedConnectionTests,
      });
      expect(changed.withNativeScope(p.scope).grants, changed.grants);
    },
  );
  test(
    'synthetic provenance requires exact session/messages/category handles',
    () {
      final p = permissionPolicy(grants: SupportPermission.values);
      expect(permissionSources(p).every((s) => s.isSelectedBy(p)), isTrue);
      for (final source in [
        SupportPermissionSource.gameHistory(
          id,
          'other-game',
          p.scope!.gameHistory!,
        ),
        SupportPermissionSource.gameHistory(
          id,
          p.scope!.gameSessionId!,
          SupportMessageSelection(['game-1']),
        ),
        SupportPermissionSource.supportHistory(
          'other-support',
          p.scope!.supportHistory!,
        ),
        SupportPermissionSource.selectedData(
          id,
          p.scope!.gameSessionId!,
          SupportDataCategory.character,
          ['not-selected'],
        ),
      ]) {
        expect(
          source.allowedFor(p, SupportPermissionUse.modelContext),
          isFalse,
        );
      }
    },
  );
  test(
    'synthetic model transfer never implies local read, prompts are not diagnostics',
    () {
      final p = permissionPolicy(
        grants: [
          SupportPermission.modelGameHistory,
          SupportPermission.readDiagnostics,
          SupportPermission.modelPromptProviderSnippets,
          SupportPermission.modelAttachments,
        ],
      );
      final game = permissionSources(p).first;
      expect(game.allowedFor(p, SupportPermissionUse.modelContext), isTrue);
      expect(game.allowedFor(p, SupportPermissionUse.localRead), isFalse);
      for (final c in [
        SupportDataCategory.promptSnippet,
        SupportDataCategory.providerSnippet,
        SupportDataCategory.attachment,
      ]) {
        final s = SupportPermissionSource.selectedData(
          id,
          p.scope!.gameSessionId!,
          c,
          p.scope!.selectedData[c]!,
        );
        expect(s.allowedFor(p, SupportPermissionUse.localRead), isFalse);
      }
    },
  );
}
