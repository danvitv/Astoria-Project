import 'dart:convert';
import 'dart:math';

// No filesystem, database, transport, parser, or application-action dependency.
enum SourceDomain {
  game,
  ordinaryPreset,
  studioPreset,
  memory,
  savedSummary,
  ledgerState,
  ledgerSnapshot,
  reconciliation,
  characterKnowledge,
}

enum SourceState {
  currentSaved,
  current,
  historicalCommitted,
  tentative,
  bootstrap,
  derived,
  pendingGeneration,
  pendingApproval,
  error,
  needsRegeneration,
  active,
  superseded,
  retracted,
  tombstone,
  unknown,
}

enum SectionKind {
  presetBlock,
  regexDefinitions,
  reasoning,
  templates,
  studioBlock,
  studioAgents,
  runtime,
  settings,
  activeMessages,
  memoryEntries,
  memoryEntry,
  memoryRevision,
  memoryDraft,
  memoryDerived,
  summaryText,
  summaryTemplate,
  ledgerTrackers,
  ledgerSnapshot,
  reconciliationCheckpoint,
  reconciliationSavedResult,
  reconciliationEvidence,
  knowledgeFact,
}

enum EvidenceState { attested, unknown, invalid, missing }

enum SelectionKind { section, record, messageRange }

enum Operation { list, contents, search, read }

class Limits {
  static const wireBytes = 65536;
  static const metadataBytes = 256;
  static const collection = 32;
  static const page = 16;
  static const literalScalars = 256;
  static const excerptScalars = 512;
  static const excerptBytes = 2048;
  // Native protocols encode the tool result once more as a message string.
  // Lower than the cleanroom maximum; the host independently measures/bounds
  // that extra wrapping before any durable disclosure acknowledgment.
  static const partialEscapedBytes = 24000;
  static const rawBytes = 2 * 1024 * 1024;
  static const projectedBytes = 4 * 1024 * 1024;
  static const retainedBytes = 8 * 1024 * 1024;
  static const depth = 24;
  static const nodes = 8192;
  static const references = 128;
  static const calls = 32;
  static const repositorySteps = 64;
  static const scopes = 16;
  static const bodyResults = 32;
  static const disclosureBytes = 262144;
  static const candidates = 4096;
}

/// EXACT model surface. Approval is deliberately not a model operation.
const toolManifest = <String, Map<String, String>>{
  'astoria_sources_list': {
    'domain': 'required domain enum',
    'parent': 'optional issued source handle',
    'cursor': 'optional issued list cursor',
  },
  'astoria_source_contents': {
    'source': 'required issued source handle',
    'section': 'optional issued section selector',
    'cursor': 'optional issued contents cursor',
  },
  'astoria_source_search': {
    'source': 'required issued source handle',
    'literal': 'required case-sensitive Unicode literal, 1..256 scalars',
    'section': 'optional issued section selector',
    'cursor': 'optional issued search cursor',
  },
  'astoria_source_read': {
    'source': 'required issued source handle',
    'selector': 'required ONE issued logical selector or text continuation',
    'before': 'optional integer 0..2 ACTIVE neighbours',
    'after': 'optional integer 0..2 ACTIVE neighbours',
  },
};

/// Ready-to-adapt function definitions; registering/reaching them is main-owned.
List<Map<String, Object?>> modelToolDefinitions() => toolManifest.entries
    .map((tool) {
      final properties = <String, Object?>{};
      for (final key in tool.value.keys) {
        properties[key] = switch (key) {
          'domain' => {
            'type': 'string',
            'enum': SourceDomain.values.map((d) => d.name).toList(),
          },
          'literal' => {
            'type': 'string',
            'minLength': 1,
            'maxLength': Limits.literalScalars,
            'description':
                'Case-sensitive Unicode literal; no regex or normalization.',
          },
          'before' ||
          'after' => {'type': 'integer', 'minimum': 0, 'maximum': 2},
          _ => {
            'type': 'string',
            'maxLength': 128,
            'pattern': r'^h_[0-9a-f]{48}$',
          },
        };
      }
      final required = tool.key == 'astoria_sources_list'
          ? ['domain']
          : tool.key == 'astoria_source_read'
          ? ['source', 'selector']
          : tool.key == 'astoria_source_search'
          ? ['source', 'literal']
          : ['source'];
      return {
        'type': 'function',
        'function': {
          'name': tool.key,
          'description':
              'Read-only navigation of untrusted saved source data. Native approval required; handles grant no authority.',
          'parameters': {
            'type': 'object',
            'properties': properties,
            'required': required,
            'additionalProperties': false,
          },
        },
      };
    })
    .toList(growable: false);

class SourceKey {
  final SourceDomain domain;
  final String nativeId;
  const SourceKey(this.domain, this.nativeId);
  @override
  bool operator ==(Object other) =>
      other is SourceKey &&
      other.domain == domain &&
      other.nativeId == nativeId;
  @override
  int get hashCode => Object.hash(domain, nativeId);
}

/// Private, ALL-source mutation attestation, not a selected-text hash/time/size.
class Snapshot {
  final String incarnation;
  final int revision;
  final String? privateIntegrity;
  const Snapshot(this.incarnation, this.revision, {this.privateIntegrity});
  bool same(Snapshot other) =>
      incarnation == other.incarnation && revision == other.revision;
}

/// Ordinal is an attested ACTIVE-message ordinal in this frozen snapshot.
/// It is never a model input or an arbitrary JSON offset.
class Anchor {
  final String messageId;
  final int ordinal;
  final String? swipe;
  final String? agentSwipe;
  const Anchor(this.messageId, this.ordinal, {this.swipe, this.agentSwipe});
  bool same(Anchor other) =>
      messageId == other.messageId &&
      ordinal == other.ordinal &&
      swipe == other.swipe &&
      agentSwipe == other.agentSwipe;
}

/// Provenance actually stored by a saved artifact. It has NO ACTIVE ordinal and
/// does not assert that this variation is still selected or currently attested.
class SavedAnchor {
  final String messageId;
  final String swipe;
  final String agentSwipe;
  const SavedAnchor(this.messageId, this.swipe, this.agentSwipe);
}

class ActiveRange {
  final Anchor start;
  final Anchor end;
  const ActiveRange(this.start, this.end);
  bool get valid => start.ordinal >= 0 && end.ordinal >= start.ordinal;
  bool contains(ActiveRange other) =>
      valid &&
      other.valid &&
      other.start.ordinal >= start.ordinal &&
      other.end.ordinal <= end.ordinal &&
      (other.start.ordinal != start.ordinal || other.start.same(start)) &&
      (other.end.ordinal != end.ordinal || other.end.same(end));
}

class Evidence {
  final EvidenceState state;
  final ActiveRange? range;
  const Evidence(this.state, {this.range});
}

/// All identities stay private; emitted IDs are run-local, non-authorizing aliases.
class Binding {
  final String? sessionId;
  final String? characterId;
  final String? knowerId;
  final String? subjectId;
  final Anchor? anchor;
  final SavedAnchor? savedAnchor;
  final Evidence evidence;
  const Binding({
    this.sessionId,
    this.characterId,
    this.knowerId,
    this.subjectId,
    this.anchor,
    this.savedAnchor,
    this.evidence = const Evidence(EvidenceState.unknown),
  });
}

class SourceObservation {
  final SourceKey key;
  final Snapshot snapshot;
  final SourceState state;
  final Binding binding;
  final bool? activeAtListing;
  final SourceKey? parent;
  final SnapshotLease lease;
  const SourceObservation({
    required this.key,
    required this.snapshot,
    required this.lease,
    this.state = SourceState.unknown,
    this.binding = const Binding(),
    this.activeAtListing,
    this.parent,
  });
}

abstract interface class SnapshotLease {
  /// Synchronous whole-source fence pinned to this exact snapshot. Permanently
  /// false after ANY source change/ABA, even outside selected/redacted text.
  /// Host must make final checks and actual POST one synchronous ownership gate.
  bool isCurrent();
}

class Selection {
  final SelectionKind kind;
  final String sectionId;
  final String? recordId;
  final ActiveRange? range;
  final bool readable;
  const Selection.section(this.sectionId, {this.readable = false})
    : kind = SelectionKind.section,
      recordId = null,
      range = null;
  const Selection.record(this.sectionId, this.recordId)
    : kind = SelectionKind.record,
      range = null,
      readable = true;
  const Selection.messages(this.sectionId, this.range)
    : kind = SelectionKind.messageRange,
      recordId = null,
      readable = true;
  bool same(Selection other) =>
      kind == other.kind &&
      sectionId == other.sectionId &&
      recordId == other.recordId &&
      readable == other.readable &&
      (range == null
          ? other.range == null
          : other.range != null &&
                range!.start.same(other.range!.start) &&
                range!.end.same(other.range!.end));
}

class SectionDescriptor {
  final Selection selection;
  final SectionKind kind;
  final SourceState state;
  final Binding binding;
  const SectionDescriptor(
    this.selection,
    this.kind, {
    this.state = SourceState.unknown,
    this.binding = const Binding(),
  });
}

/// A bounded COMPLETE redaction unit or complete finite typed record.
/// Structured keys are host-attested schema keys, not authored keys/JSON paths.
/// All string VALUES are authored data. Flags/numbers/shape must be preserved.
class DataRecord {
  final Selection selection;
  final SectionKind kind;
  final SourceState state;
  final Binding binding;
  final Object? payload; // String OR finite JSON-shaped structured record.
  final bool admitted;
  final bool shapeKnown;
  final bool completeUnit;
  final bool schemaKeysAttested;
  final String? role;
  DataRecord({
    required this.selection,
    required this.kind,
    required Object? payload,
    this.state = SourceState.unknown,
    this.binding = const Binding(),
    this.admitted = true,
    this.shapeKnown = true,
    this.completeUnit = true,
    this.schemaKeysAttested = false,
    this.role,
  }) : payload = _freeze(payload);
}

class WorkBound {
  final int pageSize;
  final int candidateLimit;
  final int rawByteLimit;
  const WorkBound({
    this.pageSize = Limits.page,
    this.candidateLimit = Limits.candidates,
    this.rawByteLimit = Limits.rawBytes,
  });
}

/// complete=true means this enumeration is exhausted, not the whole source.
/// A deadline/candidate stop must return complete=false and exhaustedWork=true.
/// Cursors are PRIVATE repository objects, never serialized or interpreted here.
class Page<T> {
  final List<T> items;
  final Object? next;
  final bool complete;
  final bool exhaustedWork;
  final int candidatesExamined;
  Page(
    Iterable<T> items, {
    this.next,
    this.complete = true,
    this.exhaustedWork = false,
    this.candidatesExamined = 0,
  }) : items = List.unmodifiable(items);
}

class ReadQuery {
  final Selection selection;
  final int before;
  final int after;
  const ReadQuery(this.selection, this.before, this.after);
}

/// Implement inside native repositories ONLY. No full-history API exists.
/// The host owns strict codecs, active/variation/evidence/shape admission,
/// all-source fences and bounded storage scans; never hydrate messages_json.
abstract interface class NavigationRepository {
  Future<Page<SourceObservation>> discover(
    SourceDomain domain,
    SourceKey? parent,
    Object? cursor,
    WorkBound bound,
  );
  Future<SourceObservation?> observe(SourceKey source, WorkBound bound);
  Future<bool> revalidate(SourceObservation original, WorkBound bound);
  Future<Page<SectionDescriptor>> contents(
    SourceObservation source,
    FrozenScope scope,
    Selection? section,
    Object? cursor,
    WorkBound bound,
  );

  /// Returns at most one COMPLETE text unit per matching record/ACTIVE message.
  /// Engine redacts the whole unit then finds its first visible literal match.
  /// Repository page completion enumerates records, NOT all occurrences.
  Future<Page<DataRecord>> search(
    SourceObservation source,
    FrozenScope scope,
    String literal,
    Selection? section,
    Object? cursor,
    WorkBound bound,
  );

  /// Exactly one complete record/block OR ascending admitted ACTIVE range.
  /// Neighbours count against 16 and MUST remain in the native frozen scope.
  Future<Page<DataRecord>> read(
    SourceObservation source,
    FrozenScope scope,
    ReadQuery query,
    WorkBound bound,
  );
}

class Recipient {
  final String provider;
  final String configuration;
  final String protocol;
  final String model;
  final String nativeRoute;
  final int configurationRevision;
  const Recipient(
    this.provider,
    this.configuration,
    this.protocol,
    this.model, {
    this.nativeRoute = '',
    this.configurationRevision = 0,
  });
  bool same(Recipient other) =>
      provider == other.provider &&
      configuration == other.configuration &&
      protocol == other.protocol &&
      model == other.model &&
      nativeRoute == other.nativeRoute &&
      configurationRevision == other.configurationRevision;
}

class RunContext {
  final Object originalOwner;
  final String runId;
  final Recipient recipient;
  const RunContext(this.originalOwner, this.runId, this.recipient);
}

abstract interface class OwnerPort {
  /// Host MUST latch Stop/route/model/owner ABA permanently, including changes
  /// between engine calls. A current bool without a monotonic lease is insufficient.
  bool isOriginalOwnerCurrent(RunContext original);
}

/// Scope is immutable, inclusive, explicitly native-approved. Section IDs are
/// frozen native membership roots, NOT arbitrary descendants or another source.
class FrozenScope {
  final Set<String> sections;
  final ActiveRange? messages;
  final Set<String> excludedRecords;
  FrozenScope.sections(
    Iterable<String> sections, {
    Iterable<String> excludedRecords = const [],
  }) : sections = Set.unmodifiable(sections),
       messages = null,
       excludedRecords = Set.unmodifiable(excludedRecords);
  FrozenScope.messages(
    this.messages, {
    Iterable<String> excludedRecords = const [],
  }) : sections = const {},
       excludedRecords = Set.unmodifiable(excludedRecords);
}

abstract interface class ApprovalLease {
  /// Native UI must remain present; revocation/missing UI is false, with ABA latch.
  bool isCurrent();
}

class ApprovalRequest {
  final RunContext run;
  final SourceObservation source;
  final int maximumDisclosureBytes;
  final Selection? requested;
  const ApprovalRequest(
    this.run,
    this.source,
    this.maximumDisclosureBytes,
    this.requested,
  );
}

class NativeGrant {
  final RunContext run;
  final SourceKey source;
  final Snapshot snapshot;
  final FrozenScope scope;
  final int disclosureBytes;
  final ApprovalLease lease;
  const NativeGrant({
    required this.run,
    required this.source,
    required this.snapshot,
    required this.scope,
    required this.disclosureBytes,
    required this.lease,
  });
}

abstract interface class ApprovalPort {
  /// One native gesture must name exact source/snapshot, sections or ACTIVE range,
  /// exclusions, recipient/config/protocol/model, current run, total byte budget.
  /// Send/selection/model arguments are not a gesture. null = deny/missing UI.
  Future<NativeGrant?> request(ApprovalRequest request);
}

class ProjectionStamp {
  final String incarnation;
  final int revision;
  const ProjectionStamp(this.incarnation, this.revision);
  bool same(ProjectionStamp other) =>
      incarnation == other.incarnation && revision == other.revision;
}

class ProjectedRecord {
  final Object? payload;
  final ProjectionStamp stamp;
  final bool complete;
  ProjectedRecord(Object? payload, this.stamp, {this.complete = true})
    : payload = _freeze(payload);
}

class WireCandidate {
  final String operation;
  final String argumentsJson;
  final Map<String, Object?> wire;
  final String encoded;
  WireCandidate(
    this.operation,
    this.argumentsJson,
    Map<String, Object?> wire,
    this.encoded,
  ) : wire = _freeze(wire) as Map<String, Object?>;
}

class ProjectedWire {
  final WireCandidate exactCandidate;
  final ProjectionStamp stamp;

  /// The actual FULL nested host tool result. It must contain exactly ONE
  /// original candidate.wire OR candidate.encoded object, never a rewritten body.
  /// Other strings are bounded safe protocol metadata, never authored content.
  final Object? fullResult;
  const ProjectedWire(this.exactCandidate, this.fullResult, this.stamp);
}

abstract interface class ProjectionPort {
  /// Redact COMPLETE authored string values before slicing/excerpts/escaping.
  /// No macro/regex/source-instruction execution or serialized-JSON redaction.
  /// Huge unsafe units must be refused, not truncated and marked complete.
  Future<ProjectedRecord> project(DataRecord completeRecord);
  Future<ProjectionStamp> currentStamp();

  /// Host must supply its exact real tool-result wrapper/escaping, not an estimate.
  /// The engine measures and validates the entire nested result before admission.
  Future<ProjectedWire> wire(WireCandidate original);
}

class DisclosedExtent {
  final Selection selection;
  final int? startScalar;
  final int? endScalar;
  final Binding binding;
  const DisclosedExtent(
    this.selection,
    this.binding, {
    this.startScalar,
    this.endScalar,
  });
}

class ProvenanceEntry {
  final RunContext run;
  final SourceObservation source;
  final NativeGrant grant;
  final String operation;
  final String argumentsJson;
  final String exactWireJson;
  final String exactEnvelopeJson;
  final List<DisclosedExtent> extents;
  final ProjectionStamp projection;
  ProvenanceEntry({
    required this.run,
    required this.source,
    required this.grant,
    required this.operation,
    required this.argumentsJson,
    required this.exactWireJson,
    required this.exactEnvelopeJson,
    required Iterable<DisclosedExtent> extents,
    required this.projection,
  }) : extents = List.unmodifiable(extents);
}

class ProvenanceReceipt {
  final ProvenanceEntry exactEntry;
  final bool durableEncrypted;
  final bool conflict;
  const ProvenanceReceipt(
    this.exactEntry, {
    required this.durableEncrypted,
    this.conflict = false,
  });
}

abstract interface class ProvenancePort {
  /// Durable, encrypted, exact source/domain/snapshot/selection/IDs/disclosed extent
  /// acknowledgment BEFORE egress. This is outside the host read-only ROOT.
  /// Only exact own-write fences may be advanced by host, not rebased source data.
  Future<ProvenanceReceipt> append(ProvenanceEntry entry);
}

/// Original body-result custody. No public constructor or reconstruction API.
class NavigationResult {
  final Map<String, Object?> wire;
  final String encoded;
  final bool bodyBearing;
  final String postEncoded;
  NavigationResult._(
    Map<String, Object?> wire,
    this.encoded,
    this.bodyBearing,
    this.postEncoded,
  ) : wire = _freeze(wire) as Map<String, Object?>;
}

class PostEnvelope {
  final List<NavigationResult> originalResults;
  final RunContext run;
  PostEnvelope._(Iterable<NavigationResult> results, this.run)
    : originalResults = List.unmodifiable(results);
}

class _Failure implements Exception {
  final String status;
  const _Failure(this.status);
}

class _SourceRef {
  final SourceObservation source;
  NativeGrant? grant;
  int spent = 0;
  _SourceRef(this.source);
}

class _SelectionRef {
  final _SourceRef source;
  final NativeGrant grant;
  final SectionDescriptor descriptor;
  _SelectionRef(this.source, this.grant, this.descriptor);
}

class _CursorRef {
  final Operation operation;
  final String binding;
  final _SourceRef? source;
  final NativeGrant? grant;
  final Object privateCursor;
  _CursorRef(
    this.operation,
    this.binding,
    this.source,
    this.grant,
    this.privateCursor,
  );
}

class _TextRef {
  final _SourceRef source;
  final NativeGrant grant;
  final DataRecord record;
  final ProjectedRecord projected;
  final int offset; // UTF-16 internally, scalar on wire.
  _TextRef(this.source, this.grant, this.record, this.projected, this.offset);
}

class _Retained {
  final _SourceRef source;
  final NativeGrant grant;
  final ProjectionStamp projection;
  final ProvenanceEntry entry;
  _Retained(this.source, this.grant, this.projection, this.entry);
}

/// Native-only, single-use batch created AFTER the original ROOT excludes
/// writers. It owns no authorization or cached result. Unknown repositories use
/// ordinary per-source revalidation instead; this is never a model parameter.
abstract interface class OriginalRootRevalidation {
  NavigationRepository get repository;
  bool get isCurrent;
  Future<bool> revalidate(List<SourceObservation> originals, WorkBound bound);
}

/// Implemented only by repositories that can establish their own native ROOT
/// custody. The engine never accepts a caller-supplied scope or root boolean.
abstract interface class OriginalRootNavigationRepository
    implements NavigationRepository {
  OriginalRootRevalidation? get currentOriginalRootRevalidation;
}

class SourceNavigationEngine {
  final RunContext run;
  final NavigationRepository repository;
  final OwnerPort owner;
  final ApprovalPort approval;
  final ProjectionPort projection;
  final ProvenancePort provenance;
  final int disclosureLimit;
  final Map<String, Object> _refs = {};
  final Map<SourceKey, _SourceRef> _sources = {};
  final Map<String, String> _aliases = {};
  final Set<SourceKey> _invalidSources = {};
  final Set<NavigationResult> _outcomes = Set.identity();
  final List<_Retained> _retained = [];
  final Set<ProjectedRecord> _storedProjection = Set.identity();
  final Random _random = Random.secure();
  bool _retired = false;
  bool _busy = false;
  bool _checking = false;
  int _calls = 0;
  int _steps = 0;
  int _grants = 0;
  int _bodyResults = 0;
  int _spent = 0;
  int _material = 0;
  SourceNavigationEngine({
    required this.run,
    required this.repository,
    required this.owner,
    required this.approval,
    required this.projection,
    required this.provenance,
    int disclosureLimit = Limits.disclosureBytes,
  }) : disclosureLimit = min(disclosureLimit, Limits.disclosureBytes) {
    if (disclosureLimit <= 0) throw ArgumentError('Invalid native budget');
  }

  void stop() {
    _retired = true;
  }

  /// Local host/test accounting only; not a model operation or source metadata.
  int get retainedTextBytes => _material;

  /// Original host ROOT checks share the SAME 64-step budget as navigation and
  /// replay. This is not a model operation or POST and grants no cached permit.
  /// May run while withPost awaits the actual writer-excluding host gate.
  Future<bool> revalidateForHost(
    Iterable<SourceObservation> observations,
    void Function() checkpoint,
  ) async {
    try {
      final native = repository;
      final originalRoot = native is OriginalRootNavigationRepository
          ? native.currentOriginalRootRevalidation
          : null;
      final checked = <SourceObservation>{};
      final sources = <_SourceRef>[];
      for (final observation in observations) {
        checkpoint();
        _checkpoint();
        final source = _sources[observation.key];
        if (source == null || !identical(source.source, observation)) {
          return false;
        }
        if (!checked.add(observation)) continue;
        sources.add(source);
      }
      if (originalRoot == null) {
        for (final source in sources) {
          await _fresh(source, source.grant);
          checkpoint();
          _checkpoint();
        }
        return true;
      }
      if (!identical(originalRoot.repository, repository) ||
          !originalRoot.isCurrent) {
        return false;
      }
      void leases() {
        checkpoint();
        _checkpoint();
        for (final source in sources) {
          _sourceCurrent(source);
          if (source.grant != null) _grantCurrent(source, source.grant!);
        }
      }

      leases();
      if (sources.isNotEmpty) {
        // ONE actual repository operation: the native fence is database-wide,
        // with exact observation ownership checked on both sides of its awaits.
        final valid = await _await(
          () => originalRoot.revalidate(
            List.unmodifiable(sources.map((s) => s.source)),
            const WorkBound(),
          ),
          repo: true,
        );
        checkpoint();
        _checkpoint();
        if (!valid) return false;
      }
      leases();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _checkpoint() {
    if (_retired || _checking) {
      _retired = true;
      throw const _Failure('stopped');
    }
    _checking = true;
    try {
      if (!owner.isOriginalOwnerCurrent(run) || _retired) {
        _retired = true;
        throw const _Failure('stopped');
      }
    } catch (_) {
      _retired = true;
      throw const _Failure('stopped');
    } finally {
      _checking = false;
    }
  }

  T _callback<T>(T Function() callback) {
    _checkpoint();
    try {
      final result = callback();
      _checkpoint();
      return result;
    } catch (_) {
      _retired = true;
      throw const _Failure('stopped');
    }
  }

  Future<T> _await<T>(
    Future<T> Function() callback, {
    bool repo = false,
  }) async {
    _checkpoint();
    if (repo && ++_steps > Limits.repositorySteps) {
      throw const _Failure('budgetExceeded');
    }
    // Start, join and settle private work even if a synchronous callback retires
    // the owner before returning its already-started future.
    late Future<T> future;
    try {
      future = callback();
    } catch (_) {
      _retired = true;
      throw const _Failure('stopped');
    }
    var invalid = false;
    try {
      _checkpoint();
    } catch (_) {
      invalid = true;
    }
    try {
      final value = await future;
      _checkpoint();
      if (invalid) throw const _Failure('stopped');
      return value;
    } catch (_) {
      _retired = true;
      throw const _Failure('stopped');
    }
  }

  Future<T> _joined<T>(Future<T> future) async {
    // Always settle started work, including synchronous Stop/reentry at start.
    var invalid = false;
    try {
      _checkpoint();
    } catch (_) {
      invalid = true;
    }
    try {
      final result = await future;
      _checkpoint();
      if (invalid) throw const _Failure('stopped');
      return result;
    } on _Failure {
      // Internal fixed-category refusals are not throwing injected callbacks.
      _checkpoint();
      rethrow;
    } catch (_) {
      _retired = true;
      throw const _Failure('stopped');
    }
  }

  bool _lease(NativeGrant grant) => _callback(grant.lease.isCurrent);

  void _grantCurrent(_SourceRef source, NativeGrant grant) {
    _checkpoint();
    _sourceCurrent(source);
    if (_invalidSources.contains(source.source.key) ||
        !identical(source.grant, grant) ||
        !_lease(grant)) {
      _invalidSources.add(source.source.key);
      throw const _Failure('approvalRequired');
    }
  }

  void _sourceCurrent(_SourceRef source) {
    if (_invalidSources.contains(source.source.key) ||
        !_callback(source.source.lease.isCurrent)) {
      _invalidSources.add(source.source.key);
      throw const _Failure('staleSource');
    }
  }

  Future<void> _fresh(_SourceRef source, NativeGrant? grant) async {
    _checkpoint();
    _sourceCurrent(source);
    if (grant != null) _grantCurrent(source, grant);
    final valid = await _await(
      () => repository.revalidate(source.source, const WorkBound()),
      repo: true,
    );
    _checkpoint();
    if (!valid) {
      _invalidSources.add(source.source.key);
      throw const _Failure('staleSource');
    }
    _sourceCurrent(source);
    if (grant != null) _grantCurrent(source, grant);
  }

  String _issue(Object ref) {
    if (_refs.length + _aliases.length >= Limits.references) {
      throw const _Failure('budgetExceeded');
    }
    String handle;
    do {
      handle =
          'h_${List.generate(24, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    } while (_refs.containsKey(handle) || _aliases.containsValue(handle));
    _refs[handle] = ref;
    return handle;
  }

  String _alias(String category, String id) {
    final key = '$category\u0000$id';
    return _aliases.putIfAbsent(key, () {
      final handle = _issue(Object());
      _refs.remove(handle);
      return handle;
    });
  }

  T _ref<T>(Object? value) {
    if (value is! String || !_validHandle(value)) {
      throw const _Failure('invalidReference');
    }
    final ref = _refs[value];
    if (ref is! T) throw const _Failure('invalidReference');
    return ref;
  }

  Map<String, Object?> _binding(
    Binding binding,
    SourceKey key, {
    bool discovery = false,
  }) {
    final result = <String, Object?>{
      'session': binding.sessionId == null
          ? null
          : _alias('session', binding.sessionId!),
      'character': binding.characterId == null
          ? null
          : _alias('character', binding.characterId!),
    };
    if (discovery) return result; // No match/anchor/evidence-derived discovery.
    result.addAll({
      'knower': binding.knowerId == null
          ? null
          : _alias('character', binding.knowerId!),
      'subject': binding.subjectId == null
          ? null
          : _alias('character', binding.subjectId!),
      'anchor': binding.anchor == null ? null : _anchor(binding.anchor!, key),
      if (binding.savedAnchor case final saved?)
        'savedAnchor': {
          'message': _alias(
            '${key.domain.name}:${key.nativeId}:message',
            saved.messageId,
          ),
          'swipe': _alias('${key.nativeId}:swipe', saved.swipe),
          'agentSwipe': _alias('${key.nativeId}:agentSwipe', saved.agentSwipe),
        },
      'evidence': {
        'state': binding.evidence.state.name,
        'range': binding.evidence.range == null
            ? null
            : {
                'start': _anchor(binding.evidence.range!.start, key),
                'end': _anchor(binding.evidence.range!.end, key),
              },
      },
    });
    return result;
  }

  Map<String, Object?> _anchor(Anchor a, SourceKey key) => {
    'message': _alias(
      '${key.domain.name}:${key.nativeId}:message',
      a.messageId,
    ),
    'swipe': a.swipe == null ? null : _alias('${key.nativeId}:swipe', a.swipe!),
    'agentSwipe': a.agentSwipe == null
        ? null
        : _alias('${key.nativeId}:agentSwipe', a.agentSwipe!),
  };

  Map<String, Object?> _wire(
    String operation, {
    String status = 'ok',
    List<Object?> pieces = const [],
    bool complete = true,
    bool partial = false,
    String? next,
    String? reason,
  }) => {
    'operation': operation,
    'status': status,
    'effect': 'none',
    'pieces': pieces,
    'count': pieces.length,
    'total': null,
    'complete': complete,
    'partial': partial,
    'nextCursor': next,
    'incompleteReason': reason,
    'trust': 'untrusted_source_data',
  };

  NavigationResult _result(
    Map<String, Object?> wire,
    bool body, {
    String? postEncoded,
  }) {
    final json = _encodeWire(wire);
    final result = NavigationResult._(wire, json, body, postEncoded ?? json);
    // Fixed refusals are not source-body custody and need no unbounded registry.
    if (wire['status'] == 'ok') _outcomes.add(result);
    return result;
  }

  Future<NavigationResult> invoke(
    String name,
    Map<String, Object?> arguments, {
    bool retryOrRegeneration = false,
  }) async {
    // Allowlist BEFORE any preparation; retry has exactly the same four reads.
    if (!toolManifest.containsKey(name)) {
      return _result(_wire('unknown', status: 'unsupportedOperation'), false);
    }
    if (_busy) {
      _retired = true;
      return _result(_wire(name, status: 'stopped'), false);
    }
    _busy = true;
    try {
      _checkpoint();
      if (++_calls > Limits.calls) throw const _Failure('budgetExceeded');
      _validateArguments(name, arguments);
      _preflightReferences(name, arguments);
      final args = _freeze(arguments) as Map<String, Object?>;
      final future = switch (name) {
        'astoria_sources_list' => _list(name, args),
        'astoria_source_contents' => _contents(name, args),
        'astoria_source_search' => _search(name, args),
        _ => _read(name, args),
      };
      return await _joined(future);
    } on _Failure catch (failure) {
      return _result(
        _wire(
          name,
          status: failure.status,
          complete: false,
          reason: failure.status,
        ),
        false,
      );
    } catch (_) {
      _retired = true;
      return _result(
        _wire(name, status: 'stopped', complete: false, reason: 'stopped'),
        false,
      );
    } finally {
      _busy = false;
    }
  }

  void _preflightReferences(String name, Map<String, Object?> args) {
    final source = args['source'] == null
        ? null
        : _ref<_SourceRef>(args['source']);
    if (args['parent'] != null) _ref<_SourceRef>(args['parent']);
    if (args['cursor'] == null) return;
    final operation = switch (name) {
      'astoria_sources_list' => Operation.list,
      'astoria_source_contents' => Operation.contents,
      _ => Operation.search,
    };
    _cursor(
      args['cursor'],
      operation,
      _argumentBinding(args),
      source,
      source?.grant,
    );
  }

  Future<NavigationResult> _list(String name, Map<String, Object?> args) async {
    final domain = SourceDomain.values.byName(args['domain'] as String);
    final parent = args['parent'] == null
        ? null
        : _ref<_SourceRef>(args['parent']);
    if (parent != null) {
      await _fresh(parent, null);
      _checkpoint();
    }
    final binding = _argumentBinding(args);
    final cursor = _cursor(args['cursor'], Operation.list, binding, null, null);
    final page = await _await(
      () => repository.discover(
        domain,
        parent?.source.key,
        cursor,
        const WorkBound(),
      ),
      repo: true,
    );
    _checkpoint();
    _page(page);
    final pieces = <Object?>[];
    for (final observation in page.items) {
      if (observation.key.domain != domain ||
          (parent != null && observation.parent != parent.source.key)) {
        throw const _Failure('unavailable');
      }
      _observation(observation);
      var source = _sources[observation.key];
      if (source != null &&
          !source.source.snapshot.same(observation.snapshot)) {
        _invalidSources.add(observation.key);
        throw const _Failure('staleSource');
      }
      source ??= _SourceRef(observation);
      _sources[observation.key] = source;
      final handle = _issue(source);
      _sourceCurrent(source);
      pieces.add({
        'source': handle,
        'domain': domain.name,
        'label': domain.name,
        'state': observation.state.name,
        'activeAtListing': observation.activeAtListing,
        'historicalUse': 'unknown',
        'ownership': _binding(
          observation.binding,
          observation.key,
          discovery: true,
        ),
        'parent': args['parent'],
      });
    }
    if (parent != null) {
      await _fresh(parent, null);
      _checkpoint();
    }
    final next = _next(page, Operation.list, binding, null, null);
    return _result(
      _wire(
        name,
        pieces: pieces,
        complete: page.complete,
        next: next,
        reason: _reason(page),
      ),
      false,
    );
  }

  Future<NativeGrant> _approved(_SourceRef source, Selection? requested) async {
    await _fresh(source, source.grant);
    _checkpoint();
    if (source.grant != null) return source.grant!;
    if (_grants >= Limits.scopes) throw const _Failure('budgetExceeded');
    final observed = await _await(
      () => repository.observe(source.source.key, const WorkBound()),
      repo: true,
    );
    _checkpoint();
    if (observed == null ||
        observed.key != source.source.key ||
        !observed.snapshot.same(source.source.snapshot)) {
      _invalidSources.add(source.source.key);
      throw const _Failure('staleSource');
    }
    _observation(observed);
    final maximum = disclosureLimit - _spent;
    if (maximum <= 0) throw const _Failure('budgetExceeded');
    final grant = await _await(
      () => approval.request(
        ApprovalRequest(run, source.source, maximum, requested),
      ),
    );
    _checkpoint();
    if (grant == null) throw const _Failure('approvalRequired');
    if (!identical(grant.run, run) ||
        grant.source != source.source.key ||
        !grant.snapshot.same(source.source.snapshot) ||
        grant.disclosureBytes <= 0 ||
        grant.disclosureBytes > maximum ||
        !_scopeValid(grant.scope, source.source.key.domain) ||
        !_lease(grant)) {
      _invalidSources.add(source.source.key);
      throw const _Failure('approvalRequired');
    }
    source.grant = grant;
    _grants++;
    await _fresh(source, grant);
    _checkpoint();
    return grant;
  }

  _SelectionRef? _section(Object? handle, _SourceRef source) {
    if (handle == null) return null;
    final ref = _ref<_SelectionRef>(handle);
    if (!identical(ref.source, source) ||
        ref.descriptor.selection.kind != SelectionKind.section) {
      throw const _Failure('invalidReference');
    }
    _grantCurrent(source, ref.grant);
    return ref;
  }

  Future<NavigationResult> _contents(
    String name,
    Map<String, Object?> args,
  ) async {
    final source = _ref<_SourceRef>(args['source']);
    final section = _section(args['section'], source);
    final grant = await _approved(source, section?.descriptor.selection);
    _checkpoint();
    if (section != null) _within(source, grant, section.descriptor.selection);
    final binding = _argumentBinding(args);
    final cursor = _cursor(
      args['cursor'],
      Operation.contents,
      binding,
      source,
      grant,
    );
    final page = await _await(
      () => repository.contents(
        source.source,
        grant.scope,
        section?.descriptor.selection,
        cursor,
        const WorkBound(),
      ),
      repo: true,
    );
    _checkpoint();
    _page(page);
    final pieces = <Object?>[];
    final extents = <DisclosedExtent>[];
    for (final item in page.items) {
      _descriptor(item, source.source.key.domain);
      _within(source, grant, item.selection);
      if (section != null &&
          item.selection.sectionId != section.descriptor.selection.sectionId) {
        throw const _Failure('outOfScope');
      }
      final selector = _issue(_SelectionRef(source, grant, item));
      pieces.add({
        'selector': selector,
        'kind': item.kind.name,
        'label': item.kind.name,
        'state': item.state.name,
        'readable': item.selection.readable,
        'selectionKind': item.selection.kind.name,
        'binding': _binding(item.binding, source.source.key),
      });
      extents.add(DisclosedExtent(item.selection, item.binding));
    }
    final next = _next(page, Operation.contents, binding, source, grant);
    final stamp = await _await(projection.currentStamp);
    _checkpoint();
    return _publish(
      name,
      args,
      source,
      grant,
      stamp,
      _wire(
        name,
        pieces: pieces,
        complete: page.complete,
        next: next,
        reason: _reason(page),
      ),
      extents,
    );
  }

  Future<NavigationResult> _search(
    String name,
    Map<String, Object?> args,
  ) async {
    final source = _ref<_SourceRef>(args['source']);
    final section = _section(args['section'], source);
    final grant = await _approved(source, section?.descriptor.selection);
    _checkpoint();
    if (section != null) _within(source, grant, section.descriptor.selection);
    final literal = args['literal'] as String;
    final binding = _argumentBinding(args);
    final cursor = _cursor(
      args['cursor'],
      Operation.search,
      binding,
      source,
      grant,
    );
    final page = await _await(
      () => repository.search(
        source.source,
        grant.scope,
        literal,
        section?.descriptor.selection,
        cursor,
        const WorkBound(),
      ),
      repo: true,
    );
    _checkpoint();
    _page(page);
    _rawPage(page.items);
    final pieces = <Object?>[];
    final extents = <DisclosedExtent>[];
    ProjectionStamp? stamp;
    for (final record in page.items) {
      _record(record, source, grant);
      if (section != null &&
          record.selection.sectionId !=
              section.descriptor.selection.sectionId) {
        throw const _Failure('outOfScope');
      }
      if (record.payload is! String) throw const _Failure('unavailable');
      final projected = await _project(record);
      _checkpoint();
      stamp = _sameStamp(stamp, projected.stamp);
      final text = projected.payload as String;
      final index = text.indexOf(literal);
      if (index < 0) continue; // Redacted matches never disclose IDs/counts.
      final excerpt = _excerpt(text, index, index + literal.length);
      final descriptor = SectionDescriptor(
        record.selection,
        record.kind,
        state: record.state,
        binding: record.binding,
      );
      final selector = _issue(_SelectionRef(source, grant, descriptor));
      final matchStart = _scalarOffset(text, index);
      final matchEnd = _scalarOffset(text, index + literal.length);
      pieces.add({
        'selector': selector,
        'kind': record.kind.name,
        'state': record.state.name,
        'occurrence': 'first_visible_literal_per_record',
        'excerpt': excerpt.text,
        'citation': _citation(
          args['source'] as String,
          selector,
          source,
          record,
          excerpt.start,
          excerpt.end,
        ),
        'matchSpan': {'start': matchStart, 'end': matchEnd},
      });
      extents.add(
        DisclosedExtent(
          record.selection,
          record.binding,
          startScalar: excerpt.start,
          endScalar: excerpt.end,
        ),
      );
    }
    stamp ??= await _await(projection.currentStamp);
    _checkpoint();
    final next = _next(page, Operation.search, binding, source, grant);
    return _publish(
      name,
      args,
      source,
      grant,
      stamp!,
      _wire(
        name,
        pieces: pieces,
        complete: page.complete,
        next: next,
        reason: _reason(page),
      ),
      extents,
    );
  }

  Future<NavigationResult> _read(String name, Map<String, Object?> args) async {
    final source = _ref<_SourceRef>(args['source']);
    final rawRef = _ref<Object>(args['selector']);
    final before = (args['before'] as int?) ?? 0;
    final after = (args['after'] as int?) ?? 0;
    if (rawRef is _TextRef) {
      if (!identical(rawRef.source, source) || before != 0 || after != 0) {
        throw const _Failure('invalidReference');
      }
      _grantCurrent(source, rawRef.grant);
      await _fresh(source, rawRef.grant);
      _checkpoint();
      return _textResult(
        name,
        args,
        source,
        rawRef.grant,
        rawRef.record,
        rawRef.projected,
        rawRef.offset,
      );
    }
    if (rawRef is! _SelectionRef || !identical(rawRef.source, source)) {
      throw const _Failure('invalidReference');
    }
    final selected = rawRef.descriptor.selection;
    _grantCurrent(source, rawRef.grant);
    final grant = await _approved(source, selected);
    _checkpoint();
    _within(source, grant, selected);
    if (!selected.readable ||
        (selected.kind != SelectionKind.messageRange &&
            (before != 0 || after != 0))) {
      throw const _Failure('invalidArguments');
    }
    if (selected.range != null &&
        (selected.range!.start.ordinal - before <
                grant.scope.messages!.start.ordinal ||
            selected.range!.end.ordinal + after >
                grant.scope.messages!.end.ordinal ||
            selected.range!.end.ordinal -
                    selected.range!.start.ordinal +
                    1 +
                    before +
                    after >
                Limits.page)) {
      throw const _Failure('outOfScope');
    }
    final page = await _await(
      () => repository.read(
        source.source,
        grant.scope,
        ReadQuery(selected, before, after),
        const WorkBound(),
      ),
      repo: true,
    );
    _checkpoint();
    _page(page);
    _rawPage(page.items);
    // Read never silently treats an incomplete repository page as a complete block.
    if (!page.complete || page.next != null || page.exhaustedWork) {
      throw const _Failure('workExhausted');
    }
    _readMembership(page.items, selected, before, after);
    final projected = <ProjectedRecord>[];
    var projectedBytes = 0;
    ProjectionStamp? stamp;
    for (final record in page.items) {
      _record(record, source, grant);
      final item = await _project(record);
      _checkpoint();
      projectedBytes += _validateTree(
        item.payload,
        authored: true,
        byteLimit: Limits.projectedBytes,
      );
      if (projectedBytes > Limits.projectedBytes) {
        throw const _Failure('oversized');
      }
      stamp = _sameStamp(stamp, item.stamp);
      projected.add(item);
    }
    if (page.items.length == 1 && projected.single.payload is String) {
      return _textResult(
        name,
        args,
        source,
        grant,
        page.items.single,
        projected.single,
        0,
      );
    }
    final pieces = <Object?>[];
    final extents = <DisclosedExtent>[];
    for (var i = 0; i < page.items.length; i++) {
      final record = page.items[i];
      final selector = _issue(
        _SelectionRef(
          source,
          grant,
          SectionDescriptor(
            record.selection,
            record.kind,
            state: record.state,
            binding: record.binding,
          ),
        ),
      );
      final text = projected[i].payload;
      final end = text is String ? text.runes.length : null;
      pieces.add({
        'selector': selector,
        'kind': record.kind.name,
        'state': record.state.name,
        'role': record.role,
        'payload': text,
        'complete': true,
        'citation': _citation(
          args['source'] as String,
          selector,
          source,
          record,
          text is String ? 0 : null,
          end,
        ),
      });
      extents.add(
        DisclosedExtent(
          record.selection,
          record.binding,
          startScalar: text is String ? 0 : null,
          endScalar: end,
        ),
      );
    }
    // Oversized structured records/multi-message ranges are refused, not clipped.
    stamp ??= await _await(projection.currentStamp);
    _checkpoint();
    return _publish(
      name,
      args,
      source,
      grant,
      stamp!,
      _wire(name, pieces: pieces),
      extents,
    );
  }

  Future<NavigationResult> _textResult(
    String name,
    Map<String, Object?> args,
    _SourceRef source,
    NativeGrant grant,
    DataRecord record,
    ProjectedRecord projected,
    int offset,
  ) async {
    final text = projected.payload as String;
    final chunk = _textChunk(text, offset);
    final partial = chunk.endUtf16 < text.length;
    String? next;
    if (partial) {
      if (!_storedProjection.contains(projected)) {
        final bytes = utf8.encode(text).length;
        if (_material + bytes > Limits.retainedBytes) {
          throw const _Failure('budgetExceeded');
        }
        _storedProjection.add(projected);
        _material += bytes;
      }
      // Retain sanitized text and citation metadata, never the complete raw unit.
      final metadata = DataRecord(
        selection: record.selection,
        kind: record.kind,
        state: record.state,
        binding: record.binding,
        role: record.role,
        payload: null,
      );
      next = _issue(
        _TextRef(source, grant, metadata, projected, chunk.endUtf16),
      );
    }
    final selector = _issue(
      _SelectionRef(
        source,
        grant,
        SectionDescriptor(
          record.selection,
          record.kind,
          state: record.state,
          binding: record.binding,
        ),
      ),
    );
    final wire = _wire(
      name,
      pieces: [
        {
          'selector': selector,
          'kind': record.kind.name,
          'state': record.state.name,
          'role': record.role,
          'payload': chunk.text,
          'complete': offset == 0 && !partial,
          'citation': _citation(
            args['source'] as String,
            selector,
            source,
            record,
            chunk.start,
            chunk.end,
          ),
        },
      ],
      complete: !partial,
      partial: offset != 0 || partial,
      next: next,
      reason: partial ? 'partialText' : null,
    );
    return _publish(name, args, source, grant, projected.stamp, wire, [
      DisclosedExtent(
        record.selection,
        record.binding,
        startScalar: chunk.start,
        endScalar: chunk.end,
      ),
    ]);
  }

  Map<String, Object?> _citation(
    String sourceHandle,
    String selector,
    _SourceRef source,
    DataRecord record,
    int? start,
    int? end,
  ) => {
    'source': sourceHandle,
    'selector': selector,
    'domain': source.source.key.domain.name,
    'state': record.state.name,
    'disclosedSpan': start == null ? null : {'start': start, 'end': end},
    'binding': _binding(record.binding, source.source.key),
    'meaning': 'disclosed_text_not_historical_evidence',
  };

  Future<ProjectedRecord> _project(DataRecord record) async {
    final result = await _await(() => projection.project(record));
    _checkpoint();
    if (!result.complete || !_sameShape(record.payload, result.payload)) {
      throw const _Failure('unavailable');
    }
    _validateTree(
      result.payload,
      authored: true,
      byteLimit: Limits.projectedBytes,
    );
    return result;
  }

  Future<NavigationResult> _publish(
    String name,
    Map<String, Object?> args,
    _SourceRef source,
    NativeGrant grant,
    ProjectionStamp stamp,
    Map<String, Object?> wire,
    List<DisclosedExtent> extents,
  ) async {
    // Validate full nested shape and actual escaped JSON UTF-8 BEFORE provenance.
    final encoded = _encodeWire(wire);
    final candidate = WireCandidate(name, jsonEncode(args), wire, encoded);
    final wrapped = await _await(() => projection.wire(candidate));
    _checkpoint();
    if (!identical(wrapped.exactCandidate, candidate) ||
        !wrapped.stamp.same(stamp)) {
      throw const _Failure('staleProjection');
    }
    final envelopeJson = _encodeEnvelope(wrapped, candidate);
    final bytes = utf8.encode(envelopeJson).length;
    _grantCurrent(source, grant);
    if (_bodyResults >= Limits.bodyResults ||
        _spent + bytes > disclosureLimit ||
        source.spent + bytes > grant.disclosureBytes) {
      throw const _Failure('budgetExceeded');
    }
    await _fresh(source, grant);
    _checkpoint();
    final current = await _await(projection.currentStamp);
    _checkpoint();
    if (!current.same(stamp)) throw const _Failure('staleProjection');
    // Conservative reservation: even a failed durable admission consumes budget.
    _spent += bytes;
    source.spent += bytes;
    _bodyResults++;
    final entry = ProvenanceEntry(
      run: run,
      source: source.source,
      grant: grant,
      operation: name,
      argumentsJson: jsonEncode(args),
      exactWireJson: encoded,
      exactEnvelopeJson: envelopeJson,
      extents: extents,
      projection: stamp,
    );
    final receipt = await _await(() => provenance.append(entry));
    _checkpoint();
    if (!identical(receipt.exactEntry, entry) ||
        !receipt.durableEncrypted ||
        receipt.conflict) {
      throw const _Failure('provenanceFailed');
    }
    await _fresh(source, grant);
    _checkpoint();
    final after = await _await(projection.currentStamp);
    _checkpoint();
    if (!after.same(stamp)) throw const _Failure('staleProjection');
    _grantCurrent(source, grant);
    _retained.add(_Retained(source, grant, stamp, entry));
    return _result(wire, true, postEncoded: envelopeJson);
  }

  /// The ONLY source-body POST authority. Copies/cached provenance are not outcomes.
  /// Revalidates ALL retained disclosures on EVERY call, even results=[], including
  /// unrelated-tool/replay posts. No reusable permit is exposed. Host callback must
  /// preserve original registry/arguments/body custody and checkpoint its own awaits
  /// immediately before real transport POST. Engine never calls a provider itself.
  Future<bool> withPost(
    List<Object> candidates,
    Future<void> Function(PostEnvelope originals) dispatch,
  ) async {
    if (_busy) {
      _retired = true;
      return false;
    }
    _busy = true;
    try {
      _checkpoint();
      if (candidates.length > Limits.collection) {
        throw const _Failure('budgetExceeded');
      }
      final results = <NavigationResult>[];
      for (final candidate in candidates) {
        if (candidate is! NavigationResult || !_outcomes.contains(candidate)) {
          throw const _Failure('invalidCustody');
        }
        results.add(candidate);
      }
      // Deduplicate fence work, never evict or forget a disclosure.
      final checked = <_SourceRef>{};
      final stamp = await _await(projection.currentStamp);
      _checkpoint();
      for (final retained in _retained) {
        _grantCurrent(retained.source, retained.grant);
        if (!stamp.same(retained.projection)) {
          throw const _Failure('staleProjection');
        }
        if (checked.add(retained.source)) {
          await _fresh(retained.source, retained.grant);
          _checkpoint();
        }
      }
      // Check synchronous leases again after all async fences.
      for (final retained in _retained) {
        _grantCurrent(retained.source, retained.grant);
      }
      final after = await _await(projection.currentStamp);
      _checkpoint();
      if (!after.same(stamp)) throw const _Failure('staleProjection');
      for (final retained in _retained) {
        _grantCurrent(retained.source, retained.grant);
      }
      // Conservatively reserve retransmission of ALL retained source results,
      // even for an unrelated/replay POST with no explicit source candidates.
      // Generation already counted once. The host may account still more context.
      final charges = <_SourceRef, int>{};
      var total = 0;
      for (final retained in _retained) {
        final bytes = utf8.encode(retained.entry.exactEnvelopeJson).length;
        total += bytes;
        charges.update(
          retained.source,
          (old) => old + bytes,
          ifAbsent: () => bytes,
        );
      }
      if (_spent + total > disclosureLimit ||
          charges.entries.any(
            (entry) =>
                entry.key.spent + entry.value >
                entry.key.grant!.disclosureBytes,
          )) {
        throw const _Failure('budgetExceeded');
      }
      _spent += total;
      for (final entry in charges.entries) {
        entry.key.spent += entry.value;
      }
      await _await(() => dispatch(PostEnvelope._(results, run)));
      _checkpoint();
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  Object? _cursor(
    Object? handle,
    Operation operation,
    String binding,
    _SourceRef? source,
    NativeGrant? grant,
  ) {
    if (handle == null) return null;
    final cursor = _ref<_CursorRef>(handle);
    if (cursor.operation != operation ||
        cursor.binding != binding ||
        !identical(cursor.source, source) ||
        !identical(cursor.grant, grant)) {
      throw const _Failure('invalidReference');
    }
    if (source != null && grant != null) _grantCurrent(source, grant);
    return cursor.privateCursor;
  }

  String? _next<T>(
    Page<T> page,
    Operation operation,
    String binding,
    _SourceRef? source,
    NativeGrant? grant,
  ) => page.next == null
      ? null
      : _issue(_CursorRef(operation, binding, source, grant, page.next!));

  void _within(_SourceRef source, NativeGrant grant, Selection selection) {
    _grantCurrent(source, grant);
    final scope = grant.scope;
    final range = selection.range;
    if ((selection.recordId != null &&
            scope.excludedRecords.contains(selection.recordId)) ||
        (range != null &&
            (scope.messages == null ||
                !scope.messages!.contains(range) ||
                scope.excludedRecords.contains(range.start.messageId) ||
                scope.excludedRecords.contains(range.end.messageId))) ||
        (range == null && !scope.sections.contains(selection.sectionId))) {
      throw const _Failure('outOfScope');
    }
  }

  void _record(DataRecord record, _SourceRef source, NativeGrant grant) {
    if (!record.admitted || !record.shapeKnown || !record.completeUnit) {
      throw const _Failure('unavailable');
    }
    _descriptor(
      SectionDescriptor(
        record.selection,
        record.kind,
        state: record.state,
        binding: record.binding,
      ),
      source.source.key.domain,
    );
    _within(source, grant, record.selection);
    if (!record.selection.readable) throw const _Failure('unavailable');
    if (record.role != null &&
        !const {'user', 'assistant', 'system'}.contains(record.role)) {
      throw const _Failure('unavailable');
    }
    if (source.source.key.domain == SourceDomain.game) {
      final range = record.selection.range;
      if (range == null ||
          !range.start.same(range.end) ||
          record.binding.anchor == null ||
          !range.start.same(record.binding.anchor!) ||
          !const {'user', 'assistant', 'system'}.contains(record.role) ||
          record.payload is! String ||
          record.state != SourceState.active ||
          grant.scope.excludedRecords.contains(range.start.messageId)) {
        throw const _Failure('unavailable');
      }
    }
    _validateTree(record.payload, authored: true, byteLimit: Limits.rawBytes);
  }

  void _readMembership(
    List<DataRecord> records,
    Selection selection,
    int before,
    int after,
  ) {
    if (selection.range == null) {
      if (records.length != 1 || !selection.same(records.single.selection)) {
        throw const _Failure('unavailable');
      }
      return;
    }
    final range = selection.range!;
    final first = range.start.ordinal - before;
    final last = range.end.ordinal + after;
    if (records.length != last - first + 1) throw const _Failure('unavailable');
    for (var i = 0; i < records.length; i++) {
      final actual = records[i].selection.range;
      if (actual == null ||
          actual.start.ordinal != first + i ||
          !actual.start.same(actual.end) ||
          (actual.start.ordinal == range.start.ordinal &&
              !actual.start.same(range.start)) ||
          (actual.end.ordinal == range.end.ordinal &&
              !actual.end.same(range.end))) {
        throw const _Failure('unavailable');
      }
    }
  }
}

String _argumentBinding(Map<String, Object?> args) {
  final keys = args.keys.where((key) => key != 'cursor').toList()..sort();
  return jsonEncode({for (final key in keys) key: args[key]});
}

bool _validHandle(String handle) =>
    handle.length <= 128 && RegExp(r'^h_[0-9a-f]{48}$').hasMatch(handle);

void _validateArguments(String name, Map<String, Object?> args) {
  final allowed = toolManifest[name]!;
  if (args.length > allowed.length ||
      args.keys.any((key) => !allowed.containsKey(key))) {
    throw const _Failure('invalidArguments');
  }
  final required = name == 'astoria_sources_list'
      ? ['domain']
      : name == 'astoria_source_read'
      ? ['source', 'selector']
      : name == 'astoria_source_search'
      ? ['source', 'literal']
      : ['source'];
  if (required.any((key) => !args.containsKey(key) || args[key] == null)) {
    throw const _Failure('invalidArguments');
  }
  for (final entry in args.entries) {
    final value = entry.value;
    if (entry.key == 'before' || entry.key == 'after') {
      if (value is! int || value < 0 || value > 2) {
        throw const _Failure('invalidArguments');
      }
    } else if (entry.key == 'domain') {
      if (value is! String ||
          !SourceDomain.values.any((d) => d.name == value)) {
        throw const _Failure('invalidArguments');
      }
    } else if (entry.key == 'literal') {
      if (value is! String ||
          value.length > Limits.literalScalars * 2 ||
          !_validScalars(value) ||
          value.isEmpty ||
          value.runes.length > Limits.literalScalars) {
        throw const _Failure('invalidArguments');
      }
    } else if (value is! String || !_validHandle(value)) {
      // Explicit null/coercions are not optional omission.
      throw const _Failure('invalidArguments');
    }
  }
}

void _observation(SourceObservation source) {
  if (source.key.nativeId.isEmpty ||
      source.snapshot.incarnation.isEmpty ||
      source.snapshot.revision < 0) {
    throw const _Failure('unavailable');
  }
  _privateId(source.key.nativeId);
  _privateId(source.snapshot.incarnation);
  if (source.snapshot.privateIntegrity != null) {
    _privateId(source.snapshot.privateIntegrity!);
  }
  if ((source.key.domain == SourceDomain.ordinaryPreset ||
          source.key.domain == SourceDomain.studioPreset) &&
      source.state != SourceState.currentSaved) {
    throw const _Failure('unavailable');
  }
  if (source.key.domain == SourceDomain.ledgerState &&
      (source.binding.anchor != null ||
          source.binding.evidence.range != null ||
          source.binding.evidence.state == EvidenceState.attested)) {
    throw const _Failure('unavailable');
  }
  if (source.key.domain == SourceDomain.savedSummary &&
      (source.binding.anchor != null ||
          source.binding.evidence.range != null ||
          source.binding.evidence.state == EvidenceState.attested)) {
    throw const _Failure('unavailable');
  }
  _snapshotAnchor(source.key.domain, source.state, source.binding);
  _checkBinding(source.binding);
}

const _domainSections = <SourceDomain, Set<SectionKind>>{
  SourceDomain.game: {SectionKind.activeMessages},
  SourceDomain.ordinaryPreset: {
    SectionKind.presetBlock,
    SectionKind.regexDefinitions,
    SectionKind.reasoning,
    SectionKind.templates,
  },
  SourceDomain.studioPreset: {
    SectionKind.studioBlock,
    SectionKind.studioAgents,
    SectionKind.runtime,
    SectionKind.settings,
    SectionKind.templates,
  },
  SourceDomain.memory: {
    SectionKind.memoryEntries,
    SectionKind.memoryEntry,
    SectionKind.memoryRevision,
    SectionKind.memoryDraft,
    SectionKind.memoryDerived,
    SectionKind.settings,
  },
  SourceDomain.savedSummary: {
    SectionKind.summaryText,
    SectionKind.summaryTemplate,
  },
  SourceDomain.ledgerState: {SectionKind.ledgerTrackers},
  SourceDomain.ledgerSnapshot: {SectionKind.ledgerSnapshot},
  SourceDomain.reconciliation: {
    SectionKind.reconciliationCheckpoint,
    SectionKind.reconciliationSavedResult,
    SectionKind.reconciliationEvidence,
  },
  SourceDomain.characterKnowledge: {SectionKind.knowledgeFact},
};

void _descriptor(SectionDescriptor descriptor, SourceDomain domain) {
  final selection = descriptor.selection;
  _privateId(selection.sectionId);
  if (selection.recordId != null) _privateId(selection.recordId!);
  if (selection.range != null) {
    _checkAnchor(selection.range!.start);
    _checkAnchor(selection.range!.end);
  }
  if (!_domainSections[domain]!.contains(descriptor.kind) ||
      selection.sectionId.isEmpty ||
      (selection.kind == SelectionKind.record &&
          (selection.recordId?.isEmpty ?? true)) ||
      (selection.kind == SelectionKind.messageRange &&
          (selection.range == null ||
              !selection.range!.valid ||
              selection.range!.end.ordinal - selection.range!.start.ordinal >=
                  Limits.page)) ||
      (domain == SourceDomain.game &&
          selection.kind != SelectionKind.messageRange)) {
    throw const _Failure('unavailable');
  }
  if ((domain == SourceDomain.ordinaryPreset ||
          domain == SourceDomain.studioPreset) &&
      descriptor.state != SourceState.currentSaved) {
    throw const _Failure('unavailable');
  }
  if ((domain == SourceDomain.ledgerState ||
          domain == SourceDomain.savedSummary) &&
      (descriptor.binding.anchor != null ||
          descriptor.binding.evidence.range != null ||
          descriptor.binding.evidence.state == EvidenceState.attested)) {
    throw const _Failure('unavailable');
  }
  _snapshotAnchor(domain, descriptor.state, descriptor.binding);
  _checkBinding(descriptor.binding);
}

void _snapshotAnchor(SourceDomain domain, SourceState state, Binding binding) {
  if (domain != SourceDomain.ledgerSnapshot) return;
  if (((state == SourceState.historicalCommitted ||
              state == SourceState.tentative) &&
          binding.anchor == null &&
          binding.savedAnchor == null) ||
      (state == SourceState.bootstrap &&
          (binding.anchor != null || binding.savedAnchor != null)) ||
      (binding.savedAnchor != null &&
          binding.anchor == null &&
          !const {
            EvidenceState.missing,
            EvidenceState.unknown,
          }.contains(binding.evidence.state))) {
    throw const _Failure('unavailable');
  }
}

void _checkBinding(Binding binding) {
  if (binding.savedAnchor case final saved?) {
    _privateId(saved.messageId);
    _privateId(saved.swipe);
    _privateId(saved.agentSwipe);
    final active = binding.anchor;
    if (active != null &&
        (active.messageId != saved.messageId ||
            (active.swipe ?? '0') != saved.swipe ||
            (active.agentSwipe ?? '0') != saved.agentSwipe)) {
      throw const _Failure('unavailable');
    }
  }
  for (final id in [
    binding.sessionId,
    binding.characterId,
    binding.knowerId,
    binding.subjectId,
  ]) {
    if (id != null) _privateId(id);
  }
  for (final anchor in [
    binding.anchor,
    binding.evidence.range?.start,
    binding.evidence.range?.end,
  ]) {
    if (anchor == null) continue;
    _checkAnchor(anchor);
  }
  if ((binding.evidence.state == EvidenceState.attested &&
          binding.evidence.range == null) ||
      (binding.evidence.range != null && !binding.evidence.range!.valid) ||
      (binding.anchor != null && binding.anchor!.ordinal < 0)) {
    throw const _Failure('unavailable');
  }
}

void _privateId(String id) {
  if (!_safePrivateId(id)) {
    throw const _Failure('unavailable');
  }
}

bool _safePrivateId(String id) =>
    id.isNotEmpty &&
    id.length <= Limits.metadataBytes &&
    _validScalars(id) &&
    utf8.encode(id).length <= Limits.metadataBytes;

void _checkAnchor(Anchor anchor) {
  _privateId(anchor.messageId);
  if (anchor.swipe != null) _privateId(anchor.swipe!);
  if (anchor.agentSwipe != null) _privateId(anchor.agentSwipe!);
  if (anchor.ordinal < 0) throw const _Failure('unavailable');
}

bool _scopeValid(FrozenScope scope, SourceDomain domain) =>
    scope.excludedRecords.length <= Limits.collection &&
    scope.excludedRecords.every(_safePrivateId) &&
    (domain == SourceDomain.game
        ? scope.sections.isEmpty &&
              scope.messages != null &&
              scope.messages!.valid &&
              [scope.messages!.start, scope.messages!.end].every(
                (anchor) =>
                    _safePrivateId(anchor.messageId) &&
                    (anchor.swipe == null || _safePrivateId(anchor.swipe!)) &&
                    (anchor.agentSwipe == null ||
                        _safePrivateId(anchor.agentSwipe!)),
              )
        : scope.messages == null &&
              scope.sections.isNotEmpty &&
              scope.sections.length <= Limits.collection &&
              scope.sections.every(_safePrivateId));

void _page<T>(Page<T> page) {
  if (page.items.length > Limits.page ||
      page.candidatesExamined < 0 ||
      page.candidatesExamined > Limits.candidates ||
      (page.complete && (page.next != null || page.exhaustedWork)) ||
      (!page.complete && page.next == null && !page.exhaustedWork)) {
    throw const _Failure('unavailable');
  }
}

String? _reason<T>(Page<T> page) => page.exhaustedWork
    ? 'workExhausted'
    : !page.complete
    ? 'pageLimit'
    : null;

void _rawPage(List<DataRecord> records) {
  var bytes = 0;
  for (final record in records) {
    _validateTree(record.payload, authored: true, byteLimit: Limits.rawBytes);
    bytes += record.payload is String
        ? utf8.encode(record.payload as String).length
        : utf8.encode(jsonEncode(record.payload)).length;
    if (bytes > Limits.rawBytes) throw const _Failure('oversized');
  }
}

ProjectionStamp _sameStamp(ProjectionStamp? previous, ProjectionStamp next) {
  if (previous != null && !previous.same(next)) {
    throw const _Failure('staleProjection');
  }
  return next;
}

bool _validScalars(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= text.length) return false;
      final low = text.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

Object? _freeze(Object? value) {
  var nodes = 0;
  Object? copy(Object? node, int depth) {
    if (++nodes > Limits.nodes || depth > Limits.depth) {
      throw const _Failure('oversized');
    }
    if (node is Map) {
      if (node.length > Limits.collection) throw const _Failure('oversized');
      return Map<String, Object?>.unmodifiable(
        node.map((key, value) {
          if (key is! String) throw const _Failure('unavailable');
          return MapEntry(key, copy(value, depth + 1));
        }),
      );
    }
    if (node is List) {
      if (node.length > Limits.collection) throw const _Failure('oversized');
      return List<Object?>.unmodifiable(node.map((v) => copy(v, depth + 1)));
    }
    if (node == null || node is String || node is bool || node is num) {
      return node;
    }
    throw const _Failure('unavailable');
  }

  return copy(value, 0);
}

int _validateTree(
  Object? value, {
  required bool authored,
  required int byteLimit,
  bool wire = false,
  List<Object> ownedBodies = const [],
}) {
  var nodes = 0;
  var bytes = 0;
  void visit(Object? node, int depth, bool body) {
    if (ownedBodies.any((original) => identical(original, node))) body = true;
    if (++nodes > Limits.nodes || depth > Limits.depth) {
      throw const _Failure('oversized');
    }
    if (node is String) {
      if (node.length > byteLimit ||
          (!body && node.length > Limits.metadataBytes)) {
        throw const _Failure('oversized');
      }
      if (!_validScalars(node)) throw const _Failure('unavailable');
      final length = utf8.encode(node).length;
      if (!body && length > Limits.metadataBytes) {
        throw const _Failure('oversized');
      }
      bytes += length;
    } else if (node is Map) {
      if (node.length > Limits.collection) throw const _Failure('oversized');
      for (final entry in node.entries) {
        if (entry.key is! String) throw const _Failure('unavailable');
        visit(entry.key, depth + 1, false);
        visit(
          entry.value,
          depth + 1,
          body ||
              (wire &&
                  depth == 2 &&
                  (entry.key == 'payload' || entry.key == 'excerpt')),
        );
      }
    } else if (node is List) {
      if (node.length > Limits.collection) throw const _Failure('oversized');
      for (final item in node) {
        visit(item, depth + 1, body);
      }
    } else if (node is num) {
      if (!node.isFinite) throw const _Failure('unavailable');
      bytes += 24;
    } else if (node == null || node is bool) {
      bytes += 5;
    } else {
      throw const _Failure('unavailable');
    }
    if (bytes > byteLimit) throw const _Failure('oversized');
  }

  visit(value, 0, authored);
  return bytes;
}

String _encodeWire(Map<String, Object?> wire) {
  _validateTree(wire, authored: false, byteLimit: Limits.wireBytes, wire: true);
  final json = jsonEncode(wire);
  if (utf8.encode(json).length > Limits.wireBytes) {
    throw const _Failure('oversized');
  }
  return json;
}

String _encodeEnvelope(ProjectedWire wrapped, WireCandidate candidate) {
  var occurrences = 0;
  var nodes = 0;
  void find(Object? node, int depth) {
    if (++nodes > Limits.nodes || depth > Limits.depth) {
      throw const _Failure('oversized');
    }
    if (identical(node, candidate.wire) || identical(node, candidate.encoded)) {
      occurrences++;
      return;
    }
    if (node is Map) {
      if (node.length > Limits.collection) throw const _Failure('oversized');
      for (final value in node.values) {
        find(value, depth + 1);
      }
    } else if (node is List) {
      if (node.length > Limits.collection) throw const _Failure('oversized');
      for (final value in node) {
        find(value, depth + 1);
      }
    }
  }

  find(wrapped.fullResult, 0);
  if (occurrences != 1) throw const _Failure('invalidCustody');
  _validateTree(
    wrapped.fullResult,
    authored: false,
    byteLimit: Limits.wireBytes,
    ownedBodies: [candidate.wire, candidate.encoded],
  );
  final encoded = jsonEncode(wrapped.fullResult);
  if (utf8.encode(encoded).length > Limits.wireBytes) {
    throw const _Failure('oversized');
  }
  return encoded;
}

bool _sameShape(Object? raw, Object? projected) {
  if (raw is String) return projected is String;
  if (raw is Map) {
    return projected is Map &&
        raw.length == projected.length &&
        raw.keys.every(
          (key) =>
              projected.containsKey(key) &&
              _sameShape(raw[key], projected[key]),
        );
  }
  if (raw is List) {
    return projected is List &&
        raw.length == projected.length &&
        List.generate(
          raw.length,
          (i) => i,
        ).every((i) => _sameShape(raw[i], projected[i]));
  }
  return raw == projected;
}

int _scalarOffset(String text, int utf16) {
  if (utf16 < 0 ||
      utf16 > text.length ||
      (utf16 < text.length &&
          text.codeUnitAt(utf16) >= 0xdc00 &&
          text.codeUnitAt(utf16) <= 0xdfff)) {
    throw const _Failure('unavailable');
  }
  return text.substring(0, utf16).runes.length;
}

class _Chunk {
  final String text;
  final int start;
  final int end;
  final int endUtf16;
  const _Chunk(this.text, this.start, this.end, this.endUtf16);
}

_Chunk _textChunk(String text, int offset) {
  final start = _scalarOffset(text, offset);
  var end = offset;
  var escaped = 2; // JSON quotes
  var escapedAgain = 2;
  var scalars = 0;
  while (end < text.length) {
    final unit = text.codeUnitAt(end);
    final width = unit >= 0xd800 && unit <= 0xdbff ? 2 : 1;
    final scalar = text.substring(end, end + width);
    final encoded = jsonEncode(scalar);
    final cost = utf8.encode(encoded).length - 2;
    final again =
        utf8
            .encode(jsonEncode(encoded.substring(1, encoded.length - 1)))
            .length -
        2;
    if (escaped + cost > Limits.partialEscapedBytes ||
        escapedAgain + again > Limits.partialEscapedBytes) {
      break;
    }
    escaped += cost;
    escapedAgain += again;
    end += width;
    scalars++;
  }
  if (end == offset && offset < text.length) throw const _Failure('oversized');
  return _Chunk(text.substring(offset, end), start, start + scalars, end);
}

_Chunk _excerpt(String text, int matchStart, int matchEnd) {
  final startScalar = _scalarOffset(text, matchStart);
  final endScalar = _scalarOffset(text, matchEnd);
  final scalars = text.runes.toList(growable: false);
  var start = max(0, startScalar - 64);
  var end = min(scalars.length, start + Limits.excerptScalars);
  if (end < endScalar) {
    end = endScalar;
    start = max(0, end - Limits.excerptScalars);
  }
  var excerpt = String.fromCharCodes(scalars.sublist(start, end));
  while (utf8.encode(excerpt).length > Limits.excerptBytes) {
    if (end > endScalar) {
      end--;
    } else if (start < startScalar) {
      start++;
    } else {
      throw const _Failure('oversized');
    }
    excerpt = String.fromCharCodes(scalars.sublist(start, end));
  }
  return _Chunk(excerpt, start, end, 0);
}
