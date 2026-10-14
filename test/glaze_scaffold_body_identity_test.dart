import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';

class _Body extends StatefulWidget {
  const _Body();
  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets('background wrapper changes retain the body State', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final background = ValueNotifier(true);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => ValueListenableBuilder<bool>(
            valueListenable: background,
            builder: (_, value, _) => GlazeScaffold(
              showBack: false,
              hideHeader: true,
              showBackground: value,
              body: const _Body(),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(background.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pump();
    final original = tester.state(find.byType(_Body));
    background.value = false;
    await tester.pump();
    expect(tester.state(find.byType(_Body)), same(original));
    background.value = true;
    await tester.pump();
    expect(tester.state(find.byType(_Body)), same(original));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
