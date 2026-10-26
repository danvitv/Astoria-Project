import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_view.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';

import 'helpers/support_model_provider_fixture.dart';
import 'support_app_domain_loop_fixture.dart';

// Actual workspace/native policy and original model ROOT over the existing
// explicit text/SSE fixture. The separate native tool fixture covers tools.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SupportModelUiSend sendVisible(
    ModelProviderFixture f, {
    String text = 'Actual native question',
  }) {
    final emitter = f.bridge.bindEmitter(
      controller: Object(),
      uiLifetime: Object(),
      isEmitterCurrent: () => true,
      visibleConversation: f.state.activeMessages
          .map(
            (m) => SupportModelConversationMessage(
              id: m.id,
              role: m.role.name,
              text: m.body,
            ),
          )
          .toList(),
    );
    f.emitters.add(emitter);
    return f.send(from: emitter, text: text);
  }

  test(
    'native global configuration remains enabled cross-chat while exact selected history is ineffective; DirectSend unchanged',
    () async {
      await ModelProviderFixture(nativeToolRuntime: false).run((f) async {
        await f.grantHistory(
          SupportPermissionScope(
            selectionRevision: 1,
            supportHistory: SupportMessageSelection(['old-excluded']),
          ),
          [SupportPermission.modelSupportHistory],
        );
        final runtime = f.container.read(supportNativeRuntimeProvider);
        expect(runtime.snapshot.preferences!.isGlobal, isTrue);
        final global = (await f.repo.getContextBlockById(
          SupportPermissionCodec.globalId,
        ))!;
        f.workspace.selectSession(ModelProviderFixture.otherSession);
        await f.workspace.refresh();
        final p = runtime.snapshot.preferences!;
        expect(p.isConfigured(SupportPermission.modelSupportHistory), isTrue);
        expect(p.allows(SupportPermission.modelSupportHistory), isFalse);
        expect(p.scope!.supportHistory, isNull);
        expect(
          await f.repo.getContextBlockById(SupportPermissionCodec.globalId),
          global,
        );
        // No new per-request recipient confirmation for ordinary current chat.
        final send = sendVisible(f, text: 'Current other chat question');
        final preview = await f.preview(send);
        expect(preview.gameMessages, 0);
        final result = await send.finished;
        expect(result.saved, isTrue);
        expect(f.adapters.single.fetches, 1);
        expect(
          f.adapters.single.upload,
          contains('Current other chat question'),
        );
        expect(
          f.adapters.single.upload,
          isNot(contains(ModelProviderFixture.excluded)),
        );
      });
    },
  );

  domainLoopTest(
    'ORIGINAL ROOT sees durable global revocation from separate store before wire, not stale native UI policy',
    (tester, f) async {
      final core = f.screen.core;
      final runtime = core.native.runtime;
      await configurationAction(tester, () async {
        await runtime.permissions.initializeGlobalFromNative(
          core.native.session,
          isCurrent: () => true,
        );
        await runtime.permissions.selectScopeFromNative(
          core.native.session,
          SupportPermissionScope(
            selectionRevision: 1,
            safeCategories: [SupportSafeCategory.connections],
          ),
          isCurrent: () => true,
        );
        await runtime.permissions.setGrantFromNative(
          core.native.session,
          SupportPermission.readSafeSettings,
          true,
          isCurrent: () => true,
        );
        await core.container.read(supportWorkspaceProvider.notifier).refresh();
      });
      final nativeRevision = runtime.snapshot.preferences!.revision;
      final entered = Completer<void>(), release = Completer<void>();
      final settled = Completer<void>();
      final bridge = core.container.read(supportModelUiBridgeProvider);
      final stop = bridge.listen(() {
        final view = bridge.view;
        if (!view.busy &&
            (view.phase == SupportModelPhase.settled ||
                view.reason != SupportModelRefusal.none) &&
            !settled.isCompleted) {
          settled.complete();
        }
      });
      core.native.storage.beforeRead = () async {
        if (bridge.view.phase == SupportModelPhase.waiting &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      f.script(core.answer('This response must never be requested.'));
      try {
        await tester.enterText(
          find.byType(TextField).first,
          'Use current Astoria settings.',
        );
        await configurationAction(
          tester,
          () => tester.tap(
            find.byKey(const ValueKey('support_composer_send_btn')),
          ),
        );
        await f.screen.join(tester, entered.future);
        final b = SupportPermissionStore(core.native.repo);
        await configurationAction(
          tester,
          () => b.setGrantFromNative(
            core.native.session,
            SupportPermission.readSafeSettings,
            false,
            isCurrent: () => true,
          ),
        );
        expect(runtime.snapshot.preferences!.revision, nativeRevision);
        expect(
          (await configurationAction(
            tester,
            () => b.readForNative(core.native.session),
          )).preferences!.revision,
          greaterThan(nativeRevision),
        );
        release.complete();
        await f.screen.join(tester, settled.future);
        expect(core.wire, isEmpty);
        expect(core.firstFetch.isCompleted, false);
      } finally {
        core.native.storage.beforeRead = null;
        if (!release.isCompleted) release.complete();
        stop();
      }
    },
  );

  test(
    'global local-read grant alone sends no foreign selected history; current question is permitted',
    () async {
      await ModelProviderFixture(nativeToolRuntime: false).run((f) async {
        await f.grantHistory(
          SupportPermissionScope(
            selectionRevision: 1,
            supportHistory: SupportMessageSelection(['old-excluded']),
            safeCategories: [SupportSafeCategory.connections],
          ),
          [SupportPermission.readSafeSettings],
        );
        final runtime = f.container.read(supportNativeRuntimeProvider);
        await runtime.permissions.setGrantFromNative(
          ModelProviderFixture.otherSession,
          SupportPermission.modelSupportHistory,
          false,
          isCurrent: () => true,
        );
        await runtime.refresh(resolve: true);
        f.workspace.selectSession(ModelProviderFixture.otherSession);
        await f.workspace.refresh();
        expect(
          runtime.snapshot.preferences!.isConfigured(
            SupportPermission.readSafeSettings,
          ),
          isTrue,
        );
        expect(
          runtime.snapshot.preferences!.allows(
            SupportPermission.modelSupportHistory,
          ),
          isFalse,
        );
        final send = sendVisible(f, text: 'Native current question only');
        final preview = await f.preview(send);
        expect(preview.gameMessages, 0);
        expect(
          preview.messages.map((m) => m.text),
          isNot(contains(ModelProviderFixture.excluded)),
        );
        final result = await send.finished;
        expect(result.saved, isTrue);
        expect(f.adapters.single.fetches, 1);
        expect(
          f.adapters.single.upload,
          isNot(contains(ModelProviderFixture.excluded)),
        );
        expect(
          f.adapters.single.upload,
          contains('Native current question only'),
        );
      });
    },
  );
}
