import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_provider_fixture.dart';

void main() {
  themeProviderTest(
    'mode choices belong to original emitted observation, not another UI',
    (f) async {
      final original = f.emit()!, other = f.emit()!;
      final observation = (await original.observe())!;
      expect(other.modeChoices(observation), isNull);
      final choices = original.modeChoices(observation)!.choices;
      expect(choices.map((c) => c.value!.mode), ['dark', 'light', 'system']);
      final light = choices.singleWhere((c) => c.value!.mode == 'light');
      expect(await other.prepareApply(light), isNull);
      final review = (await original.prepareApply(light))!;
      expect(other.preview(review), isNull);
      expect(other.confirm(review), isNull);
      expect(original.preview(review)!.operation, SupportThemeOperation.mode);
      final before = List.of(f.backing.presets);
      final result = await f.confirm(original, review);
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.settled);
      expect(f.backing.activeId, 'a');
      expect(
        f.backing.presets.first,
        before.first.copyWith(themeMode: 'light'),
      );
      expect(f.backing.presets.skip(1), before.skip(1));
      expect(original.confirm(review), isNull);
      expect(f.harness.store.checkedWrites, isEmpty);
    },
  );

  themeProviderTest(
    'new provider readers discover mode evidence without restoring Undo',
    (f) async {
      final original = f.emit()!;
      final observed = (await original.observe())!;
      final light = original
          .modeChoices(observed)!
          .choices
          .singleWhere((c) => c.value!.mode == 'light');
      final result = await f.confirm(
        original,
        (await original.prepareApply(light))!,
      );
      expect(result.effect, SupportThemeEffect.applied);
      await f.replaceTheme();
      final fresh = f.emit()!;
      final page = (await fresh.discoverHistory(
        operation: SupportThemeOperation.mode,
      ))!;
      final view = fresh.history(page)!;
      expect(view.entries, hasLength(1));
      expect(view.entries.single.before!.mode, 'dark');
      expect(view.entries.single.after!.mode, 'light');
      expect(view.entries.single.before!.active, isFalse);
      expect(await fresh.prepareUndo(result.applied!), isNull);
      expect(await fresh.prepareLastUndo(), isNull);
      expect(f.backing.presets.first.themeMode, 'light');
    },
  );
}
