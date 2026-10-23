import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_key_sheet.dart';

import 'support_provider_action_fixture.dart' show ProviderActionFixture;
import 'support_provider_screen_fixture.dart';

void main() {
  providerScreenTest(
    'default-OFF provider sheet is passive and never reads saved keys',
    (tester, f) async {
      await f.mount(tester);
      final before = List.of(f.root.backing.storage.operations);
      await f.tap(tester, 'support_provider_open');
      expect(f.controller(tester), isNull);
      expect(find.byKey(const ValueKey('support_provider_form')), findsNothing);
      expect(f.root.backing.storage.operations, before);
      expect(f.root.requests, isEmpty);
    },
    permissions: false,
  );

  for (final width in [390.0, 1100.0]) {
    providerScreenTest(
      'actual form -> exact Apply -> trusted key -> fake wire width $width',
      (tester, f) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await f.mount(tester);
        await f.tap(tester, 'support_provider_open');
        final c = f.controller(tester)!;
        await f.idle(tester, c);
        await f.tap(tester, 'support_provider_mode_create');
        await f.text(tester, 'support_provider_name', 'Synthetic UI provider');
        await f.text(tester, 'support_provider_model', 'synthetic-model');
        await f.tap(tester, 'support_provider_review');
        expect(
          c.binding.preview(c.review!)?.after?.name,
          'Synthetic UI provider',
        );
        expect(
          await f.join(
            tester,
            f.root.api.getConfigIds,
            label: 'offline config IDs',
          ),
          isEmpty,
        );
        expect(f.root.requests, isEmpty);
        await f.tap(tester, 'support_provider_confirm');
        final fact = await f.join(
          tester,
          () => c.originalJob!,
          label: 'original Apply fact',
        );
        expect(fact.code, SupportProviderActionCode.applied);
        expect(
          (await f.join(
            tester,
            () => f.root.api.getById(fact.applied!.value!.connectionId),
            label: 'actual keyless row',
          ))?.apiKey,
          isEmpty,
        );
        await f.tap(tester, 'support_provider_result_key_open');
        expect(c.keyEntry, isNotNull);
        expect(
          c.current,
          isTrue,
          reason: 'Key opening keeps the original route',
        );
        expect(
          c.keyEntry!.current,
          isTrue,
          reason: 'Original key entry remains mounted',
        );
        expect(c.keyEntry!.requiresCustomConfirmation, isFalse);
        expect(
          c.keyEntry!.readyForInput,
          isTrue,
          reason: 'Original standard-route review completed',
        );
        expect(find.byType(SupportProviderKeySheet), findsOneWidget);
        expect(find.byType(ErrorWidget), findsNothing);
        await f.until(
          tester,
          () => find
              .byKey(const ValueKey('support_provider_key_input'))
              .evaluate()
              .isNotEmpty,
          label: 'native key field built',
        );
        final input = tester.widget<TextField>(
          find.byKey(const ValueKey('support_provider_key_input')),
        );
        expect(input.obscureText, isTrue);
        expect(input.autocorrect, isFalse);
        expect(input.enableSuggestions, isFalse);
        expect(input.enableIMEPersonalizedLearning, isFalse);
        expect(input.autofillHints, isEmpty);
        expect(input.restorationId, isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await f.text(
          tester,
          'support_provider_key_input',
          ProviderActionFixture.secret,
        );
        final target = c.keyEntry!;
        final beforeWrite = f.root.native.mutations.observe()!;
        final metadataReady = Completer<void>();
        void settled() {
          if (!f.root.native.mutations.isCurrent(beforeWrite) &&
              f.root.native.mutations.observe() != null &&
              !metadataReady.isCompleted) {
            metadataReady.complete();
          }
        }

        f.root.native.mutations.addFenceListener(settled);
        try {
          await f.tap(tester, 'support_provider_key_submit', waits: false);
          expect(input.controller!.text, isEmpty); // Before any follow-up pump.
          await f.join(
            tester,
            () => metadataReady.future,
            label: 'original native key fence',
          );
          // _KeySheetState publishes this metadata ONLY from its own original
          // submit future. A stable fence/replacement readiness read is not enough.
          final saved = find.descendant(
            of: find.byType(SupportProviderKeySheet),
            matching: find.text(
              'Key saved (${ProviderActionFixture.secret.runes.length})',
            ),
          );
          await f.until(
            tester,
            () => saved.evaluate().isNotEmpty,
            label: 'original key metadata rendered',
          );
          expect(saved, findsOneWidget);
        } finally {
          f.root.native.mutations.removeFenceListener(settled);
        }
        expect(
          input.controller!.text,
          isEmpty,
        ); // Immediately cleared original controller.
        final ready = await f.join(
          tester,
          () => c.binding.readiness(fact.applied!),
          label: 'actual key readiness',
        );
        expect(ready?.credentialConfigured, isTrue);
        expect(
          ready?.characterCount,
          ProviderActionFixture.secret.runes.length,
        );
        expect(c.current, isTrue);
        expect(target.current, isTrue);
        expect(f.root.requests, isEmpty);
        expect(
          await f.join(
            tester,
            () => f.root.send(fact.applied!),
            label: 'one actual fake-wire send',
          ),
          'Synthetic reply',
        );
        expect(f.root.requests, hasLength(1));
        expect(find.text(ProviderActionFixture.secret), findsNothing);
        expect(
          find.byKey(const ValueKey('support_provider_undo')),
          findsNothing,
        );
      },
    );
  }

  providerScreenTest(
    'review cancellation and route close make retained final gesture inert',
    (tester, f) async {
      await f.mount(tester);
      await f.tap(tester, 'support_provider_open');
      final c = f.controller(tester)!;
      await f.idle(tester, c);
      await f.tap(tester, 'support_provider_mode_create');
      await f.text(tester, 'support_provider_name', 'Canceled provider');
      await f.text(tester, 'support_provider_model', 'synthetic-model');
      await f.tap(tester, 'support_provider_review');
      final retained = c.review!;
      await f.tap(tester, 'support_provider_review_cancel');
      expect(
        c.current,
        isTrue,
        reason: 'Review cancellation keeps the original route',
      );
      c.confirm(retained);
      expect(c.originalJob, isNull);
      await f.tap(tester, 'support_provider_cancel', waits: false);
      expect(c.current, isFalse);
      expect(
        await f.join(
          tester,
          f.root.api.getConfigIds,
          label: 'cancelled config IDs',
        ),
        isEmpty,
      );
      expect(f.root.requests, isEmpty);
    },
  );
}
