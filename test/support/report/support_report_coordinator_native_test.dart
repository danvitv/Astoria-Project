import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_read_repo.dart';
import 'package:glaze_flutter/core/support_report/support_report_crypto.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';
import 'package:glaze_flutter/core/support_report/support_report_save_port.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_coordinator.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_report_platform_save.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_report_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'support_report_native_fixture.dart';
import 'support_report_save_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupportReportNativeFixture fixture;
  late KeyPair keys;
  late SupportReportCrypto crypto;
  late SupportReportRecipient? recipient;
  late SupportReportCoordinator coordinator;
  late SupportReportSaveProbe save;
  setUp(() async {
    fixture = SupportReportNativeFixture();
    await fixture.initialize();
    final sodium = await SodiumInit.init();
    keys = sodium.crypto.box.keyPair();
    crypto = SupportReportCrypto(sodium);
    recipient = SupportReportRecipient(
      keyId: 'synthetic-native-report',
      publicKey: keys.publicKey,
    );
    save = SupportReportSaveProbe();
    coordinator = SupportReportCoordinator(
      readRepo: SupportReportReadRepo(fixture.database),
      ownership: fixture,
      loadRecipient: () async => recipient,
      crypto: crypto,
      savePort: save,
    );
  });
  tearDown(() async {
    coordinator.dispose();
    keys.secretKey.dispose();
    await fixture.close();
  });

  for (final changed in [
    'source',
    'recipient',
    'recipientCleanupUnconfirmed',
  ]) {
    test(
      '$changed change after Android selection cancels only unadmitted custody and allows a fresh request',
      () async {
        const channel = MethodChannel(SupportReportPlatformSave.channelName);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        String? active;
        var issued = 0, commits = 0, cancellations = 0, mutate = true;
        var emptyDocumentMayRemain = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'beginRequest':
              if (active != null) return {'status': 'refused'};
              active = 'synthetic-request-${++issued}';
              return {'status': 'ready', 'request': active};
            case 'choose':
              expect(fixture.originalRoot, isNull);
              expect((call.arguments as Map).containsKey('bytes'), false);
              expect(call.arguments['request'], active);
              if (mutate) {
                mutate = false;
                if (changed == 'source') {
                  await fixture.database.customStatement(
                    'CREATE TABLE synthetic_report_source_change(value INTEGER)',
                  );
                } else {
                  recipient = SupportReportRecipient(
                    keyId: 'synthetic-recipient-changed',
                    publicKey: keys.publicKey,
                  );
                }
              }
              return {'status': 'selected', 'token': 'opaque-$active'};
            case 'commit':
              commits++;
              return {'status': 'saved'};
            case 'cancel':
              expect(fixture.originalRoot, isNull);
              expect(call.arguments['request'], active);
              active = null;
              cancellations++;
              if (changed == 'recipientCleanupUnconfirmed') {
                emptyDocumentMayRemain = true;
                throw PlatformException(code: 'cleanupUnconfirmed');
              }
              return null;
            default:
              fail('Unexpected native method');
          }
        });
        coordinator.dispose();
        final port = SupportReportPlatformSave(
          validateCiphertext: crypto.isWellFormedPacket,
          platform: SupportReportSavePlatform.android,
          androidChannel: channel,
        );
        coordinator = SupportReportCoordinator(
          readRepo: SupportReportReadRepo(fixture.database),
          ownership: fixture,
          loadRecipient: () async => recipient,
          crypto: crypto,
          savePort: port,
        );
        final preview = await coordinator.prepare(
          const SupportReportPrepareRequest(),
        );
        final result = await coordinator.exportDisplayed(preview);
        expect(result.status, isNot(SupportReportSaveStatus.saved));
        expect(commits, 0);
        expect(cancellations, 1);
        expect(active, isNull);
        expect(preview.isRetired, true);
        if (changed == 'recipientCleanupUnconfirmed') {
          expect(emptyDocumentMayRemain, true);
          final message = supportReportFailureText(result.reason);
          expect(message, isNot(contains('Файл не создан')));
          expect(message, contains('пустой документ'));
        }
        final next = SupportReportPlatformSave(
          validateCiphertext: crypto.isWellFormedPacket,
          platform: SupportReportSavePlatform.android,
          androidChannel: channel,
        );
        expect(
          await next.chooseDestination(
            fileName: 'ignored',
            isCurrent: () => true,
          ),
          isNotNull,
        );
        expect(issued, 2);
        await next.cancel();
      },
    );
  }

  test(
    'picker has no ROOT; actual writer ROOT survives exact dispatch; ack waits after release',
    () async {
      final other = sqlite.sqlite3.open(fixture.path);
      other.execute('PRAGMA busy_timeout=0');
      final ack = Completer<SupportReportSaveResult>(),
          released = Completer<void>();
      fixture.onAdmissionReleased = () => released.complete();
      save.response = ack.future;
      save.choose = () async {
        expect(fixture.originalRoot, isNull);
        other.execute('BEGIN IMMEDIATE');
        other.execute('ROLLBACK'); // picker has no writer lock
        return save.destination;
      };
      save.onCommit = () {
        fixture.originalRoot!.check(fixture.database);
        expect(
          () => other.execute('BEGIN IMMEDIATE'),
          throwsA(isA<sqlite.SqliteException>()),
        );
      };
      try {
        final preview = await coordinator.prepare(
          const SupportReportPrepareRequest(),
        );
        final exported = coordinator.exportDisplayed(preview);
        await save.dispatched.future;
        await released.future;
        expect(fixture.originalRoot, isNull);
        other.execute('BEGIN IMMEDIATE');
        other.execute('ROLLBACK'); // OS response is still pending
        expect(save.commits, 1);
        expect(
          crypto.decrypt(
            packet: save.packet!,
            recipient: recipient!,
            privateKey: keys.secretKey,
          ),
          preview.payloadJson,
        );
        ack.complete(
          const SupportReportSaveResult(SupportReportSaveStatus.saved),
        );
        expect((await exported).status, SupportReportSaveStatus.saved);
      } finally {
        other.close();
      }
    },
  );
  test('saved admitted receipt survives Stop after ROOT release', () async {
    final ack = Completer<SupportReportSaveResult>(),
        released = Completer<void>();
    save.response = ack.future;
    fixture.onAdmissionReleased = () => released.complete();
    final preview = await coordinator.prepare(
      const SupportReportPrepareRequest(),
    );
    final exported = coordinator.exportDisplayed(preview);
    await save.dispatched.future;
    await released.future;
    fixture.alive = false;
    await coordinator.cancel();
    ack.complete(const SupportReportSaveResult(SupportReportSaveStatus.saved));
    expect((await exported).status, SupportReportSaveStatus.saved);
  });
  test(
    'post-dispatch original-owner completion failure preserves admitted native future',
    () async {
      final ack = Completer<SupportReportSaveResult>(),
          released = Completer<void>();
      save.response = ack.future;
      fixture.onAdmissionReleased = () {
        released.complete();
        throw const SupportReportException(SupportReportFailure.changed);
      };
      final preview = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      final exported = coordinator.exportDisplayed(preview);
      await save.dispatched.future;
      await released.future;
      expect(fixture.originalRoot, isNull);
      ack.complete(
        const SupportReportSaveResult(SupportReportSaveStatus.saved),
      );
      expect((await exported).status, SupportReportSaveStatus.saved);
    },
  );
  test(
    'missing recipient, picker cancel, changed source and Stop refuse before any ciphertext handoff',
    () async {
      recipient = null;
      final unconfigured = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      expect(unconfigured.recipientConfigured, isFalse);
      final refused = await coordinator.exportDisplayed(unconfigured);
      expect(refused.reason, 'recipientMissing');
      expect(save.choices, 0);
      expect(save.commits, 0);

      recipient = SupportReportRecipient(
        keyId: 'synthetic-native-report',
        publicKey: keys.publicKey,
      );
      save.choose = () async => null;
      final canceled = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      expect(
        (await coordinator.exportDisplayed(canceled)).status,
        SupportReportSaveStatus.canceled,
      );
      expect(save.commits, 0);

      final recipientChanged = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      save.choose = () async {
        recipient = SupportReportRecipient(
          keyId: 'synthetic-other-recipient',
          publicKey: keys.publicKey,
        );
        return save.destination;
      };
      expect(
        (await coordinator.exportDisplayed(recipientChanged)).status,
        SupportReportSaveStatus.refused,
      );
      expect(save.commits, 0);

      final changed = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      save.choose = () async {
        expect(fixture.originalRoot, isNull);
        await fixture.database.customStatement(
          "INSERT INTO characters(char_id,name) VALUES('synthetic-change','Changed')",
        );
        return save.destination;
      };
      expect(
        (await coordinator.exportDisplayed(changed)).status,
        SupportReportSaveStatus.refused,
      );
      expect(save.commits, 0);

      final stopped = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      save.choose = () async {
        fixture.alive = false;
        return save.destination;
      };
      expect(
        (await coordinator.exportDisplayed(stopped)).status,
        SupportReportSaveStatus.refused,
      );
      expect(save.commits, 0);
    },
  );
  test(
    'exclusion retires displayed preview and removes derivative dependency closure',
    () async {
      final preview = await coordinator.prepare(
        const SupportReportPrepareRequest(),
      );
      final excluded = coordinator.exclude(preview, {'events'});
      expect(preview.isRetired, isTrue);
      expect(
        excluded.blocks.any((b) => b.id == 'events' || b.id == 'diagnoses'),
        isFalse,
      );
      expect(
        (await coordinator.exportDisplayed(preview)).status,
        SupportReportSaveStatus.refused,
      );
      expect(save.commits, 0);
      expect(
        (await coordinator.exportDisplayed(excluded)).status,
        SupportReportSaveStatus.saved,
      );
      expect(
        crypto.decrypt(
          packet: save.packet!,
          recipient: recipient!,
          privateKey: keys.secretKey,
        ),
        excluded.payloadJson,
      );
    },
  );
}
