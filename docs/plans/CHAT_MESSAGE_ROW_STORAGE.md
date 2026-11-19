# Построчное хранение сообщений чата

**Статус:** срезы A–B реализованы локально; C–E остаются в плане.
**Дата:** 2026-11-19.  
**Исходная точка:** `c75db9e4` (`fix(chat): reduce long-session regeneration stalls`).  
**Область:** `chat_sessions.messages_json`, `ChatRepo`, prompt assembly,
backup/restore, cloud sync, native history и служебные читатели истории.

## 1. Причина

Сейчас вся история сессии хранится одним JSON-массивом в
`chat_sessions.messages_json`. Любое изменение сообщения потенциально требует:

1. прочитать весь blob;
2. передать его из SQLite executor;
3. декодировать весь массив;
4. изменить один элемент;
5. заново сериализовать и записать весь массив.

Реальная проблемная сессия содержит 1029 сообщений и около 89 МБ в
`messages_json`. До исправления `c75db9e4` сценарий Delete → Regenerate не
показывал начало генерации более 30 секунд. После удаления лишних декодирований
и последовательных snapshot-запросов durable delete всё ещё занимает около
4,4 секунды на этой базе. Это предел blob-модели, а не повод убирать защищающий
целостность write barrier.

Построчное хранение нужно, чтобы стоимость append/edit/delete зависела от
изменяемых сообщений, а не от полного размера сессии. Само по себе оно не
устранит стоимость загрузки всей истории: для этого последующим срезом нужны
постраничный UI/read API и ограниченная token budget сборка prompt.

## 2. Цели и нецели

### Цели

- Одна строка SQLite на одно логическое сообщение.
- Append/edit/delete без чтения и перезаписи остальных сообщений.
- Сохранение точного порядка, всех swipe/agent-swipe вариантов, reasoning,
  attachments, lorebook/memory metadata и Studio outputs.
- Атомарность generation commit, canon/tracker rollback и acceptance writes.
- Безопасная, возобновляемая миграция существующих сессий без долгой работы в
  `onUpgrade` и без обязательной миграции всей базы при запуске.
- Сохранение внешних backup/import форматов на первом этапе.
- Возможность читать историю с конца диапазонами для prompt token budget.

### Нецели первого этапа

- Не раскладывать каждое поле `ChatMessage`, swipe, attachment или Studio output
  в отдельную таблицу.
- Не менять пользовательский формат backup только ради внутренней схемы.
- Не убирать session write queue, ownership fences, source-currentness checks
  или compare-and-swap guards.
- Не обещать ускорение полного открытия/рендера 89-МБ чата, пока `ChatState` и
  WebView всё ещё требуют полный `List<ChatMessage>`.
- Не выполнять сетевые/provider вызовы для проверки миграции.

## 3. Инварианты

1. Каноническим является ровно один storage backend для каждой сессии:
   legacy blob либо активное поколение message rows.
2. Незавершённые staging-строки никогда не видны обычным читателям.
3. Переключение legacy → rows происходит атомарно после проверки количества,
   порядка и содержимого.
4. `message_id` нельзя использовать как физический primary key: legacy-данные
   могут содержать пустые или неуникальные ID. Позиционное поведение должно
   сохраниться.
5. Swipe identity остаётся тройкой `messageId/swipeId/agentSwipeId`; выбор
   варианта и tracker/canon anchors не должны приблизительно сопоставляться.
6. Generation result не может примениться после изменения base revision,
   target message или выбранной вариации.
7. Session deletion каскадно удаляет активные и staging message rows.
8. Ошибка, отмена, disk-full или падение процесса до переключения оставляют
   legacy blob каноническим и пригодным для повторной попытки.
9. Порядок сообщений задаётся storage-полем, а не timestamp или message ID.
10. Экспорт и импорт должны давать логически тот же упорядоченный список
    `ChatMessage`, независимо от внутреннего backend.

## 4. Предлагаемая схема

Названия окончательно утвердить вместе с Drift-моделью. Базовый вариант:

```sql
CREATE TABLE chat_message_rows (
  row_id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id          TEXT NOT NULL,
  storage_generation  INTEGER NOT NULL,
  position_key        INTEGER NOT NULL,
  message_id          TEXT NOT NULL,
  role                TEXT NOT NULL,
  message_timestamp   INTEGER,
  message_json        TEXT NOT NULL,
  updated_at          INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(session_id) REFERENCES chat_sessions(session_id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_chat_message_rows_position
  ON chat_message_rows(session_id, storage_generation, position_key);

CREATE INDEX idx_chat_message_rows_message_id
  ON chat_message_rows(session_id, storage_generation, message_id);
```

В `chat_sessions` либо в отдельной storage-state таблице нужны:

```text
message_storage_version      0 = legacy blob, 1 = message rows
active_message_generation   поколение, видимое читателям
message_revision            монотонная CAS/revision граница
message_count               дешёвая metadata-проекция
```

Дополнительные cached metadata (`first timestamp`, `last preview`, origin)
добавлять только для уже существующих запросов, которые сейчас используют
SQLite JSON-функции над blob. Кэши обновляются в той же транзакции, что rows.

### Почему `message_json` остаётся

На первом этапе вся сериализованная форма одного `ChatMessage` остаётся в
одной строке. Это сохраняет Freezed/JSON codec и снижает риск потери редких
полей. `message_id`, `role` и timestamp — индексируемые проекции; helper записи
обязан получать их из того же объекта и проверять согласованность.

Swipes можно вынести отдельно позже, только если измерения покажут отдельные
многомегабайтные сообщения. Сейчас основная проблема — 89-МБ session blob.

### Порядок

`position_key` — 64-битный ключ порядка с промежутками. Append получает ключ
после последнего; delete не требует перенумерации. Если операция вставки между
двумя соседними ключами исчерпала промежуток, репозиторий перенумеровывает одну
сессию внутри её write queue. Нельзя использовать timestamp как порядок.

## 5. Repository API

Сначала ввести storage abstraction, чтобы feature-код не выбирал backend:

```text
loadSessionMetadata(sessionId)
loadAllMessages(sessionId)
loadMessageRange(sessionId, beforePosition, limit)
loadMessageByIdentity(sessionId, messageId, occurrence/position)
appendMessage(... expectedRevision ...)
mutateMessage(... expectedRevision/identity ...)
deleteMessages(... expectedRevision ...)
replaceOrderedMessages(...)       // только для branch/import/repair
streamMessagesForExport(sessionId)
```

`ChatSession` можно временно продолжать собирать с полным `messages`, но новые
mutation paths не должны проходить через `mutateSession`, если меняется одно
сообщение. Session metadata и message writes должны иметь раздельные методы.

Любая feature-операция, которой одновременно нужны rows и tracker/canon/
manifest/acceptance записи, выполняет их в одной Drift-транзакции. Возвращаемое
состояние строится из уже известных изменённых объектов, а не повторной полной
загрузки.

## 6. Миграция

### 6.1 Schema upgrade

Следующая версия схемы только создаёт таблицу, индексы и storage-state поля.
`onUpgrade` не декодирует `messages_json` и не мигрирует все сессии.

Новые установки и новые сессии после включения feature сразу используют rows.
Старые сессии остаются `message_storage_version = 0`, пока не мигрированы.

### 6.2 Lazy/resumable migration одной сессии

1. Прочитать legacy row и зафиксировать исходные `message_revision`, размер и
   hash `messages_json`.
2. Выделить новое `storage_generation`.
3. Один раз декодировать blob и писать staging rows ограниченными batch.
4. После каждого batch сохранять resumable progress; staging generation не
   виден обычным читателям.
5. Проверить count, порядок, обязательные проекции и rolling hash
   канонического JSON представления.
6. Под session write queue выполнить короткую транзакцию и CAS-проверку, что
   исходный blob/revision не изменился.
7. Атомарно выставить `message_storage_version = 1`, активное generation,
   count и увеличить revision.
8. Очистить legacy blob только в согласованной политикой точке. До решения о
   downgrade/rollback он может временно оставаться frozen fallback, но после
   переключения не должен синхронно перезаписываться при каждой mutation.
9. Удалить старые/stale staging generations после успешного переключения либо
   при следующем обслуживании.

Если CAS не прошёл, staging generation удаляется или переиспользуется только
после полной повторной валидации. Нельзя объединять строки со свежим blob.

### 6.3 Когда запускать

- Не при startup schema upgrade.
- Предпочтительно при открытии сессии в idle/preparation состоянии либо перед
  первой mutation, с явным progress/cancel поведением для патологических
  размеров.
- Фоновую массовую миграцию добавлять только после доказанной надёжности
  миграции одной сессии и с проверками места на диске/питания.
- До переключения пользователь может продолжать работать через legacy path.

### 6.4 Место на диске и WAL

Во время миграции одновременно существуют blob, staging rows и WAL. Перед
стартом нужна консервативная оценка свободного места. Нехватка места оставляет
legacy backend активным. Нельзя очищать исходный blob до durable commit и
проверки rows.

Отдельно решить downgrade policy: более старая версия приложения не должна
тихо увидеть `[]` вместо истории. Допустимые варианты — запрет открытия более
новой схемы, frozen legacy snapshot на переходный релиз или явный экспорт перед
необратимой очисткой.

## 7. Потребители, которые надо перевести

По текущему коду прямые или косвенные зависимости включают:

- `ChatRepo` и все append/mutate/delete/generation commit paths;
- session metadata/history list projections, использующие JSON-функции;
- session branching, clone, rewrite и repair operations;
- prompt/history assembly и context budget preflight;
- tracker snapshots, canon rollback, lorebook manifests и acceptance events;
- chat embeddings и Memory/Links source readers;
- cloud sync adapters;
- backup exporter и Flutter/JS/ST/TavernAI importers;
- native history index/invalidation triggers;
- database health/JSON shape checks и restore engine;
- support navigation/report/text readers;
- card evolution и другие сервисы, которые сейчас напрямую декодируют
  `messages_json`.

До переключения первой production-сессии grep по `messages_json` и прямым SQL
`chat_sessions` должен быть классифицирован: legacy-only migration, abstraction
consumer либо намеренный metadata reader. Просто заменить `ChatRepo` недостаточно.

## 8. Поставки

### Срез A — схема и read abstraction

- Добавить таблицу/state и migration без переноса payload.
- Ввести единый reader с legacy/rows backend.
- Добавить per-message codec/projection validation.
- Перевести metadata projection с JSON-функций на backend-neutral контракт.
- Добавить parity-тесты; production sessions всё ещё legacy.

**Выход:** обе формы дают идентичный упорядоченный `List<ChatMessage>`, schema
upgrade быстрый и не зависит от размера истории.

### Срез B — row writes для новых сессий

- Новые сессии пишутся только в rows.
- Реализовать атомарные append/edit/delete/swipe/generation commit paths.
- Перевести branch/import/export/backup и критические direct consumers.
- Перенести native history invalidation на session revision/row mutations.

**Выход:** полный пользовательский chat flow работает без `messages_json` у
новой сессии; mutation одного сообщения не декодирует и не пишет остальные.

### Срез C — lazy migration legacy-сессий

- Staging generation, resumable batches, CAS switch, cleanup.
- UI/status для долгой миграции и безопасная отмена.
- Disk-space, crash-resume и race coverage.
- Сначала ручной opt-in/dev preview, затем bounded automatic policy.

**Выход:** копия реальной 89-МБ сессии мигрируется, повторно открывается и
проходит Delete → Regenerate без semantic drift.

### Срез D — bounded reads

- Добавить range/cursor API от хвоста истории.
- Prompt assembler читает назад до token budget и отдельно получает нужные
  summaries/memory/anchors.
- При необходимости WebView/ChatState переходят на paged history, сохраняя
  корректность поиска, selection, delete и scroll anchors.
- Только после этого оценить удаление полного-list API из обычного chat flow.

**Выход:** preparation и пиковая память не обязаны масштабироваться со всем
89-МБ payload, когда модель использует только ограниченное окно.

### Срез E — завершение перехода

- Миграция всех поддерживаемых legacy shapes доказана.
- Определена downgrade policy.
- Удалены obsolete blob writers и совместимые только с ними triggers.
- Legacy column удалять лишь отдельной table-rebuild миграцией, если выигрыш
  оправдывает риск; оставить неиспользуемую колонку допустимо.

## 9. Проверки и конечный evidence budget

### Семантическая эквивалентность

- Round-trip всех полей `ChatMessage`, включая пустые/повторные IDs, swipes,
  agent swipes, continuation, reasoning, attachments, lorebook/memory metadata
  и Studio outputs.
- Сохранение порядка после append, middle delete, bulk delete, branch и import.
- Один и тот же prompt/history input до и после миграции при одинаковом token
  budget.
- Точные tracker/canon/manifest identities и rollback bases.

### Атомарность и races

- Generation commit против delete/edit/swipe/session switch.
- Migration против draft save, send, regenerate, branch и session deletion.
- Падение/отмена/disk-full после каждого migration batch и до/после switch.
- Stale staging rows никогда не читаются как активные.
- Повторный запуск миграции идемпотентен.

### Интеграции

- Backup → restore и export → import для legacy и row-backed сессий.
- Cloud sync payload parity либо версионированное обновление протокола.
- Native history invalidation и source-currentness fences.
- Database health/repair на mixed-storage базе.

### Производительность

На одной и той же приватной копии 1029-message / 89-МБ базы, без сети:

- измерить open, append, edit, swipe, delete, Regenerate preparation и prompt
  assembly до/после;
- подтвердить по instrumentation, что single-message mutation не декодирует и
  не сериализует полный legacy payload;
- измерить main-isolate heartbeat, SQLite/WAL bytes, peak RSS и размер базы;
- отдельно измерить row storage до и после bounded prompt reads, не смешивая
  два эффекта.

Debug emulator timing годится для сравнительного воспроизведения, но итоговые
latency/memory claims требуют profile/release проверки хотя бы на одном
физическом Android-устройстве.

### Условия остановки проверки

Поставка считается готовой, когда её собственный выходной критерий выполнен,
сфокусированные DB/race/backup тесты проходят и соответствующий реальный flow
проверен. Не требуется ждать paged UI, чтобы принять row-backed mutation path;
нельзя, однако, называть storage migration решением полной prompt latency до
среза D.

## 10. Риски и решения до реализации

1. **Downgrade:** сколько времени хранить frozen blob и как старая версия
   должна отвергать новую схему.
2. **Canonical JSON hash:** определить стабильное представление, не зависящее
   от порядка map keys, либо проверять структурный rolling digest.
3. **Migration trigger:** при открытии, перед первой mutation или только через
   явное обслуживание на первом preview-этапе.
4. **UI pagination:** сохранить поиск, scroll anchors, multi-select и bulk
   delete без скрытой полной загрузки.
5. **Cloud protocol:** собирать старый массив на границе или версионировать
   message-level sync. На первом этапе предпочтительнее сохранить протокол.
6. **Крупное одиночное сообщение:** установить наблюдаемый порог, после которого
   отдельно проектировать swipe/output rows; не усложнять v1 заранее.
7. **Revision ownership:** определить единственный источник revision bump, чтобы
   draft/session-metadata writes не инвалидировали generation без причины, а
   message mutations всегда инвалидировали stale commits.

## 11. Рекомендуемый следующий шаг

Начать только со среза A: Drift schema, backend-neutral reader и parity fixtures
для нескольких legacy shapes. Не включать automatic migration и не менять
production write path в том же коммите. После доказанной read parity сделать
одну новую row-backed сессию end-to-end и лишь затем проектировать переключение
существующей 89-МБ сессии.
