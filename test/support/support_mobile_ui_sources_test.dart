import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_source_tool_names.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_source_preparation_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_entry.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_source_preparation_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_surface_layout.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_entry.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'helpers/support_desktop_shell_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

Finder _key(String value) => find.byKey(ValueKey(value));

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  testWidgets(
    'actual desktop gated source entry opens only local preparation',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      installShellPlatformTripwires(tester);
      final fixture = SupportDesktopShellFixture();
      await fixture.initialize(const {});
      addTearDown(fixture.dispose);
      final router = testGoRouterShellRoute();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // Local metadata only. Every worker/DB, native model and grant seam
            // remains the fixture's original fail-closed owner.
            supportSourcePreparationPageProvider(0).overrideWith(
              (_) => Stream.value(HistoryIndexLocalPage([], null)),
            ),
          ],
          child: fixture.app(router),
        ),
      );
      await tester.pumpAndSettle();
      final screen = find.byType(SupportAssistantScreen);
      final original = tester.state(screen);
      final container = ProviderScope.containerOf(tester.element(screen));
      final workspace = container.read(supportWorkspaceProvider);
      expect(DesktopScope.isDesktopOf(tester.element(screen)), isTrue);
      expect(find.byType(SupportThemeEntry), findsOneWidget);
      expect(find.byType(SupportProviderEntry), findsOneWidget);
      expect(_key('support_drawer_toggle'), findsNothing);
      final entry = _key('support_local_source_preparation');
      if (!supportSourceNavigationExperimentalEnabled) {
        expect(entry, findsNothing);
      } else {
        expect(entry, findsOneWidget);
        expect(entry.hitTestable(), findsOneWidget);
        expect(tester.getRect(entry).bottom, lessThanOrEqualTo(900));
        await tester.tap(entry);
        await tester.pumpAndSettle();
        final sheet = find.byType(SupportSourcePreparationSheet);
        expect(sheet, findsOneWidget);
        final route = ModalRoute.of<void>(tester.element(sheet))!;
        expect(route.isCurrent, isTrue);
        expect(
          find.text('На этой странице нет доступных историй.'),
          findsOneWidget,
        );
        expect(container.read(supportWorkspaceProvider), same(workspace));
        expect(_key('support_tool_confirmation_accept'), findsNothing);
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
        expect(route.isActive, isFalse);
        expect(sheet, findsNothing);
        expect(tester.state(screen), same(original));
      }
      expect(container.read(supportWorkspaceProvider), same(workspace));
      expect(workspace.activeMessages, isEmpty);
      fixture.expectNoExternalWork();
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'mobile $width local source metadata and contextual guidance clear one header',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final fixture = SupportDesktopShellFixture();
        await fixture.initialize(const {});
        addTearDown(fixture.dispose);
        final router = GoRouter(
          initialLocation: '/fixture',
          routes: [
            GoRoute(
              path: '/fixture',
              builder: (context, _) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      key: const ValueKey('open_local_sources'),
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => SheetView(
                          titleWidget: SupportSheetTitle(
                            title: 'Локальная подготовка источников',
                            onBack: () => Navigator.of(context).pop(),
                          ),
                          body: ProviderScope(
                            overrides: [
                              // Only the page's local metadata/status seam. No worker, grant,
                              // source reader, native action controller or DB callback is faked.
                              supportSourcePreparationPageProvider(
                                0,
                              ).overrideWith(
                                (_) => Stream.value(
                                  HistoryIndexLocalPage([
                                    for (var i = 0; i < 16; i++)
                                      HistoryIndexLocalCandidate(
                                        'synthetic-$i',
                                        'Synthetic local source $i',
                                        i,
                                        i == 15
                                            ? HistoryIndexMaintenanceState
                                                  .unsupported
                                            : HistoryIndexMaintenanceState
                                                  .incomplete,
                                      ),
                                  ], null),
                                ),
                              ),
                            ],
                            child: const SupportSourcePreparationSheet(),
                          ),
                        ),
                      ),
                      child: const Text('Open local sources'),
                    ),
                    TextButton(
                      key: const ValueKey('open_guidance'),
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => const SupportGuidanceSheet(
                          target: SupportGuidanceTarget.mode,
                        ),
                      ),
                      child: const Text('Open contextual mode'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(fixture.app(router, textScale: 1.6));
        await tester.pumpAndSettle();
        await tester.tap(_key('open_local_sources'));
        await tester.pumpAndSettle();
        final list = _key('support_source_preparation_scroll');
        expect(list, findsOneWidget);
        final scroll = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        expect(scroll, findsOneWidget);
        final original = tester.state<ScrollableState>(scroll);
        expect(original.widget.axisDirection, AxisDirection.down);
        final header = find.ancestor(
          of: find.byType(SupportSheetTitle),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Positioned &&
                widget.top == 0 &&
                widget.left == 0 &&
                widget.right == 0 &&
                widget.bottom == null,
          ),
        );
        expect(header, findsOneWidget);
        expect(ModalRoute.of(tester.element(list))!.isCurrent, isTrue);
        await tester.scrollUntilVisible(
          _key('support_source_prepare_synthetic-0'),
          180,
          scrollable: scroll,
          maxScrolls: 30,
        );
        // scrollUntilVisible aligns only the row's start and does not pump the
        // final ensureVisible jump. Reveal its whole control before hit testing.
        await Scrollable.ensureVisible(
          tester.element(_key('support_source_prepare_synthetic-0')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        expect(tester.state<ScrollableState>(scroll), same(original));
        final first = tester.getRect(
          _key('support_source_prepare_synthetic-0'),
        );
        final firstViewport = tester.getRect(scroll);
        expect(first.top, greaterThanOrEqualTo(tester.getRect(header).bottom));
        expect(first.top, greaterThanOrEqualTo(firstViewport.top));
        expect(first.bottom, lessThanOrEqualTo(firstViewport.bottom));
        expect(first.left, greaterThanOrEqualTo(firstViewport.left));
        expect(first.right, lessThanOrEqualTo(firstViewport.right));
        expect(
          _key('support_source_prepare_synthetic-0').hitTestable(),
          findsOneWidget,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          _key('support_source_prepare_synthetic-15'),
          180,
          scrollable: scroll,
          maxScrolls: 30,
        );
        await Scrollable.ensureVisible(
          tester.element(_key('support_source_prepare_synthetic-15')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        expect(tester.state<ScrollableState>(scroll), same(original));
        final last = tester.getRect(
          _key('support_source_prepare_synthetic-15'),
        );
        final lastViewport = tester.getRect(scroll);
        expect(last.top, greaterThanOrEqualTo(tester.getRect(header).bottom));
        expect(last.top, greaterThanOrEqualTo(lastViewport.top));
        expect(last.bottom, lessThanOrEqualTo(lastViewport.bottom));
        expect(last.left, greaterThanOrEqualTo(lastViewport.left));
        expect(last.right, lessThanOrEqualTo(lastViewport.right));
        expect(
          tester.getRect(_key('support_source_prepare_synthetic-15')).bottom,
          lessThanOrEqualTo(544),
        );
        final disabled = find
            .ancestor(
              of: _key('support_source_prepare_synthetic-15'),
              matching: find.byType(SupportControlAvailability),
            )
            .first;
        expect(
          tester.widget<SupportControlAvailability>(disabled).enabled,
          isFalse,
        );
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(_key('open_guidance'));
        await tester.pumpAndSettle();
        expect(find.text(SupportGuidanceTarget.mode.title), findsOneWidget);
        final back = find.byIcon(Icons.arrow_back);
        expect(
          tester
              .getSize(
                find.ancestor(of: back, matching: find.byType(IconButton)),
              )
              .shortestSide,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(back);
        await tester.pumpAndSettle();
        fixture.expectNoExternalWork();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
