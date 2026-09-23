import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/glass_nav_bar.dart';

import 'helpers/pump_localized.dart';

void main() {
  testWidgets('navigation labels fit a narrow phone in Russian', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      GlassNavBar(currentIndex: 0, onTap: (_) {}),
      locale: const Locale('ru'),
      surfaceSize: const Size(320, 720),
    );
    expect(tester.takeException(), isNull);
  });
}
