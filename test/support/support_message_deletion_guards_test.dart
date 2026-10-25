import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;

import 'helpers/support_model_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('selected deletion refuses another durable support session', () async {
    await ModelProviderFixture().run((f) async {
      final row = (await f.repo.getMessageById('old-excluded'))!;
      expect(
        await f.repo.deleteCurrentMessage(
          sessionId: ModelProviderFixture.otherSession,
          messageId: row.id,
          createdAt: row.createdAt,
          role: row.role,
          runId: row.runId,
          isCurrent: () => true,
        ),
        isFalse,
      );
      expect(await f.repo.getMessageById(row.id), row);
    }, configured: false);
  });

  test('selected deletion refuses changed durable message identity', () async {
    await ModelProviderFixture().run((f) async {
      final row = (await f.repo.getMessageById('old-excluded'))!;
      await f.repo.mutateMessage(
        messageId: row.id,
        mutate: (latest) => latest.copyWith(runId: 'replacement-run'),
      );
      expect(
        await f.repo.deleteCurrentMessage(
          sessionId: row.sessionId,
          messageId: row.id,
          createdAt: row.createdAt,
          role: row.role,
          runId: row.runId,
          isCurrent: () => true,
        ),
        isFalse,
      );
      expect((await f.repo.getMessageById(row.id))?.runId, 'replacement-run');
    }, configured: false);
  });

  test('selection loss during delete SQL rolls the transaction back', () async {
    await ModelProviderFixture().run((f) async {
      final row = (await f.repo.getMessageById('old-excluded'))!;
      var current = true;
      final interceptor = _AfterActualDelete(() => current = false);
      await f.db.runWithInterceptor(
        () => expectLater(
          f.repo.deleteCurrentMessage(
            sessionId: row.sessionId,
            messageId: row.id,
            createdAt: row.createdAt,
            role: row.role,
            runId: row.runId,
            isCurrent: () => current,
          ),
          throwsStateError,
        ),
        interceptor: interceptor,
      );
      expect(interceptor.observed, true);
      expect(current, isFalse);
      expect(await f.repo.getMessageById(row.id), row);
    }, configured: false);
  });
}

final class _AfterActualDelete extends QueryInterceptor {
  _AfterActualDelete(this.afterDelete);
  final void Function() afterDelete;
  bool observed = false;
  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runDelete(executor, statement, args);
    observed = true;
    afterDelete();
    return result;
  }
}
