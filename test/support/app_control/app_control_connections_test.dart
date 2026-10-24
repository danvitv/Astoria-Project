import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';

import 'app_control_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  appControlTest(
    'keyless create and finite update persist actual repository effects',
    (f) async {
      final id = await f.createConnection();
      final before = (await f.api.inspectKeyless(id))!.view;
      expect(before.model, 'synthetic-model');
      final result = await f.call('astoria_connection_update', {
        'connectionId': id,
        'name': 'SYNTHETIC_RENAMED',
        'model': 'synthetic-next-model',
        'maxTokens': 1024,
        'contextSize': 8192,
        'temperature': 0.5,
      });
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      final after = (await f.api.inspectKeyless(id))!.view;
      expect(after.displayName, 'SYNTHETIC_RENAMED');
      expect(after.model, 'synthetic-next-model');
      expect(after.maxTokens, 1024);
      expect(after.contextSize, 8192);
      expect(after.temperature, 0.5);
      expect(after.endpoint, before.endpoint);
      expect(after.protocol, before.protocol);
      expect(f.mutations.releases, 2);
      final read = await f.call('astoria_connection_read', {
        'connectionId': id,
      });
      expect(read.content['code'], 'completed');
      final data = read.content['data']! as Map;
      expect(data['credentialConfigured'], isFalse);
      expect(data['credentialCharacterCount'], 0);
      expect(data['verification'], 'notTested');
      expect(data.containsKey('endpoint'), isFalse);
      expect(data.containsKey('apiKey'), isFalse);
      final list = await f.call('astoria_connections_list');
      expect((list.content['data']! as Map)['connections'], hasLength(1));
    },
  );

  appControlTest('missing confirmation port refuses before creating a row', (
    f,
  ) async {
    final result = await f.call('astoria_connection_create', {
      'template': 'openaiChat',
      'name': 'SYNTHETIC_CONNECTION',
      'model': 'synthetic-model',
    }, f.context(withConfirmation: false));
    expect(result.content['code'], 'unavailable');
    expect(await f.api.getConfigIds(), isEmpty);
  });

  appControlTest('denied exact configuration confirmation makes no update', (
    f,
  ) async {
    final id = await f.createConnection();
    final before = (await f.api.inspectKeyless(id))!.view;
    f.confirmation.accept = false;
    final result = await f.call('astoria_connection_update', {
      'connectionId': id,
      'name': 'DENIED_NAME',
    });
    expect(result.content['code'], 'denied');
    expect((await f.api.inspectKeyless(id))!.view, before);
    expect(f.confirmation.last!.target, id);
    expect(f.confirmation.last!.arguments['name'], 'DENIED_NAME');
    expect(
      () => f.confirmation.last!.arguments['name'] = 'CHANGED',
      throwsUnsupportedError,
    );
    expect(
      () =>
          (f.confirmation.last!.preview['before']! as Map)['name'] = 'CHANGED',
      throwsUnsupportedError,
    );
  });

  appControlTest('cancelled native confirmation creates no row', (f) async {
    f.confirmation.beforeDecision = (_) async => f.cancelToken.cancel();
    final result = await f.call('astoria_connection_create', {
      'template': 'openaiChat',
      'name': 'SYNTHETIC_CONNECTION',
      'model': 'synthetic-model',
    });
    expect(result.content['code'], 'cancelled');
    expect(result.content['effect'], 'none');
    expect(await f.api.getConfigIds(), isEmpty);
  });

  appControlTest(
    'retained decision for different immutable request cannot authorize update',
    (f) async {
      final id = await f.createConnection();
      final original = f.confirmation.last!;
      final before = (await f.api.inspectKeyless(id))!.view;
      f.confirmation.replaceWith = original;
      final result = await f.call('astoria_connection_update', {
        'connectionId': id,
        'name': 'WRONG_REQUEST_NAME',
      });
      expect(result.content['code'], 'denied');
      expect((await f.api.inspectKeyless(id))!.view, before);
    },
  );

  appControlTest(
    'cancel during native repository acquisition rolls back/no row',
    (f) async {
      f.mutations.beforeAcquire = () async => f.cancelToken.cancel();
      final result = await f.call('astoria_connection_create', {
        'template': 'openaiChat',
        'name': 'SYNTHETIC_CONNECTION',
        'model': 'synthetic-model',
      });
      expect(result.content['code'], 'cancelled');
      expect(await f.api.getConfigIds(), isEmpty);
    },
  );
}
