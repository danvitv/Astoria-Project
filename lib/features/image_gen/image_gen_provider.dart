import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/credentials/image_routmy_credential_owner.dart';
import '../../../core/credentials/image_routmy_legacy_source.dart';
import '../../../core/credentials/image_openrouter_credential_owner.dart';
import '../../../core/credentials/image_openrouter_legacy_source.dart';
import '../../../core/credentials/image_novelai_credential_owner.dart';
import '../../../core/credentials/image_novelai_legacy_source.dart';
import '../../../core/credentials/image_naistera_credential_owner.dart';
import '../../../core/credentials/image_naistera_legacy_source.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/credentials/credential_vault.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import 'image_gen_models.dart';
import 'image_gen_settings_codec.dart';
import 'image_openrouter_auth_provider.dart';
import 'image_novelai_auth_provider.dart';
import 'image_naistera_auth_provider.dart';
import 'services/image_gen_service.dart';

export 'image_openrouter_auth_provider.dart';
export 'image_novelai_auth_provider.dart';
export 'image_naistera_auth_provider.dart';

final imageRoutmyCredentialOwnerProvider = Provider<ImageRoutmyCredentialOwner>(
  (ref) {
    final owner = ImageRoutmyCredentialOwner(
      vault: ref.watch(credentialVaultProvider),
      redaction: ref.watch(secretRedactionCoordinatorProvider),
      originalPreferences: ref.read(sharedPreferencesProvider.future),
    );
    ref.onDispose(owner.dispose);
    return owner;
  },
);

final imageRoutmyAuthProvider =
    AsyncNotifierProvider<ImageRoutmyAuthNotifier, ImageRoutmyAuthSummary>(
      ImageRoutmyAuthNotifier.new,
    );

class ImageRoutmyAuthNotifier extends AsyncNotifier<ImageRoutmyAuthSummary> {
  int _intent = 0;

  @override
  Future<ImageRoutmyAuthSummary> build() =>
      ref.watch(imageRoutmyCredentialOwnerProvider).load();

  Future<void> setApiKey(String input) async {
    final owner = ref.read(imageRoutmyCredentialOwnerProvider);
    final intent = ++_intent;
    // Native setter owns admission synchronously, not a provider-state save.
    final pending = owner.setApiKey(input);
    final ownsPublication = owner.captureAuthPublicationGuard();
    try {
      final summary = await pending;
      if (ref.mounted &&
          intent == _intent &&
          ownsPublication() &&
          owner.isCurrentSummary(summary)) {
        state = AsyncData(summary);
      }
    } on CredentialVaultAdmissionDenied {
      // Retirement is not a protected-storage outage. The newer owner/intent
      // supplies its own summary; do not repaint it with a stale failure.
    } catch (_) {
      if (ref.mounted && intent == _intent && ownsPublication()) {
        state = const AsyncData(ImageRoutmyAuthSummary(unavailable: true));
      }
    }
  }
}

final imageGenSettingsProvider =
    AsyncNotifierProvider<ImageGenSettingsNotifier, ImageGenSettings>(
      ImageGenSettingsNotifier.new,
    );

class ImageGenSettingsNotifier extends AsyncNotifier<ImageGenSettings> {
  static const _key = 'gz_imggen_settings';
  int _intent = 0;
  late ImageRoutmyCredentialOwner _routmy;
  late ImageOpenRouterCredentialOwner _openrouter;
  late ImageNovelAiCredentialOwner _novelai;
  late ImageNaisteraCredentialOwner _naistera;

  @override
  Future<ImageGenSettings> build() async {
    _intent++;
    _service = null;
    _routmy = ref.watch(imageRoutmyCredentialOwnerProvider);
    _openrouter = ref.watch(imageOpenRouterCredentialOwnerProvider);
    _novelai = ref.watch(imageNovelAiCredentialOwnerProvider);
    _naistera = ref.watch(imageNaisteraCredentialOwnerProvider);
    final redaction = ref.watch(secretRedactionCoordinatorProvider);
    void projectNewAliases(SecretRedactor _) {
      final current = state.value;
      if (ref.mounted && current != null) {
        state = AsyncData(_publicModels(current));
      }
    }

    // A newly entered native secret may equal an already-public model alias.
    // Reproject native state synchronously; this never rewrites private JSON.
    redaction.addListener(projectNewAliases);
    ref.onDispose(() => redaction.removeListener(projectNewAliases));
    ref.listen(
      errorRedactionPolicyRevisionProvider,
      (_, next) => projectNewAliases(redaction.redactor),
    );
    final lease = _naistera.source.captureSettings();
    final prefs = await _naistera.source.preferences(lease, () => ref.mounted);
    final raw = prefs.get(_key);
    if (raw != null) {
      final json = ImageRoutmyLegacySource.decode(raw)!;
      final safe =
          ImageNaisteraLegacySource.withoutSecret(
              ImageNovelAiLegacySource.withoutSecret(
                ImageOpenRouterLegacySource.withoutSecret(json),
              ),
            )
            ..remove('routmyApiKey')
            ..remove('ruRoutmyApiKey');
      // Seed only the image slot before ordinary native saves can retire the
      // original legacy revision. This is secure import, never a network probe.
      await _routmy.load();
      await _openrouter.load();
      await _novelai.load();
      if (json.containsKey('naisteraApiKey') || json['apiType'] == 'naistera') {
        await _naistera.load();
      }
      await _naistera.source.preferences(lease, () => ref.mounted);
      // Secret never hydrates the immutable settings/provider snapshot.
      return _publicModels(ImageGenSettingsCodec.fromJson(safe));
    }
    await _routmy.load();
    await _openrouter.load();
    await _novelai.load();
    if (prefs.containsKey(ImageNaisteraLegacySource.standaloneKey) ||
        prefs.get(ImageNaisteraLegacySource.apiTypeKey) == 'naistera') {
      await _naistera.load();
    }
    await _naistera.source.preferences(lease, () => ref.mounted);
    final migrated = await _migrateFromJsKeys(prefs);
    if (migrated != null) return _publicModels(migrated);
    return const ImageGenSettings();
  }

  Future<ImageGenSettings?> _migrateFromJsKeys(SharedPreferences prefs) async {
    final apiType = prefs.getString('gz_imggen_api_type');
    if (apiType == null) return null;
    final settings = ImageGenSettings(
      enabled: _safeBool(prefs, 'gz_imggen_enabled', false),
      apiType: ImageGenSettingsCodec.parseApiType(apiType),
      useSameEndpoint: _safeBool(prefs, 'gz_imggen_use_same', true),
      customEndpoint: prefs.getString('gz_imggen_endpoint') ?? '',
      customApiKey: prefs.getString('gz_imggen_api_key') ?? '',
      customModel: prefs.getString('gz_imggen_model') ?? '',
      openaiSize: prefs.getString('gz_imggen_image_size') ?? '1024x1024',
      openaiQuality: prefs.getString('gz_imggen_quality') ?? 'standard',
      geminiAspectRatio: prefs.getString('gz_imggen_aspect_ratio') ?? '1:1',
      geminiImageSize: prefs.getString('gz_imggen_gemini_image_size') ?? '1K',
      routmyModel:
          prefs.getString('gz_imggen_routmy_model') ??
          'google/gemini-3.1-flash-image-preview',
      routmyAspectRatio:
          prefs.getString('gz_imggen_routmy_aspect_ratio') ?? '1:1',
      routmyImageSize: prefs.getString('gz_imggen_routmy_image_size') ?? '1K',
      routmyQuality: prefs.getString('gz_imggen_routmy_quality') ?? 'standard',
      naisteraApiKey: '',
      naisteraModel: prefs.getString('gz_imggen_naistera_model') ?? 'grok',
      naisteraAspectRatio:
          prefs.getString('gz_imggen_naistera_aspect_ratio') ?? '1:1',
      sendCharAvatar:
          _safeBool(prefs, 'gz_imggen_routmy_send_char_avatar', false) ||
          _safeBool(prefs, 'gz_imggen_naistera_send_char_avatar', false),
      sendUserAvatar:
          _safeBool(prefs, 'gz_imggen_routmy_send_user_avatar', false) ||
          _safeBool(prefs, 'gz_imggen_naistera_send_user_avatar', false),
      imageContextEnabled: _safeBool(
        prefs,
        'gz_imggen_image_context_enabled',
        false,
      ),
      imageContextCount: _safeInt(prefs, 'gz_imggen_image_context_count', 1),
    );
    // Reading legacy JS options does not grant settings/key cleanup permission.
    // Ordinary settings are saved only by a later explicit native action.
    return settings;
  }

  bool _safeBool(SharedPreferences prefs, String key, bool defaultValue) {
    final raw = prefs.get(key);
    if (raw is bool) return raw;
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return defaultValue;
  }

  int _safeInt(SharedPreferences prefs, String key, int defaultValue) {
    final raw = prefs.get(key);
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw) ?? defaultValue;
    return defaultValue;
  }

  Future<void> save(
    ImageGenSettings settings, {
    NovelAIImageSettings? displayedNovelAiBefore,
    String? displayedNaisteraModelBefore,
    bool Function()? ownsNaisteraCatalog,
  }) async {
    final intent = ++_intent;
    if (settings.routmyApiKey.isNotEmpty) {
      // Only the explicit native owner entry may rotate this credential.
      throw StateError('Use the native rout.my key replacement action');
    }
    final previous = state.value;
    if (settings.openrouter.apiKey.isNotEmpty) {
      throw StateError('Use the native OpenRouter key replacement action');
    }
    if (settings.novelai.apiKey.isNotEmpty) {
      throw StateError('Use the native NovelAI key replacement action');
    }
    if (settings.naisteraApiKey.isNotEmpty) {
      throw StateError('Use the native Naistera key replacement action');
    }
    if (previous == null) throw StateError('Image settings are still loading');
    final ordinary = ImageGenSettingsCodec.toJson(settings)
      ..remove('routmyApiKey')
      ..remove('ruRoutmyApiKey');
    ordinary.remove('naisteraApiKey');
    final before = ImageGenSettingsCodec.toJson(previous);
    before.remove('naisteraApiKey');
    (ordinary['openrouter'] as Map<String, dynamic>).remove('apiKey');
    (before['openrouter'] as Map<String, dynamic>).remove('apiKey');
    (ordinary['novelai'] as Map<String, dynamic>).remove('apiKey');
    (before['novelai'] as Map<String, dynamic>).remove('apiKey');
    // Display denial is not a request to clear a persisted leaf. Native rows
    // supply the exact display baseline that produced their gesture. It never
    // supplies credentials or authority; the original source still owns CAS.
    final novelAiBefore = displayedNovelAiBefore == null
        ? before['novelai'] as Map<String, dynamic>
        : (ImageGenSettingsCodec.toJson(
                previous.copyWith(novelai: displayedNovelAiBefore),
              )['novelai']
              as Map<String, dynamic>);
    final novelAiChanges = <String, dynamic>{
      for (final entry in (ordinary['novelai'] as Map<String, dynamic>).entries)
        if (!_sameSetting(entry.value, novelAiBefore[entry.key]))
          entry.key: entry.value,
    };
    // A codec round-trip may normalize old/other-provider data. Do not let an
    // unrelated native toggle rewrite it: persist only genuinely changed rows.
    final changed = <String, dynamic>{
      for (final entry in ordinary.entries)
        if (entry.key != 'novelai' &&
            entry.key != 'naisteraModel' &&
            !_sameSetting(entry.value, before[entry.key]))
          entry.key: entry.value,
      if (settings.naisteraModel !=
          (displayedNaisteraModelBefore ?? previous.naisteraModel))
        'naisteraModel': settings.naisteraModel,
      if (novelAiChanges.isNotEmpty) 'novelai': novelAiChanges,
    };
    final publicText = _routmy.capturePublicTextGuard();
    final publicOpenRouter = _openrouter.capturePublicTextGuard();
    final publicNovelAi = _novelai.capturePublicTextGuard(url: true);
    final publicNaistera = _naistera.capturePublicTextGuard();
    bool publicModels() =>
        publicText(settings.routmyModel) &&
        settings.routmyModels.every(
          (model) => publicText(model.id) && publicText(model.name),
        ) &&
        publicOpenRouter(settings.openrouter.model) &&
        [
          settings.novelai.model,
          settings.novelai.endpoint,
          settings.novelai.negativePrompt,
          settings.novelai.sampler,
          settings.novelai.noiseSchedule,
          settings.novelai.ucPreset,
        ].every(publicNovelAi) &&
        (!changed.containsKey('naisteraModel') ||
            publicNaistera(settings.naisteraModel) &&
                publicNaistera(
                  NaisteraConstants.normalizeModel(settings.naisteraModel),
                )) &&
        (!changed.containsKey('naisteraModels') ||
            (ownsNaisteraCatalog?.call() ?? true) &&
                settings.naisteraModels.every(
                  (model) =>
                      publicNaistera(model.id) &&
                      publicNaistera(model.name) &&
                      publicNaistera(
                        NaisteraConstants.normalizeModel(model.id),
                      ),
                ));
    if (!publicModels()) throw const CredentialVaultAdmissionDenied();
    if (changed.isEmpty) return;
    await _naistera.source.saveSettings(
      changed,
      isCurrent: () => ref.mounted && intent == _intent && publicModels(),
      hasNovelAiRecord: _novelai.hasNativeRecord,
      hasOpenRouterRecord: _openrouter.hasNativeRecord,
    );
    if (ref.mounted && intent == _intent && publicModels()) {
      state = AsyncData(_publicModels(settings));
      if (changed['openrouter'] is Map &&
          (changed['openrouter'] as Map)['endpoint'] != null &&
          settings.openrouter.endpoint != previous.openrouter.endpoint) {
        ref.invalidate(imageOpenRouterAuthProvider);
      }
      if (settings.novelai.endpoint != previous.novelai.endpoint ||
          settings.novelai.model != previous.novelai.model) {
        ref.invalidate(imageNovelAiAuthProvider);
      }
      if (changed.containsKey('naisteraModel'))
        ref.invalidate(imageNaisteraAuthProvider);
    }
  }

  ImageGenSettings _publicModels(ImageGenSettings settings) {
    final publicText = _routmy.capturePublicTextGuard();
    final publicOpenRouter = _openrouter.capturePublicTextGuard();
    final publicNovelAi = _novelai.capturePublicTextGuard(url: true);
    final publicNaistera = _naistera.capturePublicTextGuard();
    return settings.copyWith(
      naisteraApiKey: '',
      naisteraModel:
          publicNaistera(settings.naisteraModel) &&
              publicNaistera(
                NaisteraConstants.normalizeModel(settings.naisteraModel),
              )
          ? settings.naisteraModel
          : '',
      naisteraModels: settings.naisteraModels
          .where(
            (model) =>
                publicNaistera(model.id) &&
                publicNaistera(model.name) &&
                publicNaistera(NaisteraConstants.normalizeModel(model.id)),
          )
          .toList(),
      novelai: settings.novelai.copyWith(
        apiKey: '',
        model: publicNovelAi(settings.novelai.model)
            ? settings.novelai.model
            : '',
        endpoint: publicNovelAi(settings.novelai.endpoint)
            ? settings.novelai.endpoint
            : '',
        negativePrompt: publicNovelAi(settings.novelai.negativePrompt)
            ? settings.novelai.negativePrompt
            : '',
        sampler: publicNovelAi(settings.novelai.sampler)
            ? settings.novelai.sampler
            : '',
        noiseSchedule: publicNovelAi(settings.novelai.noiseSchedule)
            ? settings.novelai.noiseSchedule
            : '',
        ucPreset: publicNovelAi(settings.novelai.ucPreset)
            ? settings.novelai.ucPreset
            : '',
      ),
      openrouter: settings.openrouter.copyWith(
        apiKey: '',
        model: publicOpenRouter(settings.openrouter.model)
            ? settings.openrouter.model
            : '',
      ),
      routmyModel: publicText(settings.routmyModel) ? settings.routmyModel : '',
      routmyModels: settings.routmyModels
          .where((model) => publicText(model.id) && publicText(model.name))
          .toList(),
    );
  }

  static bool _sameSetting(Object? a, Object? b) {
    if (a is List && b is List) {
      return a.length == b.length &&
          Iterable<int>.generate(
            a.length,
          ).every((i) => _sameSetting(a[i], b[i]));
    }
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
            (key) => b.containsKey(key) && _sameSetting(a[key], b[key]),
          );
    }
    return a == b;
  }

  Future<void> updateEnabled(bool enabled) async {
    final s = state.value ?? const ImageGenSettings();
    await save(s.copyWith(enabled: enabled));
  }

  Future<void> updateApiType(ImageGenApiType apiType) async {
    final s = state.value ?? const ImageGenSettings();
    await save(s.copyWith(apiType: apiType));
  }

  ImageGenService? _service;
  Future<ImageGenService> getServiceAsync() async {
    if (_service != null) return _service!;
    final originalOwner = _routmy;
    final originalOpenRouter = _openrouter;
    final originalNovelAi = _novelai;
    final originalNaistera = _naistera;
    final storage = await ref.read(imageStorageProvider.future);
    if (!ref.mounted ||
        !identical(_routmy, originalOwner) ||
        !identical(_openrouter, originalOpenRouter) ||
        !identical(_novelai, originalNovelAi) ||
        !identical(_naistera, originalNaistera)) {
      throw StateError('Image settings owner retired');
    }
    _service = ImageGenService(
      storage,
      routmyCredentials: originalOwner,
      openrouterCredentials: originalOpenRouter,
      novelaiCredentials: originalNovelAi,
      naisteraCredentials: originalNaistera,
    );
    return _service!;
  }

  ImageGenService? getService() {
    if (_service != null) return _service!;
    final storage = ref.read(imageStorageProvider).value;
    if (storage == null) return null;
    _service = ImageGenService(
      storage,
      routmyCredentials: _routmy,
      openrouterCredentials: _openrouter,
      novelaiCredentials: _novelai,
      naisteraCredentials: _naistera,
    );
    return _service!;
  }
}
