import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/glaze_expansion_tile.dart';

void main() {
  test('requires exactly one body source', () {
    expect(
      () => GlazeExpansionTile(title: const Text('Details')),
      throwsAssertionError,
    );
    expect(
      () => GlazeExpansionTile(
        title: const Text('Details'),
        children: const [],
        childrenBuilder: (_) => const [],
      ),
      throwsAssertionError,
    );
  });

  testWidgets('collapsed lazy bodies are not created or built until opened', (
    tester,
  ) async {
    var builderCalls = 0;
    var bodyBuilds = 0;
    Widget tile() => GlazeExpansionTile(
      title: const Text('Details'),
      childrenBuilder: (_) {
        builderCalls++;
        return [
          Builder(
            builder: (_) {
              bodyBuilds++;
              return const Text('Large diagnostic body');
            },
          ),
        ];
      },
    );

    await tester.pumpWidget(_host(tile()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(tile()));
    expect(builderCalls, 0);
    expect(bodyBuilds, 0);
    expect(
      find.text('Large diagnostic body', skipOffstage: false),
      findsNothing,
    );

    await tester.tap(find.text('Details'));
    await tester.pump();
    expect(builderCalls, 1);
    expect(bodyBuilds, 1);
    final crossFade = tester.widget<AnimatedCrossFade>(
      find.byType(AnimatedCrossFade),
    );
    expect(crossFade.crossFadeState, CrossFadeState.showSecond);
    expect(crossFade.duration, const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(find.text('Large diagnostic body').hitTestable(), findsOneWidget);
  });

  testWidgets('initially expanded lazy bodies build immediately', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        GlazeExpansionTile(
          title: const Text('Details'),
          initiallyExpanded: true,
          childrenBuilder: (_) {
            calls++;
            return const [Text('Initial body')];
          },
        ),
      ),
    );

    expect(calls, 1);
    expect(find.text('Initial body').hitTestable(), findsOneWidget);
  });

  testWidgets('expanded lazy bodies receive fresh parent inputs', (
    tester,
  ) async {
    var calls = 0;
    Widget tile(String value) => GlazeExpansionTile(
      title: const Text('Details'),
      childrenBuilder: (_) {
        calls++;
        return [Text(value)];
      },
    );

    await tester.pumpWidget(_host(tile('Old response')));
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    final callsBeforeUpdate = calls;
    expect(find.text('Old response'), findsOneWidget);

    await tester.pumpWidget(_host(tile('New response')));
    expect(calls, callsBeforeUpdate + 1);
    expect(find.text('Old response', skipOffstage: false), findsNothing);
    expect(find.text('New response').hitTestable(), findsOneWidget);
  });

  testWidgets('lazy body state stays mounted across collapse and reopen', (
    tester,
  ) async {
    var initializations = 0;
    var disposals = 0;
    final bodyKey = GlobalKey<_RememberedBodyState>();
    Widget tile(String value) => GlazeExpansionTile(
      title: const Text('Details'),
      childrenBuilder: (_) => [
        _RememberedBody(
          key: bodyKey,
          value: value,
          onInit: () => initializations++,
          onDispose: () => disposals++,
        ),
      ],
    );

    await tester.pumpWidget(_host(tile('Old')));
    expect(initializations, 0);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    final originalState = bodyKey.currentState;
    expect(initializations, 1);
    await tester.tap(find.text('Remember'));
    await tester.pumpAndSettle();
    expect(find.text('Old: 1'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(bodyKey.currentState, same(originalState));
    expect(disposals, 0);
    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showFirst,
    );

    // Retained bodies stay live, including updates received while collapsed.
    await tester.pumpWidget(_host(tile('New')));
    expect(bodyKey.currentState, same(originalState));
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('New: 1').hitTestable(), findsOneWidget);
    expect(initializations, 1);
    expect(disposals, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposals, 1);
  });

  testWidgets('existing eager children still mount while initially collapsed', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(
      _host(
        GlazeExpansionTile(
          title: const Text('Details'),
          children: [
            Builder(
              builder: (_) {
                builds++;
                return const Text('Eager body');
              },
            ),
          ],
        ),
      ),
    );
    expect(builds, 1);
    expect(find.text('Eager body', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Eager body').hitTestable(), findsOneWidget);
  });
}

Widget _host(Widget tile) => MaterialApp(
  home: Material(
    child: Align(alignment: Alignment.topCenter, child: tile),
  ),
);

class _RememberedBody extends StatefulWidget {
  const _RememberedBody({
    super.key,
    required this.value,
    required this.onInit,
    required this.onDispose,
  });

  final String value;
  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_RememberedBody> createState() => _RememberedBodyState();
}

class _RememberedBodyState extends State<_RememberedBody> {
  var _count = 0;

  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('${widget.value}: $_count'),
      GlazeActionButton(
        icon: Icons.add,
        label: 'Remember',
        fixedPreset: const ThemePreset(
          id: 'expansion-test',
          name: 'Expansion test',
        ),
        onTap: () => setState(() => _count++),
      ),
    ],
  );
}
