import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/memory_setup/memory_setup_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_connection_metadata_service.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../support_app_domain_loop_fixture.dart';
import 'memory_setup_preferences_backing.dart';

export '../support_app_domain_loop_fixture.dart';
export 'package:glaze_flutter/core/state/db_provider.dart';
export 'package:glaze_flutter/core/models/memory_book.dart';
export 'package:glaze_flutter/features/support_assistant/services/memory_setup/memory_setup_service.dart';

/// Reuses real ChatNotifier/domain queue + native root/FakeVault/AEAD/SQL hooks
/// and no-file/socket/platform tripwires. No fake native controller or POST.
final class MemorySetupNativeFixture {
  MemorySetupNativeFixture(this.domain);
  final DomainLoopFixture domain;
  late MemorySetupService service;
  late TrackedSharedPreferences prefs;
  late MemorySetupPreferencesBacking backing;
  SharedPreferencesStorePlatform? previousBackend;
  bool alive = true;
  final secret = 'WIZARD_PRIVATE_CREDENTIAL_CANARY';

  Future<void> initialize({bool grant = true, bool selectTarget = true}) async {
    final core = domain.screen.core, c = core.container, native = core.native;
    core.isolation.extraAllowed.addAll({
      memoryGlobalSettingsProvider,
      pipelineSettingsProvider,
    });
    await native.runtime.permissions.initializeGlobalFromNative(
      native.session,
      isCurrent: () => alive,
    );
    if (grant)
      await native.runtime.permissions.setGrantFromNative(
        native.session,
        SupportPermission.readApplicationData,
        true,
        isCurrent: () => alive,
      );
    await native.runtime.refresh(resolve: false);
    native.redaction.registerSecret(secret);
    // Synthetic plugin backend only. No actual user preferences are consulted.
    final initial = <String, Object>{
      'memorySettings': jsonEncode({
        'enabled': true,
        'autoCreateEnabled': false,
        'autoGenerateEnabled': false,
        'vectorSearchEnabled': false,
        'unknownMemory': {'retained': secret},
      }),
      'pipelineSettings': jsonEncode({
        'studioAgent': <String, Object?>{},
        'memoryBookApi': {
          'generationSource': 'custom',
          'apiConfigId': 'old-slot',
          'generationModel': 'old-model',
          'generationApiKey': secret,
          'generationEndpoint': 'https://example.invalid',
          'unknownSlot': {'retained': secret},
        },
        'unknownRoot': {'retained': secret},
      }),
    };
    SharedPreferences.setMockInitialValues(initial);
    previousBackend = SharedPreferencesStorePlatform.instance;
    backing = MemorySetupPreferencesBacking(initial);
    SharedPreferencesStorePlatform.instance = backing;
    prefs =
        await TrackedSharedPreferences.getInstance()
            as TrackedSharedPreferences;
    final controller = c.read(supportNativeConsentControllerProvider);
    final redactor = native.redaction.redactor;
    final metadata = SupportConnectionMetadataService(
      native.apiRepo,
      () => native.redaction.redactor,
      nativeMetadata: native.native.credentialReader,
      nativeMetadataIsCurrent: () => alive && native.native.isCurrent,
    );
    service = MemorySetupService(
      controller: controller,
      books: c.read(memoryBookRepoProvider),
      chats: c.read(chatRepoProvider),
      catalog: c.read(memoryCatalogRepoProvider),
      api: native.apiRepo,
      sources: c.read(chatSourceMutationRegistryProvider),
      owners: c.read(chatNativeOwnerRegistryProvider),
      journal: native.repo,
      redactor: redactor,
      connections: native.revisions,
      originalCurrent: () => alive && native.native.isCurrent,
      dbCurrent: () => alive,
      preferences: prefs,
      publishMemory: c
          .read(memoryGlobalSettingsProvider.notifier)
          .publishNativeSaved,
      publishPipeline: c
          .read(pipelineSettingsProvider.notifier)
          .publishNativeSaved,
      onBookChanged: (_) {},
      loadConnectionMetadata: (current) => metadata.load(isCurrent: current),
    );
    if (grant) {
      expect(service.start(controller.view.displayedIntent), isTrue);
      if (selectTarget)
        expect(
          service.selectTarget(
            service.targets.singleWhere((t) => t.sessionId == DomainLoopFixture.session),
          ),
          isTrue,
        );
    }
  }

  void close() {
    service.retire();
    alive = false;
    if (previousBackend case final previous?)
      SharedPreferencesStorePlatform.instance = previous;
  }
}

void memorySetupTest(
  String name,
  Future<void> Function(WidgetTester, MemorySetupNativeFixture) body, {
  bool selectTarget = true,
}) {
  domainLoopTest(name, (tester, domain) async {
    final f = MemorySetupNativeFixture(domain);
    try {
      await configurationAction(
        tester,
        () => f.initialize(selectTarget: selectTarget),
      );
      await body(tester, f);
    } finally {
      f.close();
    }
  });
}
