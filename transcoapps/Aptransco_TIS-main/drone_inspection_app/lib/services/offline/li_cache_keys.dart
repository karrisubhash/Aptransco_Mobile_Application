/// Canonical cache keys for the line-inspection read endpoints.
///
/// Kept in one place so the read layer ([LineInspectionApi]) and the optimistic
/// write layer ([OfflineActions]) agree on exactly which file a resource lives
/// in. Keys use only `[A-Za-z0-9_]` so they map 1:1 to file names and share
/// stable prefixes (see `LocalStore.patchCachesWithPrefix`).
class LiCacheKeys {
  static String _n(Object? v) => v == null ? 'x' : v.toString();

  static const catalog = 'li_catalog';
  static const linesAll = 'li_lines_all';
  static const subdivisions = 'li_subdivisions';

  static String towers(int lineId) => 'li_towers_$lineId';

  static const inspectionsPrefix = 'li_insp_';

  /// The `_by_<id>` suffix is appended only when scoping to one inspector, so
  /// every unscoped key keeps the exact name it had before that dimension
  /// existed — an installed app's caches stay readable across the upgrade.
  static String inspections(
      {int? subdivision, int? line, int? tower, String? inspector}) {
    final base = 'li_insp_${_n(subdivision)}_${_n(line)}_${_n(tower)}';
    final by = _slug(inspector ?? '');
    return by.isEmpty ? base : '${base}_by_$by';
  }

  /// Keys must stay `[A-Za-z0-9_]` to map 1:1 onto file names, so an employee id
  /// contributes only those characters.
  static String _slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');

  static const inspectionDetailPrefix = 'li_insp_detail_';
  static String inspectionDetail(int id) => 'li_insp_detail_$id';

  static const ticketsPrefix = 'li_tickets_';
  static String tickets(
          {String? status, int? subdivision, int? line, int? tower}) =>
      'li_tickets_${_n(status)}_${_n(subdivision)}_${_n(line)}_${_n(tower)}';

  static const supportPrefix = 'li_support_';
  static String support({int? subdivision}) => 'li_support_${_n(subdivision)}';

  static String dashboard({int? subdivision}) => 'li_dash_${_n(subdivision)}';
}
