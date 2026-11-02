class RecalledMessageChunk {
  final String text;
  final List<String> messageIds;
  final String? ledgerRange;
  final String? entryId;
  final int chunkIndex;
  final double? score;
  final String? rawText;

  const RecalledMessageChunk({
    required this.text,
    this.messageIds = const [],
    this.ledgerRange,
    this.entryId,
    this.chunkIndex = 0,
    this.score,
    this.rawText,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'messageIds': messageIds,
    if (ledgerRange != null) 'ledgerRange': ledgerRange,
    if (entryId != null) 'entryId': entryId,
    'chunkIndex': chunkIndex,
    if (score != null) 'score': score,
    if (rawText != null) 'rawText': rawText,
  };

  factory RecalledMessageChunk.fromJson(Map<String, dynamic> json) =>
      RecalledMessageChunk(
        text: json['text'] as String? ?? '',
        messageIds: (json['messageIds'] as List? ?? const []).cast<String>(),
        ledgerRange: json['ledgerRange'] as String?,
        entryId: json['entryId'] as String?,
        chunkIndex: json['chunkIndex'] as int? ?? 0,
        score: (json['score'] as num?)?.toDouble(),
        rawText: json['rawText'] as String?,
      );
}
