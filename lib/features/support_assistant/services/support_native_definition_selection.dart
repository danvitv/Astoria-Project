import '../../../core/llm/transport/native_tool_types.dart';
import '../models/support_source_tool_names.dart';
import 'diagnostics/support_diagnostic_agent.dart';

/// Pure availability selection, never approval or execution authority. Capture
/// the actual composed registry definitions ONCE, before context/preview/POST.
/// Neither later registry getters nor conversation/source/provider data can
/// enlarge this original run's catalog. Native definitions already freeze JSON.
final class SupportNativeDefinitionSelection {
  SupportNativeDefinitionSelection._(
    this.captured,
    this.definitions, {
    required this.overflow,
    this.sourceOnly = false,
  });

  final List<NativeToolDefinition> captured;
  final List<NativeToolDefinition> definitions;
  final bool overflow, sourceOnly;
  bool get available => definitions.isNotEmpty;

  static SupportNativeDefinitionSelection capture({
    required Iterable<NativeToolDefinition> connected,
    required String currentUserText,
    SupportDiagnosticAgent? diagnosticAgent,
    bool readOnlySources = false,
  }) {
    final captured = List<NativeToolDefinition>.unmodifiable(connected);
    final overflow = captured.length > NativeToolLimits.definitions;
    List<NativeToolDefinition>? complete(Set<String> names) {
      final selected = captured.where((d) => names.contains(d.name)).toList();
      if (selected.length != names.length ||
          selected.map((d) => d.name).toSet().length != names.length ||
          selected.length > NativeToolLimits.definitions) {
        return null;
      }
      return List<NativeToolDefinition>.unmodifiable(selected);
    }

    if (readOnlySources) {
      return SupportNativeDefinitionSelection._(
        captured,
        complete(SupportSourceToolNames.all) ?? const [],
        overflow: overflow,
        sourceOnly: true,
      );
    }
    if (diagnosticAgent != null) {
      // Retain the existing trusted read filter, applied to captured objects.
      final reads = diagnosticAgent.definitions(captured);
      return SupportNativeDefinitionSelection._(
        captured,
        reads.length <= NativeToolLimits.definitions ? reads : const [],
        overflow: overflow,
      );
    }
    if (!overflow) {
      // Ordinary runs MUST retain every definition, in order and by identity.
      return SupportNativeDefinitionSelection._(
        captured,
        captured,
        overflow: false,
      );
    }
    final requested = _requestedFamilies(currentUserText);
    if (requested != null) {
      final names = <String>{...SupportSourceToolNames.all};
      for (final family in requested) {
        names.addAll(_families[family]!);
      }
      final selected = complete(names);
      if (selected != null) {
        return SupportNativeDefinitionSelection._(
          captured,
          selected,
          overflow: true,
        );
      }
    }
    // Explicit fallback: the COMPLETE actually supplied Source4, never an
    // unrestricted catalog or a partial task family. Missing Source4 means the
    // run is unavailable before POST; do not substitute ordinary text dispatch.
    return SupportNativeDefinitionSelection._(
      captured,
      complete(SupportSourceToolNames.all) ?? const [],
      overflow: true,
      sourceOnly: true,
    );
  }

  /// Additional host check BEFORE ROOT, registry preparation or confirmation.
  /// No unposted provider name is echoed or projected as display metadata.
  void requirePosted(String name) {
    if (!definitions.any((d) => d.name == name)) {
      throw const NativeToolException(NativeToolReason.unknownTool);
    }
  }

  String get availabilityInstruction => overflow
      ? 'Some registered tools are not connected in THIS run. This does not '
            'mean they are absent from the application or that consent was denied. '
            'Do not infer an omitted catalog or call an unposted operation. '
            '${sourceOnly ? 'Only the supplied complete read-only source family is connected; the requested application action is not connected in this run. ' : ''}'
      : '';

  // Closed, source-audited names from current app_control adapters. Each entry
  // includes discovery/read and genuine receipt/Undo prerequisites, not only
  // the effect. Source4 is mandatory for every overflow task union. A future
  // family must be deliberately added after its native implementation exists;
  // prefixes, schema descriptions, risks and model prose are NOT classifiers.
  static const _families = <String, Set<String>>{
    'preferences': {
      'astoria_preferences_read',
      'astoria_preferences_update',
      'astoria_battery_saver_set',
    },
    'theme': {
      'astoria_themes_list',
      'astoria_theme_select',
      'astoria_theme_mode_set',
    },
    'connection': {
      'astoria_connections_list',
      'astoria_connection_read',
      'astoria_connection_create',
      'astoria_connection_update',
    },
    'sessionTitle': {
      'astoria_session_integrity',
      'astoria_roleplay_inspect',
      'astoria_session_rename',
      'astoria_session_title_receipts',
      'astoria_session_rename_undo',
    },
    'selection': {
      'astoria_content_catalog',
      'astoria_active_persona_set',
      'astoria_active_preset_set',
      'astoria_active_selection_receipts',
      'astoria_active_selection_undo',
    },
    'globalRegex': {
      // Retained Undo discovers genuine receipts. Fresh disable has no supplied
      // script-ID discovery path; never advertise it as a complete overflow task.
      'astoria_global_regex_receipts',
      'astoria_global_regex_undo',
    },
    'memoryEntry': {
      'astoria_session_integrity',
      'astoria_roleplay_inspect',
      'astoria_memory_inspect',
      'astoria_memory_entry_text_revise',
      'astoria_memory_entry_text_receipts',
      'astoria_memory_entry_text_undo',
    },
    'sessionRepair': {
      'astoria_roleplay_inspect',
      'astoria_session_integrity',
      'astoria_session_repair',
      'astoria_session_repair_undo',
    },
    'databaseRepair': {
      'astoria_database_health',
      'astoria_database_repair',
      'astoria_database_repair_undo',
    },
    'backup': {'astoria_database_snapshot'},
    'recovery': {'astoria_database_restore_prepare'},
    'navigation': {'astoria_navigate'},
  };

  // Deliberately narrow WHOLE imperative clauses. No arbitrary pasted targets,
  // JSON, quoted content or trailing prose is understood as a task. Unknown or
  // negative clauses invalidate the entire union, rather than adding families
  // because an object name happens to appear somewhere in the input.
  static final _commands = <String, RegExp>{
    'preferences': _command(
      r'(?:change (?:the )?preferences|set (?:the )?battery saver(?: to (?:on|off|auto))?|'
      r'измени настройки приложения|(?:включи|отключи) экономию батареи)',
    ),
    'theme': _command(
      r'(?:change (?:the )?theme|set (?:the )?theme(?: mode)? to (?:light|dark|system)|'
      r'измени тему|(?:включи|установи) (?:светлую|темную|системную) тему)',
    ),
    'connection': _command(
      r'(?:(?:create|change) (?:the |a )?connection|(?:создай|измени) подключение)',
    ),
    'sessionTitle': _command(
      r'(?:(?:rename|undo renaming) (?:the )?(?:roleplay )?session|'
      r'переименуй (?:игровую )?сессию|отмени переименование сессии)',
    ),
    'selection': _command(
      r'(?:(?:select|clear) (?:the )?(?:active )?(?:persona|ordinary preset)|'
      r'undo (?:the )?active selection|(?:выбери|сбрось) (?:активную персону|обычный пресет)|'
      r'отмени активный выбор)',
    ),
    'globalRegex': _command(
      r'(?:undo (?:the )?global regex disable|отмени отключение глобального regex)',
    ),
    'memoryEntry': _command(
      r'(?:revise (?:the )?memory entry text|undo (?:the )?memory entry text revision|'
      r'измени текст записи memory|отмени изменение текста записи memory)',
    ),
    'sessionRepair': _command(
      r'(?:repair (?:the )?session|undo (?:the )?session repair|'
      r'почини сессию|отмени исправление сессии)',
    ),
    'databaseRepair': _command(
      r'(?:repair (?:the )?database|undo (?:the )?database repair|'
      r'почини базу данных|отмени исправление базы данных)',
    ),
    'backup': _command(
      r'(?:save (?:a )?local database snapshot|сохрани локальную копию базы данных)',
    ),
    'recovery': _command(
      r'(?:prepare offline database recovery|подготовь автономное восстановление базы данных)',
    ),
    'navigation': _command(
      r'(?:open (?:the )?(?:settings|memory|characters)|открой (?:настройки|memory|персонажей))',
    ),
  };

  static RegExp _command(String body) =>
      RegExp('^(?:(?:please|пожалуйста) )?(?:$body)\$');

  static Set<String>? _requestedFamilies(String text) {
    if (text.length > 4096 ||
        RegExp(r'^ {4,}').hasMatch(text) ||
        RegExp(r'''["'`«»“”‘’{}\[\]<>\\\x00-\x1f\x7f]''').hasMatch(text)) {
      return null;
    }
    final normalized = text.toLowerCase().replaceAll('ё', 'е').trim();
    final clauses = normalized.split(
      RegExp(r'\s*[;.!]\s*|\s+(?:and then|then|and|затем|и)\s+'),
    );
    if (clauses.isNotEmpty && clauses.last.isEmpty) clauses.removeLast();
    if (clauses.isEmpty || clauses.length > _families.length) return null;
    final selected = <String>{};
    for (final clause in clauses) {
      final matches = _commands.entries.where((e) => e.value.hasMatch(clause));
      if (matches.length != 1) return null;
      selected.add(matches.single.key);
    }
    return selected.isEmpty ? null : selected;
  }
}
