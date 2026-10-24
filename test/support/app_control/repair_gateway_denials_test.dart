import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repair_gateway_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final denial in [
    'noConfirmation',
    'cancel',
    'staleRun',
    'staleRoot',
    'declined',
    'uiRetired',
    'noQueue',
    'sourceRetired',
  ]) {
    repairGatewayTest(
      'native $denial denies real Ledger repair with no effect',
      (f) async {
        final target = await f.target('liveLedger');
        final before = await f.base.snapshot();
        SupportAppActionContext context = f.original;
        switch (denial) {
          case 'noConfirmation':
            context = f.context(confirm: false);
          case 'cancel':
            f.token.cancel();
          case 'staleRun':
            f.runCurrent = false;
          case 'staleRoot':
            f.rootCurrent = false;
          case 'declined':
            f.confirmation.approved = false;
          case 'uiRetired':
            f.confirmation.uiCurrent = false;
          case 'noQueue':
            f.native.queueAvailable = false;
          case 'sourceRetired':
            final settle = f.mutations.beginMutation(
              sessionId: RepairFixture.session,
            );
            settle();
        }
        final result = await f.call('astoria_session_repair', {
          'target': target,
          'operation': 'correctLedger',
          'value': 'SYNTHETIC_NEW_VALUE',
        }, context);
        expect(result.content['effect'], 'none');
        expect(result.content['code'], isNot('completed'));
        expect(await f.base.snapshot(), before);
        expect(f.mutations.isSessionPending(RepairFixture.session), isFalse);
        f.safe(result);
      },
    );
  }

  repairGatewayTest(
    'exact confirmation cannot substitute another plan or request',
    (f) async {
      final target = await f.target('liveLedger');
      f.confirmation.beforeDecision = (request) async {
        f.confirmation.substituted = SupportAppConfirmationRequest(
          context: request.context,
          callId: request.callId,
          action: request.action,
          target: request.target,
          arguments: request.arguments,
          observation: Object(),
          observationIsCurrent: () => true,
          preview: request.preview,
        );
      };
      final before = await f.base.snapshot();
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'denied');
      expect(await f.base.snapshot(), before);
      f.safe(result);
    },
  );

  for (final changed in ['head', 'target', 'parent', 'source']) {
    repairGatewayTest('native preview $changed CAS conflict cannot apply', (
      f,
    ) async {
      if (changed == 'head') await f.repair.collector();
      final target = await f.target('liveLedger');
      String? afterChange;
      f.confirmation.beforeDecision = (_) async {
        switch (changed) {
          case 'head':
            await f.repair.advanceHead();
          case 'target':
            await f.base.db.customStatement(
              'UPDATE tracker_rows SET value=? WHERE session_id=? AND scope=?',
              ['SYNTHETIC_LATER', RepairFixture.session, 'ledger'],
            );
          case 'parent':
            await f.base.db.customStatement(
              'UPDATE support_sessions SET updated_at=? WHERE id=?',
              [50, MaintenanceFixture.sessionId],
            );
          case 'source':
            final settle = f.mutations.beginMutation(
              sessionId: RepairFixture.session,
            );
            settle();
        }
        afterChange = await f.base.snapshot();
      };
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['effect'], 'none');
      expect(result.content['code'], isNot('completed'));
      expect(await f.base.snapshot(), afterChange);
      expect(f.native.invalidated, isEmpty);
      f.safe(result);
    });
  }

  for (final retirement in ['cancel', 'source', 'root', 'target']) {
    repairGatewayTest(
      'after real AEAD $retirement rolls target and original journal back',
      (f) async {
        final target = await f.target('liveLedger');
        final before = await f.base.snapshot();
        var triggered = false;
        f.base.hook = (event) async {
          if (triggered ||
              !event.startsWith('encrypt:') ||
              !event.contains('before_ciphertext'))
            return;
          triggered = true;
          switch (retirement) {
            case 'cancel':
              f.token.cancel();
            case 'source':
              final settle = f.mutations.beginMutation(
                sessionId: RepairFixture.session,
              );
              settle();
            case 'root':
              f.rootCurrent = false;
            case 'target':
              await f.base.db.customStatement(
                'UPDATE tracker_rows SET value=? WHERE session_id=? AND scope=?',
                ['SYNTHETIC_INTRUDER', RepairFixture.session, 'ledger'],
              );
          }
        };
        final result = await f.call('astoria_session_repair', {
          'target': target,
          'operation': 'correctLedger',
          'value': 'SYNTHETIC_NEW_VALUE',
        });
        f.base.hook = null;
        expect(triggered, isTrue);
        expect(result.content['effect'], 'none');
        expect(await f.base.snapshot(), before);
        expect(f.mutations.isSessionPending(RepairFixture.session), isFalse);
        f.safe(result);
      },
    );
  }

  repairGatewayTest(
    'write then throw rolls back actual repair and encrypted originals',
    (f) async {
      final target = await f.target('liveLedger');
      final before = await f.base.snapshot();
      var failed = false;
      f.base.hook = (event) async {
        if (!failed && event.startsWith('update:UPDATE "tracker_rows"')) {
          failed = true;
          throw StateError('SYNTHETIC_PRIVATE_REPAIR_FAILURE');
        }
      };
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      f.base.hook = null;
      expect(failed, isTrue);
      expect(result.content['code'], 'storageUncertain');
      expect(result.content['effect'], 'uncertain');
      expect(await f.base.snapshot(), before);
      f.safe(result);
    },
  );

  repairGatewayTest(
    'Stop after actual commit retains persisted fact and retires continuation',
    (f) async {
      final target = await f.target('liveLedger');
      f.native.afterInvalidate = () =>
          f.token.cancel('synthetic Stop after commit');
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'persisted');
      expect(RepairGatewayFixture.data(result), isEmpty);
      expect(
        (await f.base.db.select(f.base.db.supportMutationJournal).get())
            .single
            .status,
        'applied',
      );
      expect(
        (await f.base.db.select(f.base.db.trackerRows).get())
            .where((r) => r.value == 'SYNTHETIC_NEW_VALUE')
            .length,
        1,
      );
      expect(f.native.invalidated, [RepairFixture.session]);
      f.safe(result);
    },
  );

  repairGatewayTest(
    'missing private-body lease does not reveal before image in confirmation',
    (f) async {
      final target = await f.target('liveLedger');
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'completed');
      expect(f.original.sourceAccess, isNull);
      final preview = f.confirmation.requests.single;
      expect(preview.preview['bodyAccess'], 'notGranted');
      expect(preview.preview.containsKey('before'), isFalse);
      f.safe(result);
    },
  );

  repairGatewayTest(
    'foreign original parent/run cannot use native target or receipt',
    (f) async {
      final result = await f.call('astoria_database_repair', {
        'target': f.groupHandle,
      });
      expect(result.content['code'], 'completed');
      final before = await f.base.snapshot();
      final foreign = f.context(
        parent: 'synthetic-foreign-parent',
        run: 'foreign-run',
        cancel: CancelToken(),
      );
      final undo = await f.call('astoria_database_repair_undo', {
        'receipt': RepairGatewayFixture.data(result)['receipt'],
      }, foreign);
      expect(undo.content['code'], 'unavailable');
      expect(await f.base.snapshot(), before);
      f.safe(undo);
    },
  );

  repairGatewayTest(
    'later run Undo uses actual receipt with fresh lease, not old current callback',
    (f) async {
      final target = await f.target('liveLedger');
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'completed');
      f.token.cancel();
      final later = f.context(
        run: 'synthetic-later-run',
        cancel: CancelToken(),
      );
      final undo = await f.call('astoria_session_repair_undo', {
        'receipt': RepairGatewayFixture.data(result)['receipt'],
      }, later);
      expect(undo.content['code'], 'completed');
      expect(RepairGatewayFixture.data(undo)['outcome'], 'undone');
      expect(f.confirmation.requests.last.context, same(later));
      f.safe(undo);
    },
  );
}
