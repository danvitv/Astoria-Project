/// Writer cadence is separate from the three-reconciliation Collector batch.
/// Historical automatic batches remain recoverable; new automatic work always
/// uses current. Explicit manual runs retain their existing input window.
enum CardEvolutionWriterCadence {
  historicalTwoCollectors(2),
  fiveCollectors(5);

  const CardEvolutionWriterCadence(this.collectorCount);

  static const current = fiveCollectors;
  static const manualWindow = historicalTwoCollectors;

  final int collectorCount;

  static CardEvolutionWriterCadence? forSavedRunCount(
    int runCount, {
    required int reconciliationsPerCollector,
  }) {
    for (final cadence in values) {
      if (cadence.collectorCount * reconciliationsPerCollector == runCount) {
        return cadence;
      }
    }
    return null;
  }
}
