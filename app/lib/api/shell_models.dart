/// One line of the alerts bell (GET /api/v1/alerts).
class AlertItem {
  AlertItem.fromJson(Map<String, dynamic> j)
      : kind = j['kind'] as String? ?? '',
        severity = j['severity'] as String? ?? 'warning',
        title = j['title'] as String? ?? '',
        count = (j['count'] as num?)?.toInt() ?? 0,
        examples = [for (final e in (j['examples'] as List? ?? const [])) e.toString()],
        target = j['target'] as String? ?? '';

  final String kind;
  final String severity; // critical | warning
  final String title;
  final int count;
  final List<String> examples;
  final String target; // module key to open

  bool get critical => severity == 'critical';
}
