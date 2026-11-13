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
    await tester.tap(find.byTooltip('Stop work'));
    expect(stopped, isTrue);
  });

  testWidgets('one-line status retains its full text as a tooltip', (
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
    expect(find.byTooltip(text.data!), findsOneWidget);
  });
}
