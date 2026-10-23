import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../core/llm/aux_llm_client.dart';
import '../../core/llm/native_saved_connection_source.dart';
import '../../core/credentials/native_provider_credentials.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/llm/transport/llm_capture_context.dart';
import '../../core/llm/macro_engine.dart';
import '../../core/llm/memory_book_api_config_resolver.dart';
import '../../core/llm/memory_draft_api_source.dart';
import '../../core/llm/memory_draft_response_parser.dart';
import '../../core/llm/memory_draft_transcript_builder.dart';
import '../../core/llm/regex_service.dart';
import '../../core/models/memory_book.dart';
import '../../core/models/memory_source_manifest.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/pipeline_settings.dart';
import '../../core/services/memory_prompt_presets.dart';
import '../../core/state/memory_settings_provider.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/global_regex_provider.dart';
import '../../core/state/studio_regex_provider.dart';
import '../settings/api_list_provider.dart';

class MemoryDraftGenerator {
  final T Function<T>(ProviderListenable<T> provider) _read;
  final AuxLlmClient _llm;
  final NativeSavedConnectionSourceResolver? _sources;
  final bool Function() _isCurrent;

  MemoryDraftGenerator(Ref ref, {AuxLlmClient? llm})
    : _read = ref.read,
      _sources = ref.read(nativeProviderRuntimeProvider)?.sources,
      _isCurrent = (() => ref.mounted),
      _llm =
          llm ??
          AuxLlmClient(
            sources: ref.read(nativeProviderRuntimeProvider)?.sources,
            purpose: NativeProviderPurpose.memoryBooks,
            transportPicker:
                ref.read(nativeProviderRuntimeProvider)?.transports.pick ??
                pickChatTransport,
          );

  MemoryDraftGenerator.widget(WidgetRef ref, {AuxLlmClient? llm})
    : _read = ref.read,
      _sources = ref.read(nativeProviderRuntimeProvider)?.sources,
      _isCurrent = (() => ref.context.mounted),
      _llm =
          llm ??
          AuxLlmClient(
            sources: ref.read(nativeProviderRuntimeProvider)?.sources,
            purpose: NativeProviderPurpose.memoryBooks,
            transportPicker:
                ref.read(nativeProviderRuntimeProvider)?.transports.pick ??
                pickChatTransport,
          );

  /// Explicit dependency seam for non-widget settings/jobs and synthetic tests.
  MemoryDraftGenerator.settings({
    required this._read,
    this._llm = const AuxLlmClient(),
    this._sources,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? _alwaysCurrent;

  static bool _alwaysCurrent() => true;

  Future<MemoryDraft> generate({
    required MemoryDraft draft,
    required MemoryBookSettings settings,
    required PipelineSettings pipeline,
    required List<ChatMessage> messages,
    required String charId,
    required String sessionId,
    required Map<String, String> sessionVars,
    CancelToken? cancelToken,
  }) async {
    final original = _sources?.captureOriginalStamp();
    NativePreparedSavedConnection? source;
    void requireCurrent() {
      if (!_isCurrent() ||
          cancelToken?.isCancelled == true ||
          (original != null &&
              !_sources!.isOriginalCurrent(original, _isCurrent))) {
        throw const NativeProviderException(NativeProviderFailure.stale);
      }
      source?.requireCurrent();
    }

    requireCurrent();
    final apiResolver = MemoryDraftApiSourceResolver(
      sources: _sources,
      loadApiConfigs: () async {
        await _read(apiListProvider.future);
        return _read(apiListProvider).value ?? const [];
      },
      readActiveApiConfig: () => _read(activeApiConfigProvider),
    );
    late ResolvedMemoryDraftApiSource resolvedApi;
    Future<void> resolveConfiguration() async {
      resolvedApi = await apiResolver.resolve(
        settings: pipeline.memoryBookApi,
        originalStamp: original,
        isCurrent: () => _isCurrent() && cancelToken?.isCancelled != true,
      );
      source = resolvedApi.source;
      requireCurrent();
    }

    if (_sources != null) await resolveConfiguration();
    requireCurrent();
    final manifest = MemorySourceManifest.capture(
      sessionId,
      messages,
      draft.messageIds,
    );
    final character = await _read(characterRepoProvider).getById(charId);
    requireCurrent();
    if (character == null) throw StateError('Character not found: $charId');
    final presets = await _read(presetRepoProvider).getAll();
    requireCurrent();
    final preset = getEffectivePreset(
      presets,
      charId,
      sessionId,
      _read(activePresetIdProvider),
      _read(presetConnectionsProvider),
    );
    final personas = await _read(personaRepoProvider).getAll();
    requireCurrent();
    final persona = getEffectivePersona(
      personas,
      charId,
      sessionId,
      _read(activePersonaIdProvider),
      _read(personaConnectionsProvider),
    );
    final globalRegexes = await _read(globalRegexProvider.future);
    requireCurrent();
    final studioRegexes = await _read(studioRegexProvider.future);
    requireCurrent();
    final globalVars = _read(globalVarsProvider);
    final ledgerRange = MemoryDraftTranscriptBuilder.ledgerRange(messages);
    final historyText = MemoryDraftTranscriptBuilder.build(
      messages: messages,
      scripts: [
        ...?preset?.regexes,
        ...globalRegexes,
        ...studioRegexes.map((entry) => entry.script),
      ],
      context: RegexApplyContext(
        char: character,
        persona: persona,
        sessionVars: sessionVars,
        globalVars: globalVars,
        macroContext: MacroContext(
          charName: character.name,
          charDescription: character.description,
          charScenario: character.scenario,
          charPersonality: character.personality,
          charMesExample: character.mesExample,
          userName: persona?.name ?? 'User',
          personaPrompt: persona?.prompt,
          sessionVars: sessionVars,
          globalVars: globalVars,
          charId: charId,
          sessionId: sessionId,
          macroName: character.macroName,
        ),
      ),
    );
    final customPrompts = MemoryPromptPreset.fromJsonList(
      _read(memoryGlobalSettingsProvider).customPrompts,
    );
    final template = MemoryPromptPresets.resolve(
      settings.promptPreset,
      customPrompts,
      ledgerRange != null,
    );
    var prompt = template.replaceAll('{{history}}', historyText);
    if (!template.contains('{{history}}')) {
      prompt = '$prompt\n\n$historyText';
    }

    // Legacy-only DI preserves the original prompt-then-config ordering. Native
    // composition resolves its keyless saved source before prompt collection.
    if (_sources == null) await resolveConfiguration();
    requireCurrent();

    // Left on "auto", the output cap is the one configured on the connection
    // this draft runs through — not a fixed number written in here. The old
    // flat 25000 was above what several providers accept for output plus
    // reasoning tokens, and no field in the app could bring it back down.
    final maxTokens = MemoryBookApiConfigResolver.maxTokensFor(
      pipeline.memoryBookApi,
      resolvedApi.configuration,
    );
    final temperature = MemoryBookApiConfigResolver.temperatureFor(
      pipeline.memoryBookApi,
    );

    // Through the shared auxiliary client, not a bare transport call: it picks
    // the same chat transport per protocol, and it brings the retry policy
    // every other auxiliary call in the app already has. A draft used to die
    // on the first 5xx — a provider gateway answering one request with 504
    // left the draft marked `needs_regeneration` and the reader pressing the
    // button again by hand, while the identical hiccup in the cleaner or the
    // summary was retried and never seen.
    final result = await _llm.callOnce(
      config: resolvedApi.config,
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      // 0 keeps the old behaviour for a connection that names no timeout: the
      // request is not cut off on a deadline of ours.
      timeoutMs: resolvedApi.receiveTimeoutMs ?? 0,
      cancelToken: cancelToken,
      // Memory-book drafting goes through a chat transport, so it was always
      // captured — but with no identity, which parked it in the session-less
      // bucket where no per-chat view could reach it.
      captureContext: LlmCaptureContext(
        stage: 'memory.draft',
        sessionId: sessionId,
      ),
    );
    requireCurrent();
    return MemoryDraftResponseParser.parse(
      draft.copyWith(sourceManifest: manifest),
      result,
      ledgerRange: ledgerRange,
    );
  }
}
