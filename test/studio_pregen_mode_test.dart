import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/card_rewriter_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_pregen_mode.dart';
import 'package:glaze_flutter/features/studio/widgets/studio_block_section_list.dart';
import 'package:glaze_flutter/shared/widgets/list_controls.dart';

void main() {
  const ordinary = StudioPreset(
    id: 'preset',
    agentEnabled: {'agency': false, 'continuity': true, 'think': false},
    agents: [
      StudioAgent(id: 'continuity', controllerId: 'continuity', order: 0),
      StudioAgent(id: 'agency', controllerId: 'agency', order: 1),
      StudioAgent(id: 'final', controllerId: 'final', order: 8),
    ],
  );

  test('switching sets preserves ordinary toggles and adds one Think lane', () {
    final think = applyStudioPregenMode(
      ordinary,
      StudioPregenMode.thinkReplacement,
    );
    expect(studioPregenMode(think), StudioPregenMode.thinkReplacement);
    expect(think.agentEnabled['agency'], false);
    expect(think.agentEnabled['continuity'], true);
    final thinkAgents = think.agents.where((a) => a.controllerId == 'think');
    expect(thinkAgents, hasLength(1));
    expect(thinkAgents.single.reasoningMode, 'think-replacement');

    final normal = applyStudioPregenMode(think, StudioPregenMode.normal);
    expect(studioPregenMode(normal), StudioPregenMode.normal);
    expect(normal.agentEnabled['agency'], false);
    expect(normal.agentEnabled['continuity'], true);
    expect(
      normal.agents.where((a) => a.controllerId == 'think'),
      hasLength(1),
    );
    expect(normal.agents.last.enabled, false);

    final again = applyStudioPregenMode(
      normal,
      StudioPregenMode.thinkReplacement,
    );
    expect(again.agents.where((a) => a.controllerId == 'think'), hasLength(1));
  });

  testWidgets('pregen dropdown replaces the controller rows with Think', (
    tester,
  ) async {
    var preset = ordinary;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: StudioBlockSectionList(
                  preset: preset,
                  sections: const [('pregen', 'Pre-generation')],
                  onReorder: (_) {},
                  onEdit: (_) {},
                  onToggle: (_, _) {},
                  onSelectExclusive: (_, _) {},
                  onToggleGroup: (_, _) {},
                  onDelete: (_) {},
                  onDeleteGroup: (_) {},
                  onMoveToGroup: (_, _) {},
                  onMoveToSection: (_, _) {},
                  onToggleAgent: (_, _) {},
                  onPregenModeChanged: (mode) => setState(() {
                    preset = applyStudioPregenMode(preset, mode);
                  }),
                  onLedgerPromptInjectionChanged: (_) {},
                  cardRewriter: const CardRewriterSettings(),
                  onCardRewriterChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('studio_agent_pregen_continuity')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('studio_agent_pregen_think')), findsNothing);
    expect(find.byKey(const ValueKey('studio_section_empty_pregen')), findsNothing);
    expect(find.byType(GlazeDropdownChip), findsOneWidget);
    await tester.tap(find.byType(GlazeDropdownChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('studio_reasoning_mode_think').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('studio_agent_pregen_continuity')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('studio_agent_pregen_agency')), findsNothing);
    expect(find.byKey(const ValueKey('studio_agent_pregen_think')), findsOneWidget);
    expect(find.byKey(const ValueKey('studio_section_empty_pregen')), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(preset.agentEnabled['agency'], false);
    await tester.tap(find.byType(GlazeDropdownChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('studio_reasoning_mode_normal').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('studio_agent_pregen_think')), findsNothing);
    expect(
      find.byKey(const ValueKey('studio_agent_pregen_continuity')),
      findsOneWidget,
    );
    expect(preset.agentEnabled['agency'], false);
  });

  testWidgets(
    'addressed prompt follows the active controller, not a separate section',
    (tester) async {
    late StateSetter rebuild;
    var preset = ordinary.copyWith(blocks: const [
      StudioPresetBlock(
        id: 'think-prompt',
        title: 'Think prompt',
        injectionPoint: 'specificAgent',
        targetAgentId: 'think',
      ),
      StudioPresetBlock(
        id: 'continuity-prompt',
        title: 'Continuity prompt',
        injectionPoint: 'specificAgent',
        targetAgentId: 'continuity',
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SingleChildScrollView(
                  child: StudioBlockSectionList(
                    preset: preset,
                    sections: const [
                      ('pregen', 'Pre-generation'),
                      ('specificAgent', 'Specific agent'),
                    ],
                    onReorder: (_) {},
                    onEdit: (_) {},
                    onToggle: (_, _) {},
                    onSelectExclusive: (_, _) {},
                    onToggleGroup: (_, _) {},
                    onDelete: (_) {},
                    onDeleteGroup: (_) {},
                    onMoveToGroup: (_, _) {},
                    onMoveToSection: (_, _) {},
                    onToggleAgent: (_, _) {},
                    onPregenModeChanged: (mode) => setState(() {
                      preset = applyStudioPregenMode(preset, mode);
                    }),
                    onLedgerPromptInjectionChanged: (_) {},
                    cardRewriter: const CardRewriterSettings(),
                    onCardRewriterChanged: (_) {},
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('studio_block_continuity-prompt')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('studio_block_think-prompt')), findsNothing);
    expect(find.byKey(const ValueKey('studio_section_specificAgent')), findsNothing);
    await tester.tap(find.byType(GlazeDropdownChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('studio_reasoning_mode_think').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('studio_agent_pregen_think')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('studio_block_think-prompt')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('studio_block_continuity-prompt')),
      findsNothing,
    );
    // Inactive prompts stay in the preset and reappear with their controller.
    final thinkTop = tester
        .getTopLeft(find.byKey(const ValueKey('studio_agent_pregen_think')))
        .dy;
    final promptTop = tester
        .getTopLeft(find.byKey(const ValueKey('studio_block_think-prompt')))
        .dy;
    expect(promptTop, greaterThan(thinkTop));
    expect(
      find.byKey(const ValueKey('studio_section_specificAgent')),
      findsNothing,
    );
    expect(preset.blocks.first.injectionPoint, 'specificAgent');
    expect(preset.blocks.first.targetAgentId, 'think');

    await tester.tap(find.byType(GlazeDropdownChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('studio_reasoning_mode_normal').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('studio_block_continuity-prompt')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('studio_block_think-prompt')), findsNothing);

    await tester.tap(find.byType(GlazeDropdownChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('studio_reasoning_mode_think').last);
    await tester.pumpAndSettle();

    rebuild(() {
      preset = preset.copyWith(blocks: [preset.blocks.first]);
    });
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('studio_section_specificAgent')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('studio_section_empty_pregen')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('studio_block_think-prompt')), findsOneWidget);
    },
  );
}
