import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/glaze_bottom_sheet.dart';

void main() {
  testWidgets(
    'bootstrap kit renders and taps with no ProviderScope or storage',
    (tester) async {
      const preset = ThemePreset(id: 'fixture', name: 'Synthetic bootstrap');
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Center(
              child: SizedBox(
                width: 440,
                child: GlazeBottomSheetFrame(
                  fixedPreset: preset,
                  showHandle: false,
                  child: GlassSurface.fixed(
                    preset: preset,
                    borderRadius: BorderRadius.circular(14),
                    child: GlazeActionButton(
                      fixedPreset: preset,
                      icon: Icons.check,
                      label: 'Synthetic action',
                      onTap: () => taps++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Synthetic action'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
