import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_mode.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_settings_mapper.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

/// Characterization test for the legacy `summary_block` /
/// `summary_macro` enum migration.
///
/// Pre-{{memory}}-split the memory injection target was named after
/// "where" memory went:
/// * `summary_block`: hard system block "Memory Book"
/// * `summary_macro`: piggyback on the {{summary}} expansion
///
/// The names were misleading because the "summary" prefix was about
/// *where memory goes*, not about the summary feature itself. After
/// the split, the names are:
/// * `hard_block`: hard system block "Memory Book"
/// * `macro`: explicit `{{memory}}` macro in the preset
///
/// Old data in shared_prefs / DB still has the old values. Both
/// model `fromJson` methods must translate them transparently.
void main() {
  group('MemoryBookSettings.injectionTarget migration', () {
    test('summary_block -> hard_block', () {
      final result = MemoryBookSettings.fromJson({
        'enabled': true,
        'autoCreateEnabled': true,
        'autoGenerateEnabled': false,
        'maxInjectedEntries': 7,
        'autoCreateInterval': 15,
        'useDelayedAutomation': true,
        'injectionTarget': 'summary_block',
        'batchSize': 3,
        'vectorSearchEnabled': false,
        'keyMatchMode': 'glaze',
        'generationSource': 'current',
        'generationModel': '',
        'generationEndpoint': '',
        'generationApiKey': '',
        'promptPreset': 'detailed_beats',
        'maxInjectionBudgetPercent': 0.35,
      });
      expect(result.injectionTarget, 'hard_block');
    });

    test('summary_macro -> macro', () {
      final result = MemoryBookSettings.fromJson({
        'injectionTarget': 'summary_macro',
      });
      expect(result.injectionTarget, 'macro');
    });

    test('new value hard_block is preserved', () {
      final result = MemoryBookSettings.fromJson({
        'injectionTarget': 'hard_block',
      });
      expect(result.injectionTarget, 'hard_block');
    });

    test('new value macro is preserved', () {
      final result = MemoryBookSettings.fromJson({'injectionTarget': 'macro'});
      expect(result.injectionTarget, 'macro');
    });

    test('missing injectionTarget defaults to hard_block', () {
      final result = MemoryBookSettings.fromJson({});
      expect(result.injectionTarget, 'hard_block');
    });

    test('toJson round-trips through migration', () {
      const original = MemoryBookSettings(injectionTarget: 'hard_block');
      final json = original.toJson();
      final restored = MemoryBookSettings.fromJson(json);
      expect(restored.injectionTarget, 'hard_block');
    });

    test('maxInjectedTokens and memoryBudgetPreset round-trip', () {
      const original = MemoryBookSettings(
        maxInjectedTokens: 6000,
        memoryBudgetPreset: 'medium',
      );
      final restored = MemoryBookSettings.fromJson(original.toJson());
      expect(restored.maxInjectedTokens, 6000);
      expect(restored.memoryBudgetPreset, 'medium');
    });
  });

  group('MemoryGlobalSettings.injectionTarget migration', () {
    test('removed agentic memory mode migrates to deep', () {
      final result = MemoryGlobalSettings.fromJson({'memoryMode': 'agentic'});
      expect(result.memoryMode, 'deep');
    });

    test('legacy consolidation flag migrates to Memory + links', () {
      final result = MemoryGlobalSettings.fromJson({
        'memoryMode': 'balanced',
        'consolidationEnabled': true,
      });
      expect(result.memoryMode, 'memory_links');
      expect(result.consolidationEnabled, isTrue);
    });

    test('MemoryBook snapshot also migrates the legacy consolidation flag', () {
      final result = MemoryBookSettings.fromJson({
        'memoryMode': 'fast',
        'consolidationEnabled': true,
      });
      expect(result.memoryMode, 'memory_links');
      expect(result.consolidationEnabled, isTrue);

      final explicitMode = MemoryBookSettings.fromJson({
        'memoryMode': 'memory_links',
      });
      expect(explicitMode.consolidationEnabled, isTrue);
    });

    test('explicit ordinary mode keeps consolidation disabled', () {
      final result = MemoryGlobalSettings.fromJson({
        'memoryMode': 'balanced',
        'consolidationEnabled': false,
      });
      expect(result.memoryMode, 'balanced');
      expect(result.consolidationEnabled, isFalse);
    });

    test('settings mapper derives the compatibility flag from memory mode', () {
      const mapper = MemorySettingsMapper();
      const global = MemoryGlobalSettings(memoryMode: memoryLinksMode);

      final book = mapper.globalToBook(global);
      expect(book.memoryMode, memoryLinksMode);
      expect(book.consolidationEnabled, isTrue);

      final ordinary = mapper.bookToGlobal(
        const MemoryBookSettings(
          memoryMode: 'balanced',
          consolidationEnabled: true,
        ),
        global,
        global.vectorThreshold,
      );
      expect(ordinary.memoryMode, 'balanced');
      expect(ordinary.consolidationEnabled, isFalse);
    });

    test('summary_block -> hard_block', () {
      final result = MemoryGlobalSettings.fromJson({
        'injectionTarget': 'summary_block',
      });
      expect(result.injectionTarget, 'hard_block');
    });

    test('summary_macro -> macro', () {
      final result = MemoryGlobalSettings.fromJson({
        'injectionTarget': 'summary_macro',
      });
      expect(result.injectionTarget, 'macro');
    });

    test('hard_block preserved', () {
      final result = MemoryGlobalSettings.fromJson({
        'injectionTarget': 'hard_block',
      });
      expect(result.injectionTarget, 'hard_block');
    });

    test('macro preserved', () {
      final result = MemoryGlobalSettings.fromJson({
        'injectionTarget': 'macro',
      });
      expect(result.injectionTarget, 'macro');
    });

    test('missing injectionTarget defaults to hard_block', () {
      final result = MemoryGlobalSettings.fromJson({});
      expect(result.injectionTarget, 'hard_block');
    });

    test('toJson round-trips through migration', () {
      const original = MemoryGlobalSettings(injectionTarget: 'macro');
      final json = original.toJson();
      final restored = MemoryGlobalSettings.fromJson(json);
      expect(restored.injectionTarget, 'macro');
    });

    test('maxInjectedTokens and memoryBudgetPreset round-trip', () {
      const original = MemoryGlobalSettings(
        maxInjectedTokens: 10000,
        memoryBudgetPreset: 'large',
      );
      final restored = MemoryGlobalSettings.fromJson(original.toJson());
      expect(restored.maxInjectedTokens, 10000);
      expect(restored.memoryBudgetPreset, 'large');
    });
  });
}
