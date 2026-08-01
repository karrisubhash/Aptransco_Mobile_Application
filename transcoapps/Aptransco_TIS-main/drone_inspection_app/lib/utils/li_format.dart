/// Human date formatting for the record screens.
///
/// Hand-rolled rather than reaching for `intl`: that package is only a
/// *transitive* dependency here, so importing it directly would mean depending
/// on something no `pubspec.yaml` declares — it could vanish on any upgrade.
///
/// Every function takes the raw ISO-8601 string the API sends and returns the
/// input unchanged if it will not parse, so a malformed server value degrades to
/// something readable instead of throwing inside a list builder.
library;

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// A short, scannable day label: `Today`, `Yesterday`, `12 Jul`, or
/// `12 Jul 2025` once the year differs from the current one.
///
/// [now] is injectable so this is testable without freezing the clock.
String liDayLabel(String iso, {DateTime? now}) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final at = parsed.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final dayMonth = '${at.day} ${_months[at.month - 1]}';
  return at.year == today.year ? dayMonth : '$dayMonth ${at.year}';
}

/// [liDayLabel] plus the clock time, for a line where the exact moment matters.
String liDayTimeLabel(String iso, {DateTime? now}) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final at = parsed.toLocal();
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return '${liDayLabel(iso, now: now)} · $hh:$mm';
}

/// Coarse elapsed time, for an at-a-glance age: `4h`, `5d`, `3w`, `7mo`, `2y`.
///
/// Deliberately blunt — on a defect backlog the useful signal is the order of
/// magnitude ("this has been open for months"), not the exact interval. Returns
/// an empty string for a future or unparseable timestamp, so callers can just
/// omit it.
String liAgeLabel(String iso, {DateTime? now}) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final d = (now ?? DateTime.now()).toLocal().difference(parsed.toLocal());
  if (d.isNegative) return '';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 14) return '${d.inDays}d';
  if (d.inDays < 60) return '${(d.inDays / 7).floor()}w';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
  return '${(d.inDays / 365).floor()}y';
}
