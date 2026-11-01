import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_report_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';

import '../helpers/support_native_widget_fixture.dart';
import 'support_report_sheet_fixture.dart';

// Bounded real/fake-zone driver: no pumpAndSettle over an intentional busy
// spinner or retained cipher/native future. Parent serial native lane runs this.
Future<void> _turns(WidgetTester tester, {int count = 60}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key));
  await _turns(tester);
}

String _payload(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('support_report_payload')))
    .data!;

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  late SupportReportSheetFixture fixture;
  setUp(() async {
    fixture = SupportReportSheetFixture();
    await fixture.initialize();
  });
  tearDown(() => fixture.close());

  Future<void> mount(
    WidgetTester tester, {
    List<Override>? overrides,
    bool watchController = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides ?? fixture.overrides,
        child: localizedNativeWidget(
          Consumer(
            builder: (context, ref, _) {
              ref.watch(supportNativeRuntimeProvider);
              if (watchController) {
                ref.watch(supportNativeConsentControllerProvider);
              } else {
                // No unrelated eager observer should recreate a retired graph;
                // this case measures only the old report-selection flow.
                ref.read(supportNativeConsentControllerProvider);
              }
              return GlazeActionButton(
                key: const ValueKey('open-report'),
                icon: Icons.description_outlined,
                label: 'Открыть',
                onTap: () => showSupportReportSheet(context),
              );
            },
          ),
        ),
      ),
    );
    await _turns(tester);
    await _tap(tester, const ValueKey('open-report'));
    expect(tester.takeException(), isNull);
  }

  for (final retired in ['controller', 'selections']) {
    testWidgets(
      'pending content consent retains $retired without constructing a replacement',
      (tester) async {
        var controllerConstructions = 0, selectionConstructions = 0;
        var selectionAlive = true;
        await mount(
          tester,
          watchController: false,
          overrides: fixture.overridesWith(
            controllerOverride: supportNativeConsentControllerProvider
                .overrideWith((ref) {
                  controllerConstructions++;
                  if (controllerConstructions != 1)
                    throw StateError(
                      'Replacement controller must not be constructed',
                    );
                  ref.onDispose(fixture.controller.invalidateDisplayedIntents);
                  return fixture.controller;
                }),
            selectionsOverride: supportConsentSelectionRepoProvider.overrideWith((
              ref,
            ) {
              selectionConstructions++;
              if (selectionConstructions != 1)
                throw StateError(
                  'Replacement selection graph must not be constructed or queried',
                );
              ref.onDispose(() => selectionAlive = false);
              return SupportConsentSelectionRepo(
                db: fixture.native.database,
                supportRepo: fixture.repo,
                currentRedactor: () => fixture.native.redactor,
                originalOwnerCurrent: () => selectionAlive,
              );
            }),
          ),
        );
        await _tap(tester, const ValueKey('support_report_include_game'));
        expect(
          find.byKey(
            const ValueKey('support_application_data_consent_decline'),
          ),
          findsOneWidget,
        );
        expect(controllerConstructions, 1);
        expect(
          selectionConstructions,
          1,
          reason: 'Selection owner must be retained BEFORE the consent await',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SupportReportSheet)),
        );
        if (retired == 'controller') {
          container.invalidate(supportNativeConsentControllerProvider);
        } else {
          container.invalidate(supportConsentSelectionRepoProvider);
          expect(selectionAlive, false);
        }
        await _tap(
          tester,
          const ValueKey('support_application_data_consent_decline'),
        );
        expect(controllerConstructions, 1);
        expect(selectionConstructions, 1);
        expect(find.text('Одна игровая сессия для репорта'), findsNothing);
        expect(fixture.saves.single.choices, 0);
        expect(
          fixture.runtime.snapshot.preferences!.allows(
            SupportPermission.readApplicationData,
          ),
          false,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'whole passive preview, one read consent, real exclusion and exact encrypted save',
    (tester) async {
      await mount(tester);
      final safe = _payload(tester);
      expect(safe, isNot(contains(SupportReportSheetFixture.body)));
      expect(fixture.saves.single.choices, 0);
      await _tap(tester, const ValueKey('support_report_include_current'));
      expect(
        find.byKey(const ValueKey('support_application_data_consent_accept')),
        findsOneWidget,
      );
      await _tap(
        tester,
        const ValueKey('support_application_data_consent_accept'),
      );
      expect(
        fixture.runtime.snapshot.preferences!.allows(
          SupportPermission.readApplicationData,
        ),
        isTrue,
      );
      final personal = _payload(tester);
      expect(personal, contains(SupportReportSheetFixture.title));
      expect(personal, contains(SupportReportSheetFixture.body));
      expect(
        find.byKey(const ValueKey('support_application_data_consent_accept')),
        findsNothing,
      );
      await _tap(tester, const ValueKey('support_report_include_current'));
      expect(
        find.byKey(const ValueKey('support_application_data_consent_accept')),
        findsNothing,
        reason:
            'Existing single global read consent is reused, not re-requested.',
      );
      final excludes = find.byWidgetPredicate(
        (widget) =>
            widget is GlazeActionButton &&
            widget.key.toString().contains(
              'support_report_exclude_supportCommentary',
            ),
      );
      // Native backend block names are read from the actual payload, not a forged
      // preview. Pick any personal block by its issued stable identifier.
      expect(excludes, findsOneWidget);
      await tester.ensureVisible(excludes);
      await tester.pump();
      final oldSaveHandler = tester
          .widget<GlazeActionButton>(
            find.byKey(const ValueKey('support_report_save')),
          )
          .onTap!;
      await tester.tap(excludes);
      oldSaveHandler(); // Old painted callback cannot export unpainted replacement.
      expect(fixture.saves.last.choices, 0);
      await _turns(tester);
      expect(_payload(tester), isNot(contains('Commentary boundary')));
      await _tap(tester, const ValueKey('support_report_exclude_supportTitle'));
      final replacement = _payload(tester);
      expect(replacement, isNot(contains(SupportReportSheetFixture.body)));
      expect(replacement, isNot(contains(SupportReportSheetFixture.title)));
      expect(
        find.byKey(const ValueKey('support_report_removed')),
        findsOneWidget,
      );
      final save = fixture.saves.last;
      expect(save.choices, 0);
      await _tap(tester, const ValueKey('support_report_save'));
      expect(save.commits, 1);
      expect(
        fixture.crypto.decrypt(
          packet: save.packet!,
          recipient: fixture.recipient!,
          privateKey: fixture.keys.secretKey,
        ),
        replacement,
      );
      expect(find.textContaining('Ничего не отправлено.'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing recipient still prepares, cannot save or send', (
    tester,
  ) async {
    fixture.recipient = null;
    await mount(tester);
    expect(_payload(tester), isNotEmpty);
    expect(
      tester
          .widget<GlazeActionButton>(
            find.byKey(const ValueKey('support_report_save')),
          )
          .onTap,
      isNull,
    );
    expect(find.textContaining('ключ получателя не настроен'), findsOneWidget);
    expect(fixture.saves.single.choices, 0);
    expect(fixture.saves.single.commits, 0);
  });

  testWidgets('declining the existing consent never adds personal history', (
    tester,
  ) async {
    await mount(tester);
    await _tap(tester, const ValueKey('support_report_include_current'));
    await _tap(
      tester,
      const ValueKey('support_application_data_consent_decline'),
    );
    expect(
      fixture.runtime.snapshot.preferences!.allows(
        SupportPermission.readApplicationData,
      ),
      isFalse,
    );
    expect(find.textContaining(SupportReportSheetFixture.body), findsNothing);
    expect(fixture.saves.single.choices, 0);
    expect(fixture.saves.single.commits, 0);
  });

  testWidgets(
    'native epoch retires displayed preview with no automatic recapture',
    (tester) async {
      await mount(tester);
      fixture.runtime.invalidateLease();
      await _turns(tester);
      expect(
        find.byKey(const ValueKey('support_report_payload')),
        findsNothing,
      );
      expect(
        tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_report_save')),
            )
            .onTap,
        isNull,
      );
      expect(fixture.owners.length, 1);
      expect(fixture.saves.single.choices, 0);
    },
  );

  testWidgets(
    'same-DB OFF from another store retires even without durable write',
    (tester) async {
      await mount(tester);
      SupportPermissionStore(fixture.repo).latchApplicationDataRevocation();
      await _turns(tester);
      expect(
        find.byKey(const ValueKey('support_report_payload')),
        findsNothing,
      );
      expect(fixture.owners.length, 1);
      expect(fixture.saves.single.commits, 0);
    },
  );

  testWidgets('cancel while selector is pending admits no ciphertext', (
    tester,
  ) async {
    await mount(tester);
    final save = fixture.saves.single;
    final selection = Completer<void>();
    save.choose = () async {
      await selection.future;
      return save.destination;
    };
    await _tap(tester, const ValueKey('support_report_save'));
    expect(save.choices, 1);
    expect(save.commits, 0);
    await _tap(tester, const ValueKey('support_report_cancel'));
    selection.complete();
    await _turns(tester);
    expect(save.commits, 0);
    expect(fixture.owners.single.isCurrent, isFalse);
  });
}
