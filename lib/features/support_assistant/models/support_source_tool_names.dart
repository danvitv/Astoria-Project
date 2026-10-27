/// Source navigation and local preparation are enabled in production.
/// An explicit false define remains an opt-out, not a source permission.
const supportSourceNavigationExperimentalEnabled = bool.fromEnvironment(
  'ASTORIA_SOURCE_NAVIGATION_EXPERIMENTAL',
  defaultValue: true,
);

/// Finite source-navigation surface. These names confer no source authority;
/// the original native run still owns approval, snapshots and result custody.
abstract final class SupportSourceToolNames {
  static const list = 'astoria_sources_list';
  static const contents = 'astoria_source_contents';
  static const search = 'astoria_source_search';
  static const read = 'astoria_source_read';
  static const all = {list, contents, search, read};
  static const body = {contents, search, read};
}
