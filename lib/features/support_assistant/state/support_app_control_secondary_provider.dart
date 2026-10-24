import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/llm_request_capture_repo.dart';
import '../../../core/llm/transport/llm_call_event.dart';
import '../../../core/llm/transport/llm_request_capture.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/global_regex_provider.dart';
import '../../../core/state/studio_regex_provider.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../image_gen/image_gen_provider.dart';
import '../models/support_app_action.dart';
import '../services/app_control/secondary/support_app_diagnostics_adapter.dart';
import '../services/app_control/secondary/support_app_extension_controls_adapter.dart';
import '../services/app_control/secondary/support_app_secondary_profiles_adapter.dart';

/// Add this list to the shared registry only in the integration lane. This does
/// not create a run, prompt for a file/secret, or grant source/network authority.
final supportAppControlSecondaryAdaptersProvider =
    Provider<List<SupportAppActionAdapter>>((ref) {
      final captures = ref.watch(llmRequestCaptureRepoProvider);
      // These are existing native owners. Warm their normal app loading here,
      // not inside a typed metadata call; the global loader may migrate prefs.
      // The port returns unavailable until that native loading is settled.
      // Metadata must not initialize an unloaded private preference owner.
      return List<SupportAppActionAdapter>.unmodifiable([
        SupportAppDiagnosticsAdapter(
          repo: captures,
          sinks: _OriginalDiagnosticSinks(captures),
        ),
        SupportAppExtensionControlsAdapter(
          repo: ref.watch(extensionPresetsRepoProvider),
          notifier: ref.watch(extensionPresetsProvider.notifier),
        ),
        SupportAppSecondaryProfilesAdapter(_OriginalSecondaryProfiles(ref)),
      ]);
    });

/// Uses the application's actual capture installation, without replacing it.
final class _OriginalDiagnosticSinks implements SupportAppDiagnosticSinksPort {
  _OriginalDiagnosticSinks(this.repo);
  final LlmRequestCaptureRepo repo;
  @override
  SupportAppDiagnosticSinkObservation observe() =>
      SupportAppDiagnosticSinkObservation(
        requests: identical(LlmRequestCapture.sink, repo),
        events: identical(LlmCallEventCapture.sink, repo),
      );
  @override
  bool isCurrent(SupportAppDiagnosticSinkObservation observation) =>
      observation.requests == identical(LlmRequestCapture.sink, repo) &&
      observation.events == identical(LlmCallEventCapture.sink, repo);
}

/// Ref remains in the composition layer, never in tools/DTOs or services.
final class _OriginalSecondaryProfiles
    implements SupportAppSecondaryProfilesPort {
  _OriginalSecondaryProfiles(this.ref);
  final Ref ref;
  @override
  SupportAppSecondaryProfileFacts? observe(
    SupportAppSecondaryProfileDomain domain,
  ) {
    if (!ref.mounted) return null;
    switch (domain) {
      case SupportAppSecondaryProfileDomain.globalRegex:
        if (!ref.exists(globalRegexProvider)) return null;
        final scripts = ref.read(globalRegexProvider).value;
        if (scripts == null) return null;
        return SupportAppSecondaryProfileFacts(
          domain: domain,
          nativeObservation: scripts,
          count: scripts.length,
          enabledCount: scripts.where((s) => !s.disabled).length,
        );
      case SupportAppSecondaryProfileDomain.studioRegex:
        if (!ref.exists(studioRegexProvider)) return null;
        final scripts = ref.read(studioRegexProvider).value;
        if (scripts == null) return null;
        return SupportAppSecondaryProfileFacts(
          domain: domain,
          nativeObservation: scripts,
          count: scripts.length,
          enabledCount: scripts.where((s) => !s.script.disabled).length,
          bindingCount: scripts.fold(
            0,
            (count, script) => count + script.stages.length,
          ),
        );
      case SupportAppSecondaryProfileDomain.image:
        if (!ref.exists(imageGenSettingsProvider)) return null;
        final settings = ref.read(imageGenSettingsProvider).value;
        if (settings == null) return null;
        return SupportAppSecondaryProfileFacts(
          domain: domain,
          nativeObservation: settings,
          count: settings.references.length,
          enabledCount: settings.references.where((r) => r.enabled).length,
          styles: settings.styles.length,
          workflows: settings.comfyui.workflows.length,
          enabled: settings.enabled,
          concurrent: settings.concurrentGeneration,
        );
    }
  }

  @override
  bool isCurrent(SupportAppSecondaryProfileFacts facts) =>
      ref.mounted &&
      identical(
        observe(facts.domain)?.nativeObservation,
        facts.nativeObservation,
      );
}
