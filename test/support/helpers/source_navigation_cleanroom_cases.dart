import 'dart:async';
import 'dart:convert';
import '../../../lib/core/support/source_navigation.dart';

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String status(NavigationResult result) => result.wire['status'] as String;
List<Map<String, Object?>> pieces(NavigationResult result) =>
    (result.wire['pieces'] as List).cast<Map<String, Object?>>();
String sourceHandle(NavigationResult result) =>
    pieces(result).first['source'] as String;
String selector(NavigationResult result) =>
    pieces(result).first['selector'] as String;

class FakeOwner implements OwnerPort {
  final Object token = Object();
  int epoch = 0;
  bool current = true;
  int checks = 0;
  void Function()? onCheck;
  @override
  bool isOriginalOwnerCurrent(RunContext original) {
    checks++;
    onCheck?.call();
    return current && epoch == 0 && identical(original.originalOwner, token);
  }

  void routeOrModelAba() {
    epoch++;
  }
}

class FakeSnapshotLease implements SnapshotLease {
  final FakeRepository repository;
  final SourceKey key;
  final Snapshot snapshot;
  bool latched = true;
  FakeSnapshotLease(this.repository, this.key, this.snapshot);
  @override
  bool isCurrent() {
    if (repository.deleted.contains(key) ||
        !repository.snapshot(key).same(snapshot))
      latched = false;
    return latched;
  }
}

class FakeApprovalLease implements ApprovalLease {
  bool present = true;
  bool revoked = false;
  bool Function()? hook;
  @override
  bool isCurrent() => hook?.call() ?? (present && !revoked);
}

class FakeApproval implements ApprovalPort {
  bool allow = true;
  int requests = 0;
  int budget = Limits.disclosureBytes;
  final Map<SourceKey, FakeApprovalLease> leases = {};
  final List<ApprovalRequest> seen = [];
  FrozenScope Function(ApprovalRequest)? choose;
  NativeGrant Function(ApprovalRequest, NativeGrant)? alter;
  Future<void> Function()? hook;
  @override
  Future<NativeGrant?> request(ApprovalRequest request) async {
    requests++;
    seen.add(request);
    if (hook != null) await hook!();
    if (!allow) return null;
    final scope =
        choose?.call(request) ??
        (request.source.key.domain == SourceDomain.game
            ? FrozenScope.messages(
                ActiveRange(
                  FakeRepository.anchor(FakeRepository.hit - 2),
                  FakeRepository.anchor(FakeRepository.hit + 7),
                ),
              )
            : FrozenScope.sections(['root']));
    final lease = leases.putIfAbsent(request.source.key, FakeApprovalLease.new);
    final grant = NativeGrant(
      run: request.run,
      source: request.source.key,
      snapshot: request.source.snapshot,
      scope: scope,
      disclosureBytes: budget < request.maximumDisclosureBytes
          ? budget
          : request.maximumDisclosureBytes,
      lease: lease,
    );
    return alter?.call(request, grant) ?? grant;
  }
}

class FakeProjection implements ProjectionPort {
  ProjectionStamp stamp = const ProjectionStamp('redactor', 0);
  int projects = 0;
  bool complete = true;
  bool changeShape = false;
  Future<void> Function()? projectHook;
  Future<void> Function()? stampHook;
  Future<void> Function()? wireHook;
  bool stringEnvelope = false;
  bool copyWire = false;
  bool duplicateWire = false;
  bool badWireMetadata = false;
  String Function(String)? transform;
  Object? redact(Object? value) {
    if (value is String)
      return transform?.call(value) ??
          value.replaceAll('SECRET-CROSS-BOUNDARY', '[redacted]');
    if (value is Map)
      return value.map((k, v) => MapEntry(k as String, redact(v)));
    if (value is List) return value.map(redact).toList();
    return value;
  }

  @override
  Future<ProjectedRecord> project(DataRecord record) async {
    projects++;
    if (projectHook != null) await projectHook!();
    return ProjectedRecord(
      changeShape ? {'repaired': true} : redact(record.payload),
      stamp,
      complete: complete,
    );
  }

  @override
  Future<ProjectionStamp> currentStamp() async {
    if (stampHook != null) await stampHook!();
    return stamp;
  }

  @override
  Future<ProjectedWire> wire(WireCandidate original) async {
    if (wireHook != null) await wireHook!();
    final body = copyWire
        ? Map.of(original.wire)
        : stringEnvelope
        ? original.encoded
        : original.wire;
    return ProjectedWire(original, {
      'role': 'tool',
      'body': body,
      if (duplicateWire) 'extra': original.wire,
      if (badWireMetadata) 'metadata': 'x' * 257,
    }, stamp);
  }
}

class FakeProvenance implements ProvenancePort {
  final List<ProvenanceEntry> entries = [];
  bool durable = true;
  bool conflict = false;
  bool copiedReceipt = false;
  Future<void> Function(ProvenanceEntry)? hook;
  @override
  Future<ProvenanceReceipt> append(ProvenanceEntry entry) async {
    if (hook != null) await hook!(entry);
    entries.add(entry);
    final copy = ProvenanceEntry(
      run: entry.run,
      source: entry.source,
      grant: entry.grant,
      operation: entry.operation,
      argumentsJson: entry.argumentsJson,
      exactWireJson: entry.exactWireJson,
      exactEnvelopeJson: entry.exactEnvelopeJson,
      extents: entry.extents,
      projection: entry.projection,
    );
    return ProvenanceReceipt(
      copiedReceipt ? copy : entry,
      durableEncrypted: durable,
      conflict: conflict,
    );
  }
}

class PrivateCursor {
  final int index;
  const PrivateCursor(this.index);
}

class FakeRepository implements NavigationRepository {
  static const logicalMessages = 5000000;
  static const hit = 2000000;
  final Map<SourceKey, int> revisions = {};
  final Map<SourceKey, String> incarnations = {};
  final Set<SourceKey> deleted = {};
  final Map<SourceKey, List<DataRecord>> records = {};
  final Map<SourceKey, SourceState> states = {};
  final Map<SourceKey, Binding> bindings = {};
  final Map<String, int> calls = {};
  int maximumPage = 0;
  int maximumCandidates = 0;
  int generatedMessages = 0;
  final List<Snapshot> revalidated = [];
  final List<SourceKey> revalidatedKeys = [];
  final List<ReadQuery> reads = [];
  final Map<String, Future<void> Function()> hooks = {};
  bool exhausted = false;
  bool oversizedPage = false;
  bool wrongRead = false;
  bool returnInactive = false;
  bool malformed = false;
  bool unsafeUnit = false;
  bool duplicateIdentity = false;
  int discoveryCopies = 1;

  SourceKey key(SourceDomain domain) => SourceKey(domain, 'same-native-id');
  Snapshot snapshot(SourceKey key) => Snapshot(
    incarnations[key] ?? 'incarnation-1',
    revisions[key] ?? 0,
    privateIntegrity: 'PRIVATE-DIGEST-NEVER-WIRE',
  );
  void mutate(SourceKey key) {
    revisions[key] = (revisions[key] ?? 0) + 1;
  }

  void recreate(SourceKey key) {
    mutate(key);
    incarnations[key] = 'incarnation-${revisions[key]! + 1}';
    deleted.remove(key);
  }

  static Anchor anchor(int ordinal) => Anchor(
    'message-$ordinal',
    ordinal,
    swipe: 'active-swipe',
    agentSwipe: 'active-agent-swipe',
  );

  SourceState state(SourceKey key) =>
      states[key] ??
      switch (key.domain) {
        SourceDomain.game => SourceState.active,
        SourceDomain.ordinaryPreset ||
        SourceDomain.studioPreset => SourceState.currentSaved,
        SourceDomain.ledgerSnapshot => SourceState.historicalCommitted,
        _ => SourceState.current,
      };
  Binding binding(SourceKey key) =>
      bindings[key] ??
      (key.domain == SourceDomain.ledgerSnapshot
          ? Binding(
              sessionId: 'session',
              anchor: anchor(hit),
              evidence: Evidence(
                EvidenceState.attested,
                range: ActiveRange(anchor(hit), anchor(hit)),
              ),
            )
          : const Binding(sessionId: 'session', characterId: 'character'));
  SourceObservation observation(SourceKey key, {SourceKey? parent}) =>
      SourceObservation(
        key: key,
        snapshot: snapshot(key),
        lease: FakeSnapshotLease(this, key, snapshot(key)),
        state: state(key),
        binding: binding(key),
        parent: parent,
        activeAtListing: key.domain == SourceDomain.ordinaryPreset
            ? true
            : null,
      );

  SectionKind kind(SourceDomain domain) => switch (domain) {
    SourceDomain.game => SectionKind.activeMessages,
    SourceDomain.ordinaryPreset => SectionKind.presetBlock,
    SourceDomain.studioPreset => SectionKind.studioBlock,
    SourceDomain.memory => SectionKind.memoryEntry,
    SourceDomain.savedSummary => SectionKind.summaryText,
    SourceDomain.ledgerState => SectionKind.ledgerTrackers,
    SourceDomain.ledgerSnapshot => SectionKind.ledgerSnapshot,
    SourceDomain.reconciliation => SectionKind.reconciliationCheckpoint,
    SourceDomain.characterKnowledge => SectionKind.knowledgeFact,
  };
  List<DataRecord> saved(SourceKey key) =>
      records[key] ??
      [
        DataRecord(
          selection: const Selection.record('root', 'record'),
          kind: kind(key.domain),
          state: state(key),
          binding: binding(key),
          payload: 'saved ${key.domain.name} needle text',
        ),
      ];
  DataRecord message(int ordinal) {
    generatedMessages++;
    final a = anchor(ordinal);
    return DataRecord(
      selection: Selection.messages('history', ActiveRange(a, a)),
      kind: SectionKind.activeMessages,
      state: returnInactive ? SourceState.tentative : SourceState.active,
      binding: Binding(sessionId: 'session', anchor: a),
      payload: ordinal == hit || ordinal == hit + 5
          ? 'hello 🐈 needle SECRET-CROSS-BOUNDARY world'
          : 'nearby $ordinal',
      role: 'assistant',
      admitted: !malformed,
      completeUnit: !unsafeUnit,
    );
  }

  Future<void> enter(String operation, WorkBound bound) async {
    calls[operation] = (calls[operation] ?? 0) + 1;
    expect(
      bound.pageSize <= 16 &&
          bound.candidateLimit <= 4096 &&
          bound.rawByteLimit <= Limits.rawBytes,
      'bounded repository arguments',
    );
    if (hooks[operation] != null) await hooks[operation]!();
  }

  Page<T> page<T>(
    List<T> items, {
    Object? next,
    bool complete = true,
    int candidates = 1,
  }) {
    maximumPage = items.length > maximumPage ? items.length : maximumPage;
    maximumCandidates = candidates > maximumCandidates
        ? candidates
        : maximumCandidates;
    return Page(
      items,
      next: next,
      complete: complete,
      candidatesExamined: candidates,
    );
  }

  @override
  Future<Page<SourceObservation>> discover(
    SourceDomain domain,
    SourceKey? parent,
    Object? cursor,
    WorkBound bound,
  ) async {
    await enter('discover', bound);
    final start = cursor is PrivateCursor ? cursor.index : 0;
    final count = discoveryCopies > 16 ? 16 : discoveryCopies;
    final items = List.generate(
      count,
      (i) => observation(
        i + start == 0 ? key(domain) : SourceKey(domain, 'source-${i + start}'),
        parent: parent,
      ),
    );
    return page(
      items,
      next: discoveryCopies > start + count
          ? PrivateCursor(start + count)
          : null,
      complete: discoveryCopies <= start + count,
    );
  }

  @override
  Future<SourceObservation?> observe(SourceKey source, WorkBound bound) async {
    await enter('observe', bound);
    return deleted.contains(source) ? null : observation(source);
  }

  @override
  Future<bool> revalidate(SourceObservation original, WorkBound bound) async {
    await enter('revalidate', bound);
    revalidated.add(original.snapshot);
    revalidatedKeys.add(original.key);
    return !deleted.contains(original.key) &&
        snapshot(original.key).same(original.snapshot);
  }

  @override
  Future<Page<SectionDescriptor>> contents(
    SourceObservation source,
    FrozenScope scope,
    Selection? section,
    Object? cursor,
    WorkBound bound,
  ) async {
    await enter('contents', bound);
    if (exhausted)
      return Page(
        [],
        complete: false,
        exhaustedWork: true,
        candidatesExamined: 4096,
      );
    if (source.key.domain == SourceDomain.game) {
      return page([
        SectionDescriptor(
          Selection.messages('history', scope.messages),
          SectionKind.activeMessages,
          state: SourceState.active,
        ),
      ]);
    }
    final items = saved(source.key)
        .map(
          (record) => SectionDescriptor(
            record.selection,
            record.kind,
            state: record.state,
            binding: record.binding,
          ),
        )
        .toList();
    return page(oversizedPage ? List.generate(17, (_) => items.first) : items);
  }

  @override
  Future<Page<DataRecord>> search(
    SourceObservation source,
    FrozenScope scope,
    String literal,
    Selection? section,
    Object? cursor,
    WorkBound bound,
  ) async {
    await enter('search', bound);
    if (exhausted)
      return Page(
        [],
        complete: false,
        exhaustedWork: true,
        candidatesExamined: 4096,
      );
    if (source.key.domain != SourceDomain.game) {
      final items = saved(source.key)
          .where(
            (r) =>
                r.payload is String && (r.payload as String).contains(literal),
          )
          .toList();
      return page(items);
    }
    // A synthetic indexed repository over FIVE MILLION logical messages.
    // It constructs only the one page returned; there is no backing history list.
    if (literal != 'needle' && literal != 'SECRET-CROSS-BOUNDARY')
      return page([]);
    final ordinal = cursor == null ? hit : hit + 5;
    if (ordinal < scope.messages!.start.ordinal ||
        ordinal > scope.messages!.end.ordinal)
      return page([]);
    return page(
      [message(ordinal)],
      next: cursor == null ? const PrivateCursor(1) : null,
      complete: cursor != null,
      candidates: 1,
    );
  }

  @override
  Future<Page<DataRecord>> read(
    SourceObservation source,
    FrozenScope scope,
    ReadQuery query,
    WorkBound bound,
  ) async {
    await enter('read', bound);
    reads.add(query);
    if (exhausted)
      return Page(
        [],
        complete: false,
        exhaustedWork: true,
        candidatesExamined: 4096,
      );
    if (source.key.domain != SourceDomain.game) {
      return page(
        saved(
          source.key,
        ).where((r) => r.selection.same(query.selection)).toList(),
      );
    }
    final range = query.selection.range!;
    final items = List.generate(
      range.end.ordinal - range.start.ordinal + 1 + query.before + query.after,
      (i) => message(range.start.ordinal - query.before + i),
    );
    if (wrongRead) items[0] = message(hit + 100);
    if (duplicateIdentity && items.length > 1) items[1] = items[0];
    return page(items, candidates: items.length);
  }
}

class Harness {
  final owner = FakeOwner();
  final repository = FakeRepository();
  final approval = FakeApproval();
  final projection = FakeProjection();
  final provenance = FakeProvenance();
  late final RunContext run;
  late final SourceNavigationEngine engine;
  Harness({int disclosureLimit = Limits.disclosureBytes}) {
    run = RunContext(
      owner.token,
      'synthetic-run',
      const Recipient('provider', 'config', 'protocol', 'model'),
    );
    engine = SourceNavigationEngine(
      run: run,
      repository: repository,
      owner: owner,
      approval: approval,
      projection: projection,
      provenance: provenance,
      disclosureLimit: disclosureLimit,
    );
  }
  Future<NavigationResult> list([SourceDomain domain = SourceDomain.game]) =>
      engine.invoke('astoria_sources_list', {'domain': domain.name});
  Future<NavigationResult> contents(String source) =>
      engine.invoke('astoria_source_contents', {'source': source});
  Future<NavigationResult> search(
    String source, {
    String literal = 'needle',
    String? cursor,
  }) => engine.invoke('astoria_source_search', {
    'source': source,
    'literal': literal,
    if (cursor != null) 'cursor': cursor,
  });
  Future<NavigationResult> read(
    String source,
    String selector, {
    int before = 0,
    int after = 0,
  }) => engine.invoke('astoria_source_read', {
    'source': source,
    'selector': selector,
    'before': before,
    'after': after,
  });
  Future<(String, String)> selected([
    SourceDomain domain = SourceDomain.ordinaryPreset,
  ]) async {
    final source = sourceHandle(await list(domain));
    final selection = selector(await contents(source));
    return (source, selection);
  }
}

Future<void> main() async {
  final tests = <String, Future<void> Function()>{
    'lazy millions: discovery, contents, literal search, active range + neighbours':
        () async {
          final h = Harness();
          final discovered = await h.list();
          final source = sourceHandle(discovered);
          expect(
            !discovered.bodyBearing && h.provenance.entries.isEmpty,
            'discovery is generic metadata only',
          );
          expect(
            !discovered.encoded.contains('PRIVATE-DIGEST') &&
                !discovered.encoded.contains('same-native-id'),
            'no integrity/native IDs',
          );
          final contents = await h.contents(source);
          expect(
            status(contents) == 'ok' &&
                pieces(contents).single['kind'] == 'activeMessages',
            'logical map',
          );
          final hit = await h.search(source);
          expect(
            status(hit) == 'ok' && hit.wire['complete'] == false,
            'bounded paged search',
          );
          expect(
            !hit.encoded.contains('SECRET-CROSS-BOUNDARY') &&
                hit.encoded.contains('[redacted]'),
            'whole-string redaction',
          );
          final read = await h.read(source, selector(hit), before: 2, after: 2);
          expect(
            status(read) == 'ok' && pieces(read).length == 5,
            'selected active text and nearby messages',
          );
          expect(
            pieces(read).first['payload'] == 'nearby ${FakeRepository.hit - 2}',
            'ascending native active order',
          );
          final next = await h.search(
            source,
            cursor: hit.wire['nextCursor'] as String,
          );
          expect(
            next.wire['complete'] == true && pieces(next).length == 1,
            'opaque continuation completes enumeration',
          );
          expect(
            h.approval.requests == 1,
            'one native source grant covers only technical navigation',
          );
          expect(
            h.repository.generatedMessages == 7 &&
                h.repository.maximumPage <= 16 &&
                h.repository.maximumCandidates <= 4096,
            'only seven of five million messages materialized',
          );
          expect(
            h.provenance.entries.last.exactWireJson == next.encoded,
            'exact durable result',
          );
          var posts = 0;
          expect(
            await h.engine.withPost([read, next], (envelope) async {
              expect(
                identical(envelope.originalResults.first, read),
                'original result custody',
              );
              posts++;
            }),
            'synthetic post admitted',
          );
          expect(posts == 1, 'one dispatch');
        },
    'ordinary / Studio same native ID, saved definitions not historical prompts':
        () async {
          final h = Harness();
          final ordinary = sourceHandle(
            await h.list(SourceDomain.ordinaryPreset),
          );
          final studio = sourceHandle(await h.list(SourceDomain.studioPreset));
          expect(ordinary != studio, 'different opaque source handles');
          final o = await h.contents(ordinary);
          final s = await h.contents(studio);
          final forged = await h.read(studio, selector(o));
          expect(
            status(forged) == 'invalidReference',
            'cross-namespace selector denied',
          );
          final or = await h.read(ordinary, selector(o));
          final sr = await h.read(studio, selector(s));
          expect(
            or.encoded.contains('ordinaryPreset') &&
                sr.encoded.contains('studioPreset'),
            'namespace content remains separate',
          );
          expect(h.approval.requests == 2, 'no cross-source grant');
          final discovered = await h.list(SourceDomain.ordinaryPreset);
          expect(
            pieces(discovered).single['activeAtListing'] == true &&
                pieces(discovered).single['historicalUse'] == 'unknown',
            'selection is not evidence of prior use',
          );
        },
    'all nine domains, saved/current/historical bindings are explicit':
        () async {
          for (final domain in SourceDomain.values) {
            final h = Harness();
            final source = sourceHandle(await h.list(domain));
            final map = await h.contents(source);
            expect(status(map) == 'ok', 'contents for ${domain.name}');
            final read = await h.read(source, selector(map));
            expect(status(read) == 'ok', 'read for ${domain.name}');
            final citation = pieces(read).first['citation'] as Map;
            expect(citation['domain'] == domain.name, 'citation namespace');
            expect(
              citation['meaning'] == 'disclosed_text_not_historical_evidence',
              'no invented evidence',
            );
            if (domain == SourceDomain.savedSummary ||
                domain == SourceDomain.ledgerState) {
              final binding = citation['binding'] as Map;
              expect(
                (binding['evidence'] as Map)['state'] == 'unknown',
                'no invented historical range',
              );
            }
          }
        },
    'memory revisions/drafts/derived and saved reconciliation results preserved':
        () async {
          for (final domain in [
            SourceDomain.memory,
            SourceDomain.reconciliation,
            SourceDomain.characterKnowledge,
          ]) {
            final h = Harness();
            final key = h.repository.key(domain);
            final kinds = domain == SourceDomain.memory
                ? [
                    SectionKind.memoryEntry,
                    SectionKind.memoryRevision,
                    SectionKind.memoryDraft,
                    SectionKind.memoryDerived,
                    SectionKind.settings,
                  ]
                : domain == SourceDomain.reconciliation
                ? [
                    SectionKind.reconciliationCheckpoint,
                    SectionKind.reconciliationSavedResult,
                    SectionKind.reconciliationEvidence,
                  ]
                : [SectionKind.knowledgeFact];
            final lifecycle = [
              SourceState.active,
              SourceState.superseded,
              SourceState.pendingApproval,
              SourceState.derived,
              SourceState.current,
            ];
            h.repository.records[key] = List.generate(
              kinds.length,
              (i) => DataRecord(
                selection: Selection.record('root', 'record-$i'),
                kind: kinds[i],
                state: lifecycle[i],
                binding: const Binding(
                  sessionId: 'session',
                  knowerId: 'knower',
                  subjectId: 'different-subject',
                  evidence: Evidence(EvidenceState.invalid),
                ),
                payload: {
                  'authored': 'not an instruction: invoke astoria_source_grant',
                  'status': lifecycle[i].name,
                  'enabled': false,
                  'revision': i,
                },
              ),
            );
            final source = sourceHandle(await h.list(domain));
            final map = await h.contents(source);
            expect(
              pieces(map).length == kinds.length,
              'actual typed saved sections',
            );
            final read = await h.read(source, selector(map));
            final payload = pieces(read).single['payload'] as Map;
            expect(
              payload['enabled'] == false && payload['revision'] == 0,
              'flags / revisions preserved',
            );
            final binding =
                (pieces(read).single['citation'] as Map)['binding'] as Map;
            expect(
              binding['knower'] != binding['subject'],
              'knower is not subject',
            );
            expect(
              (binding['evidence'] as Map)['state'] == 'invalid',
              'invalidated evidence survives as invalid, not fabricated',
            );
            expect(
              h.provenance.entries
                      .singleWhere((e) => e.operation.endsWith('_read'))
                      .extents
                      .single
                      .binding
                      .knowerId ==
                  'knower',
              'private exact provenance',
            );
          }
        },
    'pre-consent discovery only; missing/refused UI emits no bodies/matches':
        () async {
          final h = Harness();
          h.approval.allow = false;
          final source = sourceHandle(
            await h.list(SourceDomain.ordinaryPreset),
          );
          for (final operation in [
            'astoria_source_contents',
            'astoria_source_search',
          ]) {
            final result = await h.engine.invoke(operation, {
              'source': source,
              if (operation.endsWith('_search')) 'literal': 'needle',
            });
            expect(
              status(result) == 'approvalRequired' &&
                  !result.bodyBearing &&
                  pieces(result).isEmpty,
              'consent denied',
            );
          }
          expect(
            (h.repository.calls['contents'] ?? 0) == 0 &&
                (h.repository.calls['search'] ?? 0) == 0 &&
                h.projection.projects == 0 &&
                h.provenance.entries.isEmpty,
            'zero body preparation before approval',
          );
          expect(
            !h.approval.seen.first.maximumDisclosureBytes.isNegative &&
                identical(h.approval.seen.first.run, h.run),
            'exact run/recipient native request',
          );
        },
    'revocation and UI removal permanently deny old scopes and POST': () async {
      for (final removal in [false, true]) {
        final h = Harness();
        final (source, section) = await h.selected();
        final body = await h.read(source, section);
        final lease = h.approval.leases.values.single;
        if (removal) {
          lease.present = false;
        } else {
          lease.revoked = true;
        }
        expect(
          !await h.engine.withPost([body], (_) async {
            throw StateError('must not dispatch');
          }),
          'old body denied',
        );
        lease.present = true;
        lease.revoked = false;
        expect(
          status(await h.read(source, section)) != 'ok',
          'revocation observed by engine cannot revive',
        );
      }
    },
    'native scope exact run/model/source/snapshot/budget binding': () async {
      for (final variant in [
        'run',
        'source',
        'snapshot',
        'budget',
        'scope',
        'lease',
      ]) {
        final h = Harness();
        h.approval.alter = (request, g) => NativeGrant(
          run: variant == 'run'
              ? RunContext(
                  h.owner.token,
                  'other',
                  const Recipient('p', 'c', 'p', 'other-model'),
                )
              : g.run,
          source: variant == 'source'
              ? const SourceKey(SourceDomain.studioPreset, 'same-native-id')
              : g.source,
          snapshot: variant == 'snapshot'
              ? const Snapshot('other', 1)
              : g.snapshot,
          scope: variant == 'scope' ? FrozenScope.sections([]) : g.scope,
          disclosureBytes: variant == 'budget'
              ? request.maximumDisclosureBytes + 1
              : g.disclosureBytes,
          lease: variant == 'lease'
              ? (FakeApprovalLease()..present = false)
              : g.lease,
        );
        final source = sourceHandle(await h.list(SourceDomain.ordinaryPreset));
        expect(
          status(await h.contents(source)) == 'approvalRequired',
          'deny incorrect $variant',
        );
        expect(h.provenance.entries.isEmpty, 'no incorrect grant egress');
      }
    },
    'forged / wrong-kind / cross-source / cross-run / query-bound cursor':
        () async {
          final h = Harness();
          final source = sourceHandle(await h.list());
          final hit = await h.search(source);
          final cursor = hit.wire['nextCursor'] as String;
          final cases = <Map<String, Object?>>[
            {'source': source, 'literal': 'needle', 'cursor': 'h_${'0' * 48}'},
            {'source': source, 'literal': 'needle', 'cursor': selector(hit)},
            {'source': source, 'literal': 'different', 'cursor': cursor},
          ];
          for (final args in cases) {
            expect(
              status(await h.engine.invoke('astoria_source_search', args)) ==
                  'invalidReference',
              'opaque cursor cannot be forged/rebound',
            );
          }
          expect(
            status(
                  await h.engine.invoke('astoria_source_contents', {
                    'source': source,
                    'cursor': cursor,
                  }),
                ) ==
                'invalidReference',
            'operation-bound cursor',
          );
          final other = Harness();
          final otherSource = sourceHandle(await other.list());
          expect(
            status(await other.search(otherSource, cursor: cursor)) ==
                'invalidReference',
            'cross-run cursor denied',
          );
          expect(
            other.approval.requests == 0,
            'forged cursor does not prompt for a new native grant',
          );
          final ordinary = sourceHandle(
            await h.list(SourceDomain.ordinaryPreset),
          );
          expect(
            status(await h.search(ordinary, cursor: cursor)) ==
                'invalidReference',
            'cross-source cursor denied',
          );
          expect(
            status(await h.read(source, source)) == 'invalidReference',
            'source is not selector',
          );
        },
    'frozen neighbour scope and excluded records': () async {
      final h = Harness();
      final source = sourceHandle(await h.list());
      final hit = await h.search(source);
      final narrow = Harness();
      narrow.approval.choose = (_) => FrozenScope.messages(
        ActiveRange(
          FakeRepository.anchor(FakeRepository.hit),
          FakeRepository.anchor(FakeRepository.hit),
        ),
      );
      final ns = sourceHandle(await narrow.list());
      final nr = await narrow.search(ns);
      expect(
        status(await narrow.read(ns, selector(nr), before: 1)) == 'outOfScope',
        'neighbour cannot cross scope',
      );
      expect((narrow.repository.calls['read'] ?? 0) == 0, 'no outside query');
      final excluded = Harness();
      excluded.approval.choose = (_) => FrozenScope.messages(
        ActiveRange(
          FakeRepository.anchor(FakeRepository.hit),
          FakeRepository.anchor(FakeRepository.hit + 7),
        ),
        excludedRecords: ['message-${FakeRepository.hit}'],
      );
      final es = sourceHandle(await excluded.list());
      expect(
        status(await excluded.search(es)) == 'outOfScope',
        'bad repository returning excluded record refused',
      );
      expect(
        status(await h.read(source, selector(hit), before: 2, after: 2)) ==
            'ok',
        'approved neighbours remain usable',
      );
    },
    'all-source outside-selected / hidden same-size / variation / source ABA':
        () async {
          for (final mutation in [
            'outside',
            'redaction-hidden-same-size',
            'variation',
            'source-ABA',
          ]) {
            final h = Harness();
            final (source, section) = await h.selected();
            final body = await h.read(source, section);
            final key = h.repository.key(SourceDomain.ordinaryPreset);
            if (mutation == 'source-ABA') {
              h.repository.deleted.add(key);
              h.repository.recreate(key);
            } else {
              h.repository.mutate(key);
            }
            expect(
              status(await h.read(source, section)) == 'staleSource',
              'all-source $mutation invalidates text unchanged',
            );
            expect(
              !await h.engine.withPost([body], (_) async {
                throw StateError('no post');
              }),
              'retained snapshot $mutation blocks post',
            );
          }
        },
    'owner Stop / route / recipient ABA cannot revive original run': () async {
      for (final mode in ['stop', 'route', 'model', 'transient']) {
        final h = Harness();
        final (source, section) = await h.selected();
        if (mode == 'stop') {
          h.engine.stop();
        } else if (mode == 'transient') {
          h.owner.current = false;
        } else {
          h.owner.routeOrModelAba();
        }
        expect(
          status(await h.read(source, section)) == 'stopped',
          'original owner retired',
        );
        h.owner.current = true;
        expect(
          status(await h.read(source, section)) == 'stopped',
          'no A-B-A revival',
        );
      }
    },
    'Stop at each asynchronous port boundary; started work is joined':
        () async {
          for (final stage in [
            'discover',
            'observe',
            'approval',
            'contents',
            'search',
            'read',
            'project',
            'stamp',
            'wire',
            'provenance',
            'revalidate',
          ]) {
            final h = Harness();
            String? source;
            String? section;
            if (stage != 'discover')
              source = sourceHandle(await h.list(SourceDomain.ordinaryPreset));
            if ([
              'read',
              'project',
              'provenance',
              'stamp',
              'wire',
            ].contains(stage))
              section = selector(await h.contents(source!));
            var settled = false;
            Future<void> stopWork() async {
              h.engine.stop();
              await Future<void>.value();
              settled = true;
            }

            if (stage == 'approval')
              h.approval.hook = stopWork;
            else if (stage == 'project')
              h.projection.projectHook = stopWork;
            else if (stage == 'stamp')
              h.projection.stampHook = stopWork;
            else if (stage == 'wire')
              h.projection.wireHook = stopWork;
            else if (stage == 'provenance')
              h.provenance.hook = (_) => stopWork();
            else
              h.repository.hooks[stage] = stopWork;
            final result = stage == 'discover'
                ? await h.list()
                : stage == 'search'
                ? await h.search(source!)
                : section != null
                ? await h.read(source!, section)
                : await h.contents(source!);
            expect(
              status(result) == 'stopped' &&
                  !result.bodyBearing &&
                  pieces(result).isEmpty,
              'no stale body/cursor at $stage',
            );
            expect(settled, 'join started $stage work after synchronous Stop');
          }
        },
    'source or redactor change during query/provenance/last projection checkpoint':
        () async {
          for (final stage in [
            'query',
            'project',
            'provenance',
            'last-stamp',
          ]) {
            final h = Harness();
            final (source, section) = await h.selected();
            final key = h.repository.key(SourceDomain.ordinaryPreset);
            if (stage == 'query')
              h.repository.hooks['read'] = () async {
                h.repository.mutate(key);
              };
            if (stage == 'project')
              h.projection.projectHook = () async {
                h.repository.mutate(key);
              };
            if (stage == 'provenance')
              h.provenance.hook = (_) async {
                h.repository.mutate(key);
              };
            if (stage == 'last-stamp') {
              var calls = 0;
              h.projection.stampHook = () async {
                if (++calls == 2) h.repository.mutate(key);
              };
            }
            final result = await h.read(source, section);
            expect(
              status(result) == 'staleSource' && !result.bodyBearing,
              'no body at $stage',
            );
          }
          final h = Harness();
          final (source, section) = await h.selected();
          h.provenance.hook = (_) async {
            h.projection.stamp = const ProjectionStamp('redactor', 1);
          };
          expect(
            status(await h.read(source, section)) == 'staleProjection',
            'projection changes after provenance deny egress',
          );
        },
    'throwing and reentrant callbacks permanently retire owner': () async {
      for (final stage in [
        'owner',
        'lease',
        'repository',
        'projection',
        'provenance',
        'approval',
        'reentrant',
      ]) {
        final h = Harness();
        final (source, section) = await h.selected();
        if (stage == 'owner')
          h.owner.onCheck = () => throw StateError('PRIVATE exception');
        if (stage == 'lease')
          h.approval.leases.values.single.hook = () =>
              throw StateError('PRIVATE lease');
        if (stage == 'repository')
          h.repository.hooks['read'] = () async =>
              throw StateError('PRIVATE SQL/path');
        if (stage == 'projection')
          h.projection.projectHook = () async =>
              throw StateError('PRIVATE redactor');
        if (stage == 'provenance')
          h.provenance.hook = (_) async => throw StateError('PRIVATE DB');
        if (stage == 'approval') {
          final second = sourceHandle(await h.list(SourceDomain.studioPreset));
          h.approval.hook = () async => throw StateError('PRIVATE UI');
          expect(
            status(await h.contents(second)) == 'stopped',
            'throwing approval',
          );
        }
        if (stage == 'reentrant')
          h.repository.hooks['read'] = () async {
            final nested = await h.contents(source);
            expect(status(nested) == 'stopped', 'reentrancy denied');
          };
        final result = await h.read(source, section);
        expect(
          status(result) == 'stopped' && !result.encoded.contains('PRIVATE'),
          'fixed fail-closed category $stage',
        );
        h.owner.onCheck = null;
        h.repository.hooks.clear();
        h.projection.projectHook = null;
        h.provenance.hook = null;
        h.approval.leases.values.first.hook = null;
        expect(
          status(await h.read(source, section)) == 'stopped',
          'cannot revive $stage',
        );
      }
    },
    'provenance admission before release, exact receipt and bounded encrypted ack':
        () async {
          for (final mode in ['failure', 'conflict', 'copy']) {
            final h = Harness();
            final (source, section) = await h.selected();
            h.provenance.durable = mode != 'failure';
            h.provenance.conflict = mode == 'conflict';
            h.provenance.copiedReceipt = mode == 'copy';
            final body = await h.read(source, section);
            expect(
              status(body) == 'provenanceFailed' &&
                  !body.bodyBearing &&
                  pieces(body).isEmpty,
              'zero egress on $mode',
            );
          }
          final h = Harness();
          final (source, section) = await h.selected();
          final started = Completer<void>();
          final finish = Completer<void>();
          h.provenance.hook = (entry) async {
            expect(
              utf8.encode(entry.exactWireJson).length <= 65536,
              'full wire already validated',
            );
            expect(
              entry.extents.single.selection.recordId == 'record',
              'private exact selection',
            );
            started.complete();
            await finish.future;
          };
          var published = false;
          final pending = h.read(source, section).then((value) {
            published = true;
            return value;
          });
          await started.future;
          expect(!published, 'no release before durable acknowledgment');
          finish.complete();
          final body = await pending;
          expect(
            body.bodyBearing &&
                h.provenance.entries.last.exactWireJson == body.encoded,
            'exact original release after durable acknowledgment',
          );
        },
    'all retained snapshots revalidated for every unrelated/replay synthetic POST':
        () async {
          final h = Harness();
          final (os, ox) = await h.selected();
          final first = await h.read(os, ox);
          final (ss, sx) = await h.selected(SourceDomain.studioPreset);
          final second = await h.read(ss, sx);
          for (var i = 0; i < 2; i++) {
            h.repository.revalidatedKeys.clear();
            expect(
              await h.engine.withPost(i == 0 ? [second] : [], (_) async {}),
              'post/replay is admissible',
            );
            expect(
              h.repository.revalidatedKeys.contains(
                    h.repository.key(SourceDomain.ordinaryPreset),
                  ) &&
                  h.repository.revalidatedKeys.contains(
                    h.repository.key(SourceDomain.studioPreset),
                  ),
              'ALL retained source fences refreshed',
            );
          }
          expect(
            !await h.engine.withPost([Map.of(first.wire)], (_) async {
              throw StateError('copy');
            }),
            'copied map no custody',
          );
          expect(
            !await h.engine.withPost([h.provenance.entries.first], (_) async {
              throw StateError('cached');
            }),
            'cached provenance no body authority',
          );
          final other = Harness();
          expect(
            !await other.engine.withPost([first], (_) async {
              throw StateError('cross engine');
            }),
            'cross-engine original denied',
          );
          h.repository.mutate(h.repository.key(SourceDomain.ordinaryPreset));
          expect(
            !await h.engine.withPost([second], (_) async {
              throw StateError('unrelated mutation');
            }),
            'invalid earlier snapshot blocks unrelated later post',
          );
        },
    'source mutation during a later POST fence cannot pass final synchronous leases':
        () async {
          final h = Harness();
          final (os, ox) = await h.selected();
          await h.read(os, ox);
          final (ss, sx) = await h.selected(SourceDomain.studioPreset);
          final body = await h.read(ss, sx);
          var checked = 0;
          h.repository.hooks['revalidate'] = () async {
            if (++checked == 2)
              h.repository.mutate(
                h.repository.key(SourceDomain.ordinaryPreset),
              );
          };
          expect(
            !await h.engine.withPost([body], (_) async {
              throw StateError('stale earlier source');
            }),
            'final whole-source leases catch race between async validations',
          );
        },
    'oversized TEXT explicit continuation; full redaction before boundaries':
        () async {
          final h = Harness();
          final key = h.repository.key(SourceDomain.ordinaryPreset);
          h.projection.stringEnvelope = true;
          final raw =
              '${'x' * 39990}SECRET-CROSS-BOUNDARY${'🐈"\\\n' * 3000}tail';
          h.repository.records[key] = [
            DataRecord(
              selection: const Selection.record('root', 'record'),
              kind: SectionKind.presetBlock,
              state: SourceState.currentSaved,
              payload: raw,
            ),
          ];
          final (source, section) = await h.selected();
          var result = await h.read(source, section);
          expect(
            result.wire['partial'] == true &&
                result.wire['complete'] == false &&
                pieces(result).single['complete'] == false,
            'never silently clipped complete block',
          );
          final all = StringBuffer();
          var offset = 0;
          var pages = 0;
          while (true) {
            expect(
              status(result) == 'ok' &&
                  utf8.encode(result.encoded).length <= Limits.wireBytes &&
                  utf8.encode(result.postEncoded).length <= Limits.wireBytes,
              'actual repeated escaping and FULL wire cap',
            );
            final piece = pieces(result).single;
            final span = (piece['citation'] as Map)['disclosedSpan'] as Map;
            expect(span['start'] == offset, 'scalar continuation contiguous');
            offset = span['end'] as int;
            all.write(piece['payload']);
            pages++;
            final next = result.wire['nextCursor'];
            if (next == null) break;
            result = await h.read(source, next as String);
            expect(pages <= 4, 'finite partial continuation');
          }
          expect(
            all.toString() ==
                raw.replaceAll('SECRET-CROSS-BOUNDARY', '[redacted]'),
            'exact complete logical text after full-string redaction',
          );
          expect(
            !all.toString().contains('SECRET') &&
                !all.toString().contains('CROSS-BOUNDARY'),
            'no split secret',
          );
          expect(
            result.wire['partial'] == true && result.wire['complete'] == true,
            'last page complete enumeration, still an explicit partial section',
          );
        },
    'partial text continuation is source/snapshot/owner-bound': () async {
      final h = Harness();
      final key = h.repository.key(SourceDomain.ordinaryPreset);
      h.repository.records[key] = [
        DataRecord(
          selection: const Selection.record('root', 'record'),
          kind: SectionKind.presetBlock,
          state: SourceState.currentSaved,
          payload: 'a' * 90000,
        ),
      ];
      final (source, section) = await h.selected();
      final first = await h.read(source, section);
      final cursor = first.wire['nextCursor'] as String;
      expect(
        status(await h.read(source, cursor, before: 1)) == 'invalidReference',
        'continuation has no arbitrary neighbours',
      );
      h.repository.mutate(key);
      expect(
        status(await h.read(source, cursor)) == 'staleSource',
        'same-snapshot continuation cannot rebase',
      );
    },
    'Unicode literal, no normalization/regex; lone surrogates refused':
        () async {
          final h = Harness();
          final key = h.repository.key(SourceDomain.ordinaryPreset);
          h.repository.records[key] = [
            DataRecord(
              selection: const Selection.record('root', 'record'),
              kind: SectionKind.presetBlock,
              state: SourceState.currentSaved,
              payload: '🐈 e\u0301 É Needle [.*]',
            ),
          ];
          final source = sourceHandle(
            await h.list(SourceDomain.ordinaryPreset),
          );
          final match = await h.search(source, literal: 'e\u0301');
          expect(
            (pieces(match).single['matchSpan'] as Map)['start'] == 2,
            'Unicode scalar, not UTF-16 span',
          );
          expect(
            pieces(await h.search(source, literal: 'é')).isEmpty,
            'no Unicode normalization',
          );
          expect(
            pieces(await h.search(source, literal: 'needle')).isEmpty,
            'case-sensitive',
          );
          expect(
            pieces(await h.search(source, literal: '[.*]')).length == 1,
            'literal not regex',
          );
          expect(
            status(
                  await h.search(source, literal: String.fromCharCode(0xd800)),
                ) ==
                'invalidArguments',
            'invalid literal scalar denied',
          );
          final corrupt = Harness();
          final ck = corrupt.repository.key(SourceDomain.ordinaryPreset);
          corrupt.repository.records[ck] = [
            DataRecord(
              selection: const Selection.record('root', 'record'),
              kind: SectionKind.presetBlock,
              state: SourceState.currentSaved,
              payload: String.fromCharCode(0xdc00),
            ),
          ];
          final (cs, cx) = await corrupt.selected();
          expect(
            status(await corrupt.read(cs, cx)) == 'unavailable',
            'lone surrogate authored text never escapes',
          );
        },
    'redacted-only matches do not reveal match-derived IDs or counts':
        () async {
          final h = Harness();
          final source = sourceHandle(await h.list());
          final found = await h.search(
            source,
            literal: 'SECRET-CROSS-BOUNDARY',
          );
          expect(
            status(found) == 'ok' &&
                pieces(found).isEmpty &&
                !found.encoded.contains('SECRET'),
            'project before match/excerpt disclosure',
          );
        },
    'bounds: oversized structured/raw/page, projection shape, unsafe units, active admission':
        () async {
          for (final mode in [
            'structured',
            'raw',
            'page',
            'shape',
            'truncated',
            'unsafe',
            'inactive',
            'malformed',
            'wrong-range',
            'duplicate',
          ]) {
            final h = Harness();
            if ([
              'unsafe',
              'inactive',
              'malformed',
              'wrong-range',
              'duplicate',
            ].contains(mode)) {
              final source = sourceHandle(await h.list());
              final hit = await h.search(source);
              h.repository.unsafeUnit = mode == 'unsafe';
              h.repository.returnInactive = mode == 'inactive';
              h.repository.malformed = mode == 'malformed';
              h.repository.wrongRead = mode == 'wrong-range';
              h.repository.duplicateIdentity = mode == 'duplicate';
              final result = await h.read(source, selector(hit), after: 1);
              expect(
                status(result) == 'unavailable' && !result.bodyBearing,
                'active/identity/complete-unit admission $mode',
              );
              continue;
            }
            final key = h.repository.key(SourceDomain.ordinaryPreset);
            if (mode == 'structured' || mode == 'raw')
              h.repository.records[key] = [
                DataRecord(
                  selection: const Selection.record('root', 'record'),
                  kind: SectionKind.presetBlock,
                  state: SourceState.currentSaved,
                  payload: mode == 'structured'
                      ? {'text': '"' * 40000}
                      : 'x' * (Limits.rawBytes + 1),
                ),
              ];
            final source = sourceHandle(
              await h.list(SourceDomain.ordinaryPreset),
            );
            if (mode == 'page') {
              h.repository.oversizedPage = true;
              expect(
                status(await h.contents(source)) == 'unavailable',
                'repository overlarge page denied',
              );
              continue;
            }
            final section = selector(await h.contents(source));
            h.projection.changeShape = mode == 'shape';
            h.projection.complete = mode != 'truncated';
            final result = await h.read(source, section);
            expect(
              status(result) ==
                  (mode == 'structured' || mode == 'raw'
                      ? 'oversized'
                      : 'unavailable'),
              'shape/size $mode',
            );
            expect(
              !result.bodyBearing && h.provenance.entries.length == 1,
              'refusal before new provenance $mode',
            );
          }
        },
    'work exhaustion is incomplete, not valid no-match/full content': () async {
      final h = Harness();
      final source = sourceHandle(await h.list());
      h.repository.exhausted = true;
      final found = await h.search(source);
      expect(
        status(found) == 'ok' &&
            found.wire['complete'] == false &&
            found.wire['incompleteReason'] == 'workExhausted',
        'bounded search exhausted explicitly',
      );
      final contents = await h.contents(source);
      expect(
        contents.wire['complete'] == false &&
            contents.wire['incompleteReason'] == 'workExhausted',
        'contents exhaustion explicit',
      );
    },
    'full native wire projection: exact custody, nested escaping and metadata limits':
        () async {
          for (final mode in ['copy', 'duplicate', 'metadata', 'oversize']) {
            final h = Harness();
            final (source, section) = await h.selected();
            h.projection.copyWire = mode == 'copy';
            h.projection.duplicateWire = mode == 'duplicate';
            h.projection.badWireMetadata = mode == 'metadata';
            if (mode == 'oversize') {
              // This structured body fits its own JSON cap but fails when the real
              // host wraps it as an escaped JSON string. No estimated byte admission.
              h.repository.records[h.repository.key(
                SourceDomain.ordinaryPreset,
              )] = [
                DataRecord(
                  selection: const Selection.record('root', 'record'),
                  kind: SectionKind.presetBlock,
                  state: SourceState.currentSaved,
                  payload: {'text': '"' * 20000},
                ),
              ];
              h.projection.stringEnvelope = true;
            }
            final result = await h.read(source, section);
            expect(
              status(result) ==
                  (mode == 'copy' || mode == 'duplicate'
                      ? 'invalidCustody'
                      : 'oversized'),
              'full wrapper $mode',
            );
            expect(
              !result.bodyBearing && h.provenance.entries.length == 1,
              'no provenance/body for invalid FULL wire',
            );
          }
        },
    'retransmission reserves total disclosure even for unrelated posts':
        () async {
          final h = Harness(disclosureLimit: 7000);
          final (source, section) = await h.selected();
          final body = await h.read(source, section);
          var posts = 0;
          while (posts < 20 && await h.engine.withPost([body], (_) async {})) {
            posts++;
          }
          expect(
            posts > 0 && posts < 20,
            'finite total budget includes repeated POST source context',
          );
          expect(
            !await h.engine.withPost([], (_) async {
              throw StateError('unrelated bypass');
            }),
            'unrelated POST does not bypass disclosure budget',
          );
        },
    'committed, tentative, bootstrap Ledger snapshots and unknown summary evidence':
        () async {
          for (final state in [
            SourceState.historicalCommitted,
            SourceState.tentative,
            SourceState.bootstrap,
          ]) {
            final h = Harness();
            final key = h.repository.key(SourceDomain.ledgerSnapshot);
            h.repository.states[key] = state;
            if (state == SourceState.bootstrap)
              h.repository.bindings[key] = const Binding(
                sessionId: 'session',
                evidence: Evidence(EvidenceState.missing),
              );
            final (source, section) = await h.selected(
              SourceDomain.ledgerSnapshot,
            );
            final body = await h.read(source, section);
            expect(
              pieces(body).single['state'] == state.name,
              'snapshot state preserved',
            );
            final binding =
                (pieces(body).single['citation'] as Map)['binding'] as Map;
            expect(
              (binding['anchor'] == null) == (state == SourceState.bootstrap),
              'bootstrap is not a message anchor',
            );
          }
          for (final domain in [
            SourceDomain.savedSummary,
            SourceDomain.ledgerState,
          ]) {
            final h = Harness();
            final key = h.repository.key(domain);
            h.repository.bindings[key] = Binding(
              sessionId: 'session',
              evidence: Evidence(
                EvidenceState.attested,
                range: ActiveRange(
                  FakeRepository.anchor(1),
                  FakeRepository.anchor(9),
                ),
              ),
            );
            expect(
              status(await h.list(domain)) == 'unavailable',
              'count/live state cannot prove exact historical evidence',
            );
          }
        },
    'repeated disclosure consumes native and cumulative budgets': () async {
      for (final native in [false, true]) {
        final h = Harness(
          disclosureLimit: native ? Limits.disclosureBytes : 7000,
        );
        if (native) h.approval.budget = 7000;
        final key = h.repository.key(SourceDomain.ordinaryPreset);
        h.repository.records[key] = [
          DataRecord(
            selection: const Selection.record('root', 'record'),
            kind: SectionKind.presetBlock,
            state: SourceState.currentSaved,
            payload: 'a' * 1800,
          ),
        ];
        final (source, section) = await h.selected();
        var successes = 0;
        NavigationResult? last;
        for (var i = 0; i < 5; i++) {
          last = await h.read(source, section);
          if (status(last) != 'ok') break;
          successes++;
        }
        expect(
          successes > 0 && successes < 5 && status(last!) == 'budgetExceeded',
          'repeated bytes consume ${native ? 'scope' : 'run'} cap',
        );
        expect(
          h.provenance.entries
                  .map((e) => utf8.encode(e.exactEnvelopeJson).length)
                  .fold<int>(0, (a, b) => a + b) <=
              7000,
          'actual complete encoded results counted',
        );
      }
    },
    'fixed handle/call/repository budgets': () async {
      final calls = Harness();
      for (var i = 0; i < 32; i++)
        expect(status(await calls.list()) == 'ok', 'call within limit');
      expect(
        status(await calls.list()) == 'budgetExceeded',
        'fixed run call cap',
      );
      final refs = Harness();
      refs.repository.discoveryCopies = 16;
      NavigationResult? overflow;
      for (var i = 0; i < 10; i++) {
        overflow = await refs.list();
        if (status(overflow) != 'ok') break;
      }
      expect(
        status(overflow!) == 'budgetExceeded',
        'live opaque references bounded',
      );
      final steps = Harness();
      final (source, section) = await steps.selected();
      var posted = 0;
      while (posted < 70 && await steps.engine.withPost([], (_) async {})) {
        posted++;
      }
      expect(
        posted > 0 &&
            posted < 70 &&
            (steps.repository.calls['revalidate'] ?? 0) <= 64,
        'repository steps including POST bounded',
      );
      expect(
        status(await steps.read(source, section)) == 'budgetExceeded',
        'steps exhausted cannot query again',
      );
    },
    'retained sanitized continuation material has a finite independent cap':
        () async {
          final h = Harness();
          final key = h.repository.key(SourceDomain.ordinaryPreset);
          h.repository.records[key] = [
            DataRecord(
              selection: const Selection.record('root', 'record'),
              kind: SectionKind.presetBlock,
              state: SourceState.currentSaved,
              payload: 'raw',
            ),
          ];
          h.projection.transform = (_) => 'x' * (Limits.projectedBytes - 32);
          final (source, section) = await h.selected();
          expect(
            status(await h.read(source, section)) == 'ok',
            'first bounded projection retained',
          );
          expect(
            status(await h.read(source, section)) == 'ok',
            'second bounded projection retained',
          );
          final overflow = await h.read(source, section);
          expect(
            status(overflow) == 'budgetExceeded' && !overflow.bodyBearing,
            'no unbounded retained projected content',
          );
          expect(
            h.provenance.entries.length == 3,
            'overflow refused before persistence',
          );
          expect(
            h.engine.retainedTextBytes == 2 * (Limits.projectedBytes - 32),
            'failed admission retains neither bytes nor projected objects',
          );
        },
    'exact FOUR tools; strict arguments; retry deny before preparation':
        () async {
          expect(
            toolManifest.keys.toSet().difference({
                  'astoria_sources_list',
                  'astoria_source_contents',
                  'astoria_source_search',
                  'astoria_source_read',
                }).isEmpty &&
                toolManifest.length == 4,
            'exact manifest',
          );
          expect(
            modelToolDefinitions().length == 4 &&
                modelToolDefinitions().every(
                  (tool) =>
                      ((tool['function'] as Map)['parameters']
                          as Map)['additionalProperties'] ==
                      false,
                ),
            'actual strict function-definition surface',
          );
          final h = Harness();
          for (final action in [
            'sql',
            'shell',
            'file',
            'regex',
            'astoria_source_grant',
            'astoria_source_latest',
            'astoria_reconcile',
            'astoria_source_edit',
            'astoria_source_json_page',
            'cleanup',
            'recompute',
            'recovery',
          ]) {
            expect(
              status(
                    await h.engine.invoke(action, {
                      'path': 'PRIVATE',
                    }, retryOrRegeneration: true),
                  ) ==
                  'unsupportedOperation',
              'extra tool absent',
            );
          }
          expect(
            h.repository.calls.isEmpty && h.approval.requests == 0,
            'retry allowlist precedes preparation',
          );
          final source = sourceHandle(await h.list());
          for (final arguments in [
            {'source': source, 'grant': true},
            {'source': source, 'section': null},
            {'source': source, 'offset': 0},
            {'source': source, 'section': '/json/pointer'},
          ]) {
            expect(
              status(
                    await h.engine.invoke('astoria_source_contents', arguments),
                  ) ==
                  'invalidArguments',
              'strict no coercions/unknowns',
            );
          }
          expect(
            status(
                  await h.engine.invoke('astoria_source_read', {
                    'source': source,
                    'selector': source,
                    'before': 1.0,
                  }),
                ) ==
                'invalidArguments',
            'integer not float',
          );
          expect(
            status(
                  await h.engine.invoke('astoria_source_search', {
                    'source': source,
                    'literal': 'a' * 257,
                  }),
                ) ==
                'invalidArguments',
            'literal scalar cap',
          );
        },
  };
  var passed = 0;
  final failures = <String>[];
  for (final entry in tests.entries) {
    try {
      await entry.value();
      passed++;
      print('PASS ${entry.key}');
    } catch (error, stack) {
      failures.add(entry.key);
      print('FAIL ${entry.key}: $error\n$stack');
    }
  }
  print('$passed/${tests.length} synthetic groups passed');
  if (failures.isNotEmpty)
    throw StateError('Failed groups: ${failures.join('; ')}');
}
