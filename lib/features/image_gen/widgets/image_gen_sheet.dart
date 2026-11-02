import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../../../core/models/api_config.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/utils/platform_paths.dart';
import '../../character_gallery/gallery_image_picker.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/widgets/connection_status.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/help_tip.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import '../image_gen_provider.dart';
import '../services/image_gen_connection_service.dart';
import '../services/image_gen_service.dart' show ImageGenErrorSanitizer;
import 'a1111_fields.dart';
import 'comfyui_fields.dart';
import 'comfyui_workflow_sheet.dart';
import 'connection_fields.dart';
import 'model_fields.dart';
import 'novelai_fields.dart';
import 'openrouter_fields.dart';
import 'reference_library_section.dart';
import 'rows.dart' as rows;
import 'style_library_sheet.dart';
import 'xai_fields.dart';

class ImageGenSheet extends ConsumerStatefulWidget {
  const ImageGenSheet({super.key, this.charId, this.connectionDio});

  final String? charId;

  /// Trusted HTTP fixture only; native owners/recipients are still composed here.
  final Dio? connectionDio;

  @override
  ConsumerState<ImageGenSheet> createState() => _ImageGenSheetState();
}

class _ImageGenSheetState extends ConsumerState<ImageGenSheet> {
  late ImageGenSettings _settings;
  bool _isFetchingModels = false;
  late final ImageGenConnectionService _connectionService;
  late final bool Function(String) _publicRoutmyText;
  late final bool Function(String) _publicOpenRouterText;
  late final bool Function(String) _publicNovelAiValue;
  late final bool Function(String) _publicNaisteraValue;
  late final ImageGenErrorSanitizer _errors;
  final ScrollController _scrollController = ScrollController();
  int _connectionEpoch = 0;
  ApiConnectionStatus _connectionStatus = ApiConnectionStatus.idle;
  String _connectionError = '';
  String _modelFetchError = '';

  @override
  void initState() {
    super.initState();
    _publicRoutmyText = ref
        .read(imageRoutmyCredentialOwnerProvider)
        .capturePublicTextGuard();
    _errors = ImageGenErrorSanitizer(
      routmyCredentials: ref.read(imageRoutmyCredentialOwnerProvider),
      openrouterCredentials: ref.read(imageOpenRouterCredentialOwnerProvider),
      novelaiCredentials: ref.read(imageNovelAiCredentialOwnerProvider),
      naisteraCredentials: ref.read(imageNaisteraCredentialOwnerProvider),
    );
    _connectionService = ImageGenConnectionService(
      dio: widget.connectionDio,
      routmyCredentials: ref.read(imageRoutmyCredentialOwnerProvider),
      openrouterCredentials: ref.read(imageOpenRouterCredentialOwnerProvider),
      novelaiCredentials: ref.read(imageNovelAiCredentialOwnerProvider),
      naisteraCredentials: ref.read(imageNaisteraCredentialOwnerProvider),
    );
    _publicOpenRouterText = ref
        .read(imageOpenRouterCredentialOwnerProvider)
        .capturePublicTextGuard();
    _settings =
        // Original captured owner remains in the sheet and open pickers.
        ref.read(imageGenSettingsProvider).value ?? const ImageGenSettings();
    _publicNovelAiValue = ref
        .read(imageNovelAiCredentialOwnerProvider)
        .capturePublicTextGuard(url: true);
    _publicNaisteraValue = ref
        .read(imageNaisteraCredentialOwnerProvider)
        .capturePublicTextGuard();
  }

  void _update(ImageGenSettings s, {bool Function()? ownsNaisteraCatalog}) {
    if (!_publicNovelAiValue(s.novelai.model) ||
        !_publicOpenRouterText(s.openrouter.model) ||
        !_publicRoutmyText(s.routmyModel) ||
        !s.routmyModels.every(
          (model) =>
              _publicRoutmyText(model.id) && _publicRoutmyText(model.name),
        )) {
      if (mounted)
        setState(() => _connectionError = 'Image model selection unavailable');
      return;
    }
    final displayedNovelAiBefore = _displayNovelAi(_settings.novelai);
    final displayedNaisteraModelBefore = _displayNaistera(
      _settings,
    ).naisteraModel;
    final connectionChanged = _hasConnectionChanged(_settings, s);
    s = _displayNaistera(s);
    _settings = s;
    ref
        .read(imageGenSettingsProvider.notifier)
        .save(
          s,
          displayedNovelAiBefore: displayedNovelAiBefore,
          displayedNaisteraModelBefore: displayedNaisteraModelBefore,
          ownsNaisteraCatalog: ownsNaisteraCatalog,
        )
        .catchError((Object _) {
          if (mounted) {
            setState(
              () => _connectionError = 'Image settings could not be saved',
            );
          }
        });
    // Nothing is probed automatically — but a verdict about the old endpoint
    // must not linger once the connection settings change under it.
    if (!s.enabled || connectionChanged) {
      _connectionEpoch++;
      _connectionStatus = ApiConnectionStatus.idle;
      _connectionError = '';
    }
    if (mounted) setState(() {});
  }

  NovelAIImageSettings _displayNovelAi(
    NovelAIImageSettings settings,
  ) => settings.copyWith(
    apiKey: '',
    model: _publicNovelAiValue(settings.model) ? settings.model : '',
    endpoint: _publicNovelAiValue(settings.endpoint) ? settings.endpoint : '',
    negativePrompt: _publicNovelAiValue(settings.negativePrompt)
        ? settings.negativePrompt
        : '',
    sampler: _publicNovelAiValue(settings.sampler) ? settings.sampler : '',
    noiseSchedule: _publicNovelAiValue(settings.noiseSchedule)
        ? settings.noiseSchedule
        : '',
    ucPreset: _publicNovelAiValue(settings.ucPreset) ? settings.ucPreset : '',
  );

  ImageGenSettings _displayNaistera(ImageGenSettings s) => s.copyWith(
    naisteraApiKey: '',
    naisteraModel:
        _publicNaisteraValue(s.naisteraModel) &&
            _publicNaisteraValue(
              NaisteraConstants.normalizeModel(s.naisteraModel),
            )
        ? s.naisteraModel
        : '',
    naisteraModels: s.naisteraModels
        .where(
          (m) =>
              _publicNaisteraValue(m.id) &&
              _publicNaisteraValue(m.name) &&
              _publicNaisteraValue(NaisteraConstants.normalizeModel(m.id)),
        )
        .toList(),
  );

  @override
  void dispose() {
    _connectionService.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _hasConnectionChanged(ImageGenSettings before, ImageGenSettings after) =>
      before.apiType != after.apiType ||
      before.useSameEndpoint != after.useSameEndpoint ||
      before.customEndpoint != after.customEndpoint ||
      before.customApiKey != after.customApiKey ||
      before.naisteraModel != after.naisteraModel ||
      before.xai.apiKey != after.xai.apiKey ||
      before.xai.endpoint != after.xai.endpoint ||
      before.routmyMirror != after.routmyMirror ||
      before.openrouter.apiKey != after.openrouter.apiKey ||
      before.openrouter.endpoint != after.openrouter.endpoint ||
      before.electronhub.apiKey != after.electronhub.apiKey ||
      before.electronhub.endpoint != after.electronhub.endpoint ||
      before.a1111.endpoint != after.a1111.endpoint ||
      before.a1111.apiKey != after.a1111.apiKey ||
      before.novelai.endpoint != after.novelai.endpoint ||
      before.novelai.apiKey != after.novelai.apiKey ||
      before.novelai.model != after.novelai.model ||
      before.comfyui.endpoint != after.comfyui.endpoint ||
      before.comfyui.apiKey != after.comfyui.apiKey;

  void _invalidateRoutmyAuth() {
    _connectionEpoch++;
    _connectionStatus = ApiConnectionStatus.idle;
    _connectionError = '';
    _modelFetchError = '';
    if (mounted) setState(() {});
  }

  /// Probes the provider. Only ever runs from a tap on the status badge — the
  /// sheet never reaches out on its own.
  Future<void> _checkConnection() async {
    final settings = _settings;
    if (!settings.enabled) return;
    final ownsAuth = settings.apiType == ImageGenApiType.routmy
        ? ref.read(imageRoutmyCredentialOwnerProvider).captureGuard()
        : settings.apiType == ImageGenApiType.openrouter
        ? ref.read(imageOpenRouterCredentialOwnerProvider).captureGuard()
        : settings.apiType == ImageGenApiType.novelai
        ? ref.read(imageNovelAiCredentialOwnerProvider).captureGuard()
        : settings.apiType == ImageGenApiType.naistera
        ? ref.read(imageNaisteraCredentialOwnerProvider).captureGuard()
        : () => true;
    final epoch = ++_connectionEpoch;
    setState(() {
      _connectionStatus = ApiConnectionStatus.connecting;
      _connectionError = '';
    });
    final apiConfig = ref.read(activeApiConfigProvider);
    try {
      await _connectionService.checkConnection(
        settings: settings,
        llmEndpoint: apiConfig?.endpoint ?? '',
        llmApiKey: apiConfig?.apiKey ?? '',
      );
      if (!mounted || !ownsAuth() || epoch != _connectionEpoch) return;
      setState(() => _connectionStatus = ApiConnectionStatus.connected);
    } catch (error) {
      if (!mounted || !ownsAuth() || epoch != _connectionEpoch) return;
      setState(() {
        _connectionStatus = ApiConnectionStatus.failed;
        _connectionError = _errors
            .sanitize(error.toString())
            .replaceFirst('Bad state: ', '');
      });
    }
  }

  void _showOptions<T>({
    required String title,
    required List<T> items,
    required String Function(T) labelBuilder,
    required bool Function(T) isSelected,
    required void Function(T) onSelected,
    bool Function(String)? isPublicText,
  }) {
    rows.showImageGenOptions<T>(
      context,
      title: title,
      items: items,
      labelBuilder: labelBuilder,
      isSelected: isSelected,
      onSelected: onSelected,
      isPublicText: isPublicText,
    );
  }

  void _openApiTypeSelector() {
    _showOptions<ImageGenApiType>(
      title: 'imggen_api_type'.tr(),
      items: ImageGenApiType.values,
      labelBuilder: (t) => t.label,
      isSelected: (t) => _settings.apiType == t,
      onSelected: (t) => _update(_settings.copyWith(apiType: t)),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(errorRedactionPolicyRevisionProvider);
    ref.watch(secretRedactorProvider);
    // A mixed-document write can retire another family's pending auth load.
    // Its unavailable summary is not a change to this provider's connection.
    ref.listen(imageNaisteraAuthProvider, (previous, next) {
      if (_settings.apiType == ImageGenApiType.naistera &&
          (previous?.value?.revision != next.value?.revision ||
              previous?.value?.unavailable != next.value?.unavailable))
        _invalidateRoutmyAuth();
    });
    ref.listen(imageNovelAiAuthProvider, (previous, next) {
      if (_settings.apiType == ImageGenApiType.novelai &&
          (previous?.value?.revision != next.value?.revision ||
              previous?.value?.unavailable != next.value?.unavailable))
        _invalidateRoutmyAuth();
    });
    ref.listen(imageOpenRouterAuthProvider, (previous, next) {
      if (_settings.apiType == ImageGenApiType.openrouter &&
          (previous?.value?.revision != next.value?.revision ||
              previous?.value?.unavailable != next.value?.unavailable)) {
        _invalidateRoutmyAuth();
      }
    });
    ref.listen(imageRoutmyAuthProvider, (previous, next) {
      if (_settings.apiType == ImageGenApiType.routmy &&
          (previous?.value?.revision != next.value?.revision ||
              previous?.value?.unavailable != next.value?.unavailable)) {
        _invalidateRoutmyAuth();
      }
    });
    final s = _displayNaistera(
      _settings,
    ).copyWith(novelai: _displayNovelAi(_settings.novelai));

    return SheetView(
      titleWidget: Row(
        children: [
          Text(
            'section_image_gen'.tr(),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const HelpTip(term: 'image-gen'),
          const Spacer(),
          Switch(
            value: s.enabled,
            onChanged: (v) => _update(s.copyWith(enabled: v)),
          ),
        ],
      ),
      fitContent: false,
      scrollController: _scrollController,
      enableHeaderBlur: false,
      body: s.enabled ? _buildBody(context, s) : _buildDisabledPlaceholder(),
    );
  }

  /// Shown instead of the settings when generation is off, so the sheet does
  /// not read as broken or empty.
  Widget _buildDisabledPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: 56,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'imggen_disabled_placeholder'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ImageGenSettings s) {
    return Builder(
      builder: (context) => SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ConnectionStatus(
                status: _connectionStatus,
                errorMessage: _errors.sanitize(_connectionError),
                onRetry: _checkConnection,
                child: _buildPresetSelector(s.apiType),
              ),
            ),
            MenuGroup(
              header: 'imggen_connection'.tr(),
              items: _buildConnectionFields(s),
            ),
            MenuGroup(header: 'Model', items: _buildModelFields(s)),
            if (_modelFetchError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  _errors.sanitize(_modelFetchError),
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            MenuGroup(
              header: 'imggen_generation'.tr(),
              items: [
                MenuSwitchItem(
                  label: 'imggen_concurrent'.tr(),
                  description: 'imggen_concurrent_desc'.tr(),
                  value: s.concurrentGeneration,
                  onChanged: (v) =>
                      _update(s.copyWith(concurrentGeneration: v)),
                ),
              ],
            ),
            MenuGroup(
              header: 'imggen_styles'.tr(),
              items: [
                MenuSelectorItem(
                  label: 'imggen_style_active'.tr(),
                  currentValue: s.activeStyle?.name ?? 'imggen_style_none'.tr(),
                  onTap: _openStyleLibrary,
                ),
              ],
            ),
            if (providerMaxReferences(s) == 0)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.cs.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  border: Border.all(color: context.cs.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    'imggen_no_refs_hint'.tr(),
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              )
            else ...[
              ...buildReferenceSections(
                context: context,
                settings: s,
                maxReferences: providerMaxReferences(s),
                onUpdate: _update,
                pickImage: _pickReferenceImage,
              ),
              MenuGroup(
                header: 'Image Context',
                items: [
                  MenuSwitchItem(
                    label: 'Send previous images as context',
                    description: 'imggen_image_context_desc'.tr(),
                    value: s.imageContextEnabled,
                    onChanged: (v) =>
                        _update(s.copyWith(imageContextEnabled: v)),
                  ),
                  if (s.imageContextEnabled)
                    MenuSelectorItem(
                      label: 'Context image count',
                      currentValue: s.imageContextCount.toString(),
                      onTap: () {
                        _showOptions<int>(
                          title: 'Context image count',
                          items: [1, 2, 3],
                          labelBuilder: (i) => i.toString(),
                          isSelected: (i) => s.imageContextCount == i,
                          onSelected: (i) =>
                              _update(s.copyWith(imageContextCount: i)),
                        );
                      },
                    ),
                ],
              ),
            ],
            MenuGroup(
              header: 'imggen_tag_hint_title'.tr(),
              description: 'imggen_tag_hint_desc'.tr(),
              items: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: SelectableText(
                    '[IMG:GEN:{"prompt":"...","style":"anime"}]',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: context.cs.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The API-type pill. Sits left of the connection-status badge, mirroring
  /// the preset pill in the API settings screen.
  Widget _buildPresetSelector(ImageGenApiType selected) {
    return InkWell(
      onTap: _openApiTypeSelector,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selected.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: context.cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildConnectionFields(ImageGenSettings s) {
    switch (s.apiType) {
      case ImageGenApiType.naistera:
        return buildNaisteraConnectionFields(s, _update, _invalidateRoutmyAuth);
      case ImageGenApiType.routmy:
        return buildRoutmyConnectionFields(
          s,
          context,
          _update,
          _invalidateRoutmyAuth,
        );
      case ImageGenApiType.xai:
        return buildXaiConnectionFields(s, _update);
      case ImageGenApiType.openrouter:
        return buildOpenRouterConnectionFields(
          s,
          _update,
          _invalidateRoutmyAuth,
        );
      case ImageGenApiType.electronhub:
        return buildElectronHubConnectionFields(s, _update);
      case ImageGenApiType.a1111:
        return buildA1111ConnectionFields(s, _update);
      case ImageGenApiType.novelai:
        return buildNovelAiConnectionFields(s, _update, _invalidateRoutmyAuth);
      case ImageGenApiType.comfyui:
        return buildComfyUiConnectionFields(s, _update);
      case ImageGenApiType.openai:
      case ImageGenApiType.gemini:
        return buildOpenaiConnectionFields(s, _update);
    }
  }

  void _openStyleLibrary() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StyleLibrarySheet(settings: _settings, onUpdate: _update),
    );
  }

  void _openComfyUiWorkflows() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ComfyUiWorkflowSheet(
        settings: _settings.comfyui,
        onUpdate: (comfyui) => _update(_settings.copyWith(comfyui: comfyui)),
      ),
    );
  }

  List<Widget> _buildModelFields(ImageGenSettings s) {
    final showOptions = _showOptionsCallback();
    switch (s.apiType) {
      case ImageGenApiType.naistera:
        return buildNaisteraModelFields(
          s,
          isPublicText: _publicNaisteraValue,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.xai:
        return buildXaiModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.routmy:
        return buildRoutmyModelFields(
          s,
          isPublicText: _publicRoutmyText,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.openai:
        return buildOpenaiModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.gemini:
        return buildGeminiModelFields(s, _update, showOptions);
      case ImageGenApiType.openrouter:
        return buildOpenRouterModelFields(
          s,
          isPublicText: _publicOpenRouterText,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.electronhub:
        return buildElectronHubModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.a1111:
        return buildA1111ModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.novelai:
        return buildNovelAiModelFields(
          s,
          isPublicText: _publicNovelAiValue,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.comfyui:
        return buildComfyUiModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onManageWorkflows: _openComfyUiWorkflows,
          onUpdate: _update,
          showOptions: showOptions,
        );
    }
  }

  ShowOptionsCallback _showOptionsCallback() {
    final originalType = _settings.apiType;
    final originalNaistera = originalType == ImageGenApiType.naistera
        ? ref.read(imageNaisteraCredentialOwnerProvider)
        : null;
    final ownsNaistera = originalNaistera?.captureGuard();
    final publicText = switch (_settings.apiType) {
      ImageGenApiType.routmy => _publicRoutmyText,
      ImageGenApiType.openrouter => _publicOpenRouterText,
      ImageGenApiType.novelai => _publicNovelAiValue,
      ImageGenApiType.naistera => _publicNaisteraValue,
      _ => null,
    };
    return <T>({
      required String title,
      required List<T> items,
      required String Function(T) labelBuilder,
      required bool Function(T) isSelected,
      required void Function(T) onSelected,
    }) {
      _showOptions<T>(
        title: title,
        items: items,
        labelBuilder: labelBuilder,
        isSelected: isSelected,
        onSelected: onSelected,
        isPublicText: originalNaistera == null
            ? publicText
            : (value) =>
                  mounted &&
                  _settings.apiType == originalType &&
                  ownsNaistera!() &&
                  identical(
                    ref.read(imageNaisteraCredentialOwnerProvider),
                    originalNaistera,
                  ) &&
                  publicText!(value),
      );
    };
  }

  /// Model discovery differs per provider: OpenAI-style `/v1/models` for the
  /// OpenAI and Gemini paths, filtered listings for OpenRouter and Electron
  /// Hub, and loaded checkpoints for a local AUTOMATIC1111 server.
  Future<List<String>> _fetchModelsForProvider(ApiConfig? apiConfig) {
    switch (_settings.apiType) {
      case ImageGenApiType.openrouter:
        return _connectionService.fetchOpenRouterModels(_settings);
      case ImageGenApiType.electronhub:
        return _connectionService.fetchElectronHubModels(_settings);
      case ImageGenApiType.a1111:
        return _connectionService.fetchA1111Models(_settings);
      case ImageGenApiType.novelai:
        // No model-listing endpoint — the shipped catalog is the catalog.
        return Future.value(
          NovelAIConstants.models.map((model) => model.$1).toList(),
        );
      case ImageGenApiType.comfyui:
        return _connectionService.fetchComfyUiModels(_settings);
      case ImageGenApiType.xai:
        return _connectionService.fetchXaiModels(_settings);
      case ImageGenApiType.naistera:
        return _fetchNaisteraModels();
      case ImageGenApiType.routmy:
        return _fetchRoutmyModels();
      case ImageGenApiType.openai:
      case ImageGenApiType.gemini:
        return _connectionService.fetchOpenAiModels(
          settings: _settings,
          llmEndpoint: apiConfig?.endpoint ?? '',
          llmApiKey: apiConfig?.apiKey ?? '',
        );
    }
  }

  /// Loads the Naistera catalog and stores it in the settings, so reference
  /// support and the model labels follow the API instead of the shipped list.
  Future<List<String>> _fetchNaisteraModels() async {
    final settings = _settings;
    final epoch = _connectionEpoch;
    final owner = ref.read(imageNaisteraCredentialOwnerProvider);
    final custody = owner.captureGuard();
    final lifetime = owner.captureAuthPublicationGuard();
    bool current() =>
        mounted &&
        lifetime() &&
        epoch == _connectionEpoch &&
        _settings.apiType == ImageGenApiType.naistera &&
        identical(ref.read(imageNaisteraCredentialOwnerProvider), owner);
    final catalog = await _connectionService.fetchNaisteraModels(settings);
    if (!current() || !custody()) return const [];
    final publicCatalog = catalog
        .where(
          (m) =>
              _publicNaisteraValue(m.id) &&
              _publicNaisteraValue(m.name) &&
              _publicNaisteraValue(NaisteraConstants.normalizeModel(m.id)),
        )
        .toList();
    if (publicCatalog.isEmpty) return const [];
    // Guard precedes the original queued write, not merely the outer picker.
    final next = _displayNaistera(
      _settings.copyWith(naisteraModels: publicCatalog),
    );
    await ref
        .read(imageGenSettingsProvider.notifier)
        .save(
          next,
          displayedNovelAiBefore: _displayNovelAi(_settings.novelai),
          displayedNaisteraModelBefore: _displayNaistera(
            _settings,
          ).naisteraModel,
          ownsNaisteraCatalog: current,
        );
    if (!current()) return const [];
    _settings = _displayNaistera(next);
    return publicCatalog
        .where(
          (m) =>
              current() &&
              _publicNaisteraValue(m.id) &&
              _publicNaisteraValue(m.name),
        )
        .map((m) => m.id)
        .toList();
  }

  /// Loads the rout.my catalog and stores it with the `/images/edits`
  /// capability each entry advertises, so the reference gate follows the API.
  Future<List<String>> _fetchRoutmyModels() async {
    final settings = _settings;
    final epoch = _connectionEpoch;
    final current = ref.read(imageRoutmyCredentialOwnerProvider).captureGuard();
    final catalog = await _connectionService.fetchRoutmyModels(settings);
    if (!mounted || !current() || epoch != _connectionEpoch || catalog.isEmpty)
      return const [];
    final publicCatalog = catalog
        .where(
          (model) =>
              _publicRoutmyText(model.id) && _publicRoutmyText(model.name),
        )
        .toList();
    if (publicCatalog.isEmpty) return const [];
    _update(_settings.copyWith(routmyModels: publicCatalog));
    return publicCatalog.map((model) => model.id).toList();
  }

  bool _isSelectedModel(String model) => switch (_settings.apiType) {
    ImageGenApiType.openrouter => _settings.openrouter.model == model,
    ImageGenApiType.xai => _settings.xai.model == model,
    ImageGenApiType.naistera => _settings.naisteraModel == model,
    ImageGenApiType.routmy => _settings.routmyModel == model,
    ImageGenApiType.electronhub => _settings.electronhub.model == model,
    ImageGenApiType.a1111 => _settings.a1111.model == model,
    ImageGenApiType.novelai => _settings.novelai.model == model,
    ImageGenApiType.comfyui => _settings.comfyui.model == model,
    _ => _settings.customModel == model,
  };

  void _applyModel(String model) {
    switch (_settings.apiType) {
      case ImageGenApiType.openrouter:
        _update(
          _settings.copyWith(
            openrouter: _settings.openrouter.copyWith(model: model),
          ),
        );
      case ImageGenApiType.electronhub:
        _update(
          _settings.copyWith(
            electronhub: _settings.electronhub.copyWith(model: model),
          ),
        );
      case ImageGenApiType.a1111:
        _update(
          _settings.copyWith(a1111: _settings.a1111.copyWith(model: model)),
        );
      case ImageGenApiType.comfyui:
        _update(
          _settings.copyWith(comfyui: _settings.comfyui.copyWith(model: model)),
        );
      case ImageGenApiType.xai:
        _update(_settings.copyWith(xai: _settings.xai.copyWith(model: model)));
      case ImageGenApiType.naistera:
        _update(_settings.copyWith(naisteraModel: model));
      case ImageGenApiType.routmy:
        _update(_settings.copyWith(routmyModel: model));
      case ImageGenApiType.novelai:
        _update(
          _settings.copyWith(novelai: _settings.novelai.copyWith(model: model)),
        );
      default:
        _update(_settings.copyWith(customModel: model));
    }
  }

  Future<void> _onFetchModels() async {
    final provider = _settings.apiType;
    final routmy = _settings.apiType == ImageGenApiType.routmy;
    final openrouter = _settings.apiType == ImageGenApiType.openrouter;
    final novelai = _settings.apiType == ImageGenApiType.novelai;
    final naistera = _settings.apiType == ImageGenApiType.naistera;
    final originalNaistera = naistera
        ? ref.read(imageNaisteraCredentialOwnerProvider)
        : null;
    final publicText = routmy
        ? _publicRoutmyText
        : openrouter
        ? _publicOpenRouterText
        : novelai
        ? _publicNovelAiValue
        : naistera
        ? _publicNaisteraValue
        : null;
    final epoch = _connectionEpoch;
    final ownsRoutmy = routmy
        ? ref.read(imageRoutmyCredentialOwnerProvider).captureGuard()
        : openrouter
        ? ref.read(imageOpenRouterCredentialOwnerProvider).captureGuard()
        : novelai
        ? ref.read(imageNovelAiCredentialOwnerProvider).captureGuard()
        : naistera
        ? ref
              .read(imageNaisteraCredentialOwnerProvider)
              .captureAuthPublicationGuard()
        : () => true;
    bool current() =>
        mounted &&
        ownsRoutmy() &&
        (!(routmy || openrouter || novelai || naistera) ||
            epoch == _connectionEpoch);
    setState(() => _isFetchingModels = true);
    final apiConfig = ref.read(activeApiConfigProvider);
    try {
      final fetched = await _fetchModelsForProvider(apiConfig);
      final models = openrouter
          ? fetched.where(_publicOpenRouterText).toList()
          : novelai
          ? fetched.where(_publicNovelAiValue).toList()
          : fetched;
      if (!current()) return;
      if (models.isEmpty) {
        setState(() => _modelFetchError = 'imggen_no_models'.tr());
        return;
      }
      setState(() => _modelFetchError = '');
      final catalogOwner = originalNaistera?.captureGuard();
      bool publicSelection(String value) =>
          (publicText?.call(value) ?? true) &&
          (!naistera ||
              current() &&
                  catalogOwner!() &&
                  identical(
                    ref.read(imageNaisteraCredentialOwnerProvider),
                    originalNaistera,
                  ));
      _showOptions<String>(
        title: 'Image models',
        items: models,
        labelBuilder: (model) =>
            publicSelection(model) ? model : 'Model unavailable',
        isSelected: _isSelectedModel,
        onSelected: (model) {
          if (!current() ||
              _settings.apiType != provider ||
              !publicSelection(model))
            return;
          _applyModel(model);
        },
        isPublicText: naistera ? publicSelection : publicText,
      );
    } catch (error) {
      if (!current()) return;
      setState(
        () => _modelFetchError = _errors
            .sanitize(error.toString())
            .replaceFirst('Bad state: ', ''),
      );
    } finally {
      if (mounted) setState(() => _isFetchingModels = false);
    }
  }

  Future<String?> _pickReferenceImage() async {
    final source = await GlazeBottomSheet.show<String>(
      context,
      title: 'imggen_ref_pick_title'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.folder_open,
          label: 'imggen_ref_pick_device'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('device'),
        ),
        if (widget.charId != null)
          BottomSheetItem(
            icon: Icons.photo_library_outlined,
            label: 'imggen_ref_pick_gallery'.tr(),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('gallery'),
          ),
      ],
    );
    if (!mounted || source == null) return null;

    if (source == 'gallery') {
      final entry = await showCharacterGalleryImagePicker(
        context,
        charId: widget.charId!,
      );
      if (entry == null) return null;
      final path = resolveGlazeFilePath(entry.imagePath) ?? entry.imagePath;
      return _fileToDataUrl(File(path), path);
    }

    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes =
        picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) return null;
    return 'data:${_imageMime(picked.name)};base64,${base64Encode(bytes)}';
  }

  Future<String?> _fileToDataUrl(File file, String path) async {
    try {
      if (!await file.exists()) return null;
      return 'data:${_imageMime(path)};base64,${base64Encode(await file.readAsBytes())}';
    } catch (_) {
      return null;
    }
  }

  String _imageMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }
}
