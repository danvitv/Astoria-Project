import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/credentials/image_routmy_credential_owner.dart';
import '../../../core/credentials/image_openrouter_credential_owner.dart';
import '../../../core/credentials/image_novelai_credential_owner.dart';
import '../../../core/credentials/image_naistera_credential_owner.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/services/image_storage_service.dart';
import '../../../core/utils/error_format.dart';
import '../image_gen_models.dart';
import 'image_gen_dispatcher.dart';
import 'image_prompt_builder.dart';
import 'image_reference_collector.dart';
import 'image_tag_markup.dart';
import 'naistera_image_provider.dart';
import 'reference_matcher.dart';

/// Turns `[IMG:GEN]` tags in a message into generated images.
///
/// Prompt assembly (style block, reference descriptions, critical reference
/// instruction) lives in [image_prompt_builder], reference collection in
/// [ImageReferenceCollector] and the provider calls in [ImageGenDispatcher].
class ImageGenService {
  ImageGenService(
    this._imageStorage, {
    ImageRoutmyCredentialOwner? routmyCredentials,
    ImageOpenRouterCredentialOwner? openrouterCredentials,
    ImageNovelAiCredentialOwner? novelaiCredentials,
    ImageNaisteraCredentialOwner? naisteraCredentials,
    // Trusted native transport fixture seam, forwarded to the existing binding.
    NaisteraImageProvider Function(
      String,
      void Function(),
      bool Function(String),
    )?
    naisteraClientFactory,
  }) : _routmy = routmyCredentials,
       _openrouter = openrouterCredentials,
       _novelai = novelaiCredentials,
       _naistera = naisteraCredentials,
       _errors = ImageGenErrorSanitizer(
         routmyCredentials: routmyCredentials,
         openrouterCredentials: openrouterCredentials,
         novelaiCredentials: novelaiCredentials,
         naisteraCredentials: naisteraCredentials,
       ),
       _dispatcher = ImageGenDispatcher(
         routmyCredentials: routmyCredentials,
         openrouterCredentials: openrouterCredentials,
         novelaiCredentials: novelaiCredentials,
         naisteraCredentials: naisteraCredentials,
         naisteraClientFactory: naisteraClientFactory,
       );

  final ImageStorageService _imageStorage;
  final ImageRoutmyCredentialOwner? _routmy;
  final ImageOpenRouterCredentialOwner? _openrouter;
  final ImageNovelAiCredentialOwner? _novelai;
  final ImageNaisteraCredentialOwner? _naistera;
  final ImageGenErrorSanitizer _errors;
  final ImageReferenceCollector _references = const ImageReferenceCollector();
  final ImageGenDispatcher _dispatcher;

  bool Function() _publicationGuard(ImageGenSettings settings) =>
      settings.apiType == ImageGenApiType.routmy
      ? _routmy?.captureGuard() ?? () => false
      : settings.apiType == ImageGenApiType.openrouter
      ? _openrouter?.captureGuard() ?? () => false
      : settings.apiType == ImageGenApiType.novelai
      ? _novelai?.captureGuard() ?? () => false
      : settings.apiType == ImageGenApiType.naistera
      ? _naisteraPublicationGuard(settings)
      : () => true;

  bool Function() _naisteraPublicationGuard(ImageGenSettings settings) {
    final owner = _naistera;
    if (owner == null) return () => false;
    final custody = owner.captureGuard();
    final public = owner.capturePublicTextGuard();
    return () =>
        custody() &&
        public(settings.naisteraModel) &&
        public(NaisteraConstants.normalizeModel(settings.naisteraModel));
  }

  Future<String> processMessageImages({
    required String text,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
    void Function(String updatedText)? onUpdate,
    void Function(String error)? onError,
    // A denied return is a display-only projection, never generation output.
    void Function()? onPublicationDenied,
  }) async {
    final ownsPublication = _publicationGuard(settings);
    // Strong carried-JSON inspection belongs only to this Naistera operation.
    // The shared service can have all native owners; their mere presence must
    // not change accepted legacy/HTML/error handling for another image family.
    final errors = settings.apiType == ImageGenApiType.naistera
        ? ImageGenErrorSanitizer(
            naisteraCredentials: _naistera,
            checkNaisteraResults: () => true,
          )
        : _errors;
    var currentText = text;
    var publicationDenied = false;
    String publicationText() {
      final safe = errors.sanitizeMessageErrors(currentText);
      if ((settings.apiType == ImageGenApiType.openrouter ||
              settings.apiType == ImageGenApiType.novelai ||
              settings.apiType == ImageGenApiType.naistera) &&
          (!ownsPublication() ||
              !errors.messageErrorsAreCurrent(safe) ||
              settings.apiType == ImageGenApiType.naistera &&
                  !errors.naisteraTextIsCurrent(safe))) {
        publicationDenied = true;
        onPublicationDenied?.call();
        return errors.displayProjection(text);
      }
      return safe;
    }

    if (!settings.enabled) {
      currentText = ImageTagMarkup.replaceAllImageGenTagsWithDisabled(text);
      final disabledText = publicationText();
      if (!publicationDenied && disabledText != text)
        onUpdate?.call(disabledText);
      return disabledText;
    }

    final instructions = ImageTagMarkup.extractImageGenInstructions(text);
    if (instructions.isEmpty) return publicationText();

    // A tag is "resolved" once it carries a result or an error token, which
    // takes it out of the pending set the next replacement indexes into.
    final resolved = List<bool>.filled(instructions.length, false);

    // Writes an outcome into the tag its instruction came from. Only that one
    // tag is rewritten: a failure leaves the block in place as a retryable
    // error card instead of dropping it, and the tags of the still-running
    // images stay pending.
    void applyOutcome(int index, _ImageOutcome outcome) {
      if (!ownsPublication()) return;
      var pendingIndex = 0;
      for (var i = 0; i < index; i++) {
        if (!resolved[i]) pendingIndex++;
      }
      final updated = outcome.error == null
          ? ImageTagMarkup.replaceTagWithResult(
              currentText,
              pendingIndex,
              outcome.imagePath!,
            )
          : ImageTagMarkup.replaceTagWithError(
              currentText,
              pendingIndex,
              _formatErrorString(outcome.error!),
            );
      resolved[index] = true;
      if (updated == currentText) return;
      final safe = errors.sanitizeMessageErrors(updated);
      if ((settings.apiType == ImageGenApiType.openrouter ||
              settings.apiType == ImageGenApiType.novelai ||
              settings.apiType == ImageGenApiType.naistera) &&
          (!errors.messageErrorsAreCurrent(safe) ||
              settings.apiType == ImageGenApiType.naistera &&
                  !errors.naisteraTextIsCurrent(safe)))
        return;
      currentText = safe;
      onUpdate?.call(currentText);
    }

    Future<_ImageOutcome> run(Map<String, dynamic> instruction) => _runOne(
      instruction: instruction,
      settings: settings,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
      llmModel: llmModel,
      character: character,
      persona: persona,
      recentImageContexts: recentImageContexts,
      cancelToken: cancelToken,
    );

    if (settings.concurrentGeneration) {
      // Every request is already in flight; awaiting them in order only fixes
      // the order the finished images are written back in.
      final inFlight = instructions.map(run).toList();
      for (var i = 0; i < inFlight.length; i++) {
        final outcome = await inFlight[i];
        if (outcome.cancelled) continue;
        applyOutcome(i, outcome);
        if (ownsPublication() && outcome.error != null) {
          onError?.call(_formatErrorString(outcome.error!));
        }
      }
      return publicationText();
    }

    for (var i = 0; i < instructions.length; i++) {
      if (cancelToken?.isCancelled == true) break;
      final outcome = await run(instructions[i]);
      if (outcome.cancelled) break;
      applyOutcome(i, outcome);
      if (ownsPublication() && outcome.error != null) {
        onError?.call(_formatErrorString(outcome.error!));
      }
    }

    return publicationText();
  }

  /// Generates and persists the image for a single instruction.
  ///
  /// Never throws: every failure comes back as [_ImageOutcome.failure] so the
  /// caller can turn it into an error card and keep going.
  Future<_ImageOutcome> _runOne({
    required Map<String, dynamic> instruction,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
  }) async {
    final ownsPublication = _publicationGuard(settings);
    final publicPath = settings.apiType == ImageGenApiType.novelai
        ? _novelai?.capturePublicTextGuard(url: true)
        : settings.apiType == ImageGenApiType.naistera
        ? _naistera?.capturePublicTextGuard(url: true)
        : _openrouter?.capturePublicTextGuard(url: true);
    final rawPrompt = instruction['prompt'] as String? ?? '';
    if (rawPrompt.isEmpty) {
      return _ImageOutcome.failure('Image prompt is empty');
    }

    // Check the actual instruction before SCENE_PROMPT/style normalization.
    if (settings.apiType == ImageGenApiType.naistera &&
        (publicPath == null ||
            !NaisteraImageProvider.nativeJsonIsPublic(
              instruction,
              publicPath,
            ))) {
      return _ImageOutcome.cancelled();
    }

    final prompt = rawPrompt.replaceFirst(RegExp(r'^SCENE_PROMPT:\s*'), '');

    try {
      final imageBytes = await generateImage(
        settings: settings,
        prompt: prompt,
        tagStyle: instruction['style'] as String?,
        llmEndpoint: llmEndpoint,
        llmApiKey: llmApiKey,
        llmModel: llmModel,
        character: character,
        persona: persona,
        recentImageContexts: recentImageContexts,
        instructionAspectRatio: instruction['aspect_ratio'] as String?,
        instructionImageSize: instruction['image_size'] as String?,
        cancelToken: cancelToken,
      );
      if (cancelToken?.isCancelled == true || !ownsPublication())
        return _ImageOutcome.cancelled();
      if (settings.apiType == ImageGenApiType.naistera &&
          !NaisteraImageProvider.nativeJsonIsPublic(instruction, publicPath!))
        return _ImageOutcome.cancelled();
      if (imageBytes.isEmpty) {
        return _ImageOutcome.failure('Provider returned no image data');
      }

      final savedPath = await _saveGeneratedImage(imageBytes);
      if (cancelToken?.isCancelled == true || !ownsPublication())
        return _ImageOutcome.cancelled();
      if (settings.apiType == ImageGenApiType.naistera &&
          !NaisteraImageProvider.nativeJsonIsPublic(instruction, publicPath!))
        return _ImageOutcome.cancelled();
      if ((settings.apiType == ImageGenApiType.openrouter ||
              settings.apiType == ImageGenApiType.novelai ||
              settings.apiType == ImageGenApiType.naistera) &&
          publicPath?.call(savedPath) != true) {
        return _ImageOutcome.failure('Image URL unavailable');
      }
      return _ImageOutcome.success(savedPath);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return _ImageOutcome.cancelled();
      return _ImageOutcome.failure(_formatError(e));
    } catch (e) {
      if (cancelToken?.isCancelled == true || !ownsPublication())
        return _ImageOutcome.cancelled();
      return _ImageOutcome.failure(_formatErrorString(e.toString()));
    }
  }

  /// Generates a single image for [prompt].
  ///
  /// [tagStyle] is the `style` field of the image tag; the active style from
  /// the style library overrides it, and with "no style" selected it is used
  /// as written.
  Future<Uint8List> generateImage({
    required ImageGenSettings settings,
    required String prompt,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    String? tagStyle,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) async {
    final ownsPublication = _publicationGuard(settings);
    final isNaistera = settings.apiType == ImageGenApiType.naistera;
    // Captured before collect's first await, not by the later dispatcher/client.
    final publicNaistera = isNaistera
        ? _naistera?.capturePublicTextGuard()
        : null;
    if (isNaistera &&
        settings.styles.length + settings.references.length > 8192)
      throw StateError('Naistera image operation unavailable');
    final originalInput = isNaistera
        ? <String, Object?>{
            'model': settings.naisteraModel,
            'prompt': prompt,
            'tagStyle': tagStyle,
            'activeStyleId': settings.activeStyleId,
            'styles': [
              for (final style in settings.styles)
                {'id': style.id, 'name': style.name, 'value': style.value},
            ],
            'references': [
              for (final ref in settings.references)
                {
                  'name': ref.name,
                  'imageData': ref.imageData,
                  'description': ref.description,
                  'matchMode': ref.matchMode,
                },
            ],
            'referenceInstruction': settings.refInstruction,
            'configuredAspectRatio': settings.naisteraAspectRatio,
            'characterName': character?.name,
            'characterAvatar': character?.avatarPath,
            'personaName': persona?.name,
            'personaAvatar': persona?.avatarPath,
            'contexts': recentImageContexts,
            'aspectRatio': instructionAspectRatio,
            'imageSize': instructionImageSize,
          }
        : null;
    void checkNaistera([Object? carried]) {
      if (isNaistera &&
          (publicNaistera == null ||
              !NaisteraImageProvider.nativeJsonIsPublic(
                originalInput,
                publicNaistera,
              ) ||
              !NaisteraImageProvider.nativeJsonIsPublic(
                carried,
                publicNaistera,
              ))) {
        throw StateError('Naistera image operation unavailable');
      }
    }

    checkNaistera();
    final collected = await _references.collect(
      settings: settings,
      prompt: prompt,
      character: character,
      persona: persona,
      recentImageContexts: recentImageContexts,
    );
    if (!ownsPublication()) throw StateError('Image credential owner retired');
    checkNaistera(collected);

    final descriptionsMode = isNaistera
        ? settings.naisteraCharacterDescriptionsMode
        : CharacterDescriptionsMode.asIs;

    // Outside "as-is" the avatars travel without their caption: the
    // descriptions are carried by the prompt block instead, so leaving them on
    // the images would send each one twice.
    final references = descriptionsMode == CharacterDescriptionsMode.asIs
        ? collected
        : _withoutAvatarDescriptions(collected);

    var finalPrompt = buildFinalGenerationPrompt(
      prompt: prompt,
      tagStyle: tagStyle,
      settings: settings,
      references: references,
      // NovelAI parses the whole prompt as tags — the [STYLE: ...] wrapper
      // would reach the sampler verbatim.
      wrapStyle:
          !(settings.apiType == ImageGenApiType.novelai ||
              (isNaistera &&
                  NaisteraConstants.isNovelAIModel(settings.naisteraModel))),
    );
    if (isNaistera && settings.sendRefDescriptions) {
      finalPrompt = appendPromptBlock(
        finalPrompt,
        buildCharacterDescriptionPromptBlock(
          mode: descriptionsMode,
          references: references,
          charDescription: _appearanceOf(character?.name, settings),
          userDescription: _appearanceOf(persona?.name, settings),
        ),
      );
    }
    finalPrompt = withReferenceInstruction(
      finalPrompt,
      settings,
      hasReferences: references.isNotEmpty,
    );
    final prepared = {'prompt': finalPrompt, 'references': references};
    checkNaistera(prepared);

    final bytes = await _dispatcher.generate(
      settings: settings,
      prompt: finalPrompt,
      references: references,
      llmEndpoint: llmEndpoint,
      llmApiKey: llmApiKey,
      instructionAspectRatio: instructionAspectRatio,
      instructionImageSize: instructionImageSize,
      cancelToken: cancelToken,
      captureContext: captureContext,
      retainedNaisteraPublicGuard: publicNaistera,
    );
    if (!ownsPublication()) throw StateError('Image credential owner retired');
    checkNaistera(collected);
    checkNaistera(prepared);
    return bytes;
  }

  /// Appearance blurb for a character or persona: the description of the
  /// reference-library entry whose aliases name them. Glaze has no separate
  /// appearance field, and a library entry is exactly where a user writes one.
  static String _appearanceOf(String? name, ImageGenSettings settings) {
    final target = normalizeTriggerText(name ?? '');
    if (target.isEmpty) return '';
    for (final ref in settings.references) {
      if (!ref.enabled) continue;
      if (!parseReferenceAliases(ref.name).contains(target)) continue;
      final description = ref.description.trim();
      if (description.isNotEmpty) return description;
    }
    return '';
  }

  static List<Map<String, String>> _withoutAvatarDescriptions(
    List<Map<String, String>> references,
  ) {
    return references.map((ref) {
      final source = ref['source'];
      if (source != 'char' && source != 'user') return ref;
      return {...ref, 'description': ''};
    }).toList();
  }

  /// Delegates to the shared [formatError] — the same helper the chat and the
  /// ext blocks use — so a failed image generation reads like every other
  /// provider failure (localized status line, provider message on its own
  /// line) instead of a Dio dump. The length cap stays: this string is
  /// rendered inline in the message card.
  String _formatError(DioException e) => _formatErrorString(formatError(e));

  String _formatErrorString(String msg) {
    return _errors.sanitize(msg);
  }

  Future<String> _saveGeneratedImage(Uint8List bytes) async {
    final dir = Directory(p.join(_imageStorage.baseDir, 'generated'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final extension = imageExtensionForBytes(bytes);
    // Concurrent generations can land inside the same microsecond, so the
    // counter — not the clock alone — is what keeps the names unique.
    final name = 'imggen_${DateTime.now().microsecondsSinceEpoch}_$_saveSeq';
    _saveSeq++;
    final path = p.join(dir.path, '$name.$extension');
    await File(path).writeAsBytes(bytes);
    // Stored relative to the Glaze data root, never as the absolute path it
    // was just written to: the root moves under an installed app (a new iOS
    // container UUID, a database carried between desktop build channels) and
    // an absolute path silently stops pointing at a file, while a relative one
    // is re-joined onto the current root by resolveGlazeFilePath.
    return p.url.join('generated', '$name.$extension');
  }

  static int _saveSeq = 0;
}

/// Error publication keeps the original native coverage, but does not freeze
/// the active error sink. Call again at each downstream callback/queued write.
/// Limits discard details instead of creating an unrecognizable key prefix.
class ImageGenErrorSanitizer {
  ImageGenErrorSanitizer({
    ImageRoutmyCredentialOwner? routmyCredentials,
    ImageOpenRouterCredentialOwner? openrouterCredentials,
    ImageNovelAiCredentialOwner? novelaiCredentials,
    ImageNaisteraCredentialOwner? naisteraCredentials,
    bool Function()? checkResults,
    bool Function()? checkNaisteraResults,
  }) : _originalSink = activeErrorRedactor ?? _defaultRedactor,
       _originalCoverage = routmyCredentials?.capturePublicTextGuard(),
       _originalOpenRouterCoverage = openrouterCredentials
           ?.capturePublicTextGuard(),
       _originalNovelAiCoverage = novelaiCredentials?.capturePublicTextGuard(),
       _originalNaisteraCoverage = naisteraCredentials
           ?.capturePublicTextGuard(),
       _publicResults = _captureResults(
         openrouterCredentials,
         novelaiCredentials,
         naisteraCredentials,
       ),
       _checkResults = checkResults,
       _checkNaisteraResults = checkNaisteraResults;

  static final _defaultRedactor = SecretRedactor();
  static final _errorStarts = RegExp(r'\[IMG:ERROR:\{');
  static final _errorDetail = RegExp(r'("error"\s*:\s*)"(?:\\.|[^"\\])*"');
  static final _resultTags = RegExp(r'\[IMG:RESULT:([^\]]*)\]');
  static final _imageElements = RegExp(
    r'''<img\b(?:[^>"']|"[^"]*"|'[^']*')*>''',
    caseSensitive: false,
  );
  final SecretRedactor _originalSink;
  final bool Function(String)? _originalCoverage;
  final bool Function(String)? _originalOpenRouterCoverage, _publicResults;
  final bool Function(String)? _originalNovelAiCoverage;
  final bool Function(String)? _originalNaisteraCoverage;
  final bool Function()? _checkResults;
  final bool Function()? _checkNaisteraResults;

  static bool Function(String)? _captureResults(
    ImageOpenRouterCredentialOwner? openrouter,
    ImageNovelAiCredentialOwner? novelai,
    ImageNaisteraCredentialOwner? naistera,
  ) {
    final originalOpenRouter = openrouter?.capturePublicTextGuard(url: true);
    final originalNovelAi = novelai?.capturePublicTextGuard(url: true);
    final originalNaistera = naistera?.capturePublicTextGuard(url: true);
    if (originalOpenRouter == null &&
        originalNovelAi == null &&
        originalNaistera == null)
      return null;
    return (value) =>
        (originalOpenRouter?.call(value) ?? true) &&
        (originalNovelAi?.call(value) ?? true) &&
        (originalNaistera?.call(value) ?? true);
  }

  bool get _checksResults =>
      _publicResults != null && (_checkResults?.call() ?? true);

  bool get _checksNaisteraCarried =>
      _originalNaisteraCoverage != null &&
      (_checkNaisteraResults?.call() ??
          (_originalCoverage == null &&
              _originalOpenRouterCoverage == null &&
              _originalNovelAiCoverage == null));

  // Consume the original object, including malformed nested field types and ]
  // inside strings, before the display codec or JSON normalization can split it.
  static Iterable<({int start, int end, String payload})> _errorCards(
    String content,
  ) sync* {
    var after = 0;
    for (final start in _errorStarts.allMatches(content)) {
      if (start.start < after) continue;
      final objectStart = start.end - 1;
      var depth = 0;
      var quoted = false, escaped = false;
      for (var i = objectStart; i < content.length; i++) {
        final unit = content.codeUnitAt(i);
        if (quoted) {
          if (escaped) {
            escaped = false;
          } else if (unit == 92) {
            escaped = true;
          } else if (unit == 34) {
            quoted = false;
          }
          continue;
        }
        if (unit == 34) {
          quoted = true;
        } else if (unit == 123) {
          depth++;
        } else if (unit == 125 && --depth == 0) {
          if (i + 1 < content.length && content.codeUnitAt(i + 1) == 93) {
            after = i + 2;
            yield (
              start: start.start,
              end: after,
              payload: content.substring(objectStart, i + 1),
            );
          }
          break;
        }
      }
    }
  }

  static String _mapErrorCards(
    String content,
    String Function(String original) replace,
  ) {
    final output = StringBuffer();
    var copied = 0;
    for (final card in _errorCards(content)) {
      output.write(content.substring(copied, card.start));
      output.write(replace(card.payload));
      copied = card.end;
    }
    output.write(content.substring(copied));
    return output.toString();
  }

  bool _instructionIsCurrent(String instruction) {
    if (!_publicResults!(instruction)) return false;
    try {
      // Instruction JSON is itself a string in the error object. Inspect its
      // actual decoded text too, without imposing HTTP syntax or rewriting it.
      final decoded = jsonDecode(instruction);
      if (_checksNaisteraCarried) {
        return NaisteraImageProvider.nativeJsonIsPublic(
          decoded,
          _publicResults,
        );
      }
      return _publicResults(jsonEncode(decoded));
    } on FormatException {
      return true; // Plain prompt text remains a supported instruction.
    }
  }

  bool _carriedErrorIsCurrent(
    String original,
    Map<String, dynamic> payload, {
    required bool wholeIsPublic,
  }) {
    if (_checksNaisteraCarried &&
        !NaisteraImageProvider.nativeJsonIsPublic({
          ...payload,
          // Keep the existing diagnostic-detail redaction exception, not an
          // exception for unknown carried fields, keys or nested metadata.
          'error': 'Image error details unavailable',
        }, _publicResults!))
      return false;
    if (!wholeIsPublic) {
      final error = payload['error'];
      // Diagnostic details may be redacted, but that exception must not
      // normalize or clip any retained metadata before the whole-value fence.
      final withoutDetail = original.replaceFirstMapped(
        _errorDetail,
        (match) => '${match.group(1)}"Image error details unavailable"',
      );
      if (error is! String ||
          _publicResults!(error) ||
          withoutDetail == original ||
          !_publicResults(withoutDetail)) {
        return false;
      }
    }
    final instruction = payload['instruction'];
    if (payload.containsKey('instruction') &&
        (instruction is! String || !_instructionIsCurrent(instruction))) {
      return false;
    }
    final variants = payload['variants'];
    return !payload.containsKey('variants') ||
        (variants is String && _publicResults!(variants));
  }

  bool _elementIsCurrent(String element) {
    // Never inspect a normalized fragment in place of the original whole.
    if (!_publicResults!(element)) return false;
    return ImageTagMarkup.decodedImageElementAttributes(
      element,
    ).values.every(_publicResults);
  }

  /// Denial-safe, ephemeral display only. Keep surrounding prose and public
  /// instructions, but remove every carried image of a denied block as a unit.
  /// Callers must never persist or cache this projection.
  String displayProjection(String content) {
    if (!_checksResults) return sanitizeMessageErrors(content);
    var projected = _mapErrorCards(content, (original) {
      try {
        final wholeIsPublic = _publicResults!(original);
        final payload = jsonDecode(original) as Map<String, dynamic>;
        if (_carriedErrorIsCurrent(
          original,
          payload,
          wholeIsPublic: wholeIsPublic,
        )) {
          return '[IMG:ERROR:$original]';
        }
        final error = payload['error'];
        final safeError = error is String
            ? sanitize(error)
            : SecretRedactor.removed;
        final instruction = payload['instruction'];
        return _encodeError({
          'error': _publicResults(safeError)
              ? safeError
              : SecretRedactor.removed,
          if (instruction is String && _instructionIsCurrent(instruction))
            'instruction': instruction,
        });
      } catch (_) {
        return _unavailableBlock(null);
      }
    });
    projected = sanitizeMessageErrors(projected);
    projected = projected.replaceAllMapped(_imageElements, (match) {
      final element = match.group(0)!;
      if (!element.toLowerCase().contains('data-iig') ||
          _elementIsCurrent(element))
        return element;
      final attributes = ImageTagMarkup.decodedImageElementAttributes(element);
      return _unavailableBlock(attributes[ImageTagMarkup.instructionAttribute]);
    });
    projected = projected.replaceAllMapped(_resultTags, (match) {
      final original = match.group(1)!;
      if (_publicResults!(original)) return match.group(0)!;
      return _unavailableBlock(
        ImageBlockPayload.parseResult(original).instruction,
      );
    });
    // Pending regenerations can also carry earlier result variants.
    for (final tag in ImageTagMarkup.scanPendingTags(projected).reversed) {
      if ((!tag.payload.startsWith('@') && _originalNaisteraCoverage == null) ||
          _publicResults!(tag.payload))
        continue;
      final instruction = ImageBlockPayload.parsePending(
        tag.payload,
      ).instruction;
      projected = projected.replaceRange(
        tag.start,
        tag.end,
        _unavailableBlock(instruction),
      );
    }
    return projected;
  }

  String _unavailableBlock(String? instruction) {
    final payload = {
      'error': 'Image result unavailable',
      if (instruction != null &&
          instruction.isNotEmpty &&
          _instructionIsCurrent(instruction))
        'instruction': instruction,
    };
    return _encodeError(payload);
  }

  static String _encodeError(Map<String, dynamic> payload) =>
      '[IMG:ERROR:${jsonEncode(payload).replaceAll(']', r'\u005d')}]';

  String sanitize(String text) {
    var safe = _originalSink.redactText(text);
    if (safe == SecretRedactor.limited) return safe;
    safe = (activeErrorRedactor ?? _defaultRedactor).redactText(safe);
    if (safe == SecretRedactor.limited) return safe;
    // The owner's guard includes its captured and currently injected policies.
    // If their coverage differs from the global sink, discard the whole detail.
    if (_originalCoverage?.call(safe) == false) return SecretRedactor.removed;
    if (_originalOpenRouterCoverage?.call(safe) == false)
      return SecretRedactor.removed;
    if (_originalNovelAiCoverage?.call(safe) == false)
      return SecretRedactor.removed;
    if (_originalNaisteraCoverage?.call(safe) == false)
      return SecretRedactor.removed;
    return safe.length > 200 ? SecretRedactor.limited : safe;
  }

  String sanitizeMessageErrors(String content) => _mapErrorCards(content, (
    original,
  ) {
    try {
      final wholeIsPublic = !_checksResults || _publicResults!(original);
      final payload = jsonDecode(original) as Map<String, dynamic>;
      // A denied card is not a sanitized generation result. Preserve its raw
      // evidence for the caller's fence; only displayProjection may drop it.
      if (_checksResults &&
          !_carriedErrorIsCurrent(
            original,
            payload,
            wholeIsPublic: wholeIsPublic,
          )) {
        return '[IMG:ERROR:$original]';
      }
      final error = payload['error'];
      final safeError = error is String
          ? sanitize(error)
          : SecretRedactor.removed;
      payload['error'] = _checksResults && !_publicResults!(safeError)
          ? SecretRedactor.removed
          : safeError;
      // The display codec ends a tag at the first literal ]. Escaping within
      // JSON keeps markers readable without changing instructions/variants.
      return _encodeError(payload);
    } catch (_) {
      return '[IMG:ERROR:{"error":"Image error details unavailable"}]';
    }
  });

  bool messageErrorsAreCurrent(String content) {
    if (_checkNaisteraResults?.call() == true &&
        _originalNaisteraCoverage?.call(content) == false)
      return false;
    if (_checksResults) {
      // Whole original result payload/element before the display codec can split
      // a path, choose a variant, or decode the instruction. Denial only: never
      // rewrite old database results or the user's surrounding message prose.
      for (final match in _resultTags.allMatches(content)) {
        if (!_publicResults!(match.group(1)!)) return false;
      }
      for (final match in _imageElements.allMatches(content)) {
        final element = match.group(0)!;
        if (element.toLowerCase().contains('data-iig') &&
            !_elementIsCurrent(element))
          return false;
      }
      for (final tag in ImageTagMarkup.scanPendingTags(content)) {
        if (tag.payload.startsWith('@') && !_publicResults!(tag.payload)) {
          return false;
        }
      }
    }
    for (final card in _errorCards(content)) {
      try {
        final original = card.payload;
        // Check the whole raw payload before decoding its retained fields.
        final wholeIsPublic = !_checksResults || _publicResults!(original);
        final payload = jsonDecode(original) as Map<String, dynamic>;
        final error = payload['error'];
        if (error is! String || sanitize(error) != error) return false;
        if (_checksResults &&
            (!wholeIsPublic ||
                !_carriedErrorIsCurrent(
                  original,
                  payload,
                  wholeIsPublic: wholeIsPublic,
                )))
          return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  /// Naistera's complete original message/metadata fence; not a JSON codec or
  /// a replacement writer. Other accepted image families retain their guards.
  bool storedMessageIsCurrent(Map<String, dynamic> message) =>
      _checkNaisteraResults?.call() != true ||
      (_originalNaisteraCoverage != null &&
          NaisteraImageProvider.nativeJsonIsPublic(
            message,
            _originalNaisteraCoverage,
          ));

  bool naisteraTextIsCurrent(String content) =>
      _originalNaisteraCoverage?.call(content) ?? false;
  bool get checksNaisteraResults => _checkNaisteraResults?.call() == true;

  /// Ephemeral Naistera projection of the already-selected message DTO, including
  /// stored metadata. This is never accepted by the repository/cache writer.
  Map<String, dynamic> displayStoredMessage(Map<String, dynamic> message) {
    if (_checkNaisteraResults?.call() != true) return message;
    Map<String, dynamic> unavailable() => {
      'id':
          message['id'] is String &&
              naisteraTextIsCurrent(message['id'] as String)
          ? message['id']
          : '',
      'role':
          message['role'] is String &&
              naisteraTextIsCurrent(message['role'] as String)
          ? message['role']
          : 'assistant',
      'content': '',
    };
    // Structural admission before projection; never recursively visit a cycle,
    // custom object or oversized tree just to manufacture a display fallback.
    if (!NaisteraImageProvider.isNativeJsonTree(message)) return unavailable();
    Object? project(Object? value) {
      if (value is String)
        return _originalNaisteraCoverage?.call(value) == false
            ? 'Image result unavailable'
            : value;
      if (value is List) {
        final projected = value.map(project).toList();
        return !NaisteraImageProvider.nativeJsonIsPublic(
              projected,
              naisteraTextIsCurrent,
            )
            ? <Object?>[]
            : projected;
      }
      if (value is Map) {
        final projected = <String, dynamic>{
          for (final entry in value.entries)
            if (entry.key is String &&
                _originalNaisteraCoverage?.call(entry.key as String) != false)
              entry.key as String: project(entry.value),
        };
        return !NaisteraImageProvider.nativeJsonIsPublic(
              projected,
              naisteraTextIsCurrent,
            )
            ? <String, dynamic>{}
            : projected;
      }
      return value;
    }

    final projected = project(message) as Map<String, dynamic>;
    if (projected.isNotEmpty) return projected;
    // A composite alias can span metadata leaves. Keep the original identity,
    // but no carried content/variants; do not normalize it back into an outcome.
    return unavailable();
  }
}

/// Result of one image request: a saved file, a message for the error card, or
/// a cancellation that leaves the tag pending for the caller to resolve.
class _ImageOutcome {
  const _ImageOutcome._({this.imagePath, this.error, this.cancelled = false});

  factory _ImageOutcome.success(String imagePath) =>
      _ImageOutcome._(imagePath: imagePath);
  factory _ImageOutcome.failure(String error) => _ImageOutcome._(error: error);
  factory _ImageOutcome.cancelled() => const _ImageOutcome._(cancelled: true);

  final String? imagePath;
  final String? error;
  final bool cancelled;
}
