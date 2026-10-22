import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_dependencies.dart';
import 'helpers/support_native_fixture.dart';

class _SyntheticRedactor extends SecretRedactorNotifier {
  _SyntheticRedactor(this.redactor);
  final SecretRedactor redactor;
  @override
  SecretRedactor build() => redactor;
}

void main() {
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  test(
    'native view subscription reflects independent toggle and synchronous custody clear',
    () async {
      final container = ProviderContainer(
        overrides: [
          supportNativeRuntimeProvider.overrideWithValue(f.runtime),
          supportNativeConsentControllerProvider.overrideWithValue(
            f.controller,
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        supportNativeViewProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      final review = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      expect(
        container
            .read(supportNativeViewProvider)
            .rights
            .firstWhere((v) => v.right == SupportPermission.readSafeSettings)
            .enabled,
        isTrue,
      );
      expect(
        await f.runtime.inspectSelectedConnection(NativeFixture.id, () => true),
        isTrue,
      );
      expect(container.read(supportNativeViewProvider).inspection, isNotNull);
      expect((await f.controller.prepareReview())!.view.inspection, isNull);
      f.runtime.invalidateConfiguration();
      expect(container.read(supportNativeViewProvider).inspection, isNull);
      expect(
        container.read(supportNativeViewProvider).needsRecipientConfirmation,
        isTrue,
      );
    },
  );

  test(
    'actual native provider composition uses exact injected repositories without startup',
    () async {
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(f.database.db),
          supportRepoProvider.overrideWithValue(f.database.repoB),
          apiConfigRepoProvider.overrideWithValue(f.api),
          connectionRevisionRegistryProvider.overrideWithValue(f.revisions),
          secretRedactorProvider.overrideWith(
            () => _SyntheticRedactor(f.redactor),
          ),
          supportSessionStoreProvider.overrideWithValue(f.workspace),
        ],
      );
      addTearDown(container.dispose);
      final runtime = container.read(supportNativeRuntimeProvider);
      runtime.selectSession(NativeFixture.id);
      final controller = container.read(supportNativeConsentControllerProvider);
      final review = (await controller.prepareReview())!;
      expect(await controller.confirmRecipient(review), isTrue);
      expect(
        await controller.setGrant(
          (await controller.prepareReview())!,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      expect(
        await runtime.inspectSelectedConnection(NativeFixture.id, () => true),
        isTrue,
      );
      expect(runtime.inspection!.configured, isTrue);
      expect(f.api.ids.toSet(), {'synthetic-connection'});
      expect(f.api.bulkReads, 0);
    },
  );
}
