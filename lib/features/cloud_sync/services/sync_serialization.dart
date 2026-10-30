import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../features/extensions/models/info_block.dart';
import '../../../features/image_gen/services/image_tag_markup.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';
import 'sync_payload_transport.dart';

class SyncSerialization {
  static const pipelineSettingsKey = 'pipelineSettings';
  static const activeStudioPresetKey = 'activeStudioPresetId';
  static const globalRegexScriptsKey = 'gz_global_regex_scripts';
  static const studioRegexScriptsKey = 'gz_studio_regex_scripts';
  static const appSettingsKey = 'appSettings';
  static const syncIncludeApiKeysPrefKey = 'gz_sync_include_api_keys';
  static const chatLayoutKey = 'chatLayout';
  static const chatLayoutPrefKeys = [
    'composer_pins_v1',
    'composer_actions_v1',
    'composer_hidden_actions_v1',
    'composer_empty_action_v1',
    'quick_replies_list_v1',
    'magic_drawer_items',
    'magic_drawer_deleted_items',
    'tools_layout_order',
    'tools_layout_sizes',
    'tools_layout_deleted',
  ];

  static Map<String, dynamic>? readChatLayout(SharedPreferences prefs) {
    final values = <String, dynamic>{};
    for (final key in chatLayoutPrefKeys) {
      final value = prefs.get(key);
      if (value is String || value is List<String>) values[key] = value;
    }
    // Empty is an intentional reset, not an absent legacy layout document.
    return values;
  }

  static Future<void> applyChatLayout(
    SharedPreferences prefs,
    Map<String, dynamic> layout,
  ) async {
    for (final key in chatLayoutPrefKeys) {
      final value = layout[key];
      if (value is String) {
        await prefs.setString(key, value);
      } else if (value is List && value.every((e) => e is String)) {
        await prefs.setStringList(key, value.cast<String>());
      } else if (!layout.containsKey(key) || value == null) {
        await prefs.remove(key);
      }
    }
  }

  /// Content fingerprint for manifest conflict detection (not full session JSON).
  static String computeChatMetadataHash(SessionMetadata metadata) {
    return computeSyncHash({
      'sessionId': metadata.sessionId,
      'characterId': metadata.characterId,
      'sessionIndex': metadata.sessionIndex,
      'updatedAt': metadata.updatedAt,
      'messageCount': metadata.messageCount,
      'lastMessageContent': metadata.lastMessageContent,
      'lastMessageTimestamp': metadata.lastMessageTimestamp,
      'sessionName': metadata.sessionName,
    });
  }

  static String computeSyncHash(dynamic data) {
    final json = jsonEncode(data);
    return sha256.convert(utf8.encode(json)).toString();
  }

  static String computeStudioConfigHash(Map<String, dynamic> json) {
    final content = Map<String, dynamic>.from(json)
      ..remove('createdAt')
      ..remove('updatedAt');
    return computeSyncHash(content);
  }

  /// Device-local / derived fields excluded so parity does not false-conflict.
  static const _memoryBookSettingsHashKeys = {
    'enabled',
    'autoCreateEnabled',
    'autoGenerateEnabled',
    'maxInjectedEntries',
    'memoryExcerptingEnabled',
    'maxInjectionBudgetPercent',
    'maxInjectedTokens',
    'memoryBudgetPreset',
    'autoCreateInterval',
    'autoCreateLagMessages',
    'useDelayedAutomation',
    'injectionTarget',
    'batchSize',
    'vectorSearchEnabled',
    'keyMatchMode',
    'promptPreset',
  };

  static Map<String, dynamic> normalizeMemoryBookForHash(
    Map<String, dynamic> json,
  ) {
    final settings = json['settings'];
    return {
      'sessionId': json['sessionId'],
      'entries': json['entries'] ?? <dynamic>[],
      'settings': _memoryBookSettingsForHash(settings),
    };
  }

  static Map<String, dynamic> _memoryBookSettingsForHash(dynamic settings) {
    if (settings is! Map) return {};
    try {
      final canonical = MemoryBookSettings.fromJson(
        Map<String, dynamic>.from(settings),
      ).toJson();
      return {
        for (final key in _memoryBookSettingsHashKeys)
          if (canonical.containsKey(key)) key: canonical[key],
      };
    } catch (_) {
      return {};
    }
  }

  static String computeMemoryBookHash(Map<String, dynamic> json) {
    try {
      final canonical = MemoryBook.fromJson(json).toJson();
      return computeSyncHash(normalizeMemoryBookForHash(canonical));
    } catch (_) {
      return computeSyncHash(normalizeMemoryBookForHash(json));
    }
  }

  static String computeApiPresetsHash(Iterable<Map<String, dynamic>> items) {
    return computeSyncHash(
      items.map((item) {
        final copy = Map<String, dynamic>.from(item);
        copy['apiKey'] = '';
        copy['embeddingApiKey'] = '';
        return copy;
      }).toList(),
    );
  }

  static Map<String, dynamic> infoBlocksPayload(List<InfoBlock> blocks) {
    return {
      '__infoBlocks': true,
      'items': blocks.map(normalizeInfoBlockForSync).toList(),
    };
  }

  /// Normalizes an InfoBlock for cloud storage: a finished image is replaced
  /// by the instruction that produced it, so the block can be regenerated on
  /// pull and no device-local path ever leaves the device. A block holding no
  /// image is stored as-is.
  ///
  /// The test is the content, not the block's type. It used to be
  /// `blockType == 'imageGen'`, which was safe only while images could come
  /// from nothing else; now that any generated block can draw one, that check
  /// would upload the file paths of every block the old image type did not
  /// cover.
  static Map<String, dynamic> normalizeInfoBlockForSync(InfoBlock block) {
    final json = block.toJson();
    final normalized = normalizeImageGenContent(block.content);
    if (normalized == block.content) return json;
    return Map<String, dynamic>.from(json)..['content'] = normalized;
  }

  /// Replaces [IMG:RESULT:/abs/path|json] → [IMG:GEN:json]
  /// and [IMG:ERROR:...] → [IMG:GEN] so that pulled blocks can be regenerated.
  ///
  /// The stored `<img data-iig-…>` form of a finished block goes the same way:
  /// the image file itself never leaves the device, so what is uploaded is the
  /// instruction that can produce it again.
  static String normalizeImageGenContent(String content) =>
      ImageTagMarkup.reduceBlocksToInstructions(content);

  static String computeBinaryHash(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  static String computeImageHash(String dataUrl) {
    final commaIdx = dataUrl.indexOf(',');
    final raw = commaIdx >= 0 ? dataUrl.substring(commaIdx + 1) : dataUrl;
    final bytes = base64Decode(raw);
    return computeBinaryHash(bytes);
  }

  static Map<String, dynamic> localStoragePayload({
    String? pipelineSettings,
    String? activeStudioPresetId,
    String? globalRegexScripts,
    String? studioRegexScripts,
    Map<String, dynamic>? appSettings,
    Map<String, dynamic>? chatLayout,
  }) {
    return {
      '__localStorage': true,
      pipelineSettingsKey: ?pipelineSettings,
      activeStudioPresetKey: ?activeStudioPresetId,
      globalRegexScriptsKey: ?globalRegexScripts,
      studioRegexScriptsKey: ?studioRegexScripts,
      appSettingsKey: ?appSettings,
      chatLayoutKey: ?chatLayout,
    };
  }

  static String guessImageExt(String dataUrl) {
    final mimeMatch = RegExp(r'data:([^;]+);').firstMatch(dataUrl);
    if (mimeMatch == null) return 'png';
    final mime = mimeMatch[1]!;
    if (mime.contains('jpeg') || mime.contains('jpg')) return 'jpg';
    if (mime.contains('gif')) return 'gif';
    if (mime.contains('webp')) return 'webp';
    return 'png';
  }

  static Future<void> deleteCloudFileIfExists(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    try {
      await adapter.deleteFile(entry.path);
    } catch (_) {}
    if (entry.type == 'reconciliation_state') {
      // Only the owning entity's explicit tombstone deletes history parts.
      // Ordinary updates retain parts so concurrent older readers stay valid.
      for (final suffix in ['.pages', '.parts']) {
        try {
          await adapter.deleteFolder('${entry.path}$suffix');
        } catch (_) {}
      }
    }
  }

  static Future<Map<String, dynamic>?> readCloudEntity(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    try {
      return await SyncPayloadTransport.download(adapter, entry);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> readRequiredCloudEntity(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    return SyncPayloadTransport.download(adapter, entry);
  }
}
