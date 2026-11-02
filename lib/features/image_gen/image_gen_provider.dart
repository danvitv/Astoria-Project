import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/credentials/image_routmy_credential_owner.dart';
import '../../../core/credentials/image_routmy_legacy_source.dart';
import '../../../core/credentials/credential_vault.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import 'image_gen_models.dart';
import 'image_gen_settings_codec.dart';
import 'services/image_gen_service.dart';

final imageRoutmyCredentialOwnerProvider = Provider<ImageRoutmyCredentialOwner>((ref) {
  final owner = ImageRoutmyCredentialOwner(
    vault: ref.watch(credentialVaultProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
    originalPreferences: ref.read(sharedPreferencesProvider.future),
  );
  ref.onDispose(owner.dispose);
  return owner;
});

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
      if (ref.mounted && intent == _intent && ownsPublication() &&
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

  @override
  Future<ImageGenSettings> build() async {
    _intent++;
    _service = null;
    _routmy = ref.watch(imageRoutmyCredentialOwnerProvider);
    final lease = _routmy.source.captureSettings();
    final prefs = await _routmy.source.preferences(lease, () => ref.mounted);
    final raw = prefs.getString(_key);
    if (raw != null) {
      final json = ImageRoutmyLegacySource.decode(raw)!;
      final safe = Map<String, dynamic>.of(json)
        ..remove('routmyApiKey')
        ..remove('ruRoutmyApiKey');
      // Seed only the image slot before ordinary native saves can retire the
      // original legacy revision. This is secure import, never a network probe.
      await _routmy.load();
      await _routmy.source.preferences(lease, () => ref.mounted);
      // Secret never hydrates the immutable settings/provider snapshot.
      return _publicModels(ImageGenSettingsCodec.fromJson(safe));
    }
    await _routmy.load();
    await _routmy.source.preferences(lease, () => ref.mounted);
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
      naisteraApiKey: prefs.getString('gz_imggen_naistera_api_key') ?? '',
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

  Future<void> save(ImageGenSettings settings) async {
    final intent = ++_intent;
    if (settings.routmyApiKey.isNotEmpty) {
      // Only the explicit native owner entry may rotate this credential.
      throw StateError('Use the native rout.my key replacement action');
    }
    final previous = state.value;
    if (previous == null) throw StateError('Image settings are still loading');
    final ordinary = ImageGenSettingsCodec.toJson(settings)
      ..remove('routmyApiKey')
      ..remove('ruRoutmyApiKey');
    final before = ImageGenSettingsCodec.toJson(previous);
    // A codec round-trip may normalize old/other-provider data. Do not let an
    // unrelated native toggle rewrite it: persist only genuinely changed rows.
    final changed = <String, dynamic>{
      for (final entry in ordinary.entries)
        if (!_sameSetting(entry.value, before[entry.key])) entry.key: entry.value,
    };
    final publicText = _routmy.capturePublicTextGuard();
    bool publicModels() => publicText(settings.routmyModel) &&
        settings.routmyModels.every((model) =>
            publicText(model.id) && publicText(model.name));
    if (!publicModels()) throw const CredentialVaultAdmissionDenied();
    if (changed.isEmpty) return;
    await _routmy.source.saveSettings(
      changed,
      isCurrent: () => ref.mounted && intent == _intent && publicModels(),
    );
    if (ref.mounted && intent == _intent && publicModels()) {
      state = AsyncData(settings);
    }
  }

  ImageGenSettings _publicModels(ImageGenSettings settings) {
    final publicText = _routmy.capturePublicTextGuard();
    return settings.copyWith(
      routmyModel: publicText(settings.routmyModel) ? settings.routmyModel : '',
      routmyModels: settings.routmyModels.where((model) =>
          publicText(model.id) && publicText(model.name)).toList(),
    );
  }

  static bool _sameSetting(Object? a, Object? b) {
    if (a is List && b is List) {
      return a.length == b.length &&
          Iterable<int>.generate(a.length).every((i) => _sameSetting(a[i], b[i]));
    }
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _sameSetting(a[key], b[key]));
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
    final storage = await ref.read(imageStorageProvider.future);
    if (!ref.mounted || !identical(_routmy, originalOwner)) {
      throw StateError('Image settings owner retired');
    }
    _service = ImageGenService(storage, routmyCredentials: originalOwner);
    return _service!;
  }

  ImageGenService? getService() {
    if (_service != null) return _service!;
    final storage = ref.read(imageStorageProvider).value;
    if (storage == null) return null;
    _service = ImageGenService(storage, routmyCredentials: _routmy);
    return _service!;
  }
}
