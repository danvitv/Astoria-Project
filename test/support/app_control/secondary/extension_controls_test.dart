import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';

import 'secondary_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecondaryFixture fixture;
  late SupportAppActionRegistry registry;
  late SyntheticOriginalConfirmation native;
  late SupportAppActionContext context;
  late String initialConfig;

  Future<String> blockHandle() async {
    final presets = await registry.execute(
      secondaryCall('astoria_extension_controls_read'),
      context,
    );
    expect(presets.content['code'], 'completed');
    final presetHandle =
        (secondaryData(presets)['items'] as List).first['handle'] as String;
    final blocks = await registry.execute(
      secondaryCall('astoria_extension_controls_read', {
        'presetHandle': presetHandle,
      }),
      context,
    );
    expect(blocks.content['code'], 'completed');
    expect(
      jsonEncode([presets.content, blocks.content]),
      isNot(contains(secondaryPrivateCanary)),
    );
    return (secondaryData(blocks)['items'] as List).first['handle'] as String;
  }

  Future<ExtensionPresetRow> durable() =>
      fixture.db.select(fixture.db.extensionPresets).getSingle();

  setUp(() async {
    fixture = await SecondaryFixture.create();
    initialConfig = jsonEncode({
      'id': '$secondaryPrivateCanary-preset-id',
      'name': secondaryPrivateCanary,
      'privateUnknown': {'keep': secondaryPrivateCanary},
      'apiConfigId': '$secondaryPrivateCanary-connection',
      'blocks': [
        {
          'id': '$secondaryPrivateCanary-block-id',
          'name': secondaryPrivateCanary,
          'type': 'script',
          'source': 'carried',
          'script': '$secondaryPrivateCanary private stored source',
          'prompt': secondaryPrivateCanary,
          'enabled': true,
          'trigger': 'periodic',
          'unknownBlockField': secondaryPrivateCanary,
        },
        {
          'id': 'owned-other',
          'name': secondaryPrivateCanary,
          'enabled': true,
          'type': 'generated',
        },
      ],
    });
    await fixture.db
        .into(fixture.db.extensionPresets)
        .insert(
          ExtensionPresetsCompanion.insert(
            id: '$secondaryPrivateCanary-preset-id',
            name: secondaryPrivateCanary,
            configJson: initialConfig,
            createdAt: const Value(42),
          ),
        );
    registry = fixture.registry();
    native = SyntheticOriginalConfirmation();
    context = fixture.context(confirmation: native);
    await fixture.container.read(extensionPresetsProvider.notifier).refresh();
  });
  tearDown(() async => fixture.close());

  test(
    'typed call -> original native confirmation -> persisted narrow effect and native refresh',
    () async {
      final handle = await blockHandle();
      final result = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      expect(native.calls, 1);
      expect(native.request!.context, same(context));
      expect(native.request!.action, 'astoria_extension_block_disable');
      expect(native.request!.target, handle);
      expect(native.request!.arguments, {'blockHandle': handle});
      expect(native.request!.preview['executesCode'], false);
      expect(native.request!.preview['networkRequests'], 0);
      expect(
        jsonEncode(native.request!.preview),
        isNot(contains(secondaryPrivateCanary)),
      );
      expect(
        jsonEncode(result.content),
        isNot(contains(secondaryPrivateCanary)),
      );
      final row = await durable();
      final after = jsonDecode(row.configJson) as Map<String, dynamic>;
      final expected = jsonDecode(initialConfig) as Map<String, dynamic>;
      (expected['blocks'] as List).first['enabled'] = false;
      expect(after, expected);
      expect(row.name, secondaryPrivateCanary);
      expect(row.createdAt, 42);
      final visible = fixture.container.read(extensionPresetsProvider).single;
      expect(visible.blocks.first.enabled, false);
      expect(visible.blocks.last.enabled, true);
    },
  );

  test(
    'no original host and no model paid/enable/file approval have no effect',
    () async {
      context = fixture.context();
      final handle = await blockHandle();
      final missingHost = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(missingHost.content['code'], 'unavailable');
      for (final extra in [
        {'enabled': true},
        {'paidApproved': true},
        {'path': 'model-owned-path'},
        {'script': 'model source'},
        {'confirm': true},
      ]) {
        final result = await registry.execute(
          secondaryCall('astoria_extension_block_disable', {
            'blockHandle': handle,
            ...extra,
          }),
          context,
        );
        expect(result.content['code'], 'invalidArguments');
      }
      for (final action in [
        'astoria_image_generate',
        'astoria_native_file_import',
        'astoria_authenticate',
      ]) {
        final result = await registry.execute(secondaryCall(action), context);
        expect(result.content['code'], 'unknownAction');
      }
      expect((await durable()).configJson, initialConfig);
      expect(native.calls, 0);
    },
  );

  test(
    'Cancel or retired original native UI before gesture does not write',
    () async {
      final handle = await blockHandle();
      native.beforeGesture = (_) async => context.cancelToken.cancel();
      final cancelled = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(cancelled.content['code'], 'cancelled');
      expect(cancelled.content['effect'], 'none');
      expect((await durable()).configJson, initialConfig);
    },
  );

  test(
    'native denial, stale native lease and replacement context do not write',
    () async {
      final handle = await blockHandle();
      native.accept = false;
      final denied = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(denied.content['code'], 'denied');
      native.accept = true;
      native.nativeCurrent = false;
      final staleNative = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(staleNative.content['code'], 'denied');
      native.nativeCurrent = true;
      native.replaceRequest = true;
      final substituted = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(substituted.content['code'], 'denied');
      context = fixture.context(confirmation: SyntheticOriginalConfirmation());
      final replacement = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(replacement.content['code'], 'unavailable');
      expect((await durable()).configJson, initialConfig);
    },
  );

  test(
    'connection-only model ROOT cannot be borrowed for extension effects',
    () async {
      final root = SyntheticConnectionOnlyRoot();
      context = fixture.context(confirmation: native, terminalRoot: root);
      final handle = await blockHandle();
      final result = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(native.calls, 0);
      expect(root.calls, 0);
      expect((await durable()).configJson, initialConfig);
    },
  );

  test(
    'latest-row CAS rejects a real concurrent owner write during exact confirmation',
    () async {
      final handle = await blockHandle();
      final repo = fixture.container.read(extensionPresetsRepoProvider);
      native.beforeGesture = (_) async {
        final latest = await repo.getById('$secondaryPrivateCanary-preset-id');
        await repo.updatePreset(latest!.copyWith(name: 'owned native rename'));
      };
      final result = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(result.content['code'], 'conflict');
      expect(result.content['effect'], 'none');
      final after = await repo.getById('$secondaryPrivateCanary-preset-id');
      expect(after!.name, 'owned native rename');
      expect(after.blocks.first.enabled, true);
    },
  );

  test(
    'durable fact survives original source retirement after native refresh',
    () async {
      context = fixture.context(
        confirmation: native,
        current: () =>
            fixture.sourceCurrent &&
            fixture.container
                .read(extensionPresetsProvider)
                .every((p) => p.blocks.every((b) => b.enabled)),
      );
      final handle = await blockHandle();
      final result = await registry.execute(
        secondaryCall('astoria_extension_block_disable', {
          'blockHandle': handle,
        }),
        context,
      );
      expect(result.content['code'], 'stale');
      expect(result.content['effect'], 'persisted');
      expect(secondaryData(result), isEmpty);
      expect(
        (jsonDecode((await durable()).configJson)['blocks'] as List)
            .first['enabled'],
        false,
      );
    },
  );

  test('stale retained block handle fails before prompting again', () async {
    final handle = await blockHandle();
    final first = await registry.execute(
      secondaryCall('astoria_extension_block_disable', {'blockHandle': handle}),
      context,
    );
    expect(first.content['code'], 'completed');
    final stale = await registry.execute(
      secondaryCall('astoria_extension_block_disable', {'blockHandle': handle}),
      context,
    );
    expect(stale.content['code'], 'conflict');
    expect(native.calls, 1);
  });

  test('already disabled native target is exact-confirmed noChange', () async {
    final repo = fixture.container.read(extensionPresetsRepoProvider);
    final current = await repo.getById('$secondaryPrivateCanary-preset-id');
    await repo.updatePreset(
      current!.copyWith(
        blocks: [
          current.blocks.first.copyWith(enabled: false),
          current.blocks.last,
        ],
      ),
    );
    await fixture.container.read(extensionPresetsProvider.notifier).refresh();
    final before = (await durable()).configJson;
    final handle = await blockHandle();
    final result = await registry.execute(
      secondaryCall('astoria_extension_block_disable', {'blockHandle': handle}),
      context,
    );
    expect(result.content['code'], 'noChange');
    expect(result.content['effect'], 'none');
    expect(native.calls, 1);
    expect((await durable()).configJson, before);
  });

  test(
    'registry metadata is bounded to 32 native presets with explicit hasMore',
    () async {
      for (var index = 0; index < 32; index++) {
        await fixture.db
            .into(fixture.db.extensionPresets)
            .insert(
              ExtensionPresetsCompanion.insert(
                id: 'z-owned-extra-$index',
                name: secondaryPrivateCanary,
                configJson: jsonEncode({'blocks': []}),
              ),
            );
      }
      final result = await registry.execute(
        secondaryCall('astoria_extension_controls_read'),
        context,
      );
      expect(result.content['code'], 'completed');
      expect((secondaryData(result)['items'] as List).length, 32);
      expect(secondaryData(result)['hasMore'], true);
      expect(
        jsonEncode(result.content),
        isNot(contains(secondaryPrivateCanary)),
      );
    },
  );
}
