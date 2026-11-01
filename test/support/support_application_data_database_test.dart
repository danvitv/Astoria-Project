import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/support/source_navigation.dart' as nav;
import 'package:glaze_flutter/features/support_assistant/services/support_model_native_provenance_validator.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'helpers/support_automatic_sources_fixture.dart';
import 'support_app_backup_loop_native.dart';

Future<void> _seed(AutomaticSourcesFixture f) async {
  final db = f.native.db;
  await db.customStatement(
    'INSERT INTO characters(char_id,name,description,gallery_json,extensions_json) VALUES(?,?,?,?,?)',
    [
      'data-character',
      'Reader character',
      'SAVED_CARD_BODY',
      jsonEncode([
        {
          'id': 'gallery-private-id',
          'characterId': 'data-character',
          'imagePath': 'inert/gallery.png',
          'label': 'Saved gallery caption',
        },
      ]),
      jsonEncode({
        'depth_prompt': {'prompt': 'SAVED_DEPTH_PROMPT', 'depth': 4},
        'apiKey': 'UNREGISTERED_CARD_SECRET',
        'headers': {'X-Strange': 'UNREGISTERED_HEADER_SECRET'},
      }),
    ],
  );
  await db.customStatement(
    "INSERT INTO characters(char_id,name,description,hidden) VALUES('hidden-data-character','Hidden card','HIDDEN_CARD_BODY',1)",
  );
  await db.customStatement(
    'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json,session_vars_json,authors_note_json,draft,updated_at) VALUES(?,?,?,?,?,?,?,?)',
    [
      'data-game',
      'data-character',
      0,
      jsonEncode([
        {
          'id': 'data-message',
          'role': 'assistant',
          'content': 'SAVED_ACTIVE_CONTENT',
          'timestamp': 1,
          'swipes': ['SAVED_ACTIVE_CONTENT', 'SAVED_OTHER_VARIATION'],
          'swipeId': 0,
          'reasoning': 'SAVED_REASONING',
          'imagePath': 'inert/attachment.png',
          'extraImagePaths': ['inert/second.png'],
          'imageHidden': true,
        },
      ]),
      jsonEncode({
        'sessionName': 'Reader named session',
        'customVariable': 'SAVED_VARIABLE',
        'password': 'UNREGISTERED_VARIABLE_SECRET',
      }),
      jsonEncode({'content': 'SAVED_AUTHORS_NOTE', 'enabled': true}),
      'SAVED_DRAFT',
      2,
    ],
  );
  await db.customStatement(
    "INSERT INTO personas(persona_id,name,prompt) VALUES('data-persona','Reader persona','SAVED_PERSONA_PROMPT')",
  );
  await db.customStatement(
    'INSERT INTO lorebooks(lorebook_id,name,entries_json,settings_json) VALUES(?,?,?,?)',
    [
      'data-lorebook',
      'Reader lorebook',
      jsonEncode([
        {
          'id': 'private-entry',
          'content': 'SAVED_LOREBOOK_BODY',
          'keys': ['lore'],
          'enabled': true,
          'headers': {'X-Strange': 'UNREGISTERED_LORE_SECRET'},
        },
      ]),
      jsonEncode({'scanDepth': 4, 'vectorSearchEnabled': true}),
    ],
  );
  await db.customStatement(
    "INSERT INTO character_folders(folder_id,name) VALUES('data-folder','Saved folder')",
  );
  await db.customStatement(
    "INSERT INTO character_folder_members(folder_id,char_id) VALUES('data-folder','data-character')",
  );
  await db.customStatement(
    "INSERT INTO studio_config_rows(session_id,enabled) VALUES('data-game',1)",
  );
  await db.customStatement(
    'INSERT INTO character_session_baseline_rows(chat_session_id,character_id,baseline_card_json,baseline_hash) VALUES(?,?,?,?)',
    [
      'data-game',
      'data-character',
      jsonEncode({'name': 'Baseline', 'description': 'SAVED_BASELINE_CARD'}),
      'private-baseline-hash',
    ],
  );
  await db.customStatement(
    "INSERT INTO character_revision_rows(character_id,revision,revision_hash,snapshot_json) VALUES('data-character',1,'private-revision-hash','{\"description\":\"SAVED_REVISION_CARD\"}')",
  );
  await db.customStatement(
    "INSERT INTO session_lorebook_evolution_rows(chat_session_id,lorebook_id,entry_id,base_content,base_content_hash,content,content_hash,created_at,updated_at) VALUES('data-game','data-lorebook','private-entry','SAVED_BASE_LORE','private-base-hash','SAVED_EVOLVED_LORE','private-content-hash',1,2)",
  );
  await db.customStatement(
    "INSERT INTO rewrite_jobs(id,chat_session_id,character_id,status,request_json) VALUES('data-rewrite','data-game','data-character','pending','{\"prompt\":\"SAVED_REWRITE_REQUEST\"}')",
  );
  await db.customStatement(
    "INSERT INTO rewrite_operations(id,rewrite_job_id,chat_session_id,operation_json) VALUES('data-operation','data-rewrite','data-game','{\"newValue\":\"SAVED_REWRITE_OPERATION\"}')",
  );
  await db.customStatement(
    "INSERT INTO rewrite_operation_revisions(rewrite_operation_id,revision,snapshot_json) VALUES('data-operation',1,'{\"newValue\":\"SAVED_OPERATION_REVISION\"}')",
  );
  await db.customStatement(
    "INSERT INTO rewrite_evidence_rows(id,rewrite_operation_id,evidence_json) VALUES('data-evidence','data-operation','{\"text\":\"SAVED_REWRITE_EVIDENCE\"}')",
  );
  await db.customStatement(
    "INSERT INTO card_evolution_debug_runs(session_id,stage,status,model,output,attempts_json,updated_at) VALUES('data-game','card','failed','synthetic','SAVED_TRUNCATED_DIAGNOSTIC','[]',1)",
  );
  await db.customStatement(
    "INSERT INTO session_canon_checkpoint_rows(id,chat_session_id,sequence,character_id,character_revision,character_revision_hash,created_at) VALUES('data-checkpoint','data-game',0,'data-character',1,'private-card-hash',1)",
  );
  await db.customStatement(
    "INSERT INTO session_lorebook_revision_rows(checkpoint_id,chat_session_id,lorebook_id,entry_id,base_content_hash,previous_content_hash,content,content_hash,rewrite_operation_id,created_at) VALUES('data-checkpoint','data-game','data-lorebook','private-entry','private-base','private-previous','SAVED_LORE_REVISION','private-content','data-operation',1)",
  );
  await db.customStatement(
    "INSERT INTO lorebook_use_manifests(session_id,message_id,swipe_id,agent_swipe_id,manifest_json,created_at) VALUES('data-game','data-message',0,0,'{\"entries\":[{\"content\":\"SAVED_USE_MANIFEST\"}]}',1)",
  );
  await db.customStatement(
    "INSERT INTO lorebook_use_manifest_entries(session_id,message_id,swipe_id,agent_swipe_id,lorebook_id,entry_id,entry_order,evidence_json) VALUES('data-game','data-message',0,0,'data-lorebook','private-entry',0,'{\"text\":\"SAVED_USE_EVIDENCE\"}')",
  );
  await db.customStatement(
    "INSERT INTO lorebook_use_acceptance_records(acceptance_id,session_id,message_id,swipe_id,agent_swipe_id,acceptance_kind,accepted_by_user_message_id,evidence_json,accepted_at) VALUES('data-acceptance','data-game','data-message',0,0,'variation','private-next-user','{\"text\":\"SAVED_USE_ACCEPTANCE\"}',1)",
  );
  await db.customStatement(
    "INSERT INTO card_evolution_claims(id,session_id,character_id,owner_id,status,lease_expires_at,first_run_id,second_run_id,predecessor_cursor_hash,predecessor_run_ordinal,input_hash,selected_input_json,created_at) VALUES('data-claim','data-game','data-character','NEVER_EXECUTION_OWNER','claimed',10,'private-history-hash','private-canon-hash','private-cursor',0,'private-input-hash','{\"text\":\"SAVED_CLAIM_INPUT\"}',1)",
  );
  await db.customStatement(
    "INSERT INTO card_evolution_writer_calls(id,claim_id,session_id,ordinal,stage,stage_ordinal,status,prompt,prompt_hash,created_at,updated_at) VALUES('data-writer-call','data-claim','data-game',1,'card_writer',1,'prepared','SAVED_WRITER_PROMPT','private-prompt-hash',1,1)",
  );
  await db.customStatement(
    "INSERT INTO card_evolution_observations(id,session_id,character_id,run_ordinal,semantic_scope_key,observed_change,evidence_message_ids,confidence,status,first_seen_run,created_at,updated_at) VALUES('data-observation','data-game','data-character',1,'character:trait','SAVED_OBSERVED_CHANGE','[\"private-evidence-id\"]',0.8,'active',1,1,1)",
  );
  await db.customStatement(
    "INSERT INTO extension_presets(id,name,config_json) VALUES('data-extension','Saved scripts','{\"blocks\":[{\"name\":\"Script\",\"script\":\"SAVED_INERT_SCRIPT\",\"enabled\":true}]}')",
  );
  await db.customStatement(
    "INSERT INTO info_blocks(id,session_id,message_id,block_id,block_name,block_type,content) VALUES('data-info','data-game','data-message','private-block','Saved block','generated','SAVED_INFO_CONTENT')",
  );
  await db.customStatement(
    "INSERT INTO embeddings(entry_id,source_type,source_id,vectors_blob,retrieval_hints_json) VALUES('data-vector','lorebook_entry','data-lorebook',X'01020304','{\"text\":\"SAVED_RETRIEVAL_HINT\"}')",
  );
  await db.customStatement(
    'INSERT INTO api_configs(config_id,name,api_key,embedding_api_key,extra_request_parameters_json) VALUES(?,?,?,?,?)',
    [
      'data-keyed-config',
      'NONSTANDARD_API_NAME',
      'UNREGISTERED_API_COLUMN_SECRET',
      'UNREGISTERED_EMBEDDING_COLUMN_SECRET',
      jsonEncode([
        {'key': 'min_p', 'value': '0.12', 'enabled': true},
        {
          'key': 'X-Unknown-Custom',
          'value': 'UNREGISTERED_CUSTOM_PARAMETER',
          'enabled': true,
        },
        {
          'key': 'Authorization',
          'value': 'UNREGISTERED_PARAM_CREDENTIAL',
          'enabled': false,
        },
      ]),
    ],
  );
  await f.native.repo.createSession(
    const SupportSession(
      id: 'data-other-astoria',
      title: 'Other named Astoria chat',
      createdAt: 1,
      updatedAt: 2,
    ),
  );
  await f.native.repo.putMessage(
    const SupportMessage(
      id: 'data-other-message',
      sessionId: 'data-other-astoria',
      role: 'user',
      body: 'SAVED_OTHER_ASTORIA_BODY',
      createdAt: 1,
    ),
  );
  await f.native.repo.putContextBlock(
    const SupportContextBlock(
      id: 'data-user-summary',
      sessionId: 'data-other-astoria',
      startMessageId: 'data-other-message',
      endMessageId: 'data-other-message',
      summary: 'SAVED_ASTORIA_SUMMARY',
      protectedFactsJson: 'NEVER_PROVENANCE_RECEIPT',
      createdAt: 1,
    ),
  );
  await db.customStatement(
    "INSERT INTO support_reports(id,session_id,file_hash,status) VALUES('data-report','data-other-astoria','NEVER_REPORT_FILE_HASH','exported')",
  );
  final sink = LlmRequestCaptureRepo(db);
  try {
    final capture = LlmRequestCapture.build(
      const ChatTransportRequest(
        endpoint: 'https://example.invalid/v1/chat/completions',
        apiKey: 'UNREGISTERED_TRANSPORT_SECRET',
        model: 'capture-model',
        messages: [
          {'role': 'user', 'content': 'ACTUAL_CAPTURED_REQUEST_BODY'},
        ],
        maxTokens: 64,
        temperature: 0,
        topP: 1,
        captureContext: LlmCaptureContext(
          stage: 'main',
          sessionId: 'data-game',
          pipelineRunId: 'private-pipeline',
          callId: 'private-call',
          attempt: 1,
        ),
      ),
      protocol: 'openai',
    );
    await sink.record(capture);
    await sink.record(
      LlmRequestCaptureEvent(
        sequence: capture.sequence + 1,
        createdAt: capture.createdAt,
        protocol: capture.protocol,
        context: capture.context,
        request: const {
          'messages': [
            {'role': 'assistant', 'content': 'SAVED_TRUNCATED_CAPTURE'},
          ],
        },
        truncated: true,
      ),
    );
  } finally {
    await sink.close();
  }
}

SupportSourceNavigationRepo _reader(AutomaticSourcesFixture f) =>
    SupportSourceNavigationRepo(
      boundary: SupportSourceTextRepo(
        db: f.native.db,
        cipher: f.native.cipher,
        currentRedactor: () => f.native.redaction.redactor,
      ),
      isCurrent: () => f.native.rootCurrent,
      ownSupportSessionId: f.native.session,
    );

Future<List<nav.SourceObservation>> _catalog(
  SupportSourceNavigationRepo reader,
) async {
  final page = await reader.discover(
    nav.SourceDomain.applicationData,
    null,
    null,
    const nav.WorkBound(),
  );
  expect(page.complete, true);
  expect(
    page.items.map((o) => o.key.nativeId),
    SupportApplicationDataRegistry.datasets,
  );
  return page.items;
}

Future<void> _encrypted(AutomaticSourcesFixture f, int count) async {
  final reply = (await f.native.repo.getMessagesForSession(
    f.native.session,
  )).lastWhere((m) => m.role == 'assistant');
  final block = (await f.native.repo.getContextBlockById(
    'support.reply_provenance:${reply.id}',
  ))!;
  final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
    block.protectedFactsJson,
  );
  expect(decoded.isValid, true);
  expect(decoded.recipe!.toolDisclosures, hasLength(count));
  expect(
    SupportModelNativeProvenanceValidator.validate(
      f.native.session,
      SupportTextContextProvenance(
        messageId: reply.id,
        runId: reply.runId,
        dedicatedFactsJson: block.protectedFactsJson,
      ),
      f.native.redaction.redactor,
    ),
    true,
  );
  for (final d in decoded.recipe!.toolDisclosures!) {
    expect(jsonEncode(f.wire), isNot(contains(d.snapshotDigest)));
  }
}

const _projectionCanary = 'm7v9Q2p4R8';

Future<void> _seedProjectionCorrection(AutomaticSourcesFixture f) async {
  await _seed(f);
  await f.native.db.customStatement(
    'UPDATE characters SET extensions_json=?,description=?,personality=?,first_mes=? WHERE char_id=?',
    [
      jsonEncode({
        'config': {'key': _projectionCanary},
        'settings': [
          {'Key': 'Authorization', 'value': _projectionCanary},
          {'Name': 'Authorization', 'value': _projectionCanary},
          {'na-me': 'Authorization', 'value': _projectionCanary},
          {
            'name': 'safe_setting',
            'Name': 'Authorization',
            'value': _projectionCanary,
          },
          {'header': 'Authorization', 'value': _projectionCanary},
        ],
        'depth_prompt': {'prompt': 'VISIBLE_DEPTH_CORRECTION', 'depth': 4},
      }),
      jsonEncode({'key': 'Authorization', 'value': _projectionCanary}),
      jsonEncode({
        'owner': _projectionCanary,
        'cas': _projectionCanary,
        'text': 'VISIBLE_STRUCTURED_CARD',
        'content': jsonEncode({
          'owner': _projectionCanary,
          'cas': _projectionCanary,
          'text': 'VISIBLE_NESTED_CARD',
          'settings': [
            {'Key': 'Authorization', 'value': _projectionCanary},
            {'Name': 'Authorization', 'value': _projectionCanary},
            {
              'name': 'safe_setting',
              'Name': 'Authorization',
              'value': _projectionCanary,
            },
          ],
        }),
      }),
      'VISIBLE_PLAIN_CARD: Authorization, owner and cas are words in a story.',
      'data-character',
    ],
  );
  await f.native.repo.renameSession(
    sessionId: 'data-other-astoria',
    title: jsonEncode({
      'owner': _projectionCanary,
      'cas': _projectionCanary,
      'title': 'VISIBLE_ASTORIA_TITLE',
    }),
  );
  await f.native.repo.putMessage(
    SupportMessage(
      id: 'data-other-message',
      sessionId: 'data-other-astoria',
      role: 'user',
      body: jsonEncode({'key': 'Authorization', 'value': _projectionCanary}),
      createdAt: 1,
    ),
  );
  await f.native.repo.putMessage(
    SupportMessage(
      id: 'data-structured-message',
      sessionId: 'data-other-astoria',
      role: 'assistant',
      body: jsonEncode({
        'owner': _projectionCanary,
        'cas': _projectionCanary,
        'text': 'VISIBLE_STRUCTURED_ASTORIA',
        'content': jsonEncode({
          'Key': 'Authorization',
          'value': _projectionCanary,
        }),
      }),
      createdAt: 2,
    ),
  );
  await f.native.repo.putMessage(
    const SupportMessage(
      id: 'data-plain-message',
      sessionId: 'data-other-astoria',
      role: 'user',
      body:
          'VISIBLE_PLAIN_ASTORIA: Authorization, owner and cas in plain prose.',
      createdAt: 3,
    ),
  );
  await f.native.repo.putContextBlock(
    SupportContextBlock(
      id: 'data-user-summary',
      sessionId: 'data-other-astoria',
      startMessageId: 'data-other-message',
      endMessageId: 'data-structured-message',
      summary: jsonEncode({
        'owner': _projectionCanary,
        'cas': _projectionCanary,
        'text': 'VISIBLE_STRUCTURED_SUMMARY',
        'content': jsonEncode({
          'key': 'Authorization',
          'value': _projectionCanary,
        }),
      }),
      protectedFactsJson: 'NEVER_PROVENANCE_RECEIPT',
      createdAt: 1,
    ),
  );
}

Future<List<nav.SectionDescriptor>> _allApplicationFields(
  SupportSourceNavigationRepo reader,
  nav.SourceObservation source,
) async {
  final scope = reader.approvalScope(source)!;
  final roots = await reader.contents(
    source,
    scope,
    null,
    null,
    const nav.WorkBound(),
  );
  final fields = <nav.SectionDescriptor>[];
  for (final root in roots.items) {
    Object? cursor;
    for (var pageNumber = 0; pageNumber < 16; pageNumber++) {
      final page = await reader.contents(
        source,
        scope,
        root.selection,
        cursor,
        const nav.WorkBound(),
      );
      fields.addAll(page.items);
      cursor = page.next;
      if (cursor == null) break;
      expect(pageNumber, lessThan(15), reason: 'Finite fixture continuation');
    }
  }
  return fields;
}

Future<void> _seedHiddenCorrection(AutomaticSourcesFixture f) async {
  await _seed(f);
  final db = f.native.db;
  await db.customStatement(
    "INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json) VALUES('hidden-data-game','hidden-data-character',0,'[]')",
  );
  await db.customStatement(
    "INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json) VALUES('visible-correction-game','data-character',1,'[]')",
  );
  for (final kind in ['hidden', 'visible', 'unresolved']) {
    final session = kind == 'hidden'
        ? 'hidden-data-game'
        : kind == 'visible'
        ? 'visible-correction-game'
        : 'missing-owner-session';
    final character = kind == 'hidden'
        ? 'hidden-data-character'
        : kind == 'visible'
        ? 'data-character'
        : 'missing-owner-character';
    final marker = kind == 'visible'
        ? 'VISIBLE_OWNER_BODY'
        : 'DENIED_OWNER_BODY';
    await db.customStatement(
      'INSERT INTO rewrite_jobs(id,chat_session_id,character_id,status,request_json) VALUES(?,?,?,?,?)',
      [
        '$kind-job',
        session,
        character,
        'pending',
        jsonEncode({'prompt': '${marker}_${kind}_JOB'}),
      ],
    );
    await db.customStatement(
      'INSERT INTO rewrite_operations(id,rewrite_job_id,chat_session_id,operation_json) VALUES(?,?,?,?)',
      [
        '$kind-operation',
        '$kind-job',
        session,
        jsonEncode({'newValue': '${marker}_${kind}_OPERATION'}),
      ],
    );
    await db.customStatement(
      'INSERT INTO rewrite_operation_revisions(rewrite_operation_id,revision,snapshot_json) VALUES(?,?,?)',
      [
        '$kind-operation',
        1,
        jsonEncode({'newValue': '${marker}_${kind}_REVISION'}),
      ],
    );
    await db.customStatement(
      'INSERT INTO rewrite_evidence_rows(id,rewrite_operation_id,evidence_json) VALUES(?,?,?)',
      [
        '$kind-evidence',
        '$kind-operation',
        jsonEncode({'text': '${marker}_${kind}_EVIDENCE'}),
      ],
    );
    await db.customStatement(
      'INSERT INTO applied_canon_transition_rows(id,chat_session_id,character_id,canonical_claim,transition_json) VALUES(?,NULL,?,?,?)',
      [
        '$kind-transition',
        character,
        '${marker}_${kind}_TRANSITION',
        jsonEncode({'text': '${marker}_${kind}_TRANSITION_JSON'}),
      ],
    );
    await db.customStatement(
      'INSERT INTO character_knowledge_fact_rows(id,chat_session_id,knower_key,subject_key,fact_class,predicate,object,epistemic_state) VALUES(?,?,?,?,?,?,?,?)',
      [
        '$kind-fact',
        session,
        'narrator',
        'subject',
        'state',
        'is',
        'saved',
        'known',
      ],
    );
    await db.customStatement(
      'INSERT INTO canon_transition_fact_refs(applied_canon_transition_id,character_knowledge_fact_id) VALUES(?,?)',
      ['$kind-transition', '$kind-fact'],
    );
  }
  // Direct hidden ownership must still deny a transition bound to a visible
  // session; conversely, a hidden/missing selected session denies a visible card.
  for (final (id, session, character) in [
    ('direct-hidden', 'data-game', 'hidden-data-character'),
    ('session-hidden', 'hidden-data-game', 'data-character'),
    ('session-missing', 'missing-owner-session', 'data-character'),
  ]) {
    await db.customStatement(
      'INSERT INTO applied_canon_transition_rows(id,chat_session_id,character_id,canonical_claim,transition_json) VALUES(?,?,?,?,?)',
      [id, session, character, 'DENIED_OWNER_BODY_${id}_TRANSITION', '{}'],
    );
  }
  // Descendants with a missing operation have no resolvable owner at all.
  await db.customStatement(
    "INSERT INTO rewrite_operation_revisions(rewrite_operation_id,revision,snapshot_json) VALUES('missing-operation',1,'{\"text\":\"DENIED_OWNER_BODY_ORPHAN_REVISION\"}')",
  );
  await db.customStatement(
    "INSERT INTO rewrite_evidence_rows(id,rewrite_operation_id,evidence_json) VALUES('orphan-evidence','missing-operation','{\"text\":\"DENIED_OWNER_BODY_ORPHAN_EVIDENCE\"}')",
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'correction projection key and JSON-in-string exclusions precede search, every issued body read and actual continuation POST',
    () async {
      await automaticSourcesTest((f) async {
        await _seedProjectionCorrection(f);
        final reader = _reader(f);
        try {
          final catalog = await _catalog(reader);
          for (final name in ['savedCharacters', 'astoriaSavedContext']) {
            final source = catalog.singleWhere((o) => o.key.nativeId == name);
            final denied = await reader.search(
              source,
              reader.approvalScope(source)!,
              'm7v9',
              null,
              null,
              const nav.WorkBound(),
            );
            expect(denied.items, isEmpty, reason: '$name: no secret selector');
            final readable = <Object?>[];
            // A literal search scans each complete projected row, but issues
            // only the relevant selectors. Do not exhaust the intentionally
            // bounded 128-selector source cache by dumping unrelated defaults.
            Object? cursor;
            for (var pageNumber = 0; pageNumber < 16; pageNumber++) {
              final matching = await reader.search(
                source,
                reader.approvalScope(source)!,
                'VISIBLE_',
                null,
                cursor,
                const nav.WorkBound(),
              );
              for (final field in matching.items) {
                final read = await reader.read(
                  source,
                  reader.approvalScope(source)!,
                  nav.ReadQuery(field.selection, 0, 0),
                  const nav.WorkBound(),
                );
                expect(
                  jsonEncode(read.items.single.payload),
                  isNot(contains(_projectionCanary)),
                );
                readable.add(read.items.single.payload);
              }
              cursor = matching.next;
              if (cursor == null) break;
              expect(
                pageNumber,
                lessThan(15),
                reason: 'Finite matching continuation',
              );
            }
            expect(
              jsonEncode(readable),
              contains(
                name == 'savedCharacters'
                    ? 'VISIBLE_DEPTH_CORRECTION'
                    : 'VISIBLE_STRUCTURED_SUMMARY',
              ),
            );
            if (name == 'savedCharacters') {
              expect(jsonEncode(readable), contains('VISIBLE_NESTED_CARD'));
            }
          }
          final api = catalog.singleWhere(
            (o) => o.key.nativeId == 'apiConfigurations',
          );
          final parameterMatches = await reader.search(
            api,
            reader.approvalScope(api)!,
            'min_p',
            null,
            null,
            const nav.WorkBound(),
          );
          final parameterField = parameterMatches.items.singleWhere(
            (field) => field.label!.endsWith('extra_request_parameters_json'),
          );
          final parameters = await reader.read(
            api,
            reader.approvalScope(api)!,
            nav.ReadQuery(parameterField.selection, 0, 0),
            const nav.WorkBound(),
          );
          expect(parameters.items.single.payload, [
            {'parameter': 'min_p', 'value': 0.12, 'enabled': true},
          ]);
          final chat = (await reader.discover(
            nav.SourceDomain.astoriaConversation,
            null,
            null,
            const nav.WorkBound(),
          )).items.singleWhere((o) => o.key.nativeId == 'data-other-astoria');
          final denied = await reader.search(
            chat,
            reader.approvalScope(chat)!,
            'm7v9',
            null,
            null,
            const nav.WorkBound(),
          );
          expect(denied.items, isEmpty);
          final contents = await reader.contents(
            chat,
            reader.approvalScope(chat)!,
            null,
            null,
            const nav.WorkBound(),
          );
          expect(contents.items, hasLength(3));
          for (final field in contents.items) {
            final read = await reader.read(
              chat,
              reader.approvalScope(chat)!,
              nav.ReadQuery(field.selection, 0, 0),
              const nav.WorkBound(),
            );
            expect(
              jsonEncode(read.items.single.payload),
              isNot(contains(_projectionCanary)),
            );
          }
        } finally {
          reader.retire();
        }
        late String cards, summaries, chat;
        f.script = (round) async {
          if (round == 1) {
            return AutomaticSourcesFixture.calls([
              (
                'datasets',
                'astoria_sources_list',
                {'domain': 'applicationData'},
              ),
              (
                'chats',
                'astoria_sources_list',
                {'domain': 'astoriaConversation'},
              ),
            ]);
          }
          if (round == 2) {
            final datasets = f.result('datasets')['data']['pieces'] as List;
            cards =
                datasets.singleWhere(
                      (p) => p['label'] == 'Saved character cards',
                    )['source']
                    as String;
            summaries =
                datasets.singleWhere(
                      (p) =>
                          p['label'] ==
                          'Astoria saved summaries, settings and action/report status',
                    )['source']
                    as String;
            chat =
                (f.result('chats')['data']['pieces'] as List).singleWhere(
                      (p) => (p['title'] as String).contains(
                        'VISIBLE_ASTORIA_TITLE',
                      ),
                    )['source']
                    as String;
            return AutomaticSourcesFixture.calls([
              (
                'deny-card',
                'astoria_source_search',
                {'source': cards, 'literal': 'm7v9'},
              ),
              (
                'deny-summary',
                'astoria_source_search',
                {'source': summaries, 'literal': 'm7v9'},
              ),
              (
                'deny-chat',
                'astoria_source_search',
                {'source': chat, 'literal': 'm7v9'},
              ),
              (
                'card',
                'astoria_source_search',
                {'source': cards, 'literal': 'VISIBLE_STRUCTURED_CARD'},
              ),
              (
                'plain-card',
                'astoria_source_search',
                {'source': cards, 'literal': 'VISIBLE_PLAIN_CARD'},
              ),
              (
                'summary',
                'astoria_source_search',
                {'source': summaries, 'literal': 'VISIBLE_STRUCTURED_SUMMARY'},
              ),
              (
                'chat',
                'astoria_source_search',
                {'source': chat, 'literal': 'VISIBLE_STRUCTURED_ASTORIA'},
              ),
              (
                'plain-chat',
                'astoria_source_search',
                {'source': chat, 'literal': 'VISIBLE_PLAIN_ASTORIA'},
              ),
            ]);
          }
          if (round == 3) {
            for (final id in ['deny-card', 'deny-summary', 'deny-chat']) {
              expect(
                f.body(id)['pieces'],
                isEmpty,
                reason: 'No secret selector',
              );
            }
            return AutomaticSourcesFixture.calls([
              for (final (id, source) in [
                ('card', cards),
                ('plain-card', cards),
                ('summary', summaries),
                ('chat', chat),
                ('plain-chat', chat),
              ])
                (
                  '$id-read',
                  'astoria_source_read',
                  {
                    'source': source,
                    'selector': f.body(id)['pieces'][0]['selector'],
                  },
                ),
            ]);
          }
          expect(round, 4);
          for (final (id, marker) in [
            ('card', 'VISIBLE_STRUCTURED_CARD'),
            ('plain-card', 'VISIBLE_PLAIN_CARD'),
            ('summary', 'VISIBLE_STRUCTURED_SUMMARY'),
            ('chat', 'VISIBLE_STRUCTURED_ASTORIA'),
            ('plain-chat', 'VISIBLE_PLAIN_ASTORIA'),
          ]) {
            expect(jsonEncode(f.body('$id-read')['pieces']), contains(marker));
          }
          await _encrypted(f, 15);
          return AutomaticSourcesFixture.answer();
        };
        final result = await (await f.start()).finished.timeout(
          const Duration(seconds: 30),
        );
        expect(result.message?.status, 'complete');
        expect(f.wire, hasLength(4));
        expect(jsonEncode(f.wire), isNot(contains(_projectionCanary)));
        expect(jsonEncode(f.wire), isNot(contains('NEVER_PROVENANCE_RECEIPT')));
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'correction malformed duplicate scalar wrong-container and shared JSON-string depth node raw budgets fail closed',
    () async {
      Object nested(Object value, int depth) {
        for (var i = 0; i < depth; i++) {
          value = {'text': value};
        }
        return value;
      }

      final cases = <(String, String, String)>[
        ('malformed-string', 'description', '{"owner":"$_projectionCanary"'),
        (
          'duplicate-string',
          'description',
          '{"text":"$_projectionCanary","text":"duplicate"}',
        ),
        (
          'duplicate-column',
          'extensions_json',
          '{"text":"$_projectionCanary","text":"duplicate"}',
        ),
        ('scalar-column', 'extensions_json', jsonEncode(_projectionCanary)),
        (
          'wrong-map-column',
          'extensions_json',
          jsonEncode([_projectionCanary]),
        ),
        (
          'wrong-array-column',
          'tags_json',
          jsonEncode({'text': _projectionCanary}),
        ),
        (
          'deep-column',
          'extensions_json',
          jsonEncode(nested(_projectionCanary, 25)),
        ),
        (
          'shared-depth',
          'description',
          jsonEncode(nested(jsonEncode(nested(_projectionCanary, 14)), 12)),
        ),
        (
          'shared-nodes',
          'description',
          jsonEncode({
            'text': jsonEncode(List.generate(160, (_) => List.filled(32, 0))),
          }),
        ),
        (
          'shared-raw',
          'description',
          jsonEncode({
            'text': jsonEncode({'text': 'x' * 25000}),
          }),
        ),
        (
          'oversized-string',
          'description',
          jsonEncode({'owner': _projectionCanary, 'text': 'x' * 70000}),
        ),
      ];
      for (final (name, field, raw) in cases) {
        await automaticSourcesTest((f) async {
          // Fixed fixture columns only, never model-supplied SQL.
          await f.native.db.customStatement(
            'INSERT INTO characters(char_id,name,"$field") VALUES(?,?,?)',
            ['budget-character', 'VISIBLE_BUDGET_ROW', raw],
          );
          final reader = _reader(f);
          try {
            final source = (await _catalog(
              reader,
            )).singleWhere((o) => o.key.nativeId == 'savedCharacters');
            final denied = await reader.search(
              source,
              reader.approvalScope(source)!,
              'm7v9',
              null,
              null,
              const nav.WorkBound(),
            );
            expect(denied.items, isEmpty, reason: name);
            expect(denied.complete, false, reason: name);
            expect(denied.next, isNull, reason: 'No retry loop: $name');
            final fields = await _allApplicationFields(reader, source);
            final unavailable = <nav.SectionDescriptor>[];
            for (final field in fields) {
              final read = await reader.read(
                source,
                reader.approvalScope(source)!,
                nav.ReadQuery(field.selection, 0, 0),
                const nav.WorkBound(),
              );
              final payload = jsonEncode(read.items.single.payload);
              expect(payload, isNot(contains(_projectionCanary)), reason: name);
              expect(
                payload,
                isNot(contains('VISIBLE_BUDGET_ROW')),
                reason: name,
              );
              if (payload.contains(
                name == 'oversized-string'
                    ? 'oversized_complete_unit'
                    : 'unknown_saved_format',
              )) {
                unavailable.add(field);
              }
            }
            expect(
              unavailable,
              hasLength(1),
              reason: 'Exactly one unavailable target row: $name',
            );
            final id = unavailable.single.selection.recordId!;
            final targetPrefix = id.substring(0, id.lastIndexOf(':') + 1);
            expect(
              fields.where(
                (field) =>
                    field.selection.recordId?.startsWith(targetPrefix) == true,
              ),
              hasLength(1),
              reason: 'Whole target row contains only projection status: $name',
            );
          } finally {
            reader.retire();
          }
        });
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'correction hidden unresolved rewrite descendants and nullable direct-character canon owners issue no selectors bodies or outward POST',
    () async {
      await automaticSourcesTest((f) async {
        await _seedHiddenCorrection(f);
        // A hidden evidence body throws if SQL evaluates it at all. Eligibility
        // must guard both byte sizing and hydration, not merely post-read output.
        await f.native.db.customStatement(
          'CREATE TEMP VIEW rewrite_evidence_rows AS SELECT rowid AS rowid,id,rewrite_operation_id,created_at, '
          "CASE WHEN rewrite_operation_id='hidden-operation' THEN json_extract('not-json','\$') ELSE evidence_json END AS evidence_json FROM main.rewrite_evidence_rows",
        );
        expect(
          await f.native.db
              .customSelect(
                "SELECT evidence_json FROM rewrite_evidence_rows WHERE rewrite_operation_id='hidden-operation'",
              )
              .get()
              .then((_) => false, onError: (_) => true),
          true,
        );
        final reader = _reader(f);
        try {
          final catalog = await _catalog(reader);
          for (final name in ['rewrites', 'canon']) {
            final source = catalog.singleWhere((o) => o.key.nativeId == name);
            final denied = await reader.search(
              source,
              reader.approvalScope(source)!,
              'DENIED_OWNER_BODY',
              null,
              null,
              const nav.WorkBound(),
            );
            expect(denied.items, isEmpty, reason: name);
            for (final field in await _allApplicationFields(reader, source)) {
              final read = await reader.read(
                source,
                reader.approvalScope(source)!,
                nav.ReadQuery(field.selection, 0, 0),
                const nav.WorkBound(),
              );
              expect(
                jsonEncode(read.items.single.payload),
                isNot(contains('DENIED_OWNER_BODY')),
                reason: name,
              );
            }
          }
          final canon = catalog.singleWhere((o) => o.key.nativeId == 'canon');
          final roots = await reader.contents(
            canon,
            reader.approvalScope(canon)!,
            null,
            null,
            const nav.WorkBound(),
          );
          final refs = await reader.contents(
            canon,
            reader.approvalScope(canon)!,
            roots.items
                .singleWhere((s) => s.selection.sectionId == 'factReferences')
                .selection,
            null,
            const nav.WorkBound(),
          );
          // Only the visible relation: timestamp + two native positions + status.
          expect(refs.items, hasLength(4));
        } finally {
          reader.retire();
        }
        late String rewrites, canon;
        f.script = (round) async {
          if (round == 1) {
            return AutomaticSourcesFixture.calls([
              (
                'datasets',
                'astoria_sources_list',
                {'domain': 'applicationData'},
              ),
            ]);
          }
          if (round == 2) {
            final datasets = f.result('datasets')['data']['pieces'] as List;
            rewrites =
                datasets.singleWhere(
                      (p) =>
                          p['label'] == 'Saved Card Rewriter jobs and evidence',
                    )['source']
                    as String;
            canon =
                datasets.singleWhere(
                      (p) =>
                          p['label'] == 'Saved character canon and revisions',
                    )['source']
                    as String;
            return AutomaticSourcesFixture.calls([
              (
                'denied-rewrites',
                'astoria_source_search',
                {'source': rewrites, 'literal': 'DENIED_OWNER_BODY'},
              ),
              (
                'denied-canon',
                'astoria_source_search',
                {'source': canon, 'literal': 'DENIED_OWNER_BODY'},
              ),
              (
                'visible-rewrites',
                'astoria_source_search',
                {'source': rewrites, 'literal': 'VISIBLE_OWNER_BODY'},
              ),
              (
                'visible-canon',
                'astoria_source_search',
                {'source': canon, 'literal': 'VISIBLE_OWNER_BODY'},
              ),
            ]);
          }
          if (round == 3) {
            expect(f.body('denied-rewrites')['pieces'], isEmpty);
            expect(f.body('denied-canon')['pieces'], isEmpty);
            final rewritesFound = f.body('visible-rewrites')['pieces'] as List;
            expect(rewritesFound, hasLength(4));
            final canonFound = f.body('visible-canon')['pieces'] as List;
            expect(canonFound, hasLength(2));
            return AutomaticSourcesFixture.calls([
              for (var i = 0; i < rewritesFound.length; i++)
                (
                  'rewrite-read-$i',
                  'astoria_source_read',
                  {
                    'source': rewrites,
                    'selector': rewritesFound[i]['selector'],
                  },
                ),
              for (var i = 0; i < canonFound.length; i++)
                (
                  'canon-read-$i',
                  'astoria_source_read',
                  {'source': canon, 'selector': canonFound[i]['selector']},
                ),
            ]);
          }
          expect(round, 4);
          for (final id in [
            'rewrite-read-0',
            'rewrite-read-1',
            'rewrite-read-2',
            'rewrite-read-3',
            'canon-read-0',
            'canon-read-1',
          ]) {
            expect(
              jsonEncode(f.body(id)['pieces']),
              contains('VISIBLE_OWNER_BODY'),
            );
          }
          await _encrypted(f, 11);
          return AutomaticSourcesFixture.answer();
        };
        final result = await (await f.start()).finished.timeout(
          const Duration(seconds: 30),
        );
        if (f.scriptError != null)
          Error.throwWithStackTrace(f.scriptError!, f.scriptStack!);
        expect(result.message?.status, 'complete');
        expect(f.wire, hasLength(4));
        for (final kind in ['hidden', 'unresolved']) {
          expect(
            jsonEncode(f.wire),
            isNot(contains('DENIED_OWNER_BODY_$kind')),
          );
          expect(jsonEncode(f.wire), isNot(contains('$kind-operation')));
          expect(jsonEncode(f.wire), isNot(contains('$kind-transition')));
        }
        expect(jsonEncode(f.wire), isNot(contains('DENIED_OWNER_BODY_ORPHAN')));
        for (final id in [
          'direct-hidden',
          'session-hidden',
          'session-missing',
        ]) {
          expect(jsonEncode(f.wire), isNot(contains('DENIED_OWNER_BODY_$id')));
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'v139 all 64 registrations map to real readers or explicit private infrastructure; every fixed SQL projection compiles',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        final tables = f.native.db.allTables
            .map((t) => t.actualTableName)
            .toSet();
        expect(tables, hasLength(64));
        expect(
          SupportApplicationDataRegistry.tableCoverage.keys.toSet(),
          tables,
        );
        expect(
          SupportApplicationDataRegistry.tableCoverage.values.every(
            (v) => v.isNotEmpty,
          ),
          true,
        );
        expect(
          SupportApplicationDataRegistry.tableCoverage.containsKey(
            'backup_loop_extra',
          ),
          false,
        );
        final apiFields =
            SupportApplicationDataRegistry.projectedFieldsForTable(
              'api_configs',
            );
        expect(apiFields, contains('extra_request_parameters_json'));
        for (final private in ['api_key', 'embedding_api_key', 'config_id']) {
          expect(apiFields, isNot(contains(private)));
        }
        expect(
          SupportApplicationDataRegistry.projectedFieldsForTable('embeddings'),
          isNot(contains('vectors_blob')),
        );
        expect(
          SupportApplicationDataRegistry.projectedFieldsForTable(
            'support_context_blocks',
          ),
          isNot(contains('protected_facts_ciphertext')),
        );
        final reader = _reader(f);
        try {
          final sources = await _catalog(reader);
          for (final source in sources) {
            final scope = reader.approvalScope(source)!;
            final roots = await reader.contents(
              source,
              scope,
              null,
              null,
              const nav.WorkBound(),
            );
            for (final section in roots.items) {
              final page = await reader.contents(
                source,
                scope,
                section.selection,
                null,
                const nav.WorkBound(),
              );
              expect(page.items.length, lessThanOrEqualTo(16));
            }
          }
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'saved card/lorebook and OTHER encrypted Astoria conversation through all FOUR real tools, encrypted native-valid recipe and POST without a picker',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        late String cards, lore, chat;
        f.script = (round) async {
          if (round == 1) {
            return AutomaticSourcesFixture.calls([
              (
                'datasets',
                'astoria_sources_list',
                {'domain': 'applicationData'},
              ),
              (
                'chats',
                'astoria_sources_list',
                {'domain': 'astoriaConversation'},
              ),
            ]);
          }
          if (round == 2) {
            await _encrypted(f, 2);
            final datasets = f.result('datasets')['data']['pieces'] as List;
            cards =
                datasets.singleWhere(
                      (p) => p['label'] == 'Saved character cards',
                    )['source']
                    as String;
            lore =
                datasets.singleWhere(
                      (p) => p['label'] == 'Saved lorebooks',
                    )['source']
                    as String;
            final chats = f.result('chats')['data']['pieces'] as List;
            expect(
              chats.any((p) => p['title'] == 'Other named Astoria chat'),
              true,
              reason:
                  'Original exact-AAD title must be in the permitted catalog: ${jsonEncode(chats)}',
            );
            expect(
              chats.any((p) => p['title'] == 'Synthetic model backup'),
              false,
            );
            chat =
                chats.singleWhere(
                      (p) => p['title'] == 'Other named Astoria chat',
                    )['source']
                    as String;
            expect(jsonEncode(f.wire), isNot(contains('SAVED_CARD_BODY')));
            expect(
              jsonEncode(f.wire),
              isNot(contains('SAVED_OTHER_ASTORIA_BODY')),
            );
            return AutomaticSourcesFixture.calls([
              ('card-root', 'astoria_source_contents', {'source': cards}),
              ('chat-contents', 'astoria_source_contents', {'source': chat}),
              (
                'lore-search',
                'astoria_source_search',
                {'source': lore, 'literal': 'SAVED_LOREBOOK_BODY'},
              ),
            ]);
          }
          if (round == 3) {
            await _encrypted(f, 5);
            expect(
              f.body('card-root')['pieces'][0]['label'],
              'Character card fields',
            );
            return AutomaticSourcesFixture.calls([
              (
                'card-search',
                'astoria_source_search',
                {
                  'source': cards,
                  'literal': 'SAVED_CARD_BODY',
                  'section': f.body('card-root')['pieces'][0]['selector'],
                },
              ),
              (
                'chat-read',
                'astoria_source_read',
                {
                  'source': chat,
                  'selector': f.body('chat-contents')['pieces'][0]['selector'],
                },
              ),
              (
                'lore-read',
                'astoria_source_read',
                {
                  'source': lore,
                  'selector': f.body('lore-search')['pieces'][0]['selector'],
                },
              ),
            ]);
          }
          if (round == 4) {
            await _encrypted(f, 8);
            expect(
              f.body('chat-read')['pieces'][0]['payload'],
              'SAVED_OTHER_ASTORIA_BODY',
            );
            expect(
              f.body('lore-read')['pieces'][0]['payload'],
              'SAVED_LOREBOOK_BODY',
            );
            return AutomaticSourcesFixture.calls([
              (
                'card-read',
                'astoria_source_read',
                {
                  'source': cards,
                  'selector': f.body('card-search')['pieces'][0]['selector'],
                },
              ),
            ]);
          }
          expect(round, 5);
          await _encrypted(f, 9);
          expect(
            f.body('card-read')['pieces'][0]['payload'],
            'SAVED_CARD_BODY',
          );
          return AutomaticSourcesFixture.answer();
        };
        final result = await (await f.start()).finished.timeout(
          const Duration(seconds: 30),
        );
        expect(
          result.message?.status,
          'complete',
          reason:
              '${result.reason.name}: ${f.scriptError}: ${f.activity.map((a) => a.detail).join(' | ')}',
        );
        expect(f.wire, hasLength(5));
        for (final forbidden in [
          'UNREGISTERED_CARD_SECRET',
          'UNREGISTERED_HEADER_SECRET',
          'UNREGISTERED_LORE_SECRET',
          'UNREGISTERED_VARIABLE_SECRET',
          'UNREGISTERED_API_COLUMN_SECRET',
          'UNREGISTERED_EMBEDDING_COLUMN_SECRET',
          'UNREGISTERED_PARAM_CREDENTIAL',
          'UNREGISTERED_CUSTOM_PARAMETER',
          'HIDDEN_CARD_BODY',
          'data-other-astoria',
          'data-other-message',
          'data-character',
          'private-entry',
          BackupLoopNative.key,
        ]) {
          expect(jsonEncode(f.wire), isNot(contains(forbidden)));
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'remaining families are actual searchable saved content; captures retain truncation/retention uncertainty and JSON credential containers are excluded BEFORE matching',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        await f.native.db.historySourceIndex.maintain(
          sessionId: 'data-game',
          isCurrent: () => true,
          maxSteps: 16,
        );
        final reader = _reader(f);
        try {
          final catalog = await _catalog(reader);
          final expected = <String, List<String>>{
            'personas': ['SAVED_PERSONA_PROMPT'],
            'sessionSavedData': [
              'SAVED_VARIABLE',
              'SAVED_AUTHORS_NOTE',
              'SAVED_DRAFT',
              'SAVED_OTHER_VARIATION',
              'SAVED_REASONING',
              'inert/attachment.png',
            ],
            'canon': ['SAVED_BASELINE_CARD', 'SAVED_REVISION_CARD'],
            'lorebookHistory': [
              'SAVED_EVOLVED_LORE',
              'SAVED_LORE_REVISION',
              'SAVED_USE_MANIFEST',
              'SAVED_USE_EVIDENCE',
              'SAVED_USE_ACCEPTANCE',
            ],
            'rewrites': [
              'SAVED_REWRITE_REQUEST',
              'SAVED_REWRITE_OPERATION',
              'SAVED_OPERATION_REVISION',
              'SAVED_REWRITE_EVIDENCE',
            ],
            'requestDiagnostics': [
              'ACTUAL_CAPTURED_REQUEST_BODY',
              'SAVED_TRUNCATED_CAPTURE',
            ],
            'cardEvolution': [
              'SAVED_TRUNCATED_DIAGNOSTIC',
              'SAVED_CLAIM_INPUT',
              'SAVED_WRITER_PROMPT',
              'SAVED_OBSERVED_CHANGE',
            ],
            'extensions': ['SAVED_INERT_SCRIPT', 'SAVED_INFO_CONTENT'],
            'embeddingStatus': ['SAVED_RETRIEVAL_HINT'],
            'apiConfigurations': ['NONSTANDARD_API_NAME'],
            'astoriaSavedContext': ['SAVED_ASTORIA_SUMMARY'],
          };
          for (final e in expected.entries) {
            final source = catalog.singleWhere((o) => o.key.nativeId == e.key);
            for (final literal in e.value) {
              final page = await reader.search(
                source,
                reader.approvalScope(source)!,
                literal,
                null,
                null,
                const nav.WorkBound(),
              );
              expect(page.items, isNotEmpty, reason: '${e.key}: $literal');
              final record = page.items.first;
              final read = await reader.read(
                source,
                reader.approvalScope(source)!,
                nav.ReadQuery(record.selection, 0, 0),
                const nav.WorkBound(),
              );
              expect(read.items.single.payload, contains(literal));
            }
          }
          for (final name in [
            'savedCharacters',
            'lorebooks',
            'sessionSavedData',
            'apiConfigurations',
          ]) {
            final source = catalog.singleWhere((o) => o.key.nativeId == name);
            final denied = await reader.search(
              source,
              reader.approvalScope(source)!,
              'UNREGISTERED',
              null,
              null,
              const nav.WorkBound(),
            );
            expect(denied.items, isEmpty, reason: name);
          }
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'actual API SELECTs never evaluate credential columns; legitimately keyed/nonstandard configurations remain readable with explicit safe custom-parameter omissions',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        // A synthetic view makes reading either private column fail loudly. Its
        // public columns are the REAL durable api_configs projection, not a mask
        // applied after full-row hydration. No function/plugin or live API runs.
        final fields = SupportApplicationDataRegistry.projectedFieldsForTable(
          'api_configs',
        );
        await f.native.db.customStatement(
          'CREATE TEMP VIEW api_configs AS SELECT rowid AS rowid,config_id, '
          '${fields.map((c) => '"$c"').join(',')}, '
          "json_extract('not-json','\$') AS api_key, json_extract('not-json','\$') AS embedding_api_key FROM main.api_configs",
        );
        final reader = _reader(f);
        try {
          final source = (await _catalog(
            reader,
          )).singleWhere((o) => o.key.nativeId == 'apiConfigurations');
          final page = await reader.search(
            source,
            reader.approvalScope(source)!,
            'NONSTANDARD_API_NAME',
            null,
            null,
            const nav.WorkBound(),
          );
          expect(page.items.single.payload, 'NONSTANDARD_API_NAME');
          expect(
            await f.native.db
                .customSelect('SELECT api_key FROM api_configs LIMIT 1')
                .get()
                .then((_) => false, onError: (_) => true),
            true,
          );
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'oversized/unknown complete units produce honest terminal partial metadata, never slices or false complete content',
    () async {
      await automaticSourcesTest((f) async {
        await f.native.db.customStatement(
          'INSERT INTO personas(persona_id,name,prompt) VALUES(?,?,?)',
          ['oversized-persona', 'Oversized', 'x' * 70000],
        );
        await f.native.db.customStatement(
          "INSERT INTO lorebooks(lorebook_id,name,entries_json) VALUES('malformed-lorebook','Malformed','{')",
        );
        final reader = _reader(f);
        try {
          final sources = await _catalog(reader);
          for (final name in ['personas', 'lorebooks']) {
            final source = sources.singleWhere((o) => o.key.nativeId == name);
            final scope = reader.approvalScope(source)!;
            final root = (await reader.contents(
              source,
              scope,
              null,
              null,
              const nav.WorkBound(),
            )).items.single;
            final page = await reader.contents(
              source,
              scope,
              root.selection,
              null,
              const nav.WorkBound(),
            );
            expect(page.complete, false);
            expect(page.exhaustedWork, true);
            final read = await reader.read(
              source,
              scope,
              nav.ReadQuery(page.items.single.selection, 0, 0),
              const nav.WorkBound(),
            );
            expect(read.items.single.payload, isA<Map<String, Object?>>());
            expect(
              jsonEncode(read.items.single.payload),
              contains(
                name == 'personas'
                    ? 'oversized_complete_unit'
                    : 'unknown_saved_format',
              ),
            );
            expect(
              jsonEncode(read.items.single.payload),
              isNot(contains('xxx')),
            );
          }
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'Astoria catalog/title and contents never hydrate all-session bodies; one issued read decrypts exactly one original-AAD message',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        final decrypts = <String>[];
        f.native.primitive.beforeDecrypt = (aad) async {
          decrypts.add(aad);
        };
        final reader = _reader(f);
        try {
          final catalog = await reader.discover(
            nav.SourceDomain.astoriaConversation,
            null,
            null,
            const nav.WorkBound(),
          );
          final source = catalog.items.singleWhere(
            (o) => o.key.nativeId == 'data-other-astoria',
          );
          expect(decrypts.any((aad) => aad.contains('body_ciphertext')), false);
          final scope = reader.approvalScope(source)!;
          final contents = await reader.contents(
            source,
            scope,
            null,
            null,
            const nav.WorkBound(),
          );
          expect(decrypts.any((aad) => aad.contains('body_ciphertext')), false);
          final read = await reader.read(
            source,
            scope,
            nav.ReadQuery(contents.items.single.selection, 0, 0),
            const nav.WorkBound(),
          );
          expect(read.items.single.payload, 'SAVED_OTHER_ASTORIA_BODY');
          final bodies = decrypts
              .where((aad) => aad.contains('body_ciphertext'))
              .toList();
          expect(bodies, hasLength(1));
          expect(bodies.single, contains('data-other-message'));
          expect(bodies.single, contains('data-other-astoria'));
        } finally {
          reader.retire();
          f.native.primitive.beforeDecrypt = null;
        }
      });
    },
    skip: !Platform.isWindows,
  );

  for (final mode in ['mutation', 'replace', 'revoke']) {
    test(
      '$mode after new-domain encrypted contents commit but BEFORE POST retires original custody',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f);
          final controller = SupportNativeConsentController(
            runtime: f.native.runtime,
            readMessages: (_, _, _) => throw StateError('No picker'),
          );
          Future<bool>? revoked;
          Future<void>? retired;
          AppDatabase? replacement;
          var interrupted = false;
          f.onActivity = (activity) {
            if (interrupted ||
                activity.action != 'astoria_source_contents' ||
                activity.stage.name != 'completed') {
              return;
            }
            interrupted = true;
            if (mode == 'revoke') {
              revoked = controller.revokeApplicationDataFromDisplayedIntent(
                controller.view.displayedIntent,
              );
            } else if (mode == 'mutation') {
              f.native.handle.execute(
                "UPDATE characters SET description='CHANGED_BEFORE_WIRE' WHERE char_id='data-character'",
              );
            } else {
              // Retire the actual original FILE executor, then introduce a
              // different FILE AppDatabase. Its identity cannot transplant old
              // observations, ROOT, reply reservation or approved selectors.
              retired = f.native.db.close();
              replacement = AppDatabase.openedNative(
                sqlite.sqlite3.open(
                  '${f.native.directory.path}${Platform.pathSeparator}replacement.db',
                ),
              );
            }
          };
          f.script = (round) {
            if (round == 1) {
              return AutomaticSourcesFixture.calls([
                (
                  'datasets',
                  'astoria_sources_list',
                  {'domain': 'applicationData'},
                ),
              ]);
            }
            expect(round, 2);
            final source = (f.result('datasets')['data']['pieces'] as List)
                .singleWhere(
                  (p) => p['label'] == 'Saved character cards',
                )['source'];
            return AutomaticSourcesFixture.calls([
              ('contents', 'astoria_source_contents', {'source': source}),
            ]);
          };
          final result = await (await f.start()).finished.timeout(
            const Duration(seconds: 30),
          );
          if (revoked != null) expect(await revoked!, true);
          expect(interrupted, true);
          expect(result.message?.status, isNot('complete'));
          expect(f.wire, hasLength(2));
          expect(jsonEncode(f.wire), isNot(contains('SAVED_CARD_BODY')));
          if (replacement != null) {
            try {
              await retired;
              await replacement!.customSelect('SELECT 1').get();
              expect(
                replacement!.nativeDataSourceIdentity?.belongsTo(replacement!),
                true,
              );
              expect(f.native.db.nativeDataSourceIdentity, isNull);
            } finally {
              await replacement!.close();
            }
          }
        });
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'new domains require real global consent, not old per-source/session grants',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        f.script = (round) {
          if (round == 1) {
            return AutomaticSourcesFixture.calls([
              ('denied', 'astoria_sources_list', {'domain': 'applicationData'}),
            ]);
          }
          expect(f.result('denied')['ok'], false);
          return AutomaticSourcesFixture.answer();
        };
        expect(
          (await (await f.start()).finished).message?.status,
          isNot('complete'),
        );
        expect(jsonEncode(f.wire), isNot(contains('Saved character cards')));
      }, grant: false);
    },
    skip: !Platform.isWindows,
  );
}
