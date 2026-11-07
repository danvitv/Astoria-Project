import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/session_branch_identity.dart';

void main() {
  test('legacy session resolves as its own branch', () {
    final identity = SessionBranchIdentity.resolve(
      sessionId: 'session-1',
      sessionVars: const {},
    );

    expect(identity?.branchId, 'session-1');
    expect(identity?.rootSessionId, 'session-1');
    expect(identity?.parentSessionId, isNull);
  });

  test('child identity preserves root and exact selected swipe stamp', () {
    final fork = SessionBranchIdentity.childSessionVars(
      parentSessionVars: const {},
      parentSessionId: 'parent',
      branchSessionId: 'child',
      forkMessage: const ChatMessage(
        id: 'message-9',
        role: 'assistant',
        content: 'selected',
        swipeId: 2,
        agentSwipeId: 4,
      ),
    );

    final identity = SessionBranchIdentity.resolve(
      sessionId: 'child',
      sessionVars: fork,
    );
    expect(identity?.branchId, 'child');
    expect(identity?.rootSessionId, 'parent');
    expect(identity?.parentSessionId, 'parent');
    expect(identity?.forkMessageId, 'message-9');
    expect(identity?.forkSwipeId, 2);
    expect(identity?.forkAgentSwipeId, 4);
  });

  test('malformed or mismatched explicit identity is rejected', () {
    expect(
      SessionBranchIdentity.resolve(
        sessionId: 'session-1',
        sessionVars: const {
          SessionBranchIdentity.branchIdKey: 'different-session',
          SessionBranchIdentity.rootSessionIdKey: 'root',
        },
      ),
      isNull,
    );
    expect(
      SessionBranchIdentity.resolve(
        sessionId: 'child',
        sessionVars: const {
          SessionBranchIdentity.branchIdKey: 'child',
          SessionBranchIdentity.rootSessionIdKey: 'root',
          SessionBranchIdentity.parentSessionIdKey: 'parent',
          SessionBranchIdentity.forkStampKey: '{bad-json',
        },
      ),
      isNull,
    );
  });
}
