import 'dart:convert';
import 'dart:io';

import '../../../../core/db/native_history/history_message_unit.dart';
import '../../../../core/db/repositories/support_report_read_repo.dart';
import '../../../../core/support_report/support_report_error.dart';
import '../../../../core/support_report/support_report_json.dart';
import 'support_report_models.dart';
import 'support_report_diagnostic_projection.dart';
import 'support_report_ownership.dart';
import 'support_report_sanitizer.dart';

part 'support_report_personal_material.dart';

final class SupportReportBuilder {
  SupportReportBuilder(this.owner, this.current)
    : sanitizer = SupportReportSanitizer(owner.redactor);
  final SupportReportOwnership owner;
  final bool Function() current;
  final SupportReportSanitizer sanitizer;
  final blocks = <SupportReportBlock>[];
  final omissions = <String>[
    'Selected-column diagnostics only; no complete DB or live prompt snapshot.',
    'Request timings unknown: timings exist only inside excluded event JSON.',
    'Request and event retention completeness unknown; absence does not prove eviction.',
    'Volatile 200-entry operations ring omitted; it is not durable evidence.',
    'Credentials, paths, private identities and hashes, request/response bodies, raw errors, parser details and journal before/after excluded.',
    'App version and detailed OS version unknown; no environment variables collected.',
  ];
  void check() {
    if (!current()) {
      throw const SupportReportException(SupportReportFailure.changed);
    }
  }

  void add(
    String id,
    String title,
    bool personal,
    Object? value, [
    Iterable<String> deps = const [],
  ]) {
    check();
    blocks.add(
      SupportReportBlock(
        id: id,
        title: title,
        personal: personal,
        dependencies: deps,
        content: sanitizer.sanitize(value),
      ),
    );
  }

  Future<void> build(
    SupportReportReadSnapshot data,
    SupportReportPrepareRequest request,
  ) async {
    check();
    add('environment', 'Safe environment', false, {
      'app': 'Astoria',
      'os': Platform.operatingSystem,
      'schemaVersion': data.schema,
      'registeredTableCount': data.tableCount,
      'appVersion': 'unknown',
      'osVersion': 'unknown',
    });
    add('configuration', 'Configured flags and character counts', false, {
      'records': data.configurations.take(16).toList(),
      'bounded': true,
      'hasMore': data.configurations.length > 16,
      'credentialsRead': false,
    });
    add('captures', 'Persisted request capture metadata', false, {
      'records': data.captures.take(64).toList(),
      'hasMore': data.captures.length > 64,
      'retentionCompleteness': 'unknown',
      'timings': 'unknown',
    });
    final diagnostic = SupportReportDiagnosticProjection.fromEvents(
      data.events,
    );
    add(
      'events',
      'Observed transport and parser facts',
      false,
      diagnostic.events,
    );
    add(
      'diagnoses',
      'Deterministic evidence assessment',
      false,
      diagnostic.diagnoses,
      ['events'],
    );
    if (request.supportSessionId != null) {
      add('repairMetadata', 'Selected repair attempt metadata', true, {
        'records': data.repairs.take(16).toList(),
        'hasMore': data.repairs.length > 16,
        'outcomeEvidence': 'Recorded status only; no before/after inspection.',
      });
    }
    if (request.gameSessionId != null &&
        (request.includeTitles || request.includeProse)) {
      if (data.game.isEmpty) {
        omissions.add(
          'Selected game source missing or hidden; no alternate source read.',
        );
      } else {
        final game = data.game.single;
        if (request.includeTitles) {
          if (game['title'] is String) {
            add('gameTitle', 'Selected game title', true, {
              'title': game['title'],
            });
          } else {
            omissions.add(
              'Selected game title exceeds the 4096-character bound.',
            );
          }
        }
        if (request.includeProse) _gameHistory(game);
      }
    }
    final session = request.supportSessionId;
    if (session != null && request.includeTitles) {
      for (final row in data.supportTitle) {
        final title = await _decrypt(
          row,
          'title',
          'support_sessions',
          'title_ciphertext',
          session,
        );
        check();
        if (title != null) {
          add('supportTitle', 'Selected Astoria conversation title', true, {
            'title': title,
          });
        }
      }
    }
    if (session != null && request.includeProse) {
      final comments = <Map<String, Object?>>[];
      for (final row in data.supportHistory.take(8)) {
        check();
        if (row['status'] != 'complete' ||
            !const ['user', 'assistant'].contains(row['role'])) {
          omissions.add(
            'An incomplete or unknown-role Astoria message was omitted.',
          );
          continue;
        }
        final body = await _decrypt(
          row,
          'body',
          'support_messages',
          'body_ciphertext',
          session,
        );
        check();
        if (body != null) comments.add({'role': row['role'], 'text': body});
      }
      add(
        'supportCommentary',
        'Selected Astoria history (untrusted commentary)',
        true,
        {
          'records': comments.reversed.toList(),
          'bounded': true,
          'hasMore': data.supportHistory.length > 8,
          'diagnosticFacts': false,
        },
      );
      add(
        'commentaryNotice',
        'Commentary boundary',
        false,
        {
          'statement':
              'Assistant and user prose is commentary, not evidence that an operation occurred.',
        },
        ['supportCommentary'],
      );
    }
    check();
  }
}
