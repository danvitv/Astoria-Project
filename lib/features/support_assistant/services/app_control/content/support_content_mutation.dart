import '../../../models/support_app_action.dart';

enum SupportContentDomain { character, persona, lorebook, preset, studioPreset }

/// Native source fences are NOT read permission. The original-run composition
/// must map an exact content target to all its existing source owners. The
/// current sourceAccess port is reserved; this lane never invents its authority.
abstract interface class SupportContentMutationPort {
  SupportContentMutationLease? begin({
    required SupportContentDomain domain,
    required String target,
    required Object observation,
    required SupportAppActionContext context,
  });
}

abstract interface class SupportContentMutationLease {
  bool get isCurrent;
  void settle();
}

/// Shared execution discipline, not a generic command interpreter. A repository
/// still owns its own typed finite patch and latest-row CAS.
final class SupportContentMutation {
  const SupportContentMutation({required this.isOwnerCurrent, this.sources});
  final bool Function() isOwnerCurrent;
  final SupportContentMutationPort? sources;

  SupportAppPreparedAction prepare({
    required SupportContentDomain domain,
    required String target,
    required Object observation,
    required SupportAppActionContext context,
    required Future<bool> Function(bool Function() current) persist,
    required void Function() refresh,
    bool createsNew = false,
    Map<String, Object?> preview = const {},
  }) {
    var started = false;
    bool observed() => !started && isOwnerCurrent() && context.current;
    return SupportAppPreparedAction(
      target: '${domain.name}:$target',
      observation: observation,
      observationIsCurrent: observed,
      preview: {
        'domain': domain.name,
        'id': target,
        ...preview,
        'undoAvailable': false,
      },
      execute: (admitted) async {
        if (started || !admitted() || !isOwnerCurrent()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        started = true; // Claim before the source port or any await/reentry.
        SupportContentMutationLease? lease;
        if (!createsNew) {
          final source = sources;
          if (source == null) {
            return SupportAppActionOutcome(SupportAppActionCode.unavailable);
          }
          lease = source.begin(
            domain: domain,
            target: target,
            observation: observation,
            context: context,
          );
          if (lease == null) {
            return SupportAppActionOutcome(SupportAppActionCode.unavailable);
          }
        }
        bool current() =>
            admitted() &&
            isOwnerCurrent() &&
            (lease == null || lease.isCurrent) &&
            admitted();
        try {
          if (!current()) {
            return SupportAppActionOutcome(SupportAppActionCode.stale);
          }
          final changed = await persist(current);
          if (!changed) {
            return SupportAppActionOutcome(
              current()
                  ? SupportAppActionCode.conflict
                  : SupportAppActionCode.stale,
            );
          }
          // Refresh the captured owner only, never a replacement run/Ref graph.
          var refreshPending = !isOwnerCurrent();
          if (!refreshPending) {
            try {
              refresh();
            } catch (_) {
              refreshPending = true;
            }
          }
          return SupportAppActionOutcome(
            current()
                ? SupportAppActionCode.completed
                : SupportAppActionCode.stale,
            effect: SupportAppActionEffect.persisted,
            data: {
              'id': target,
              'domain': domain.name,
              'refreshPending': refreshPending,
            },
          );
        } finally {
          lease?.settle();
        }
      },
    );
  }
}

abstract final class SupportContentArguments {
  static const id = SupportAppActionField.text(
    128,
    pattern: r'^[A-Za-z0-9][A-Za-z0-9_.:-]*$',
  );
  // New user-supplied content, NOT an assertion that stored text is metadata.
  static const newText = SupportAppActionField.text(256);

  static void shape(
    Map<String, Object?> arguments,
    Set<String> allowed,
    Set<String> required,
  ) {
    if (!required.every(arguments.containsKey) ||
        !arguments.keys.every(allowed.contains)) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
  }

  static String text(Map<String, Object?> arguments) {
    final value = arguments['text'];
    final clear = arguments['clearText'];
    if (value is String && clear == null) return value;
    if (value == null && clear == true) return '';
    throw const SupportAppActionRefused(SupportAppActionCode.invalidArguments);
  }

  static void validate(
    SupportAppActionDefinition definition,
    Map<String, Object?> arguments,
  ) {
    if (!definition.accepts(arguments)) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
  }
}
