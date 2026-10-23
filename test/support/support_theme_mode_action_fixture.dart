import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

import 'support_theme_action_fixture.dart';

export 'support_theme_action_fixture.dart';

/// Reuses the original declared-memory/FakeVault/real-AEAD fixture and its
/// tripwires through drain/disposal. The shared domain fixture owns its checked
/// full-list capability; feature tests add no second storage/effect framework.
void modeActionTest(
  String name,
  Future<void> Function(ThemeActionFixture) body,
) => themeActionTest(name, body);

ThemeSelectionTestStore modeStore(ThemeActionFixture f) => f.themeStore;

/// Feature-test vocabulary only; all invocation/gate/outcome behavior lives in
/// the shared independently backed store, not in this adapter.
extension ModeActionStoreValues on ThemeSelectionTestStore {
  List<List<ThemePreset>> get modeWrites => checkedModeWrites;
  List<ThemeSelectionSyntheticWrite> get modeOutcomes => checkedModeOutcomes;
  List<ThemeSelectionGate> get modeGates => modeWriteGates;
  set afterModeWrite(void Function()? callback) =>
      afterCheckedModeWrite = callback;
}

Future<SupportThemeReview> modeReview(
  ThemeActionFixture f, [
  String mode = 'light',
]) async {
  final observed = (await f.service.observe(f.intent()))!;
  final choice = f.service
      .projectModeChoices(observed)!
      .choices
      .singleWhere((c) => c.value?.mode == mode);
  return (await f.service.prepareApply(choice))!;
}

Future<SupportThemeApproval> modeApproval(
  ThemeActionFixture f, [
  String mode = 'light',
]) async => f.service.approve(await modeReview(f, mode))!;

Future<SupportThemeActionResult> modeApply(
  ThemeActionFixture f, [
  String mode = 'light',
]) async => f.service.execute(await modeApproval(f, mode));
