import 'dart:convert';
import '../../../core/credentials/credential_metadata.dart';
import '../models/support_workspace_models.dart';

/// Versioned native-card allowlist. Unknown fields/types reject the whole payload.
class SupportCardCodec {
  const SupportCardCodec();
  String encode(List<SupportCard> cards) =>
      jsonEncode({'version': 1, 'cards': cards.map(_encode).toList()});
  List<SupportCard> decode(String raw) {
    if (raw.isEmpty) return const [];
    try {
      if (raw.length > 65536) return const [];
      final root = jsonDecode(raw) as Map<String, dynamic>;
      _keys(root, ['version', 'cards']);
      if (root['version'] is! int || root['version'] != 1) return const [];
      final cards = root['cards'] as List;
      if (cards.length > 32) return const [];
      return List.unmodifiable(
        cards.map((c) => _decode(Map<String, dynamic>.from(c as Map))),
      );
    } catch (_) {
      return const [];
    }
  }

  Map<String, Object?> _encode(SupportCard card) => switch (card) {
    SupportGuidanceCard c => {'type': 'guidance', 'target': c.target.name},
    QuickActionChipsCard c => {
      'type': 'quick',
      'title': c.title,
      'subtitle': c.subtitle,
      'actions': c.actions
          .map((a) => {'id': a.id, 'label': a.label, 'subtitle': a.subtitle})
          .toList(),
    },
    DiagnosticCheckCard c => {
      'type': 'diagnostic',
      'checkId': c.checkId,
      'title': c.title,
      'summary': c.summary,
      'status': c.status.name,
      'findings': c.findings,
    },
    SetupActionCard c => {
      'type': 'setup',
      'topicId': c.topicId,
      'title': c.title,
      'description': c.description,
      'steps': c.steps,
      'primaryActionLabel': c.primaryActionLabel,
      'secondaryActionLabel': c.secondaryActionLabel,
      'credentialMetadata': c.credentialMetadata?.toJson(),
    },
    MutationPlanCard c => {
      'type': 'plan',
      'planId': c.planId,
      'domain': c.domain,
      'title': c.title,
      'beforeSummary': c.beforeSummary,
      'afterSummary': c.afterSummary,
      'untouchedAreas': c.untouchedAreas,
      'risks': c.risks,
      'applied': c.applied,
    },
    MutationAppliedCard c => {
      'type': 'applied',
      'journalId': c.journalId,
      'domain': c.domain,
      'summary': c.summary,
      'canRollback': c.canRollback,
      'rolledBack': c.rolledBack,
    },
    SupportReportCard c => {
      'type': 'report',
      'reportId': c.reportId,
      'summary': c.summary,
      'includedSections': c.includedSections,
      'encrypted': c.encrypted,
      'fileName': c.fileName,
    },
  };
  SupportCard _decode(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'guidance':
        _keys(m, ['type', 'target']);
        // Restored JSON is a finite display destination, never a native lease.
        return SupportGuidanceCard(
          target: SupportGuidanceTarget.values.byName(_s(m, 'target')),
        );
      case 'quick':
        _keys(m, ['type', 'title', 'subtitle', 'actions']);
        final actions = m['actions'] as List;
        if (actions.length > 16) throw const FormatException();
        return QuickActionChipsCard(
          title: _s(m, 'title'),
          subtitle: _s(m, 'subtitle'),
          actions: List.unmodifiable(
            actions.map((a) {
              final item = Map<String, dynamic>.from(a as Map);
              _keys(item, ['id', 'label', 'subtitle']);
              return QuickActionItem(
                id: _s(item, 'id'),
                label: _s(item, 'label'),
                subtitle: _s(item, 'subtitle'),
              );
            }),
          ),
        );
      case 'diagnostic':
        _keys(m, ['type', 'checkId', 'title', 'summary', 'status', 'findings']);
        return DiagnosticCheckCard(
          checkId: _s(m, 'checkId'),
          title: _s(m, 'title'),
          summary: _s(m, 'summary'),
          status: SupportCheckStatus.values.byName(_s(m, 'status')),
          findings: _list(m, 'findings'),
        );
      case 'setup':
        _keys(m, [
          'type',
          'topicId',
          'title',
          'description',
          'steps',
          'primaryActionLabel',
          'secondaryActionLabel',
          'credentialMetadata',
        ]);
        final secondary = m['secondaryActionLabel'];
        if (secondary != null && secondary is! String) {
          throw const FormatException();
        }
        CredentialMetadata? credential;
        if (m['credentialMetadata'] != null) {
          final meta = Map<String, dynamic>.from(
            m['credentialMetadata'] as Map,
          );
          _keys(meta, ['configured', 'characterCount']);
          credential = CredentialMetadata.fromJson(meta);
        }
        return SetupActionCard(
          topicId: _s(m, 'topicId'),
          title: _s(m, 'title'),
          description: _s(m, 'description'),
          steps: _list(m, 'steps'),
          primaryActionLabel: _s(m, 'primaryActionLabel'),
          secondaryActionLabel: secondary as String?,
          credentialMetadata: credential,
        );
      case 'plan':
        _keys(m, [
          'type',
          'planId',
          'domain',
          'title',
          'beforeSummary',
          'afterSummary',
          'untouchedAreas',
          'risks',
          'applied',
        ]);
        if (m['applied'] != false) throw const FormatException();
        return MutationPlanCard(
          planId: _s(m, 'planId'),
          domain: _s(m, 'domain'),
          title: _s(m, 'title'),
          beforeSummary: _s(m, 'beforeSummary'),
          afterSummary: _s(m, 'afterSummary'),
          untouchedAreas: _list(m, 'untouchedAreas'),
          risks: _list(m, 'risks'),
        );
      // No executor/exporter exists: untrusted JSON cannot invent successful effects.
      case 'applied':
        throw const FormatException();
      case 'report':
        _keys(m, [
          'type',
          'reportId',
          'summary',
          'includedSections',
          'encrypted',
          'fileName',
        ]);
        if (m['encrypted'] != false || m['fileName'] != '') {
          throw const FormatException();
        }
        return SupportReportCard(
          reportId: _s(m, 'reportId'),
          summary: _s(m, 'summary'),
          includedSections: _list(m, 'includedSections'),
          fileName: '',
        );
      default:
        throw const FormatException();
    }
  }

  void _keys(Map<String, dynamic> m, List<String> keys) {
    if (m.length != keys.length || !keys.every(m.containsKey)) {
      throw const FormatException();
    }
  }

  String _s(Map<String, dynamic> m, String key) {
    final text = m[key] as String;
    if (text.length > 8192) throw const FormatException();
    return text;
  }

  List<String> _list(Map<String, dynamic> m, String key) {
    final list = m[key] as List;
    if (list.length > 64) throw const FormatException();
    return List.unmodifiable(list.map((s) => _s({'s': s}, 's')));
  }
}
