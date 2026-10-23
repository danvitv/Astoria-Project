import '../models/support_guidance_target.dart';

/// Pure proposals from the current user's own input or a known native topic.
/// Never classify model/provider output, restored rows or diagnostic payloads.
/// No input survives in a target, label or reason; no reader or executor is used.
class SupportGuidancePlanner {
  const SupportGuidancePlanner();

  List<SupportGuidanceTarget> targetsFor({String? text, String? topic}) {
    final input = (text ?? '').trim().toLowerCase().replaceAll('ё', 'е');
    final requested = _forText(input);
    if (requested.isNotEmpty) return _bounded(requested);
    return _bounded(switch (topic) {
      'theme_setup' => _theme,
      'provider_setup' => _provider,
      'connection_diagnostics' => _connectionMetadata,
      'memory_books_setup' => const [
        SupportGuidanceTarget.gameSession,
        SupportGuidanceTarget.readGameData,
      ],
      // Generic help/report explains availability, not every possible right.
      _ => const <SupportGuidanceTarget>[],
    });
  }

  List<SupportGuidanceTarget> _forText(String s) {
    if (s.isEmpty) return const [];
    final settings = _has(
      s,
      r'настро[а-я]*|смен[а-я]*|измен[а-я]*|помен[а-я]*|выб[а-я]*|'
      r'установ[а-я]*|включ[а-я]*|отключ[а-я]*|set|settings|change|'
      r'switch|select|choose|configure|setup',
    );
    final selection = _has(
      s,
      r'выб[а-я]*|смен[а-я]*|измен[а-я]*|помен[а-я]*|настрой|настроить|'
      r'настройка|установ[а-я]*|select|choose|change|switch|configure|setup|set',
    );
    final theme = _has(
      s,
      r'тем[ауы]|темой|темн[а-я]*|светл[а-я]*|оформлен[а-я]*|themes?|dark|light',
    );
    final metadata = _has(s, r'метаданн[а-я]*|metadata');
    final connection = _has(
      s,
      r'подключ[а-я]*|профил[а-я]*|connection|profile|api|провайдер[а-я]*|provider',
    );

    // Specific settings precede theme: "температура" is not "тема".
    final precise = <SupportGuidanceTarget>[
      if (_has(s, r'температур[а-я]*|temperature'))
        SupportGuidanceTarget.temperature,
      if (_has(s, r'токен[а-я]*|tokens?|max_tokens|max ?tokens|бюджет ответа'))
        SupportGuidanceTarget.maxTokens,
      if (_has(s, r'reasoning|рассужден[а-я]*|уровень размышлений'))
        SupportGuidanceTarget.reasoning,
      if (_has(s, r'dcp|сжатие контекста|context compression'))
        SupportGuidanceTarget.dcp,
      if (!theme && _has(s, r'режим[а-я]*|mode|onboarding|hybrid'))
        SupportGuidanceTarget.mode,
      if (!metadata &&
          (settings || _has(s, r'профил[а-я]*|profile')) &&
          _has(s, r'подключ[а-я]*|профил[а-я]*|connection|profile') &&
          !_has(s, r'ключ[а-я]*|key|endpoint'))
        SupportGuidanceTarget.connection,
      if ((selection ||
              s == 'model' ||
              s == 'модель' ||
              _has(s, r'model settings|настройки модели астории')) &&
          _has(s, r'модел[а-я]*|model'))
        SupportGuidanceTarget.model,
    ];
    if (precise.isNotEmpty) return precise;

    final report = _has(
      s,
      r'репорт[а-я]*|отчет[а-я]*|report|export|экспорт[а-я]*',
    );
    final supportHistory = _has(
      s,
      r'(?:чат[а-я]*|переписк[а-я]*|сесси[а-я]*|истори[а-я]*) (?:с )?астори[а-я]*|'
      r'astoria (?:chat|session|history)|(?:chat|session|history) (?:with )?astoria|'
      r'support (?:chat|session|history)|'
      r'(?:текущ[а-я]*|эт[а-я]*|наш[а-я]*) (?:чат[а-я]*|переписк[а-я]*)|this chat|current chat',
    );
    final gameHistory = _has(
      s,
      r'ролев[а-я]* (?:истори[а-я]*|переписк[а-я]*|чат[а-я]*|сесси[а-я]*)|'
      r'истори[а-я]* (?:игры|ролев[а-я]*)|roleplay|game (?:history|chat|session)',
    );
    final attachment = _has(
      s,
      r'вложен[а-я]*|attachments?|прикреплен[а-я]* файл[а-я]*',
    );
    final gameData = _has(
      s,
      r'memory(?: books)?|памят[а-я]*|лора|лор|lore|канон[а-я]*|canon|'
      r'персонаж[а-я]*|character|переменн[а-я]*|variables|ролев[а-я]* данн[а-я]*|game data',
    );
    if (report) {
      return [
        if (gameHistory) ...const [
          SupportGuidanceTarget.gameSession,
          SupportGuidanceTarget.reportGameHistory,
        ],
        if (supportHistory) ...const [
          SupportGuidanceTarget.supportSession,
          SupportGuidanceTarget.reportSupportHistory,
        ],
        if (attachment ||
            gameData ||
            _has(s, r'личн[а-я]* данн[а-я]*|personal data'))
          SupportGuidanceTarget.reportPersonalDataAttachments,
      ];
    }
    if (!metadata &&
        connection &&
        _has(s, r'тест[а-я]*|test|провер[а-я]*|check|ping')) {
      return const [
        SupportGuidanceTarget.recipient,
        SupportGuidanceTarget.confirmedConnectionTests,
      ];
    }

    final toModel = _has(
      s,
      r'модел[а-я]*|model|отправ[а-я]*|переда[а-я]*|send|share',
    );
    if (toModel &&
        _has(
          s,
          r'prompt|промпт[а-я]*|snippets?|сниппет[а-я]*|фрагмент[а-я]* провайдер[а-я]*',
        )) {
      return const [
        SupportGuidanceTarget.modelPromptProviderSnippets,
        SupportGuidanceTarget.recipient,
      ];
    }
    if (attachment && toModel) {
      return const [
        SupportGuidanceTarget.modelAttachments,
        SupportGuidanceTarget.recipient,
      ];
    }
    final diagnostics = _has(
      s,
      r'диагност[а-я]*|diagnostics?|лог[а-я]*|logs?|crash|сбой[а-я]*',
    );
    if (diagnostics && !gameHistory && !supportHistory && !metadata) {
      return [
        SupportGuidanceTarget.readDiagnostics,
        if (toModel) ...const [
          SupportGuidanceTarget.modelSafeSettingsDiagnostics,
          SupportGuidanceTarget.recipient,
        ],
      ];
    }
    if (supportHistory) {
      return const [
        SupportGuidanceTarget.supportSession,
        SupportGuidanceTarget.modelSupportHistory,
        SupportGuidanceTarget.recipient,
      ];
    }
    if (gameData) {
      return [
        SupportGuidanceTarget.gameSession,
        SupportGuidanceTarget.readGameData,
        if (toModel) ...const [
          SupportGuidanceTarget.modelGameData,
          SupportGuidanceTarget.recipient,
        ],
      ];
    }
    if (gameHistory ||
        _has(s, r'истори[а-я]* (?:диалог[а-я]*|переписк[а-я]*)|chat history')) {
      return const [
        SupportGuidanceTarget.gameSession,
        SupportGuidanceTarget.readGameData,
        SupportGuidanceTarget.modelGameHistory,
        SupportGuidanceTarget.recipient,
      ];
    }
    if (metadata && connection) return _connectionMetadata;
    if (theme &&
        (settings ||
            _has(s, r'помо[а-я]*|help') ||
            s == 'theme' ||
            s == 'тема')) {
      return _theme;
    }
    if (_has(s, r'ключ[а-я]*|api(?: key)?|провайдер[а-я]*|provider|endpoint')) {
      return _provider;
    }
    if (_has(s, r'безопасн[а-я]* настро[а-я]*|safe settings')) {
      return [
        SupportGuidanceTarget.readSafeSettings,
        if (toModel) ...const [
          SupportGuidanceTarget.modelSafeSettingsDiagnostics,
          SupportGuidanceTarget.recipient,
        ],
      ];
    }
    if (_has(
      s,
      r'(?:измен[а-я]*|помен[а-я]*) настро[а-я]*|settings changes|change settings',
    )) {
      return const [SupportGuidanceTarget.confirmedSettingsChanges];
    }
    if (_has(s, r'получател[а-я]*|recipient')) {
      return const [SupportGuidanceTarget.recipient];
    }
    return const [];
  }

  static bool _has(String text, String pattern) => RegExp(
    '(^|[^a-zа-я0-9_])(?:$pattern)'
    r'(?=$|[^a-zа-я0-9_])',
  ).hasMatch(text);

  static List<SupportGuidanceTarget> _bounded(
    Iterable<SupportGuidanceTarget> targets,
  ) => List.unmodifiable(targets.toSet().take(4));

  static const _connectionMetadata = [
    SupportGuidanceTarget.connectionsScope,
    SupportGuidanceTarget.readSafeSettings,
  ];
  static const _theme = [
    SupportGuidanceTarget.themeScope,
    SupportGuidanceTarget.readSafeSettings,
    SupportGuidanceTarget.confirmedSettingsChanges,
    SupportGuidanceTarget.themeSetup,
  ];
  static const _provider = [
    SupportGuidanceTarget.connectionsScope,
    SupportGuidanceTarget.readSafeSettings,
    SupportGuidanceTarget.confirmedSettingsChanges,
    SupportGuidanceTarget.providerSetup,
  ];
}
