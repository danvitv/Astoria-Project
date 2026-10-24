import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_repair_provider.dart';

import 'repair_gateway_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'missing native port does not construct default database or support vault',
    () {
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWith(
            (ref) => throw StateError('Default DB tripwire'),
          ),
          supportRepoProvider.overrideWith(
            (ref) => throw StateError('Default support tripwire'),
          ),
        ],
      );
      try {
        expect(
          container.read(supportAppControlRepairAdaptersProvider),
          isEmpty,
        );
      } finally {
        container.dispose();
      }
    },
  );

  repairGatewayTest(
    'definitions are finite scalar-only with actual six gateway actions',
    (f) async {
      final definitions = f.registry.definitions;
      expect(definitions.length, 6);
      for (final definition in definitions) {
        expect(definition.parameters['additionalProperties'], false);
        final properties = definition.parameters['properties'] as Map;
        expect(properties.length, lessThanOrEqualTo(16));
        for (final field in properties.values.cast<Map>()) {
          expect(field['type'], isNot(anyOf('object', 'array')));
        }
      }
      final before = await f.base.snapshot();
      for (final args in [
        {'target': f.groupHandle, 'sql': 'DELETE FROM characters'},
        {
          'target': {'id': f.groupHandle},
        },
        {'target': f.groupHandle, 'path': 'characters/legacy'},
        {'target': f.groupHandle, 'operationId': 'model-chosen-replay'},
      ]) {
        final result = await f.call('astoria_database_repair', args);
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      expect(await f.base.snapshot(), before);
    },
  );

  repairGatewayTest(
    'new value obeys strict metadata size and operation consistency',
    (f) async {
      final target = await f.target('liveLedger');
      final before = await f.base.snapshot();
      for (final args in [
        {'target': target, 'operation': 'correctLedger'},
        {
          'target': target,
          'operation': 'deleteUnusedCollector',
          'value': 'value',
        },
        {
          'target': target,
          'operation': 'correctLedger',
          'value': List.filled(257, 'x').join(),
        },
        {'target': target, 'operation': 'correctLedger', 'value': ' value'},
        {
          'target': target,
          'operation': 'correctLedger',
          'value': {'set': 'value'},
        },
      ]) {
        final result = await f.call('astoria_session_repair', args);
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      expect(await f.base.snapshot(), before);
    },
  );

  repairGatewayTest(
    'confirmation waits outside target queue with no leaked source fence',
    (f) async {
      final target = await f.target('liveLedger');
      f.confirmation.beforeDecision = (_) async {
        expect(f.mutations.isSessionPending(RepairFixture.session), false);
        var entered = false;
        await f.native.queue.run(() async {
          entered = true;
        });
        expect(entered, isTrue);
      };
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'completed');
      expect(f.mutations.isSessionPending(RepairFixture.session), false);
    },
  );

  repairGatewayTest(
    'own source admission begins before first native preparation query',
    (f) async {
      final target = await f.target('liveLedger');
      var observed = false;
      f.base.hook = (event) async {
        if (!observed && event.startsWith('select:')) {
          observed = true;
          expect(f.mutations.isSessionPending(RepairFixture.session), true);
        }
      };
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      f.base.hook = null;
      expect(observed, true);
      expect(result.content['code'], 'completed');
    },
  );

  repairGatewayTest('self-target admission cannot bypass retired model ROOT', (
    f,
  ) async {
    final target = await f.target('liveLedger');
    final before = await f.base.snapshot();
    final unsubscribe = f.mutations.subscribe((event) {
      if (event.phase == ChatSourceMutationPhase.began) f.rootCurrent = false;
    });
    try {
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'stale');
      expect(result.content['effect'], 'none');
      expect(await f.base.snapshot(), before);
    } finally {
      unsubscribe();
    }
  });

  repairGatewayTest(
    'refresh failure preserves actual committed facts without private failure',
    (f) async {
      f.native.throwRefresh = true;
      final result = await f.call('astoria_database_repair', {
        'target': f.groupHandle,
      });
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      expect(RepairGatewayFixture.data(result)['refreshPending'], true);
      expect((await f.base.character('legacy'))['variant_group_id'], 'legacy');
      f.safe(result);
    },
  );
}
