import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/widgets/chat_status_card_shell.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';

import 'helpers/pump_localized.dart';

void main() {
  testWidgets('compact kit surface keeps the spinner and action slots', (
    tester,
  ) async {
    var stopped = false;
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: ChatStatusCardShell(
          label: 'Working',
          icon: Icons.sync,
          accent: Colors.orange,
          showSpinner: true,
          action: IconButton(
            onPressed: () => stopped = true,
            tooltip: 'Stop work',
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ),
      ),
    );

    expect(find.text('Working'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsNothing);
    expect(tester.getSize(find.byType(GlazeSpinner)), const Size.square(18));
    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.borderRadius, BorderRadius.circular(12));
    expect(surface.boxShadow, isNull);
    expect(tester.getSize(find.byType(ChatStatusCardShell)).height, 52);
    expect(find.byTooltip('Working'), findsNothing);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    expect(stopped, isTrue);
  });

  testWidgets('one-line status retains full text without an overlay tooltip', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const ChatStatusCardShell(
        label: 'A detailed failure that must remain available',
        icon: Icons.error_outline,
        accent: Colors.red,
        showSpinner: false,
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsNothing);
    final text = tester.widget<Text>(
      find.text('A detailed failure that must remain available'),
    );
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.data, 'A detailed failure that must remain available');
    expect(find.byTooltip(text.data!), findsNothing);
  });

  testWidgets('fully visible status does not create a redundant tooltip', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const ChatStatusCardShell(
        label: 'Card Evolution',
        icon: Icons.check_circle_outline,
        accent: Colors.orange,
        showSpinner: false,
      ),
    );

    expect(find.text('Card Evolution'), findsOneWidget);
    expect(find.byTooltip('Card Evolution'), findsNothing);
  });

  testWidgets('action theme cannot overflow or stretch the compact row', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Theme(
          data: Theme.of(context).copyWith(
            iconButtonTheme: const IconButtonThemeData(
              style: ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(180, 108)),
              ),
            ),
          ),
          child: ChatStatusCardShell(
            label: 'A status that still needs room for its label',
            icon: Icons.sync,
            accent: Colors.orange,
            showSpinner: false,
            action: IconButton(
              onPressed: () {},
              tooltip: 'Bounded action',
              icon: const Icon(Icons.close),
            ),
          ),
        ),
      ),
      surfaceSize: const Size(320, 576),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ChatStatusCardShell)).height, 52);
    expect(tester.getSize(find.byType(IconButton)), const Size.square(32));
    expect(
      tester.widget<TooltipVisibility>(find.byType(TooltipVisibility)).visible,
      isFalse,
    );
  });
}
