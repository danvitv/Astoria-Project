import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/shell/shell_screen.dart';

void main() {
  testWidgets('hidden branches continue receiving provider updates', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var builds = 0;
    final valueProvider = Provider<int>((ref) => ++builds);

    Widget app(int index) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: FadeBranchContainer(
            currentIndex: index,
            children: [
              Consumer(
                builder: (_, ref, _) =>
                    Text('value:${ref.watch(valueProvider)}'),
              ),
              const Text('other branch'),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(app(0));
    expect(find.text('value:1'), findsOneWidget);
    await tester.pumpWidget(app(1));
    await tester.pump(const Duration(milliseconds: 250));
    container.invalidate(valueProvider);
    await tester.pump();
    expect(find.text('value:2', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(app(0));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
  });
}
