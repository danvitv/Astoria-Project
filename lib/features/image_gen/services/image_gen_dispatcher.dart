import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/credentials/image_routmy_credential_owner.dart';
import '../../../core/credentials/image_openrouter_credential_owner.dart';
import '../../../core/credentials/image_openrouter_destinations.dart';
import '../../../core/credentials/image_novelai_credential_owner.dart';
import '../../../core/credentials/image_novelai_destinations.dart';
import '../../../core/credentials/image_naistera_credential_owner.dart';
import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/llm/transport/llm_request_capture.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import 'a1111_image_provider.dart';
import 'comfyui_image_provider.dart';
import 'gemini_image_provider.dart';
import 'image_prompt_builder.dart';
import 'naistera_image_provider.dart';
import 'novelai_image_provider.dart';
import 'openai_image_provider.dart';
import 'openrouter_image_provider.dart';
import 'routmy_image_provider.dart';
import 'xai_image_provider.dart';

/// Routes a prepared prompt + reference set to the configured provider client.
///
/// Everything prompt-shaped (style block, reference descriptions, critical
/// instruction) has already been applied by the caller; this class only knows
/// about endpoints, credentials and per-model parameter validation.
class ImageGenDispatcher {
  const ImageGenDispatcher({
    this.routmyCredentials,
    this.routmyClientFactory,
    this.openrouterCredentials,
    this.openrouterClientFactory,
    this.novelaiCredentials,
    this.novelaiClientFactory,
    this.naisteraCredentials,
    this.naisteraClientFactory,
  });

  final ImageRoutmyCredentialOwner? routmyCredentials;

  /// Trusted transport fixture seam; never an alternate secret source.
  final RoutmyImageProvider Function(String, void Function())?
  routmyClientFactory;
  final ImageOpenRouterCredentialOwner? openrouterCredentials;
  final OpenRouterImageProvider Function(
    void Function(),
    bool Function(String),
  )?
  openrouterClientFactory;
  final ImageNovelAiCredentialOwner? novelaiCredentials;
  final NovelAIImageProvider Function(void Function())? novelaiClientFactory;
  final ImageNaisteraCredentialOwner? naisteraCredentials;
  final NaisteraImageProvider Function(
    String,
    void Function(),
    bool Function(String),
  )?
  naisteraClientFactory;

  Future<Uint8List> generate({
    required ImageGenSettings settings,
    required String prompt,
    required List<Map<String, String>> references,
    required String llmEndpoint,
    required String llmApiKey,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
    // Retain the service's pre-reference-await coverage; this only strengthens
    // the original/current owner policy and never changes credential custody.
    bool Function(String)? retainedNaisteraPublicGuard,
  }) async {
    // Policy sees the original complete model before diagnostics or transport.
    final currentNaistera = naisteraCredentials?.capturePublicTextGuard();
    bool publicNaistera(String value) =>
        currentNaistera?.call(value) == true &&
        (retainedNaisteraPublicGuard?.call(value) ?? true);
    if (settings.apiType == ImageGenApiType.naistera &&
        !NaisteraImageProvider.nativeJsonIsPublic({
          'model': settings.naisteraModel,
          'prompt': prompt,
          'references': references,
          'aspectRatio': instructionAspectRatio,
          'imageSize': instructionImageSize,
        }, publicNaistera)) {
      throw StateError('Image model selection unavailable');
    }
    if (settings.apiType == ImageGenApiType.openrouter &&
        openrouterCredentials?.capturePublicTextGuard().call(
              settings.openrouter.model,
            ) !=
            true) {
      throw StateError('Image model selection unavailable');
    }
    if (settings.apiType == ImageGenApiType.novelai &&
        novelaiCredentials?.capturePublicTextGuard().call(
              settings.novelai.model,
            ) !=
            true) {
      throw StateError('Image model selection unavailable');
    }
    // Image providers talk to their own endpoints over Dio, so nothing in the
    // transport layer sees them: without this the turn that drew a picture
    // showed every request it made except the one that drew it.
    void recordDiagnostic() => LlmRequestCapture.recordAuxiliary(
      stage: captureContext?.stage ?? 'image.generate',
      endpoint: settings.apiType == ImageGenApiType.routmy
          ? settings.routmyMirror.baseUrl
          : settings.apiType == ImageGenApiType.openrouter
          ? ImageOpenRouterDestinations(settings.openrouter.endpoint).generation
          : settings.apiType == ImageGenApiType.novelai
          ? ImageNovelAiDestinations(
              settings.novelai.endpoint,
              settings.novelai.model,
            ).generation
          : settings.useSameEndpoint
          ? llmEndpoint
          : settings.customEndpoint,
      model: _captureModel(settings),
      context: captureContext,
      messages: [
        {'role': 'prompt', 'content': prompt},
      ],
      params: {
        'apiType': settings.apiType.name,
        'referenceCount': references.length,
        'aspectRatio': ?instructionAspectRatio,
        'imageSize': ?instructionImageSize,
      },
    );
    if (settings.apiType != ImageGenApiType.novelai &&
        settings.apiType != ImageGenApiType.naistera)
      recordDiagnostic();
    switch (settings.apiType) {
      case ImageGenApiType.openai:
        return _openai(
          settings,
          prompt,
          references,
          llmEndpoint,
          llmApiKey,
          instructionAspectRatio,
          cancelToken,
        );
      case ImageGenApiType.xai:
        return _xai(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.electronhub:
        return _electronhub(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          cancelToken,
        );
      case ImageGenApiType.gemini:
        return _gemini(
          settings,
          prompt,
          references,
          llmEndpoint,
          llmApiKey,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.openrouter:
        return _openrouter(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken,
        );
      case ImageGenApiType.naistera:
        final owner = naisteraCredentials;
        if (owner == null)
          throw StateError('Native Naistera credential owner unavailable');
        return owner.withApiKey(
          destinations: owner.destinations,
          model: settings.naisteraModel,
          consume: (key, check) {
            check();
            if (!publicNaistera(settings.naisteraModel) ||
                !publicNaistera(
                  NaisteraConstants.normalizeModel(settings.naisteraModel),
                )) {
              throw StateError('Image model selection unavailable');
            }
            return (naisteraClientFactory?.call(
                      owner.destinations.base,
                      check,
                      publicNaistera,
                    ) ??
                    NaisteraImageProvider(
                      baseUrl: owner.destinations.base,
                      checkCurrent: check,
                      isPublicValue: publicNaistera,
                    ))
                .generate(
                  apiKey: key,
                  model: settings.naisteraModel,
                  prompt: prompt,
                  aspectRatio: _validOverride(
                    instructionAspectRatio,
                    NaisteraConstants.aspectRatios,
                    settings.naisteraAspectRatio,
                  ),
                  references: references.isEmpty ? null : references,
                  supportsReferences: settings.naisteraSupportsReferences,
                  cancelToken: cancelToken,
                );
          },
        );
      case ImageGenApiType.routmy:
        return _routmy(
          settings,
          prompt,
          references,
          instructionAspectRatio,
          instructionImageSize,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.a1111:
        return A1111ImageProvider().generate(
          settings: settings.a1111,
          prompt: prompt,
          cancelToken: cancelToken,
        );
      case ImageGenApiType.novelai:
        final owner = novelaiCredentials;
        if (owner == null)
          throw StateError('Native NovelAI credential owner unavailable');
        final destinations = ImageNovelAiDestinations(
          settings.novelai.endpoint,
          settings.novelai.model,
        );
        final publicModel = owner.capturePublicTextGuard(url: true);
        return owner.withApiKey(
          destinations: destinations,
          consume: (key, check) {
            check();
            if (!publicModel(settings.novelai.model))
              throw StateError('Image model selection unavailable');
            // Secure preparation has now registered even retained legacy aliases.
            // A local coordinator need not own the diagnostic global sink; omit a
            // private diagnostic rather than trusting a different sink's coverage.
            if (owner.capturePublicTextGuard(url: true)(prompt))
              recordDiagnostic();
            return (novelaiClientFactory?.call(check) ??
                    NovelAIImageProvider(checkCurrent: check))
                .generate(
                  apiKey: key,
                  settings: settings.novelai.copyWith(apiKey: ''),
                  prompt: prompt,
                  references: references,
                  instructionAspectRatio: instructionAspectRatio,
                  cancelToken: cancelToken,
                );
          },
        );
      case ImageGenApiType.comfyui:
        return ComfyUiImageProvider().generate(
          settings: settings.comfyui,
          prompt: prompt,
          cancelToken: cancelToken,
        );
    }
  }

  /// Best-effort name of the model that will draw: each provider keeps its own
  /// field, and the capture is a diagnostic, not a contract.
  static String _captureModel(ImageGenSettings settings) =>
      switch (settings.apiType) {
        ImageGenApiType.naistera => settings.naisteraModel,
        ImageGenApiType.routmy => settings.routmyModel,
        ImageGenApiType.openrouter => settings.openrouter.model,
        ImageGenApiType.novelai => settings.novelai.model,
        ImageGenApiType.comfyui =>
          settings.comfyui.model.isEmpty
              ? settings.apiType.name
              : settings.comfyui.model,
        _ =>
          settings.customModel.isEmpty
              ? settings.apiType.name
              : settings.customModel,
      };

  Future<Uint8List> _openai(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String llmEndpoint,
    String llmApiKey,
    String? instructionAspectRatio,
    CancelToken? cancelToken,
  ) {
    final endpoint = settings.useSameEndpoint
        ? llmEndpoint
        : settings.customEndpoint;
    final apiKey = settings.useSameEndpoint ? llmApiKey : settings.customApiKey;
    final model = settings.customModel.isEmpty
        ? 'dall-e-3'
        : settings.customModel;

    return OpenaiImageProvider().generate(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      // The configured size wins; a per-tag aspect ratio maps to the size the
      // model family understands.
      size:
          _sizeForAspect(instructionAspectRatio, model) ?? settings.openaiSize,
      quality: settings.openaiQuality,
      referenceImages: _imagesOf(references),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _xai(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) {
    final config = settings.xai;
    return XaiImageProvider(baseUrl: config.endpoint).generate(
      apiKey: config.apiKey,
      model: config.model,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        XaiConstants.aspectRatios,
        config.aspectRatio,
      ),
      // The tag writes `1K` / `2K`; xAI spells them lowercase.
      resolution: _validOverride(
        instructionImageSize?.toLowerCase(),
        XaiConstants.resolutions,
        config.resolution,
      ),
      quality: config.quality,
      references: references,
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _electronhub(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    CancelToken? cancelToken,
  ) {
    final config = settings.electronhub;
    final endpoint = config.endpoint.trim().isEmpty
        ? ElectronHubConstants.defaultEndpoint
        : config.endpoint.trim();

    // Electron Hub's /v1/images/edits takes a single `image` field only.
    return OpenaiImageProvider(allowMultiImageField: false).generate(
      endpoint: endpoint,
      apiKey: config.apiKey,
      model: config.model,
      prompt: prompt,
      size: _sizeForAspect(instructionAspectRatio, config.model) ?? config.size,
      quality: config.quality,
      referenceImages: _imagesOf(references),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _gemini(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String llmEndpoint,
    String llmApiKey,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) {
    final endpoint = settings.useSameEndpoint
        ? llmEndpoint
        : settings.customEndpoint;
    final apiKey = settings.useSameEndpoint ? llmApiKey : settings.customApiKey;
    final model = settings.customModel.isEmpty
        ? 'imagen-3.0-generate-002'
        : settings.customModel;
    final caps = geminiCapabilities(model);

    return GeminiImageProvider().generate(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      prompt: prompt,
      aspectRatio: _validOverride(
        instructionAspectRatio,
        caps.aspectRatios,
        settings.geminiAspectRatio,
      ),
      // Gemini 2.5 Flash Image has no imageSize parameter.
      imageSize: caps.imageSizes == null
          ? null
          : _validOverride(
              instructionImageSize,
              caps.imageSizes!,
              settings.geminiImageSize,
            ),
      referenceImages: references.take(caps.maxReferences).toList(),
      cancelToken: cancelToken,
    );
  }

  Future<Uint8List> _openrouter(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
  ) {
    final config = settings.openrouter;
    final caps = openRouterCapabilities(config.model);
    final owner = openrouterCredentials;
    if (owner == null)
      throw StateError('Native OpenRouter credential owner unavailable');
    final destinations = ImageOpenRouterDestinations(config.endpoint);
    final publicUrl = owner.capturePublicTextGuard(url: true);
    final publicModel = owner.capturePublicTextGuard();
    return owner.withApiKey(
      destinations: destinations,
      consume: (key, checkCurrent) {
        if (!publicModel(config.model))
          throw StateError('Image model selection unavailable');
        return (openrouterClientFactory?.call(checkCurrent, publicUrl) ??
                OpenRouterImageProvider(
                  checkCurrent: checkCurrent,
                  isPublicUrl: publicUrl,
                ))
            .generate(
              apiKey: key,
              endpoint: config.endpoint,
              model: config.model,
              prompt: prompt,
              aspectRatio: _validOverride(
                instructionAspectRatio,
                caps.aspectRatios,
                config.aspectRatio,
              ),
              imageSize: caps.imageSizes == null
                  ? ''
                  : _validOverride(
                      instructionImageSize,
                      caps.imageSizes!,
                      config.imageSize,
                    ),
              references: references,
              cancelToken: cancelToken,
            );
      },
    );
  }

  Future<Uint8List> _routmy(
    ImageGenSettings settings,
    String prompt,
    List<Map<String, String>> references,
    String? instructionAspectRatio,
    String? instructionImageSize, {
    CancelToken? cancelToken,
  }) async {
    final images = _imagesOf(references);
    final owner = routmyCredentials;
    if (owner == null)
      throw StateError('Native rout.my credential owner unavailable');
    try {
      return await owner.withApiKey(
        origin: settings.routmyMirror.baseUrl,
        consume: (apiKey, checkCurrent) =>
            (routmyClientFactory?.call(
                      settings.routmyMirror.baseUrl,
                      checkCurrent,
                    ) ??
                    RoutmyImageProvider(
                      baseUrl: settings.routmyMirror.baseUrl,
                      checkCurrent: checkCurrent,
                    ))
                .generate(
                  apiKey: apiKey,
                  model: settings.routmyModel,
                  // References have no captions — name them in the prompt.
                  prompt: imagePromptWithReferenceLabels(prompt, references),
                  aspectRatio: _validOverride(
                    instructionAspectRatio,
                    RoutMyConstants.aspectRatios,
                    settings.routmyAspectRatio,
                  ),
                  imageSize: _validOverride(
                    instructionImageSize,
                    RoutMyConstants.imageSizes,
                    settings.routmyImageSize,
                  ),
                  quality: settings.routmyQuality,
                  referenceImages: images,
                  cancelToken: cancelToken,
                ),
      );
    } catch (_) {
      if (cancelToken?.isCancelled == true) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: settings.routmyMirror.baseUrl),
          reason: 'Image generation cancelled',
        );
      }
      rethrow;
    }
  }

  /// `size` for a per-tag aspect ratio on the OpenAI images API, or null when
  /// the tag carried no (usable) ratio for this model family.
  static String? _sizeForAspect(String? instructionAspectRatio, String model) {
    final aspect = instructionAspectRatio?.trim();
    if (aspect == null || !OpenAIConstants.aspectRatios.contains(aspect)) {
      return null;
    }
    return openAiAspectRatioToSize(aspect, classifyOpenAiImageModel(model));
  }

  static List<String>? _imagesOf(List<Map<String, String>> references) {
    final images = references
        .map((ref) => ref['image'] ?? '')
        .where((image) => image.isNotEmpty)
        .toList();
    return images.isEmpty ? null : images;
  }

  /// Accepts a per-tag override only when the provider/model allows it.
  static String _validOverride(
    String? override,
    List<String> allowed,
    String fallback,
  ) {
    final value = override?.trim();
    return value != null && allowed.contains(value) ? value : fallback;
  }
}
